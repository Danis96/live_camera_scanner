import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_llama/flutter_llama.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

@immutable
class LocalLlmModelConfig {
  const LocalLlmModelConfig({
    required this.id,
    required this.fileName,
    required this.assetPath,
    required this.useGpu,
    this.contextSize = 2048,
    this.batchSize = 512,
    this.maxTokens = 512,
    this.topK = 40,
    this.topP = 0.95,
    this.temperature = 0.7,
    this.repeatPenalty = 1.1,
    this.nThreads = 4,
    this.nGpuLayers = -1,
    this.verbose = false,
  });

  final String id;
  final String fileName;
  final String assetPath;
  final bool useGpu;
  final int contextSize;
  final int batchSize;
  final int maxTokens;
  final int topK;
  final double topP;
  final double temperature;
  final double repeatPenalty;
  final int nThreads;
  final int nGpuLayers;
  final bool verbose;

  static const LocalLlmModelConfig gemma3_270mItQ4Km = LocalLlmModelConfig(
    id: 'gemma3_270m_it_q4_k_m',
    fileName: 'gemma-3-270m-it-q4_k_m.gguf',
    assetPath: 'assets/models/gemma-3-270m-it-q4_k_m.gguf',
    useGpu: true,
    contextSize: 2048,
    batchSize: 512,
    maxTokens: 384,
    topK: 40,
    topP: 0.95,
    temperature: 0.7,
    repeatPenalty: 1.1,
    nThreads: 4,
    nGpuLayers: -1,
    verbose: false,
  );

  LocalLlmModelConfig copyWith({
    String? id,
    String? fileName,
    String? assetPath,
    bool? useGpu,
    int? contextSize,
    int? batchSize,
    int? maxTokens,
    int? topK,
    double? topP,
    double? temperature,
    double? repeatPenalty,
    int? nThreads,
    int? nGpuLayers,
    bool? verbose,
  }) {
    return LocalLlmModelConfig(
      id: id ?? this.id,
      fileName: fileName ?? this.fileName,
      assetPath: assetPath ?? this.assetPath,
      useGpu: useGpu ?? this.useGpu,
      contextSize: contextSize ?? this.contextSize,
      batchSize: batchSize ?? this.batchSize,
      maxTokens: maxTokens ?? this.maxTokens,
      topK: topK ?? this.topK,
      topP: topP ?? this.topP,
      temperature: temperature ?? this.temperature,
      repeatPenalty: repeatPenalty ?? this.repeatPenalty,
      nThreads: nThreads ?? this.nThreads,
      nGpuLayers: nGpuLayers ?? this.nGpuLayers,
      verbose: verbose ?? this.verbose,
    );
  }
}

sealed class LlmServiceState {
  const LlmServiceState();
}

class LlmServiceIdle extends LlmServiceState {
  const LlmServiceIdle();
}

class LlmServiceLoading extends LlmServiceState {
  const LlmServiceLoading();
}

class LlmServiceGenerating extends LlmServiceState {
  const LlmServiceGenerating();
}

class LlmServiceReady extends LlmServiceState {
  const LlmServiceReady({
    required this.modelPath,
  });

  final String modelPath;
}

class LlmServiceError extends LlmServiceState {
  const LlmServiceError(this.message);

  final String message;
}

class LlmServicePreparingAsset extends LlmServiceState {
  const LlmServicePreparingAsset({
    required this.message,
  });

  final String message;
}

class LocalLlmService {
  LocalLlmService({
    required this.config,
    FlutterLlama? llama,
  }) : _llama = llama ?? FlutterLlama.instance;

  final LocalLlmModelConfig config;
  final FlutterLlama _llama;

  final StreamController<LlmServiceState> _stateController =
      StreamController<LlmServiceState>.broadcast();

  Stream<LlmServiceState> get stateStream => _stateController.stream;

  String? _resolvedModelPath;
  bool _modelLoaded = false;
  bool _disposed = false;

  void _emit(LlmServiceState state) {
    if (_disposed || _stateController.isClosed) return;
    _stateController.add(state);
  }

