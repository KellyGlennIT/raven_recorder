import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_key_vault.dart';

/// Minimal, provider-aware REST client. No provider SDK is bundled and no key is
/// sent anywhere until the user explicitly invokes an AI action.
enum RavenAiProvider { openRouter, openAi, gemini }

extension RavenAiProviderDetails on RavenAiProvider {
  String get id => switch (this) {
        RavenAiProvider.openRouter => 'openrouter',
        RavenAiProvider.openAi => 'openai',
        RavenAiProvider.gemini => 'gemini',
      };

  String get label => switch (this) {
        RavenAiProvider.openRouter => 'OpenRouter',
        RavenAiProvider.openAi => 'OpenAI API',
        RavenAiProvider.gemini => 'Google Gemini API',
      };

  String get defaultModel => switch (this) {
        RavenAiProvider.openRouter => 'openrouter/free',
        RavenAiProvider.openAi => 'gpt-4o-mini',
        RavenAiProvider.gemini => 'gemini-3.8-flash',
      };

  String get keyInstructions => switch (this) {
        RavenAiProvider.openRouter => 'Open openrouter.ai, create/sign in to an account, open Keys, create a key, and set a spending limit. Some models are free; others require credits.',
        RavenAiProvider.openAi => 'Open platform.openai.com, sign in, open API keys, create a secret key, and check API billing/limits. A ChatGPT subscription does not automatically include API credits.',
        RavenAiProvider.gemini => 'Open aistudio.google.com, sign in, open Get API key, create a key, and check the API usage and billing terms for your project.',
      };

  Uri get endpoint => switch (this) {
        RavenAiProvider.openRouter => Uri.parse('https://openrouter.ai/api/v1/chat/completions'),
        RavenAiProvider.openAi => Uri.parse('https://api.openai.com/v1/chat/completions'),
        RavenAiProvider.gemini => Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
      };
}

class RavenAiProviderService {
  RavenAiProviderService({AiKeyVault? vault, HttpClient? client})
      : _vault = vault ?? AiKeyVault(),
        _client = client ?? HttpClient();

  final AiKeyVault _vault;
  final HttpClient _client;

