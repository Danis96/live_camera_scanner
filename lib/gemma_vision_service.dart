import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Configuration for the Gemma Vision service.
///
/// Obtain a free API key at https://aistudio.google.com/app/apikey
/// The key is used against the Google AI / Gemma endpoint:
///   https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
///
/// Gemma 3 models available via the free tier (as of 2025-Q2):
///   - gemma-3-27b-it        (27B, highest quality)
///   - gemma-3-12b-it        (12B, good balance)
///   - gemma-3-4b-it         (4B, fastest)
///   - gemma-3n-e4b-it       (edge-optimised 4B, lowest latency)
class GemmaVisionConfig {
  const GemmaVisionConfig({
    required this.apiKey,
    // this.model = 'gemma-3-27b-it',
    this.model = 'gemma-4-26b-a4b-it',
    this.maxOutputTokens = 1024,
    this.temperature = 0.4,
    this.topP = 0.95,
    this.defaultPrompt =
    'Describe everything you observe in this image in detail. '
        'Include objects, text, colors, layout, and any notable context.',
  });

  final String apiKey;
  final String model;
  final int maxOutputTokens;
  final double temperature;
  final double topP;
  final String defaultPrompt;

  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  Uri endpointUri() =>
      Uri.parse('$_baseUrl/$model:generateContent?key=$apiKey');
}

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------

/// The outcome of a single image-interpretation request.
sealed class GemmaInterpretationResult {
  const GemmaInterpretationResult();
}

/// Successful interpretation — [text] contains the model's response.
final class GemmaInterpretationSuccess extends GemmaInterpretationResult {
  const GemmaInterpretationSuccess({
    required this.text,
    required this.model,
    this.promptTokenCount,
    this.candidateTokenCount,
  });

  final String text;
  final String model;
  final int? promptTokenCount;
  final int? candidateTokenCount;

  int? get totalTokenCount => (promptTokenCount != null &&
      candidateTokenCount != null)
      ? promptTokenCount! + candidateTokenCount!
      : null;
}

/// The API returned an error response (non-200 or structured error body).
final class GemmaInterpretationApiError extends GemmaInterpretationResult {
  const GemmaInterpretationApiError({
    required this.statusCode,
    required this.message,
    this.details,
  });

  final int statusCode;
  final String message;
  final String? details;

  @override
  String toString() => 'GemmaApiError($statusCode): $message';
}

/// A network, timeout, or unexpected parsing exception.
final class GemmaInterpretationException extends GemmaInterpretationResult {
  const GemmaInterpretationException({
    required this.error,
    this.stackTrace,
  });

  final Object error;
  final StackTrace? stackTrace;

  @override
  String toString() => 'GemmaException: $error';
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Sends an image (as raw bytes) to the Gemma multimodal API for interpretation.
///
/// Usage:
/// ```dart
/// final service = GemmaVisionService(
///   config: GemmaVisionConfig(apiKey: 'YOUR_KEY'),
/// );
///
/// final result = await service.interpretImage(
///   imageBytes: myUint8List,
///   mimeType: 'image/jpeg',
///   prompt: 'What language is the text in this image?',
/// );
///
/// switch (result) {
///   case GemmaInterpretationSuccess(:final text): print(text);
///   case GemmaInterpretationApiError(:final message): print('API error: $message');
///   case GemmaInterpretationException(:final error): print('Exception: $error');
/// }
/// ```
class GemmaVisionService {
  GemmaVisionService({
    required this.config,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final GemmaVisionConfig config;
  final http.Client _client;

  /// Interprets [imageBytes] using the Gemma vision model.
  ///
  /// [mimeType] must be one of: image/jpeg, image/png, image/webp, image/bmp
  /// [prompt]   overrides [GemmaVisionConfig.defaultPrompt] when provided.
  Future<GemmaInterpretationResult> interpretImage({
    required Uint8List imageBytes,
    String mimeType = 'image/jpeg',
    String? prompt,
  }) async {
    try {
      final effectivePrompt = prompt?.trim().isNotEmpty == true
          ? prompt!.trim()
          : config.defaultPrompt;

      final body = _buildRequestBody(
        imageBytes: imageBytes,
        mimeType: mimeType,
        prompt: effectivePrompt,
      );

      final response = await _client
          .post(
        config.endpointUri(),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
          .timeout(const Duration(seconds: 60));

      return _parseResponse(response);
    } on GemmaInterpretationResult catch (r) {
      return r;
    } catch (error, stackTrace) {
      return GemmaInterpretationException(
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Private helpers
  // -------------------------------------------------------------------------

  Map<String, Object> _buildRequestBody({
    required Uint8List imageBytes,
    required String mimeType,
    required String prompt,
  }) {
    final base64Image = base64Encode(imageBytes);

    return {
      'contents': [
        {
          'role': 'user',
          'parts': [
            {
              'inline_data': {
                'mime_type': mimeType,
                'data': base64Image,
              },
            },
            {
              'text': prompt,
            },
          ],
        },
      ],
      'generationConfig': {
        'maxOutputTokens': config.maxOutputTokens,
        'temperature': config.temperature,
        'topP': config.topP,
      },
    };
  }

  GemmaInterpretationResult _parseResponse(http.Response response) {
    final Map<String, dynamic> json;

    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return GemmaInterpretationApiError(
        statusCode: response.statusCode,
        message: 'Could not decode API response body.',
        details: response.body.length > 400
            ? '${response.body.substring(0, 400)}...'
            : response.body,
      );
    }

    // Structured error object
    if (json.containsKey('error')) {
      final err = json['error'] as Map<String, dynamic>;
      return GemmaInterpretationApiError(
        statusCode: response.statusCode,
        message: err['message']?.toString() ?? 'Unknown API error',
        details: err['status']?.toString(),
      );
    }

    // Non-200 without structured error
    if (response.statusCode != 200) {
      return GemmaInterpretationApiError(
        statusCode: response.statusCode,
        message: 'Unexpected HTTP status ${response.statusCode}.',
        details: response.body.length > 200
            ? '${response.body.substring(0, 200)}...'
            : response.body,
      );
    }

    // Parse successful body
    try {
      final candidates =
      json['candidates'] as List<dynamic>;

      if (candidates.isEmpty) {
        return const GemmaInterpretationApiError(
          statusCode: 200,
          message: 'API returned no candidates.',
        );
      }

      final content =
      (candidates.first as Map<String, dynamic>)['content']
      as Map<String, dynamic>;
      final parts = content['parts'] as List<dynamic>;
      final text = (parts.first as Map<String, dynamic>)['text']
      as String? ??
          '';

      final usage =
      json['usageMetadata'] as Map<String, dynamic>?;

      return GemmaInterpretationSuccess(
        text: text.trim(),
        model: config.model,
        promptTokenCount:
        usage?['promptTokenCount'] as int?,
        candidateTokenCount:
        usage?['candidatesTokenCount'] as int?,
      );
    } catch (error, stackTrace) {
      return GemmaInterpretationException(
        error: 'Failed to parse successful response: $error',
        stackTrace: stackTrace,
      );
    }
  }

  /// Release the underlying HTTP client when the service is no longer needed.
  void dispose() => _client.close();
}