  Future<void> ensureModelAndLoad() async {
    _throwIfDisposed();

    if (_modelLoaded && _resolvedModelPath != null) {
      _emit(LlmServiceReady(modelPath: _resolvedModelPath!));
      return;
    }

    try {
      _emit(const LlmServiceLoading());

      final modelPath = await _ensureModelFileFromAssets();
      final loaded = await _llama.loadModel(
        LlamaConfig(
          modelPath: modelPath,
          nThreads: config.nThreads,
          nGpuLayers: config.useGpu ? config.nGpuLayers : 0,
          contextSize: config.contextSize,
          batchSize: config.batchSize,
          useGpu: config.useGpu,
          verbose: config.verbose,
        ),
      );

      if (!loaded) {
        throw StateError('The GGUF model could not be loaded.');
      }

      _resolvedModelPath = modelPath;
      _modelLoaded = true;
      _emit(LlmServiceReady(modelPath: modelPath));
    } catch (e) {
      _emit(LlmServiceError(e.toString()));
      rethrow;
    }
  }

  Future<String> generate(String prompt) async {
    final buffer = StringBuffer();
    await for (final chunk in generateStreaming(prompt)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  Stream<String> generateStreaming(String prompt) async* {
    _throwIfDisposed();

    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty) {
      throw ArgumentError('Prompt must not be empty.');
    }

    if (!_modelLoaded) {
      await ensureModelAndLoad();
    }

    _emit(const LlmServiceGenerating());

    try {
      final params = GenerationParams(
        prompt: _wrapAsGemmaInstruction(normalizedPrompt),
        temperature: config.temperature,
        topP: config.topP,
        topK: config.topK,
        maxTokens: config.maxTokens,
        repeatPenalty: config.repeatPenalty,
      );

      await for (final token in _llama.generateStream(params)) {
        yield token;
      }

      if (_resolvedModelPath != null) {
        _emit(LlmServiceReady(modelPath: _resolvedModelPath!));
      } else {
        _emit(const LlmServiceIdle());
      }
    } catch (e) {
      _emit(LlmServiceError(e.toString()));
      rethrow;
    }
  }

  Future<String> getModelPath() async {
    _resolvedModelPath ??= await _expectedModelPath();
    return _resolvedModelPath!;
  }

  Future<bool> isModelPrepared() async {
    final file = File(await _expectedModelPath());
    return file.exists();
  }

  Future<void> deletePreparedModel() async {
    final path = await _expectedModelPath();
    final file = File(path);

    if (await file.exists()) {
      await file.delete();
    }

    if (_modelLoaded) {
      await _llama.unloadModel();
    }

    _modelLoaded = false;
    _resolvedModelPath = null;
    _emit(const LlmServiceIdle());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_modelLoaded) {
      await _llama.unloadModel();
    }
    await _stateController.close();
  }

  Future<String> _ensureModelFileFromAssets() async {
    final targetPath = await _expectedModelPath();
    final targetFile = File(targetPath);

    if (await targetFile.exists()) {
      return targetPath;
    }

    _emit(const LlmServicePreparingAsset(
      message: 'Copying bundled GGUF model into app storage...',
    ));

    await targetFile.parent.create(recursive: true);

    try {
      final byteData = await rootBundle.load(config.assetPath);
      final bytes = byteData.buffer.asUint8List();
      await targetFile.writeAsBytes(bytes, flush: true);
      return targetPath;
    } on FlutterError catch (error) {
      throw StateError(
        'Model asset missing at ${config.assetPath}. '
        'Place the GGUF file there and run flutter pub get. '
        'Original error: $error',
      );
    }
  }

  Future<String> _expectedModelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(dir.path, 'local_models'));
    await modelsDir.create(recursive: true);
    return p.join(modelsDir.path, config.fileName);
  }

  String _wrapAsGemmaInstruction(String prompt) {
    return '<start_of_turn>user\n$prompt<end_of_turn>\n<start_of_turn>model\n';
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw StateError('LocalLlmService was already disposed.');
    }
  }
}