  Future<String> generate({
    required RavenAiProvider provider,
    required String model,
    required String prompt,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final key = await _vault.readKey(provider.id);
    if (key == null || key.trim().isEmpty) {
      throw StateError('No ${provider.label} API key is saved. Configure it in Settings first.');
    }
    final cleanModel = model.trim();
    if (cleanModel.isEmpty || cleanModel.length > 160) {
      throw ArgumentError('Enter a valid model identifier.');
    }
    if (prompt.trim().isEmpty) throw ArgumentError('There is no text to send to the AI.');
    if (prompt.length > 60000) throw ArgumentError('This request is too long. Shorten the text to 60,000 characters or less.');

    final Uri uri;
    final Map<String, Object?> body;
    final Map<String, String> headers = <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
      HttpHeaders.acceptHeader: 'application/json',
    };
    if (provider == RavenAiProvider.gemini) {
      final safeModel = Uri.encodeComponent(cleanModel);
      uri = provider.endpoint.resolve('/v1beta/models/$safeModel:generateContent');
      headers['x-goog-api-key'] = key;
      body = <String, Object?>{
        'contents': <Object?>[
          <String, Object?>{'parts': <Object?>[<String, String>{'text': prompt}]}
        ],
        'generationConfig': <String, Object?>{'temperature': 0.2, 'maxOutputTokens': 2048},
      };
    } else {
      uri = provider.endpoint;
      headers[HttpHeaders.authorizationHeader] = 'Bearer $key';
      body = <String, Object?>{
        'model': cleanModel,
        'messages': <Object?>[
          <String, String>{'role': 'user', 'content': prompt}
        ],
        'temperature': 0.2,
        'max_tokens': 2048,
      };
    }

    HttpClientRequest request;
    HttpClientResponse response;
    try {
      request = await _client.postUrl(uri).timeout(timeout);
      // Never forward a bearer/API key to an unexpected redirect host. Official
      // provider endpoints do not require redirects for these POST requests.
      request.followRedirects = false;
      headers.forEach((name, value) => request.headers.set(name, value));
      request.write(jsonEncode(body));
      response = await request.close().timeout(timeout);
      final responseBytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (responseBytes.length + chunk.length > 1024 * 1024) {
          throw const RavenAiException('The AI provider response exceeded the 1 MB safety limit.');
        }
        responseBytes.addAll(chunk);
      }
      final responseText = utf8.decode(responseBytes, allowMalformed: true);
      Map<String, dynamic> decoded;
      try {
        decoded = _decodeObject(responseText);
      } on FormatException {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw RavenAiException('AI provider returned HTTP ${response.statusCode}. Check the provider, model, and API-key settings.');
        }
        rethrow;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final errorObject = decoded['error'];
        final detail = errorObject is Map ? (errorObject['message']?.toString() ?? '') : '';
        final message = detail.isNotEmpty ? detail : 'Provider returned HTTP ${response.statusCode}.';
        throw RavenAiException(_safeProviderError(response.statusCode, message, key));
      }
      final text = provider == RavenAiProvider.gemini
          ? _geminiText(decoded)
          : _openAiCompatibleText(decoded);
      if (text.trim().isEmpty) throw const RavenAiException('The provider returned an empty response. Try another model.');
      return text.trim();
    } on RavenAiException {
      rethrow;
    } on TimeoutException {
      throw const RavenAiException('The AI request timed out. Check your connection or try again.');
    } on SocketException {
      throw const RavenAiException('Could not connect to the AI provider. Check your internet connection.');
    } on FormatException {
      throw const RavenAiException('The provider returned an unreadable response. Check the model and provider settings.');
    } catch (error) {
      if (error is ArgumentError || error is StateError) rethrow;
      throw RavenAiException('AI request failed (${error.runtimeType}). Check provider, model, and network settings.');
    }
  }

  Future<void> testConnection({required RavenAiProvider provider, required String model}) async {
    await generate(
      provider: provider,
      model: model,
      prompt: 'Reply with exactly: RAVEN connection successful',
      timeout: const Duration(seconds: 25),
    );
  }

  Map<String, dynamic> _decodeObject(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic>) throw const FormatException('Expected JSON object.');
    return value;
  }

  String _openAiCompatibleText(Map<String, dynamic> json) {
    final choices = json['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final message = (choices.first as Map)['message'];
      if (message is Map) {
        final content = message['content'];
        if (content is String) return content;
        if (content is List) {
          return content.whereType<Map>()
              .map((part) => part['text']?.toString() ?? '')
              .where((part) => part.isNotEmpty)
              .join('\n');
        }
      }
    }
    final error = json['error'];
    if (error is Map) throw RavenAiException(error['message']?.toString() ?? 'Provider rejected the request.');
    return '';
  }

  String _geminiText(Map<String, dynamic> json) {
    final candidates = json['candidates'];
    if (candidates is List && candidates.isNotEmpty && candidates.first is Map) {
      final content = (candidates.first as Map)['content'];
      if (content is Map && content['parts'] is List) {
        return (content['parts'] as List)
            .whereType<Map>()
            .map((part) => part['text']?.toString() ?? '')
            .where((part) => part.isNotEmpty)
            .join('\n');
      }
    }
    final feedback = json['promptFeedback'];
    if (feedback is Map) throw RavenAiException('Gemini did not process this prompt (${feedback['blockReason'] ?? 'blocked'}).');
    return '';
  }

  String _safeProviderError(int status, String message, String key) {
    // Provider errors can echo request details. Never surface the credential.
    final redacted = message.replaceAll(key, '[redacted]');
    final shortened = redacted.replaceAll(RegExp(r'\s+'), ' ').trim();
    return 'AI provider error (HTTP $status): ${shortened.length > 260 ? '${shortened.substring(0, 260)}…' : shortened}';
  }

  void close() => _client.close(force: true);
}

class RavenAiException implements Exception {
  const RavenAiException(this.message);
  final String message;
  @override
  String toString() => message;
}
