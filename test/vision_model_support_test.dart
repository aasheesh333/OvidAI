import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Vision detection was a strict allowlist, so a model id it could not fully
/// parse — e.g. a custom/aggregator id like `cb/deepseek-v4.1-flash` — always
/// returned false and the agent reported "the current model cannot read
/// images" even when the user had picked a vision-capable model. There was no
/// way to override it.
///
/// Now: a per-model user override wins, and the auto-detection recognises
/// common vision families.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('auto-detection', () {
    test('known vision families are recognised', () {
      for (final m in <String>[
        'gpt-4o',
        'gemini-2.5-flash',
        'claude-sonnet-4',
        'qwen2.5-vl-7b',
        'deepseek-vl2',
        'llava-1.5',
        'grok-2-vision-1212',
      ]) {
        expect(
          AgentService.modelSupportsImages(m),
          isTrue,
          reason: '$m should be vision-capable',
        );
      }
    });

    test('plain text models are not vision-capable', () {
      for (final m in <String>[
        'deepseek-chat',
        'gpt-3.5-turbo',
        'mistral-large',
      ]) {
        expect(AgentService.modelSupportsImages(m), isFalse, reason: m);
      }
    });

    test('an unparseable aggregator id stays conservative by default', () {
      expect(AgentService.modelSupportsImages('cb/deepseek-v4.1-flash'), isFalse);
    });
  });

  group('per-model override', () {
    test('force-on makes an otherwise-unknown model vision-capable', () {
      final p = ProviderConfig(
        name: 'InferHub',
        description: '',
        baseUrl: 'https://api.inferhub.dev/v1',
        models: ['zz/no-such-route-9'],
      );
      expect(
        AgentService.modelSupportsImagesResolved('zz/no-such-route-9', p),
        isFalse,
      );
      p.setModelVisionSupport('zz/no-such-route-9', true);
      expect(
        AgentService.modelSupportsImagesResolved('zz/no-such-route-9', p),
        isTrue,
      );
    });

    test(
      'a published modality field beats the name heuristic in both '
      'directions',
      () {
        // Inferhub serves cb/deepseek-v4.1-flash with modality text,image —
        // a name heuristic cannot parse it, the gateway can.
        final vision = ProviderConfig(
          name: 'InferHub',
          description: '',
          baseUrl: 'https://api.inferhub.dev/v1',
          models: const ['cb/deepseek-v4.1-flash', 'ali/glm-5.2'],
        );
        expect(
          AgentService.modelSupportsImagesResolved(
            'cb/deepseek-v4.1-flash',
            vision,
          ),
          isTrue,
        );
        // ali/glm-5.2 is announced text-only, so image input is refused even
        // though a similar-sounding route might otherwise look capable.
        expect(
          AgentService.modelSupportsImagesResolved('ali/glm-5.2', vision),
          isFalse,
        );
        // The manual toggle still outranks the gateway.
        vision.setModelVisionSupport('ali/glm-5.2', true);
        expect(
          AgentService.modelSupportsImagesResolved('ali/glm-5.2', vision),
          isTrue,
        );
      },
    );

    test('force-off disables a normally auto-detected model', () {
      final p = ProviderConfig(
        name: 'P',
        description: '',
        baseUrl: 'https://x/v1',
        models: ['gpt-4o'],
      );
      expect(AgentService.modelSupportsImagesResolved('gpt-4o', p), isTrue);
      p.setModelVisionSupport('gpt-4o', false);
      expect(AgentService.modelSupportsImagesResolved('gpt-4o', p), isFalse);
    });

    test('clearing the override returns to auto', () {
      final p = ProviderConfig(
        name: 'P',
        description: '',
        baseUrl: 'https://x/v1',
        models: ['cb/foo'],
      );
      p.setModelVisionSupport('cb/foo', true);
      expect(AgentService.modelSupportsImagesResolved('cb/foo', p), isTrue);
      p.setModelVisionSupport('cb/foo', null);
      expect(AgentService.modelSupportsImagesResolved('cb/foo', p), isFalse);
    });

    test('the override survives persistence', () {
      final p = ProviderConfig(
        id: 'custom-p',
        name: 'P',
        description: '',
        baseUrl: 'https://x/v1',
        models: ['cb/foo'],
        custom: true,
      );
      p.setModelVisionSupport('cb/foo', true);
      final restored = ProviderConfig(
        id: p.id,
        name: p.name,
        description: p.description,
        baseUrl: p.baseUrl,
        models: p.models,
      );
      restored.applyPersistedJson(p.toPersistedJson());
      expect(restored.modelVisionSupport('cb/foo'), isTrue);
      expect(
        AgentService.modelSupportsImagesResolved('cb/foo', restored),
        isTrue,
      );
    });
  });
}
