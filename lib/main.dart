import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

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
      home: const LiveTextScannerPage(),
    );
  }
}

class LiveTextScannerPage extends StatefulWidget {
  const LiveTextScannerPage({super.key});

  @override
  State<LiveTextScannerPage> createState() => _LiveTextScannerPageState();
}

class _LiveTextScannerPageState extends State<LiveTextScannerPage> {
  static const _scanInterval = Duration(milliseconds: 280);
  static const _deviceOrientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  final TextRecognizer _textRecognizer = TextRecognizer();

  CameraController? _controller;
  List<CameraDescription> _cameras = const <CameraDescription>[];
  List<DetectedTextLine> _detectedLines = const <DetectedTextLine>[];

  bool _isInitializing = true;
  bool _isProcessingFrame = false;
  bool _torchEnabled = false;
  int _selectedCameraIndex = 0;
  String _statusMessage = 'Preparing live text scanner...';
  String _recognizedText = '';
  Size? _latestImageSize;
  InputImageRotation? _latestRotation;
  DateTime _lastScanStartedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _isMobilePlatform {
    if (kIsWeb) {
      return false;
    }

    final bindingType = WidgetsBinding.instance.runtimeType.toString();
    if (bindingType.contains('TestWidgetsFlutterBinding')) {
      return false;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
  }

  CameraDescription? get _activeCamera {
    if (_cameras.isEmpty || _selectedCameraIndex >= _cameras.length) {
      return null;
    }
    return _cameras[_selectedCameraIndex];
  }

  int get _detectedBlockCount {
    final keys = _detectedLines
        .map((line) => '${line.blockIndex}-${line.text}')
        .toSet();
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
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      await controller.dispose();
    }

    await _textRecognizer.close();
  }

  Future<void> _bootstrapCamera() async {
    if (!_isMobilePlatform) {
      setState(() {
        _isInitializing = false;
        _statusMessage =
            'Live camera OCR runs on Android and iOS. Open the app on a phone or emulator to scan text.';
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
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _statusMessage = 'Camera startup failed: $error';
      });
    }
  }

