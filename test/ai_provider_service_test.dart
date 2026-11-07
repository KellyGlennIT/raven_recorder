import 'package:flutter_test/flutter_test.dart';
import 'package:raven/services/ai_provider_service.dart';

void main() {
  group('RAVEN AI provider setup', () {
    test('provider IDs are stable for secure key storage', () {
      expect(RavenAiProvider.openRouter.id, 'openrouter');
      expect(RavenAiProvider.openAi.id, 'openai');
      expect(RavenAiProvider.gemini.id, 'gemini');
    });

    test('provider defaults use their official API endpoints', () {
      expect(RavenAiProvider.openRouter.endpoint.host, 'openrouter.ai');
      expect(RavenAiProvider.openAi.endpoint.host, 'api.openai.com');
      expect(RavenAiProvider.gemini.endpoint.host, 'generativelanguage.googleapis.com');
    });

    test('model defaults are provider-specific', () {
      expect(RavenAiProvider.openRouter.defaultModel, contains('/'));
      expect(RavenAiProvider.openAi.defaultModel, isNot(contains('/')));
      expect(RavenAiProvider.gemini.defaultModel, startsWith('gemini-'));
    });

    test('key setup guides point to official providers', () {
      expect(RavenAiProvider.openRouter.keyInstructions, contains('openrouter.ai'));
      expect(RavenAiProvider.openAi.keyInstructions, contains('platform.openai.com'));
      expect(RavenAiProvider.gemini.keyInstructions, contains('aistudio.google.com'));
    });
  });
}
