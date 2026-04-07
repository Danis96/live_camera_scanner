import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:docx_to_text/docx_to_text.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'gemma_vision_service.dart';

// ---------------------------------------------------------------------------
// App entry-point
// ---------------------------------------------------------------------------

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LiveTextScannerApp());
}

class LiveTextScannerApp extends StatelessWidget {
  const LiveTextScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Text Scanner',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF136F63),
          brightness: Brightness.light,
        ),
      ),
      home: const AppShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// AppShell — bottom-nav wrapper for the two top-level pages
// ---------------------------------------------------------------------------

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const _pages = <Widget>[
    LiveTextScannerPage(),
    ImageInterpretationPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => _selectedIndex = index),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner),
            label: 'Live Scanner',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            selectedIcon: Icon(Icons.auto_awesome),
            label: 'AI Interpret',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ImageInterpretationPage
// ---------------------------------------------------------------------------

/// A dedicated page that lets the user take or pick a photo, then sends it
/// to the Gemma vision API for free on-device interpretation.
class ImageInterpretationPage extends StatefulWidget {
  const ImageInterpretationPage({super.key});

  @override
  State<ImageInterpretationPage> createState() =>
      _ImageInterpretationPageState();
}

class _ImageInterpretationPageState extends State<ImageInterpretationPage> {
  // ── Replace with your free key from https://aistudio.google.com/app/apikey
  static const _apiKey = 'AIzaSyA9xGOimKTpYS7fRhYaevUXJ-YKETkma-k';

  final _picker = ImagePicker();
  final _promptController = TextEditingController();
  final _apiKeyController = TextEditingController(text: _apiKey);

  late GemmaVisionService _service;

  Uint8List? _imageBytes;
  String? _imageMimeType;
  String? _imageName;

  bool _isInterpreting = false;
  GemmaInterpretationResult? _lastResult;
  String _statusMessage = 'Pick or capture an image to get started.';

  @override
  void initState() {
    super.initState();
    _service = GemmaVisionService(
      config: GemmaVisionConfig(apiKey: _apiKey),
    );
  }

  @override
  void dispose() {
    _promptController.dispose();
    _apiKeyController.dispose();
    _service.dispose();
    super.dispose();
  }

  // ── Image selection ───────────────────────────────────────────────────────

