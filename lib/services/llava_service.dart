import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:image/image.dart' as img;

/// Service to communicate with a local LLaVA (Large Language and Vision Assistant) model
class LlavaService {
  final String baseUrl;
  final http.Client _client = http.Client();
  final _logger = Logger('LlavaService');

  /// Create a new LLaVA service with the specified base URL
  /// Example: LlavaService(baseUrl: 'http://localhost:8080')
  LlavaService({required this.baseUrl});

  /// Process an image and text prompt with the LLaVA model
  /// Returns the model's response as a String
  Future<String> processImageAndText(
      Uint8List imageBytes, String prompt) async {
    _logger.info('Processing image and prompt: "$prompt"');

    // Resize the image to 320x240 to reduce payload size
    Uint8List resizedImageBytes = imageBytes;
    try {
      if (imageBytes.isNotEmpty) {
        final originalImage = img.decodeImage(imageBytes);
        if (originalImage != null) {
          final resizedImage = img.copyResize(
            originalImage,
            width: 320,
            height: 240,
            interpolation: img.Interpolation.average,
          );

          // Convert back to JPEG with reduced quality
          resizedImageBytes = Uint8List.fromList(
            img.encodeJpg(resizedImage, quality: 85),
          );

          _logger.info(
            'Resized image from ${imageBytes.length} bytes to ${resizedImageBytes.length} bytes (${(resizedImageBytes.length / imageBytes.length * 100).toStringAsFixed(1)}%)',
          );
        }
      }
    } catch (e) {
      _logger.warning('Error resizing image: $e - will use original image');
    }

    // Convert image to base64
    final base64Image = base64Encode(resizedImageBytes);

    try {
      _logger.info('Sending request to Ollama LLaVA at $baseUrl');

      // Using Ollama API format
      final response = await _client.post(
        Uri.parse('$baseUrl/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {
            'temperature': 0.7,
            'num_predict': 1024,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final result = data['response'] as String;
        _logger.info('Received response from Ollama (${result.length} chars)');
        return result;
      } else {
        final error =
            'Failed to process: ${response.statusCode} - ${response.body}';
        _logger.warning(error);
        throw Exception(error);
      }
    } catch (e) {
      _logger.severe('Error communicating with Ollama: $e');
      return 'Error: $e';
    }
  }

  /// Process a text-only prompt with the LLM
  /// Returns the model's response as a String
  Future<String> processTextOnly(String prompt) async {
    _logger.info('Processing text-only prompt: "$prompt"');

    try {
      _logger.info('Sending text-only request to Ollama at $baseUrl');

      // Using Ollama API format for text-only queries
      final response = await _client.post(
        Uri.parse('$baseUrl/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava', // Using the same model, but without images
          'prompt': prompt,
          'stream': false,
          'options': {
            'temperature': 0.7,
            'num_predict': 1024,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final result = data['response'] as String;
        _logger.info('Received text-only response from Ollama (${result.length} chars)');
        return result;
      } else {
        final error =
            'Failed to process text-only query: ${response.statusCode} - ${response.body}';
        _logger.warning(error);
        throw Exception(error);
      }
    } catch (e) {
      _logger.severe('Error communicating with Ollama for text-only query: $e');
      return 'Error: $e';
    }
  }

  /// Check if the LLaVA service is available
  Future<bool> isAvailable() async {
    try {
      // Ollama API doesn't have a dedicated health endpoint, so we'll check the models list
      final response = await _client.get(
        Uri.parse('$baseUrl/api/tags'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Ollama API returns a list of models in the 'models' field
        if (data.containsKey('models')) {
          final models = data['models'] as List<dynamic>;
          // Check if llava model is available
          return models.any((model) =>
              (model['name'] as String).toLowerCase().contains('llava'));
        }
      }
      return false;
    } catch (e) {
      _logger.warning('Ollama service unavailable: $e');
      return false;
    }
  }

  /// Dispose of the HTTP client when done
  void dispose() {
    _client.close();
  }
}
