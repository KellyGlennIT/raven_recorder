import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'ai_key_vault.dart';

enum RavenAiProvider {
  openRouter(
    id: 'openrouter',
    label: 'OpenRouter',
    defaultModel: 'meta-llama/llama-3.3-70b-instruct:free',
    endpoint: 'https://openrouter.ai/api/v1/chat/completions',
    keyInstructions: 'Create a key at openrouter.ai/keys. Many models require credits.',
  ),
  openAi(
    id: 'openai',
    label: 'OpenAI API',
    defaultModel: 'gpt-4o-mini',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    keyInstructions: 'Create a key at platform.openai.com/api-keys. API billing is separate from ChatGPT Plus.',
  ),
  gemini(
    id: 'gemini',
    label: 'Google Gemini API',
    defaultModel: 'gemini-2.0-flash',
    endpoint: 'https://generativelanguage.googleapis.com',
    keyInstructions: 'Create a key at aistudio.google.com/app/apikey.',
  );

  const RavenAiProvider({
    required this.id,
    required this.label,
    required this.defaultModel,
    required String endpoint,
    required this.keyInstructions,
  }) : _endpoint = endpoint;

  final String id;
  final String label;
  final String defaultModel;

  /// Official API endpoint (for Gemini, the API host); the service appends the
  /// model path where the provider requires one.
  Uri get endpoint => Uri.parse(_endpoint);
  final String _endpoint;

  final String keyInstructions;
}

class RavenAiProviderService {
  RavenAiProviderService({required AiKeyVault vault}) : _vault = vault;
  final AiKeyVault _vault;
  
  static const int _maxPromptLength = 60000;
  static const Duration _timeout = Duration(seconds: 45);

  Future<void> testConnection({
    required RavenAiProvider provider,
    required String model,
  }) async {
    await generate(
      provider: provider,
      model: model,
      prompt: 'Reply with the single word: OK',
    );
  }

  /// Releases any service resources. Requests use a short-lived HTTP client,
  /// so this exists so callers can dispose the service uniformly.
  void close() {}

  Future<String> generate({
    required RavenAiProvider provider,
    required String model,
    required String prompt,
  }) async {
    final cleanPrompt = prompt.trim();
    if (cleanPrompt.isEmpty) {
      throw const FormatException('The prompt is empty.');
    }
    if (cleanPrompt.length > _maxPromptLength) {
      throw FormatException('The prompt is too long (${cleanPrompt.length} chars). Limit is $_maxPromptLength.');
    }

    final apiKey = await _vault.readKey(provider.id);
    if (apiKey == null || apiKey.isEmpty) {
      throw StateError('No API key saved for ${provider.label}.');
    }

    int attempt = 0;
    const maxAttempts = 3;
    
    while (attempt < maxAttempts) {
      attempt++;
      try {
        return await _executeRequest(provider, model, cleanPrompt, apiKey);
      } on _RetryableException {
        if (attempt >= maxAttempts) rethrow;
        await Future.delayed(Duration(seconds: 2 * attempt));
        continue;
      }
    }
    throw StateError('Failed after $maxAttempts attempts.');
  }

  Future<String> _executeRequest(
    RavenAiProvider provider,
    String model,
    String prompt,
    String apiKey,
  ) async {
    final client = http.Client();
    try {
      final http.Response response;
      
      switch (provider) {
        case RavenAiProvider.openRouter:
        case RavenAiProvider.openAi:
          final url = provider == RavenAiProvider.openRouter
              ? Uri.parse('https://openrouter.ai/api/v1/chat/completions')
              : Uri.parse('https://api.openai.com/v1/chat/completions');
          
          response = await client.post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': model,
              'messages': [{'role': 'user', 'content': prompt}],
            }),
          ).timeout(_timeout);
          break;

        case RavenAiProvider.gemini:
          final url = Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
          response = await client.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': prompt}
                  ]
                }
              ]
            }),
          ).timeout(_timeout);
          break;
      }

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return _parseResponse(provider, data);
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw StateError('Invalid API key or access denied. Please check your key in Settings.');
      }
      
      if (response.statusCode == 429) {
        throw StateError('Rate limit exceeded. Please wait a moment and try again, or check your provider billing.');
      }
      
      if (response.statusCode >= 500) {
        throw _RetryableException('Provider server error (${response.statusCode}).');
      }

      final errorBody = jsonDecode(response.body);
      final errorMessage = _extractErrorMessage(provider, errorBody);
      throw StateError('${provider.label} error: $errorMessage (HTTP ${response.statusCode})');

    } on TimeoutException {
      throw _RetryableException('The request timed out. Check your internet connection.');
    } on SocketException {
      throw _RetryableException('No internet connection.');
    } finally {
      client.close();
    }
  }

  String _parseResponse(RavenAiProvider provider, dynamic data) {
    try {
      if (provider == RavenAiProvider.gemini) {
        final text = data['candidates'][0]['content']['parts'][0]['text'];
        return text.toString().trim();
      } else {
        final text = data['choices'][0]['message']['content'];
        return text.toString().trim();
      }
    } catch (e) {
      throw StateError('The AI provider returned an unexpected response format.');
    }
  }

  String _extractErrorMessage(RavenAiProvider provider, dynamic data) {
    try {
      if (provider == RavenAiProvider.gemini) {
        return data['error']['message'] ?? 'Unknown error';
      } else {
        return data['error']['message'] ?? data['message'] ?? 'Unknown error';
      }
    } catch (_) {
      return 'Unknown error';
    }
  }
}

class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);
  @override
  String toString() => message;
}