  Future<void> _pickFromGallery() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    await _loadPickedFile(file);
  }

  Future<void> _captureFromCamera() async {
    final file = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    await _loadPickedFile(file);
  }

  Future<void> _loadPickedFile(XFile file) async {
    final bytes = await file.readAsBytes();
    final ext = file.name.split('.').last.toLowerCase();
    final mime = switch (ext) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => 'image/jpeg',
    };

    setState(() {
      _imageBytes = bytes;
      _imageMimeType = mime;
      _imageName = file.name;
      _lastResult = null;
      _statusMessage =
      'Image loaded (${(bytes.length / 1024).toStringAsFixed(1)} KB). '
          'Tap Interpret to send it to Gemma.';
    });
  }

  // ── Interpretation ────────────────────────────────────────────────────────

  Future<void> _interpret() async {
    final bytes = _imageBytes;
    if (bytes == null) {
      setState(() {
        _statusMessage = 'Please select an image first.';
      });
      return;
    }

    // Rebuild service if the user changed the API key in the settings field
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      setState(() {
        _statusMessage = 'Enter your Gemma API key above before interpreting.';
      });
      return;
    }

    _service.dispose();
    _service = GemmaVisionService(
      config: GemmaVisionConfig(apiKey: key),
    );

    setState(() {
      _isInterpreting = true;
      _lastResult = null;
      _statusMessage = 'Sending image to Gemma ${_service.config.model}…';
    });

    final prompt = _promptController.text.trim();
    final result = await _service.interpretImage(
      imageBytes: bytes,
      mimeType: _imageMimeType ?? 'image/jpeg',
      prompt: prompt.isNotEmpty ? prompt : null,
    );

    if (!mounted) return;
    setState(() {
      _isInterpreting = false;
      _lastResult = result;
      _statusMessage = switch (result) {
        GemmaInterpretationSuccess s =>
        'Interpreted with ${s.model}'
            '${s.totalTokenCount != null ? ' · ${s.totalTokenCount} tokens' : ''}.',
        GemmaInterpretationApiError e =>
        'API error ${e.statusCode}: ${e.message}',
        GemmaInterpretationException e =>
        'Exception: ${e.error}',
      };
    });
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color(0xFFF0FBF8),
            Color(0xFFF8F7F2),
            Color(0xFFE2F4EE),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildHero(),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 720;
                      if (isWide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(flex: 5, child: _buildImagePanel()),
                            const SizedBox(width: 20),
                            Expanded(flex: 6, child: _buildResultPanel()),
                          ],
                        );
                      }
                      return Column(
                        children: <Widget>[
                          _buildImagePanel(),
                          const SizedBox(height: 20),
                          _buildResultPanel(),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFCFE7E1)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x140F172A),
            blurRadius: 28,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFDDF4EC),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'AI Image Interpretation · Powered by Gemma',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF115E59),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Take or pick a photo, ask a question, and let Gemma describe what it sees.',
            style: TextStyle(
              fontSize: 26,
              height: 1.15,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _statusMessage,
            style: const TextStyle(
              fontSize: 15,
              height: 1.45,
              color: Color(0xFF334155),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Image',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          _buildImagePreview(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _isInterpreting ? null : _captureFromCamera,
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Camera'),
              ),
              OutlinedButton.icon(
                onPressed: _isInterpreting ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // API key field
          const Text(
            'Gemma API key',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Paste your Google AI Studio API key',
              prefixIcon: Icon(Icons.vpn_key_outlined),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Free key at aistudio.google.com/app/apikey',
            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 20),
          // Custom prompt
          const Text(
            'Question / prompt (optional)',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _promptController,
            maxLines: 3,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText:
              'e.g. "What language is the text?" or leave blank for a full description.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed:
            _isInterpreting || _imageBytes == null ? null : _interpret,
            icon: _isInterpreting
                ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
                : const Icon(Icons.auto_awesome),
            label: Text(_isInterpreting ? 'Interpreting…' : 'Interpret'),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreview() {
    final bytes = _imageBytes;

    if (bytes == null) {
      return Container(
        height: 220,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFFCBD5E1),
            style: BorderStyle.solid,
          ),
        ),
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.image_outlined, size: 48, color: Color(0xFF94A3B8)),
            SizedBox(height: 12),
            Text(
              'No image selected',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ],
        ),
      );
    }

    return Stack(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.memory(
            bytes,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xCC0F172A),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              _imageName ?? 'image',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResultPanel() {
    return _panel(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
      const Text(
      "Gemma's response",
      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
    ),
    const SizedBox(height: 16),
    _buildResultContent(),
    ],
    ),
    );
  }

  Widget _buildResultContent() {
    if (_isInterpreting) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Column(
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Sending image to Gemma…'),
            ],
          ),
        ),
      );
    }

    final result = _lastResult;

    if (result == null) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 160),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Text(
          'The interpretation will appear here after you tap Interpret.',
          style: TextStyle(color: Color(0xFF64748B), fontSize: 15, height: 1.6),
        ),
      );
    }

    return switch (result) {
      GemmaInterpretationSuccess s => _buildSuccessResult(s),
      GemmaInterpretationApiError e => _buildErrorResult(
        icon: Icons.cloud_off_outlined,
        title: 'API error ${e.statusCode}',
        body: e.message,
        detail: e.details,
      ),
      GemmaInterpretationException e => _buildErrorResult(
        icon: Icons.error_outline,
        title: 'Unexpected error',
        body: e.error.toString(),
      ),
    };
  }

  Widget _buildSuccessResult(GemmaInterpretationSuccess success) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Token chip
        if (success.totalTokenCount != null)
          Chip(
            avatar: const Icon(Icons.token_outlined, size: 16),
            label: Text('${success.totalTokenCount} tokens · ${success.model}'),
            backgroundColor: const Color(0xFFDDF4EC),
          ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 200),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(22),
          ),
          child: SelectableText(
            success.text,
            style: const TextStyle(
              color: Color(0xFFE2E8F0),
              fontSize: 15,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: success.text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied to clipboard')),
            );
          },
          icon: const Icon(Icons.copy_outlined),
          label: const Text('Copy response'),
        ),
      ],
    );
  }

  Widget _buildErrorResult({
    required IconData icon,
    required String title,
    required String body,
    String? detail,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFFFCDD2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: const Color(0xFFB91C1C), size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF7F1D1D),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(color: Color(0xFF991B1B))),
          if (detail != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              detail,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFB91C1C),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _panel({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFD7E7E3)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 24,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ============================================================================
// Everything below is your original LiveTextScannerPage — unchanged
// ============================================================================

class LiveTextScannerPage extends StatefulWidget {
  const LiveTextScannerPage({super.key});

  @override
  State<LiveTextScannerPage> createState() => _LiveTextScannerPageState();
}

class _LiveTextScannerPageState extends State<LiveTextScannerPage> {
  static const _scanInterval = Duration(milliseconds: 1000);
  static const _deviceOrientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };
  static const _targetLanguages = <TranslateLanguage>[
    TranslateLanguage.english,
    TranslateLanguage.german,
    TranslateLanguage.french,
    TranslateLanguage.spanish,
    TranslateLanguage.italian,
    TranslateLanguage.turkish,
    TranslateLanguage.croatian,
    TranslateLanguage.portuguese,
  ];

  final TextRecognizer _textRecognizer = TextRecognizer();
  final LanguageIdentifier _languageIdentifier = LanguageIdentifier(
    confidenceThreshold: 0.3,
  );
  final OnDeviceTranslatorModelManager _translationModelManager =
  OnDeviceTranslatorModelManager();

  int _stableTextCount = 0;
  static const _stableTextThreshold = 3;

  CameraController? _controller;
  OnDeviceTranslator? _translator;
  TranslateLanguage? _translatorSourceLanguage;
  TranslateLanguage? _translatorTargetLanguage;
  List<CameraDescription> _cameras = const <CameraDescription>[];
  List<DetectedTextLine> _detectedLines = const <DetectedTextLine>[];

  bool _isInitializing = true;
  bool _isProcessingFrame = false;
  bool _isTranslating = false;
  bool _isPreparingTranslationModel = false;
  bool _torchEnabled = false;
  int _selectedCameraIndex = 0;
  int _translationRequestId = 0;
  Timer? _translationDebounce;
  String _statusMessage = 'Preparing live text scanner...';
  String _recognizedText = '';
  String _translatedText = '';
  String _detectedLanguageLabel = 'Waiting for text';
  String _detectedLanguageCode = '--';
  String _translationStatus = 'Translation is idle.';
  String _lastTranslatedInput = '';
  String? _importedFilePath;
  String? _importedFileName;
  ImportedFileKind? _importedFileKind;
  Size? _importedPreviewSize;
  Size? _latestImageSize;
  InputImageRotation? _latestRotation;
  DateTime _lastScanStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  TranslateLanguage _selectedTargetLanguage = TranslateLanguage.english;

  bool get _isMobilePlatform {
    if (kIsWeb) return false;
    final bindingType = WidgetsBinding.instance.runtimeType.toString();
    if (bindingType.contains('TestWidgetsFlutterBinding')) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
  }

  CameraDescription? get _activeCamera {
    if (_cameras.isEmpty || _selectedCameraIndex >= _cameras.length) return null;
    return _cameras[_selectedCameraIndex];
  }

  bool get _isShowingImportedFile => _importedFilePath != null;
  bool get _isShowingImportedImage =>
      _importedFileKind == ImportedFileKind.image && _importedFilePath != null;

  int get _detectedBlockCount {
    final keys =
    _detectedLines.map((line) => '${line.blockIndex}-${line.text}').toSet();
    return keys.length;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrapCamera());
  }

  @override
  void dispose() {
    unawaited(_disposeResources());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      if (controller.value.isStreamingImages) await controller.stopImageStream();
      await controller.dispose();
    }
    await _translator?.close();
    _translationDebounce?.cancel();
    await _languageIdentifier.close();
    await _textRecognizer.close();
  }

  Future<void> _bootstrapCamera() async {
    if (!_isMobilePlatform) {
      setState(() {
        _isInitializing = false;
        _statusMessage =
        'Live camera OCR and ML Kit translation run on Android and iOS.';
      });
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _isInitializing = false;
          _statusMessage = 'No cameras were found on this device.';
        });
        return;
      }

      final backIndex = cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      _cameras = cameras;
      _selectedCameraIndex = backIndex >= 0 ? backIndex : 0;
      await _startSelectedCamera();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Camera startup failed: $error';
      });
    }
  }

  Future<void> _startSelectedCamera() async {
    final camera = _activeCamera;
    if (camera == null) return;

    final previous = _controller;
    if (previous != null) {
      if (previous.value.isStreamingImages) await previous.stopImageStream();
      await previous.dispose();
    }

    setState(() {
      _isInitializing = true;
      _detectedLines = const <DetectedTextLine>[];
      _recognizedText = '';
      _translatedText = '';
      _detectedLanguageLabel = 'Waiting for text';
      _detectedLanguageCode = '--';
      _translationStatus = 'Translation is idle.';
      _lastTranslatedInput = '';
      _latestImageSize = null;
      _latestRotation = null;
      _torchEnabled = false;
      _stableTextCount = 0;
      _statusMessage = 'Opening ${_cameraLabel(camera)} camera...';
    });

    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: _preferredImageFormatGroup,
    );
    _controller = controller;

    try {
      await controller.initialize();
      await controller.startImageStream(_processCameraImage);
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage =
        'Camera is live. Move printed text into view and hold for a moment.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _statusMessage = 'Could not start live scanning: $error';
      });
    }
  }

  ImageFormatGroup get _preferredImageFormatGroup =>
      defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21;

  String _cameraLabel(CameraDescription camera) => switch (camera.lensDirection) {
    CameraLensDirection.back => 'rear',
    CameraLensDirection.front => 'front',
    CameraLensDirection.external => 'external',
  };

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final nextValue = !_torchEnabled;
    try {
      await controller.setFlashMode(
          nextValue ? FlashMode.torch : FlashMode.off);
      if (!mounted) return;
      setState(() {
        _torchEnabled = nextValue;
        _statusMessage = nextValue
            ? 'Torch enabled for low-light scanning.'
            : 'Torch disabled.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Torch is not available: $error');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      setState(() => _statusMessage = 'Only one camera is available.');
      return;
    }
    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _startSelectedCamera();
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (!mounted || _isProcessingFrame || _isShowingImportedFile) return;
    final now = DateTime.now();
    if (now.difference(_lastScanStartedAt) < _scanInterval) return;
    _lastScanStartedAt = now;

    final inputImage = _buildInputImage(image);
    if (inputImage == null) return;
    _isProcessingFrame = true;

    try {
      final recognizedText = await _textRecognizer.processImage(inputImage);
      if (!mounted) return;
      final lines = _flattenDetectedLines(recognizedText);
      final text = lines.map((line) => line.text).join('\n').trim();

      if (text.isNotEmpty) {
        if (text == _recognizedText) {
          _stableTextCount++;
        } else {
          _stableTextCount = 0;
        }
      } else {
        _stableTextCount = 0;
      }

      setState(() {
        _detectedLines = lines;
        _recognizedText = text;
        if (text.isEmpty) {
          _translationStatus = _lastTranslatedInput.isEmpty
              ? 'Translation is idle.'
              : 'Waiting for stable text...';
        }
        _statusMessage = lines.isEmpty
            ? 'Scanning live camera feed... no text detected yet.'
            : 'Live OCR is tracking ${lines.length} text line(s).';
      });

      if (text.isNotEmpty &&
          _stableTextCount >= _stableTextThreshold &&
          text != _lastTranslatedInput) {
        _stableTextCount = 0;
        _scheduleTranslation(text);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Live text recognition failed: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _pickAndProcessFile() async {
    if (_isInitializing || _isProcessingFrame || _isTranslating) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['pdf', 'docx', 'md'],
      );
      final path = result?.files.single.path;
      if (!mounted || path == null || path.isEmpty) return;
      await _processImportedFile(path);
    } catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = 'Could not import a file: $error');
    }
  }

  Future<void> _processImportedFile(String path) async {
    _translationDebounce?.cancel();
    final kind = _importedFileKindFromPath(path);
    final fileName = path.split(Platform.pathSeparator).last;

    setState(() {
      _isProcessingFrame = true;
      _importedFilePath = path;
      _importedFileName = fileName;
      _importedFileKind = kind;
      _importedPreviewSize = null;
      _detectedLines = const <DetectedTextLine>[];
      _recognizedText = '';
      _translatedText = '';
      _detectedLanguageLabel = 'Waiting for text';
      _detectedLanguageCode = '--';
      _translationStatus = 'Reading imported file...';
      _lastTranslatedInput = '';
      _stableTextCount = 0;
      _statusMessage = 'Opening $fileName...';
    });

    try {
      final extraction = await _extractImportedFileText(path, kind);
      if (!mounted) return;
      setState(() {
        _importedPreviewSize = extraction.previewSize;
        _detectedLines = extraction.lines;
        _recognizedText = extraction.text;
        _statusMessage = extraction.statusMessage;
        _translationStatus = extraction.text.isEmpty
            ? extraction.emptyTranslationStatus
            : 'Imported file processed. Detecting language...';
      });
      if (extraction.text.isNotEmpty) {
        await _translateRecognizedText(extraction.text);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recognizedText = '';
        _translatedText = '';
        _translationStatus = 'Imported file processing failed.';
        _statusMessage = 'Could not process the selected file: $error';
      });
    } finally {
      if (mounted) setState(() => _isProcessingFrame = false);
    }
  }

  Future<ImportedFileExtraction> _extractImportedFileText(
      String path, ImportedFileKind kind) async =>
      switch (kind) {
        ImportedFileKind.markdown => _extractMarkdownFile(path),
        ImportedFileKind.docx => _extractDocxFile(path),
        ImportedFileKind.pdf => _extractPdfFile(path),
        ImportedFileKind.image => _extractImageFile(path),
      };

  Future<ImportedFileExtraction> _extractMarkdownFile(String path) async {
    final text = (await File(path).readAsString()).trim();
    return ImportedFileExtraction(
      text: text,
      lines: const <DetectedTextLine>[],
      statusMessage: text.isEmpty
          ? 'Markdown file opened, but it did not contain readable text.'
          : 'Markdown file loaded with ${_countTextLines(text)} text line(s).',
      emptyTranslationStatus: 'No text found in the Markdown file.',
    );
  }

  Future<ImportedFileExtraction> _extractDocxFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final text = docxToText(bytes).trim();
    return ImportedFileExtraction(
      text: text,
      lines: const <DetectedTextLine>[],
      statusMessage: text.isEmpty
          ? 'DOCX file opened, but no readable document text was found.'
          : 'DOCX file extracted with ${_countTextLines(text)} text line(s).',
      emptyTranslationStatus: 'No text found in the DOCX file.',
    );
  }

  Future<ImportedFileExtraction> _extractPdfFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final document = PdfDocument(inputBytes: bytes);
    try {
      final extractor = PdfTextExtractor(document);
      final text = extractor.extractText().trim();
      return ImportedFileExtraction(
        text: text,
        lines: const <DetectedTextLine>[],
        statusMessage: text.isEmpty
            ? 'PDF opened, but no selectable text was found.'
            : 'PDF extracted with ${_countTextLines(text)} text line(s).',
        emptyTranslationStatus:
        'No selectable text was found in the PDF.',
      );
    } finally {
      document.dispose();
    }
  }

  Future<ImportedFileExtraction> _extractImageFile(String path) async {
    final inputImage = InputImage.fromFilePath(path);
    final recognizedText = await _textRecognizer.processImage(inputImage);
    final lines = _flattenDetectedLines(recognizedText);
    final text = lines.map((line) => line.text).join('\n').trim();
    final imageSize = await _decodeImageSize(path);
    return ImportedFileExtraction(
      text: text,
      lines: lines,
      previewSize: imageSize,
      statusMessage: lines.isEmpty
          ? 'Imported image loaded, but no text was detected.'
          : 'Imported image scanned with ${lines.length} text line(s) detected.',
      emptyTranslationStatus: 'No text found in the imported image.',
    );
  }

  Future<Size?> _decodeImageSize(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final image = await decodeImageFromList(bytes);
      return Size(image.width.toDouble(), image.height.toDouble());
    } catch (_) {
      return null;
    }
  }

  int _countTextLines(String text) =>
      text.split('\n').where((line) => line.trim().isNotEmpty).length;

  ImportedFileKind _importedFileKindFromPath(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'md' => ImportedFileKind.markdown,
      'docx' => ImportedFileKind.docx,
      'pdf' => ImportedFileKind.pdf,
      'jpg' || 'jpeg' || 'png' || 'bmp' || 'webp' => ImportedFileKind.image,
      _ => ImportedFileKind.markdown,
    };
  }

  void _returnToLiveCamera() {
    _translationDebounce?.cancel();
    setState(() {
      _importedFilePath = null;
      _importedFileName = null;
      _importedFileKind = null;
      _importedPreviewSize = null;
      _detectedLines = const <DetectedTextLine>[];
      _recognizedText = '';
      _translatedText = '';
      _detectedLanguageLabel = 'Waiting for text';
      _detectedLanguageCode = '--';
      _translationStatus = 'Translation is idle.';
      _lastTranslatedInput = '';
      _stableTextCount = 0;
      _statusMessage =
      'Camera is live. Move printed text into view and hold for a moment.';
    });
  }

  InputImage? _buildInputImage(CameraImage image) {
    final controller = _controller;
    final camera = _activeCamera;
    if (controller == null || camera == null) return null;
    final rotation = _rotationFromCamera(controller, camera);
    if (rotation == null) return null;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final expectsBgra = defaultTargetPlatform == TargetPlatform.iOS;
    final supportedFormat =
    expectsBgra ? InputImageFormat.bgra8888 : InputImageFormat.nv21;
    if (format != supportedFormat || image.planes.length != 1) return null;
    final plane = image.planes.first;
    _latestImageSize = Size(image.width.toDouble(), image.height.toDouble());
    _latestRotation = rotation;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: _latestImageSize!,
        rotation: rotation,
        format: format!,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _rotationFromCamera(
      CameraController controller, CameraDescription camera) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    var rotationCompensation =
    _deviceOrientations[controller.value.deviceOrientation];
    if (rotationCompensation == null) return null;
    if (camera.lensDirection == CameraLensDirection.front) {
      rotationCompensation =
          (camera.sensorOrientation + rotationCompensation) % 360;
    } else {
      rotationCompensation =
          (camera.sensorOrientation - rotationCompensation + 360) % 360;
    }
    return InputImageRotationValue.fromRawValue(rotationCompensation);
  }

  List<DetectedTextLine> _flattenDetectedLines(RecognizedText recognizedText) {
    final lines = <DetectedTextLine>[];
    for (var blockIndex = 0;
    blockIndex < recognizedText.blocks.length;
    blockIndex += 1) {
      final block = recognizedText.blocks[blockIndex];
      for (final line in block.lines) {
        final text = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) continue;
        lines.add(DetectedTextLine(
          text: text,
          boundingBox: line.boundingBox,
          confidence: line.confidence,
          blockIndex: blockIndex,
        ));
      }
    }
    lines.sort((a, b) {
      final top = a.boundingBox.top.compareTo(b.boundingBox.top);
      if (top != 0) return top;
      return a.boundingBox.left.compareTo(b.boundingBox.left);
    });
    return lines;
  }

  Future<void> _translateRecognizedText(String text) async {
    if (!mounted) return;
    final requestId = ++_translationRequestId;
    setState(() {
      _isTranslating = true;
      _translationStatus = 'Detecting source language...';
    });

    try {
      final candidates =
      await _languageIdentifier.identifyPossibleLanguages(text);
      if (!mounted || requestId != _translationRequestId) return;

      final sourceCode = _pickSupportedLanguageCode(candidates);
      if (sourceCode == null || sourceCode == 'und') {
        setState(() {
          _detectedLanguageLabel = 'Unknown';
          _detectedLanguageCode = 'und';
          _translatedText = '';
          _translationStatus =
          'Source language could not be identified confidently.';
          _lastTranslatedInput = text;
        });
        return;
      }

      final sourceLanguage = _translateLanguageFromCode(sourceCode);
      if (sourceLanguage == null) {
        setState(() {
          _detectedLanguageLabel = _labelFromCode(sourceCode);
          _detectedLanguageCode = sourceCode;
          _translatedText = '';
          _translationStatus =
          'Detected language ($sourceCode) is not supported.';
          _lastTranslatedInput = text;
        });
        return;
      }

      setState(() {
        _detectedLanguageLabel = _displayLanguageName(sourceLanguage);
        _detectedLanguageCode = sourceCode;
      });

      if (sourceLanguage == _selectedTargetLanguage) {
        setState(() {
          _translatedText = text;
          _translationStatus =
          'Detected language already matches the selected target language.';
          _lastTranslatedInput = text;
        });
        return;
      }

      setState(() {
        _isPreparingTranslationModel = true;
        _translationStatus =
        'Downloading translation model if needed...';
      });

      await _translationModelManager.downloadModel(sourceLanguage.bcpCode,
          isWifiRequired: false);
      await _translationModelManager.downloadModel(
          _selectedTargetLanguage.bcpCode,
          isWifiRequired: false);

      if (!mounted || requestId != _translationRequestId) return;

      await _ensureTranslator(
        sourceLanguage: sourceLanguage,
        targetLanguage: _selectedTargetLanguage,
      );

      setState(() {
        _isPreparingTranslationModel = false;
        _translationStatus =
        'Translating to ${_displayLanguageName(_selectedTargetLanguage)}...';
      });

      final translated = await _translator!.translateText(text);
      if (!mounted || requestId != _translationRequestId) return;

      setState(() {
        _translatedText = translated.trim();
        _translationStatus =
        'Translated from ${_displayLanguageName(sourceLanguage)} to ${_displayLanguageName(_selectedTargetLanguage)}.';
        _lastTranslatedInput = text;
      });
    } catch (error) {
      if (!mounted || requestId != _translationRequestId) return;
      setState(() {
        _translatedText = '';
        _lastTranslatedInput = '';
        _translationStatus = 'Translation failed: $error';
      });
    } finally {
      if (mounted && requestId == _translationRequestId) {
        setState(() {
          _isTranslating = false;
          _isPreparingTranslationModel = false;
        });
      }
    }
  }

  void _scheduleTranslation(String text) {
    _translationDebounce?.cancel();
    if (!mounted) return;
    setState(() => _translationStatus =
    'Text captured. Waiting for a stable frame...');
    _translationDebounce = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final currentText = _recognizedText.trim();
      if (currentText.isEmpty || currentText == _lastTranslatedInput) return;
      unawaited(_translateRecognizedText(currentText));
    });
  }

  void _translateCurrentTextNow() {
    final text = _recognizedText.trim();
    if (text.isEmpty) {
      setState(() => _translationStatus =
      'No recognized text is available yet. Point the camera at text first.');
      return;
    }
    _translationDebounce?.cancel();
    unawaited(_translateRecognizedText(text));
  }

  Future<void> _ensureTranslator({
    required TranslateLanguage sourceLanguage,
    required TranslateLanguage targetLanguage,
  }) async {
    final sameSource = _translatorSourceLanguage == sourceLanguage;
    final sameTarget = _translatorTargetLanguage == targetLanguage;
    if (_translator != null && sameSource && sameTarget) return;
    await _translator?.close();
    _translator = OnDeviceTranslator(
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage,
    );
    _translatorSourceLanguage = sourceLanguage;
    _translatorTargetLanguage = targetLanguage;
  }

  TranslateLanguage? _translateLanguageFromCode(String code) {
    final base = code.split('-').first.toLowerCase();
    for (final language in TranslateLanguage.values) {
      if (language.bcpCode == code || language.bcpCode == base) return language;
    }
    return null;
  }

  String? _pickSupportedLanguageCode(List<IdentifiedLanguage> candidates) {
    if (candidates.isEmpty) return null;
    for (final candidate in candidates) {
      final mapped = _translateLanguageFromCode(candidate.languageTag);
      if (mapped != null) return candidate.languageTag;
    }
    return candidates.first.languageTag;
  }

  String _labelFromCode(String code) {
    final mapped = _translateLanguageFromCode(code);
    return mapped == null ? code.toUpperCase() : _displayLanguageName(mapped);
  }

  String _displayLanguageName(TranslateLanguage language) {
    final raw = language.name;
    return raw
        .replaceAll('Fallback', '')
        .replaceAllMapped(
      RegExp(r'(^|_)([a-z])'),
          (match) => ' ${match.group(2)!.toUpperCase()}',
    )
        .trim();
  }

  void _selectTargetLanguage(TranslateLanguage? language) {
    if (language == null || language == _selectedTargetLanguage) return;
    setState(() {
      _selectedTargetLanguage = language;
      _translatedText = '';
      _lastTranslatedInput = '';
      _stableTextCount = 0;
      _translationStatus =
      'Target language changed to ${_displayLanguageName(language)}.';
    });
    final currentText = _recognizedText.trim();
    if (currentText.isNotEmpty) {
      unawaited(_translateRecognizedText(currentText));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color(0xFFF0FBF8),
            Color(0xFFF8F7F2),
            Color(0xFFE2F4EE),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _buildHero(),
                  const SizedBox(height: 20),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 920;
                      if (isWide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(flex: 7, child: _buildPreviewPanel()),
                            const SizedBox(width: 20),
                            Expanded(flex: 4, child: _buildInsightsPanel()),
                          ],
                        );
                      }
                      return Column(children: <Widget>[
                        _buildPreviewPanel(),
                        const SizedBox(height: 20),
                        _buildInsightsPanel(),
                      ]);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFCFE7E1)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x140F172A),
            blurRadius: 28,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFDDF4EC),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'Live Camera OCR + Translation',
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFF115E59)),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Scan text live, paint the recognized lines on the camera feed, then translate them immediately on-device.',
            style: TextStyle(
                fontSize: 32,
                height: 1.1,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 12),
          Text(
            _statusMessage,
            style: const TextStyle(
                fontSize: 16, height: 1.45, color: Color(0xFF334155)),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Scanner',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            _isShowingImportedFile
                ? 'Import a PDF, DOCX, or Markdown file.'
                : 'Green rectangles follow recognized text lines.',
            style: const TextStyle(color: Color(0xFF475569)),
          ),
          const SizedBox(height: 16),
          _buildPreviewCard(),
          const SizedBox(height: 16),
          _buildTranslationControls(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              FilledButton.icon(
                onPressed:
                !_isMobilePlatform || _isInitializing ? null : _pickAndProcessFile,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Import File'),
              ),
              if (_isShowingImportedFile)
                OutlinedButton.icon(
                  onPressed: _isInitializing ? null : _returnToLiveCamera,
                  icon: const Icon(Icons.videocam_outlined),
                  label: const Text('Back to Camera'),
                ),
              FilledButton.icon(
                onPressed: !_isMobilePlatform ||
                    _isInitializing ||
                    _isShowingImportedFile
                    ? null
                    : _toggleTorch,
                icon: Icon(_torchEnabled ? Icons.flash_off : Icons.flash_on),
                label: Text(_torchEnabled ? 'Torch Off' : 'Torch On'),
              ),
              OutlinedButton.icon(
                onPressed: !_isMobilePlatform ||
                    _isInitializing ||
                    _isShowingImportedFile
                    ? null
                    : _switchCamera,
                icon: const Icon(Icons.cameraswitch_outlined),
                label: const Text('Switch Camera'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTranslationControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFDBEAFE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Translate To',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          DropdownButtonFormField<TranslateLanguage>(
            initialValue: _selectedTargetLanguage,
            isExpanded: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.translate),
            ),
            items: _targetLanguages
                .map((language) => DropdownMenuItem<TranslateLanguage>(
              value: language,
              child: Text(_displayLanguageName(language)),
            ))
                .toList(),
            onChanged: _isInitializing ? null : _selectTargetLanguage,
          ),
          const SizedBox(height: 10),
          Text('Detected source: $_detectedLanguageLabel',
              style: const TextStyle(color: Color(0xFF475569))),
          const SizedBox(height: 4),
          Text(
            'Source code: $_detectedLanguageCode | Target code: ${_selectedTargetLanguage.bcpCode}',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            _translationStatus,
            style: TextStyle(
              color: _isTranslating || _isPreparingTranslationModel
                  ? const Color(0xFF115E59)
                  : const Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _isInitializing ? null : _translateCurrentTextNow,
            icon: const Icon(Icons.g_translate),
            label: const Text('Translate Now'),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard() {
    if (!_isMobilePlatform) {
      return _placeholderCard(
        message:
        'This feature is implemented for Android and iOS because ML Kit live OCR and translation are mobile-only.',
      );
    }
    if (_isShowingImportedFile) return _buildImportedFilePreview();
    final controller = _controller;
    if (_isInitializing ||
        controller == null ||
        !controller.value.isInitialized) {
      return const AspectRatio(
        aspectRatio: 9 / 16,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final imageSize = _latestImageSize;
    final rotation = _latestRotation;
    final camera = _activeCamera;
    final overlayReady = imageSize != null && rotation != null && camera != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: ColoredBox(
        color: const Color(0xFF08121A),
        child: AspectRatio(
          aspectRatio: 1 / controller.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              CameraPreview(controller),
              if (overlayReady)
                CustomPaint(
                  painter: TextDetectionPainter(
                    lines: _detectedLines,
                    imageSize: imageSize,
                    rotation: rotation,
                    lensDirection: camera.lensDirection,
                  ),
                ),
              Positioned(
                  left: 16, right: 16, top: 16, child: _buildLiveHeadline()),
              Positioned(
                  left: 16, right: 16, bottom: 16, child: _buildHintBanner()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportedFilePreview() {
    final filePath = _importedFilePath;
    if (filePath == null) {
      return _placeholderCard(
          message:
          'Choose a PDF, DOCX, or Markdown file to extract text from it.');
    }
    if (_isShowingImportedImage) return _buildImportedImagePreview(filePath);
    return _buildImportedDocumentPreview();
  }

  Widget _buildImportedImagePreview(String imagePath) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: ColoredBox(
        color: const Color(0xFF08121A),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Image.file(File(imagePath),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => const Center(
                      child: Text('The selected image could not be displayed.',
                          style: TextStyle(color: Colors.white)))),
              if (_importedPreviewSize != null && _detectedLines.isNotEmpty)
                CustomPaint(
                  painter: ImportedImageDetectionPainter(
                    lines: _detectedLines,
                    imageSize: _importedPreviewSize!,
                  ),
                ),
              Positioned(
                  left: 16, right: 16, top: 16, child: _buildLiveHeadline()),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xCC115E59),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Text(
                    'Imported image mode: OCR runs once on the selected file, then translation starts automatically.',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImportedDocumentPreview() {
    final fileName = _importedFileName ?? 'Imported file';
    final kindLabel = switch (_importedFileKind) {
      ImportedFileKind.markdown => 'Markdown',
      ImportedFileKind.docx => 'DOCX',
      ImportedFileKind.pdf => 'PDF',
      ImportedFileKind.image => 'Image',
      null => 'File',
    };
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 420),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: const Color(0xFF08121A),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildLiveHeadline(),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0x3342D392)),
            ),
            child: Row(children: <Widget>[
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0x1A99F6E4),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.description_outlined,
                    color: Color(0xFF99F6E4), size: 30),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('$kindLabel import mode',
                        style: const TextStyle(color: Color(0xFF94A3B8))),
                  ],
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveHeadline() {
    final text = _translatedText.isNotEmpty
        ? _translatedText.split('\n').take(2).join('  |  ')
        : _recognizedText.isEmpty
        ? 'Waiting for text...'
        : _recognizedText.split('\n').take(2).join('  |  ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xCC08121A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x4D99F6E4)),
      ),
      child: Text(text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Color(0xFFF8FAFC), fontWeight: FontWeight.w700)),
    );
  }

  Widget _buildHintBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xCC115E59),
        borderRadius: BorderRadius.circular(18),
      ),
      child: const Text(
        'Best results: use the rear camera, fill the frame with printed text, and pause briefly.',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  Widget _buildInsightsPanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('Recognized Text',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _metricChip('Lines', _detectedLines.length.toString()),
              _metricChip('Blocks', _detectedBlockCount.toString()),
              _metricChip(
                'Input',
                _isShowingImportedFile
                    ? _importedFileName ?? 'imported file'
                    : _activeCamera == null
                    ? 'camera unavailable'
                    : _cameraLabel(_activeCamera!),
              ),
              _metricChip(
                  'Target', _displayLanguageName(_selectedTargetLanguage)),
            ],
          ),
          const SizedBox(height: 16),
          _resultSection(
            title: 'Original OCR',
            text: _recognizedText.isEmpty
                ? 'Point the camera at printed text and the live OCR output will appear here.'
                : _recognizedText,
          ),
          const SizedBox(height: 16),
          _resultSection(
            title: 'Translated Text',
            text: _translatedText.isEmpty
                ? 'The translated text will appear here after language detection and model preparation.'
                : _translatedText,
          ),
        ],
      ),
    );
  }

  Widget _resultSection({required String title, required String text}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title,
            style:
            const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 150),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(22),
          ),
          child: SelectableText(text,
              style: const TextStyle(
                  color: Color(0xFFE2E8F0), fontSize: 15, height: 1.5)),
        ),
      ],
    );
  }

  Widget _metricChip(String label, String value) =>
      Chip(backgroundColor: const Color(0xFFF1F5F9), label: Text('$label: $value'));

  Widget _panel({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFD7E7E3)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x120F172A),
            blurRadius: 24,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _placeholderCard({required String message}) {
    return Container(
      height: 420,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

// ============================================================================
// Supporting types (unchanged from original)
// ============================================================================

class ImportedImageDetectionPainter extends CustomPainter {
  const ImportedImageDetectionPainter(
      {required this.lines, required this.imageSize});
  final List<DetectedTextLine> lines;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    final fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final sourceRect =
    Alignment.center.inscribe(fitted.source, Offset.zero & imageSize);
    final destinationRect =
    Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    final framePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFF6EE7B7);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x2622C55E);
    for (final line in lines) {
      final normalized = Rect.fromLTWH(
        destinationRect.left +
            (line.boundingBox.left - sourceRect.left) *
                destinationRect.width /
                sourceRect.width,
        destinationRect.top +
            (line.boundingBox.top - sourceRect.top) *
                destinationRect.height /
                sourceRect.height,
        line.boundingBox.width * destinationRect.width / sourceRect.width,
        line.boundingBox.height * destinationRect.height / sourceRect.height,
      );
      if (normalized.width < 6 || normalized.height < 6) continue;
      final rounded =
      RRect.fromRectAndRadius(normalized, const Radius.circular(10));
      canvas.drawRRect(rounded, fillPaint);
      canvas.drawRRect(rounded, framePaint);
    }
  }

  @override
  bool shouldRepaint(covariant ImportedImageDetectionPainter oldDelegate) =>
      oldDelegate.lines != lines || oldDelegate.imageSize != imageSize;
}