  Future<void> _startSelectedCamera() async {
    final camera = _activeCamera;
    if (camera == null) {
      return;
    }

    final previous = _controller;
    if (previous != null) {
      if (previous.value.isStreamingImages) {
        await previous.stopImageStream();
      }
      await previous.dispose();
    }

    setState(() {
      _isInitializing = true;
      _detectedLines = const <DetectedTextLine>[];
      _recognizedText = '';
      _latestImageSize = null;
      _latestRotation = null;
      _torchEnabled = false;
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
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _statusMessage =
            'Camera is live. Move printed text into view and hold for a moment.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isInitializing = false;
        _statusMessage = 'Could not start live scanning: $error';
      });
    }
  }

  ImageFormatGroup get _preferredImageFormatGroup {
    return defaultTargetPlatform == TargetPlatform.iOS
        ? ImageFormatGroup.bgra8888
        : ImageFormatGroup.nv21;
  }

  String _cameraLabel(CameraDescription camera) {
    return switch (camera.lensDirection) {
      CameraLensDirection.back => 'rear',
      CameraLensDirection.front => 'front',
      CameraLensDirection.external => 'external',
    };
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }

    final nextValue = !_torchEnabled;
    try {
      await controller.setFlashMode(
        nextValue ? FlashMode.torch : FlashMode.off,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _torchEnabled = nextValue;
        _statusMessage = nextValue
            ? 'Torch enabled for low-light scanning.'
            : 'Torch disabled.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Torch is not available on this camera: $error';
      });
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) {
      setState(() {
        _statusMessage = 'Only one camera is available on this device.';
      });
      return;
    }

    _selectedCameraIndex = (_selectedCameraIndex + 1) % _cameras.length;
    await _startSelectedCamera();
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (!mounted || _isProcessingFrame) {
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastScanStartedAt) < _scanInterval) {
      return;
    }
    _lastScanStartedAt = now;

    final inputImage = _buildInputImage(image);
    if (inputImage == null) {
      return;
    }

    _isProcessingFrame = true;

    try {
      final recognizedText = await _textRecognizer.processImage(inputImage);
      if (!mounted) {
        return;
      }

      final lines = _flattenDetectedLines(recognizedText);
      final text = lines.map((line) => line.text).join('\n').trim();

      setState(() {
        _detectedLines = lines;
        _recognizedText = text;
        _statusMessage = lines.isEmpty
            ? 'Scanning live camera feed... no text detected yet.'
            : 'Live OCR is tracking ${lines.length} text line(s).';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Live text recognition failed: $error';
      });
    } finally {
      _isProcessingFrame = false;
    }
  }

  InputImage? _buildInputImage(CameraImage image) {
    final controller = _controller;
    final camera = _activeCamera;
    if (controller == null || camera == null) {
      return null;
    }

    final rotation = _rotationFromCamera(controller, camera);
    if (rotation == null) {
      return null;
    }

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final expectsBgra = defaultTargetPlatform == TargetPlatform.iOS;
    final supportedFormat = expectsBgra
        ? InputImageFormat.bgra8888
        : InputImageFormat.nv21;

    if (format != supportedFormat || image.planes.length != 1) {
      return null;
    }

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
    CameraController controller,
    CameraDescription camera,
  ) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    var rotationCompensation =
        _deviceOrientations[controller.value.deviceOrientation];
    if (rotationCompensation == null) {
      return null;
    }

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

    for (
      var blockIndex = 0;
      blockIndex < recognizedText.blocks.length;
      blockIndex += 1
    ) {
      final block = recognizedText.blocks[blockIndex];
      for (final line in block.lines) {
        final text = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (text.isEmpty) {
          continue;
        }

        lines.add(
          DetectedTextLine(
            text: text,
            boundingBox: line.boundingBox,
            confidence: line.confidence,
            blockIndex: blockIndex,
          ),
        );
      }
    }

    lines.sort((a, b) {
      final top = a.boundingBox.top.compareTo(b.boundingBox.top);
      if (top != 0) {
        return top;
      }
      return a.boundingBox.left.compareTo(b.boundingBox.left);
    });

    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
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

                        return Column(
                          children: <Widget>[
                            _buildPreviewPanel(),
                            const SizedBox(height: 20),
                            _buildInsightsPanel(),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFDDF4EC),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'Live Camera OCR',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF115E59),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Scan text live and paint the recognized lines directly on top of the camera feed.',
            style: TextStyle(
              fontSize: 32,
              height: 1.1,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _statusMessage,
            style: const TextStyle(
              fontSize: 16,
              height: 1.45,
              color: Color(0xFF334155),
            ),
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
          const Text(
            'Scanner',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text(
            'Green rectangles follow the recognized text lines. The chip above each rectangle mirrors the OCR output for that line.',
            style: TextStyle(color: Color(0xFF475569)),
          ),
          const SizedBox(height: 16),
          _buildPreviewCard(),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              FilledButton.icon(
                onPressed: !_isMobilePlatform || _isInitializing
                    ? null
                    : _toggleTorch,
                icon: Icon(_torchEnabled ? Icons.flash_off : Icons.flash_on),
                label: Text(_torchEnabled ? 'Torch Off' : 'Torch On'),
              ),
              OutlinedButton.icon(
                onPressed: !_isMobilePlatform || _isInitializing
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

  Widget _buildPreviewCard() {
    if (!_isMobilePlatform) {
      return _placeholderCard(
        message:
            'This feature is implemented for Android and iOS because ML Kit live OCR is mobile-only.',
      );
    }

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
    final overlayReady =
        imageSize != null && rotation != null && camera != null;

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
                left: 16,
                right: 16,
                top: 16,
                child: _buildLiveHeadline(),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: _buildHintBanner(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveHeadline() {
    final text = _recognizedText.isEmpty
        ? 'Waiting for text...'
        : _recognizedText.split('\n').take(2).join('  |  ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xCC08121A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x4D99F6E4)),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Color(0xFFF8FAFC),
          fontWeight: FontWeight.w700,
        ),
      ),
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
        'Best results: use the rear camera, fill the frame with printed text, and pause briefly so the overlay can lock onto the lines.',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  Widget _buildInsightsPanel() {
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Recognized Text',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _metricChip('Lines', _detectedLines.length.toString()),
              _metricChip('Blocks', _detectedBlockCount.toString()),
              _metricChip(
                'Camera',
                _activeCamera == null ? 'none' : _cameraLabel(_activeCamera!),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 240),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(22),
            ),
            child: SelectableText(
              _recognizedText.isEmpty
                  ? 'Point the camera at printed text and the live OCR output will appear here.'
                  : _recognizedText,
              style: const TextStyle(
                color: Color(0xFFE2E8F0),
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Overlay Notes',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'This implementation scans the live preview with ML Kit Text Recognition v2 and paints each recognized line back onto the camera surface. It is optimized for mobile and runs entirely on-device.',
            style: TextStyle(color: Color(0xFF475569), height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _metricChip(String label, String value) {
    return Chip(
      backgroundColor: const Color(0xFFF1F5F9),
      label: Text('$label: $value'),
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
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
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

      if (normalized.width < 6 || normalized.height < 6) {
        continue;
      }

      final rounded = RRect.fromRectAndRadius(
        normalized,
        const Radius.circular(10),
      );

      canvas.drawRRect(rounded, fillPaint);
      canvas.drawRRect(rounded, framePaint);
      _paintLabel(canvas, size, normalized, line);
    }
  }

  void _paintLabel(
    Canvas canvas,
    Size canvasSize,
    Rect rect,
    DetectedTextLine line,
  ) {
    final label = line.text.length > 26
        ? '${line.text.substring(0, 26).trimRight()}...'
        : line.text;

    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
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
            x * canvasSize.width / (isIos ? imageSize.width : imageSize.height);
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
  bool shouldRepaint(covariant TextDetectionPainter oldDelegate) {
    return oldDelegate.lines != lines ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.rotation != rotation ||
        oldDelegate.lensDirection != lensDirection;
  }
}