enum ImportedFileKind { image, markdown, docx, pdf }

class ImportedFileExtraction {
  const ImportedFileExtraction({
    required this.text,
    required this.lines,
    required this.statusMessage,
    required this.emptyTranslationStatus,
    this.previewSize,
  });
  final String text;
  final List<DetectedTextLine> lines;
  final String statusMessage;
  final String emptyTranslationStatus;
  final Size? previewSize;
}

class DetectedTextLine {
  const DetectedTextLine({
    required this.text,
    required this.boundingBox,
    required this.confidence,
    required this.blockIndex,
  });
  final String text;
  final Rect boundingBox;
  final double? confidence;
  final int blockIndex;
}

class TextDetectionPainter extends CustomPainter {
  const TextDetectionPainter({
    required this.lines,
    required this.imageSize,
    required this.rotation,
    required this.lensDirection,
  });
  final List<DetectedTextLine> lines;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final framePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = const Color(0xFF6EE7B7);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x2622C55E);
    for (final line in lines) {
      final rect = Rect.fromLTRB(
        _translateX(line.boundingBox.left, size),
        _translateY(line.boundingBox.top, size),
        _translateX(line.boundingBox.right, size),
        _translateY(line.boundingBox.bottom, size),
      );
      final normalized = Rect.fromLTRB(
        math.min(rect.left, rect.right),
        math.min(rect.top, rect.bottom),
        math.max(rect.left, rect.right),
        math.max(rect.top, rect.bottom),
      );
      if (normalized.width < 6 || normalized.height < 6) continue;
      final rounded =
      RRect.fromRectAndRadius(normalized, const Radius.circular(10));
      canvas.drawRRect(rounded, fillPaint);
      canvas.drawRRect(rounded, framePaint);
      _paintLabel(canvas, size, normalized, line);
    }
  }

  void _paintLabel(
      Canvas canvas, Size canvasSize, Rect rect, DetectedTextLine line) {
    final label = line.text.length > 26
        ? '${line.text.substring(0, 26).trimRight()}...'
        : line.text;
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '...',
    )..layout(maxWidth: math.min(rect.width + 80, canvasSize.width - 24));
    final labelWidth = textPainter.width + 20;
    final labelHeight = textPainter.height + 10;
    final desiredTop = rect.top - labelHeight - 6;
    final labelRect = Rect.fromLTWH(
      rect.left.clamp(8.0, canvasSize.width - labelWidth - 8).toDouble(),
      desiredTop < 8 ? rect.bottom + 6 : desiredTop,
      labelWidth,
      labelHeight,
    );
    final background = Paint()
      ..color = const Color(0xE6115E59)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(999)),
      background,
    );
    textPainter.paint(canvas, Offset(labelRect.left + 10, labelRect.top + 5));
  }

  double _translateX(double x, Size canvasSize) {
    final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
    switch (rotation) {
      case InputImageRotation.rotation90deg:
        return x *
            canvasSize.width /
            (isIos ? imageSize.width : imageSize.height);
      case InputImageRotation.rotation270deg:
        return canvasSize.width -
            x *
                canvasSize.width /
                (isIos ? imageSize.width : imageSize.height);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        switch (lensDirection) {
          case CameraLensDirection.back:
            return x * canvasSize.width / imageSize.width;
          case CameraLensDirection.front:
          case CameraLensDirection.external:
            return canvasSize.width - x * canvasSize.width / imageSize.width;
        }
    }
  }

  double _translateY(double y, Size canvasSize) {
    switch (rotation) {
      case InputImageRotation.rotation90deg:
      case InputImageRotation.rotation270deg:
        final isIos = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
        return y *
            canvasSize.height /
            (isIos ? imageSize.height : imageSize.width);
      case InputImageRotation.rotation0deg:
      case InputImageRotation.rotation180deg:
        return y * canvasSize.height / imageSize.height;
    }
  }

  @override
  bool shouldRepaint(covariant TextDetectionPainter oldDelegate) =>
      oldDelegate.lines != lines ||
          oldDelegate.imageSize != imageSize ||
          oldDelegate.rotation != rotation ||
          oldDelegate.lensDirection != lensDirection;
}