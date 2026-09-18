import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Anthropic native Messages API + full agent provider-control.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  group('ApiFormat', () {
    test('parses anthropic aliases and defaults to openai', () {
      expect(ApiFormat.parse('anthropic'), ApiFormat.anthropic);
      expect(ApiFormat.parse('Claude'), ApiFormat.anthropic);
      expect(ApiFormat.parse('messages'), ApiFormat.anthropic);
      expect(ApiFormat.parse('openai'), ApiFormat.openai);
      expect(ApiFormat.parse(null), ApiFormat.openai);
      expect(ApiFormat.parse('garbage'), ApiFormat.openai);
    });

    test('effective format auto-detects the Anthropic host', () {
      final auto = ProviderConfig(
        name: 'Claude',
        description: '',
        baseUrl: 'https://api.anthropic.com/v1',
      );
      expect(auto.effectiveApiFormat, ApiFormat.anthropic);

      final explicit = ProviderConfig(
        name: 'Proxy',
        description: '',
        baseUrl: 'https://my-proxy.test/v1',
        apiFormat: ApiFormat.anthropic,
      );
      expect(explicit.effectiveApiFormat, ApiFormat.anthropic);

      final openai = ProviderConfig(
        name: 'OpenAI',
        description: '',
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(openai.effectiveApiFormat, ApiFormat.openai);
    });
  });

  group('anthropic request conversion', () {
    test('system turns collapse into the top-level system string', () {
      final r = AgentService.I.anthropicRequestMessagesForTest([
        {'role': 'system', 'content': 'You are Ovid.'},
        {'role': 'system', 'content': 'Be terse.'},
        {'role': 'user', 'content': 'hi'},
      ]);
      expect(r.system, 'You are Ovid.\n\nBe terse.');
      expect(r.messages.length, 1);
      expect(r.messages.first['role'], 'user');
      expect(r.messages.first['content'], 'hi');
    });

    test('assistant tool_calls become tool_use blocks', () {
      final r = AgentService.I.anthropicRequestMessagesForTest([
        {
          'role': 'assistant',
          'content': 'working',
          'tool_calls': [
            {
              'id': 'call_1',
              'type': 'function',
              'function': {
                'name': 'run_shell',
                'arguments': '{"command":"ls"}',
              },
            },
          ],
        },
      ]);
      final blocks = r.messages.single['content'] as List;
      expect(blocks.first, {'type': 'text', 'text': 'working'});
      final use = blocks[1] as Map;
      expect(use['type'], 'tool_use');
      expect(use['id'], 'call_1');
      expect(use['name'], 'run_shell');
      expect(use['input'], {'command': 'ls'});
    });

    test('consecutive tool results merge into one user turn', () {
      final r = AgentService.I.anthropicRequestMessagesForTest([
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'a'},
        {'role': 'tool', 'tool_call_id': 'call_2', 'content': 'b'},
      ]);
      expect(r.messages.length, 1);
      final blocks = r.messages.single['content'] as List;
      expect(blocks.length, 2);
      expect(blocks[0]['type'], 'tool_result');
      expect(blocks[0]['tool_use_id'], 'call_1');
      expect(blocks[1]['tool_use_id'], 'call_2');
      // Helper key must never leak to the wire.
      expect(r.messages.single.containsKey('_toolResults'), isFalse);
    });

    test('malformed tool arguments degrade to an empty input object', () {
      final r = AgentService.I.anthropicRequestMessagesForTest([
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'id': 'x',
              'function': {'name': 'f', 'arguments': '{not json'},
            },
          ],
        },
      ]);
      final use = (r.messages.single['content'] as List).first as Map;
      expect(use['input'], <String, dynamic>{});
    });
  });

  group('anthropic tool conversion', () {
    test('OpenAI functions become Anthropic input_schema tools', () {
      final out = AgentService.I.anthropicToolsForTest([
        {
          'type': 'function',
          'function': {
            'name': 'run_shell',
            'description': 'run',
            'parameters': {
              'type': 'object',
              'properties': {
                'command': {'type': 'string'},
              },
            },
          },
        },
      ]);
      expect(out.single['name'], 'run_shell');
      expect(out.single['description'], 'run');
      expect(out.single.containsKey('input_schema'), isTrue);
      expect(out.single.containsKey('parameters'), isFalse);
      expect(
        (out.single['input_schema'] as Map)['properties'],
        contains('command'),
      );
    });
  });

  group('full agent provider control', () {
    test('add -> get -> update -> key -> model -> select -> remove', () async {
      final app = AppState.I;
      final err = await app.addCustomProvider(
        name: 'My Claude Proxy',
        baseUrl: 'https://proxy.test/v1',
        apiFormat: ApiFormat.anthropic,
      );
      expect(err, isNull);
      final p = app.providerById('custom-my-claude-proxy')!;
      expect(p.effectiveApiFormat, ApiFormat.anthropic);

      await app.updateProviderName(p, 'Renamed Proxy');
      expect(p.name, 'Renamed Proxy');

      await app.updateProviderBaseUrlChecked(p, 'https://proxy2.test/v1');
      expect(p.baseUrl, 'https://proxy2.test/v1');

      await app.updateProviderApiFormat(p, ApiFormat.openai);
      expect(p.apiFormat, ApiFormat.openai);

      await app.updateProviderApiKey(p, 'sk-test');
      expect(p.hasKey, isTrue);
      await app.clearProviderApiKey(p);
      expect(p.hasKey, isFalse);

      expect(await app.addProviderModel(p, 'claude-x'), isNull);
      expect(p.models, contains('claude-x'));
      expect(await app.addProviderModel(p, 'claude-x'), isNotNull);
      expect(await app.removeProviderModel(p, 'claude-x'), isNull);
      expect(p.models, isNot(contains('claude-x')));

      expect(await app.removeCustomProvider(p.id), isNull);
      expect(app.providerById(p.id), isNull);
    });

    test('resolveProvider matches id, exact name, then substring', () async {
      final app = AppState.I;
      expect(app.resolveProvider('Anthropic')?.name, 'Anthropic');
      expect(app.resolveProvider('anthropic')?.name, 'Anthropic');
      expect(app.resolveProvider('OpenAI')?.name, 'OpenAI');
      expect(app.resolveProvider('nope-nothing'), isNull);
    });

    test('built-in providers cannot be removed but keys can be cleared', () async {
      final app = AppState.I;
      final anthropic = app.resolveProvider('Anthropic')!;
      await app.updateProviderApiKey(anthropic, 'sk-ant');
      expect(anthropic.hasKey, isTrue);
      expect(await app.clearProviderApiKey(anthropic), isNull);
      expect(anthropic.hasKey, isFalse);
      expect(await app.removeCustomProvider(anthropic.id), isNotNull);
    });

    test('removing the active model clears the session selection', () async {
      final app = AppState.I;
      final p = app.resolveProvider('Anthropic')!;
      final s = ChatSession(id: 's1', title: 't', model: 'claude-sonnet-4-20250514')
        ..providerId = p.id;
      app.sessions.add(s);
      app.activeSessionId = s.id;
      await app.removeProviderModel(p, 'claude-sonnet-4-20250514');
      expect(s.model, 'Select a provider');
    });

    test('apiFormat round-trips through persistence', () async {
      final app = AppState.I;
      await app.addCustomProvider(
        name: 'Persisted Anthropic',
        baseUrl: 'https://p.test/v1',
        apiFormat: ApiFormat.anthropic,
      );
      await app.persistProviderState();
      app.providers.clear();
      await app.loadProviderState();
      final p = app.providerById('custom-persisted-anthropic')!;
      expect(p.apiFormat, ApiFormat.anthropic);
    });
  });

  group('catalog tool surface', () {
    test('agent exposes the full provider-control tool set', () {
      final names = AgentService.I
          .toolsForTest()
          .map((t) => (t['function'] as Map)['name'])
          .toSet();
      for (final required in <String>[
        'catalog_list_providers',
        'catalog_get_provider',
        'catalog_add_provider',
        'catalog_update_provider',
        'catalog_set_provider_key',
        'catalog_clear_provider_key',
        'catalog_add_provider_model',
        'catalog_remove_provider_model',
        'catalog_list_models',
        'catalog_select_model',
        'catalog_remove_provider',
      ]) {
        expect(names, contains(required), reason: 'missing $required');
      }
    });

    test('catalog_add_provider documents the anthropic api_format', () {
      final def = AgentService.I
          .toolsForTest()
          .map((t) => t['function'] as Map)
          .firstWhere((f) => f['name'] == 'catalog_add_provider');
      final props = (def['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('api_format'), isTrue);
      expect(
        ((props['api_format'] as Map)['enum'] as List).toSet(),
        {'openai', 'anthropic'},
      );
    });

    test('new mutating catalog tools are blocked in read-only mode', () {
      final src = File(
        'lib/core/agent_service.dart',
      ).readAsStringSync();
      for (final t in <String>[
        'catalog_update_provider',
        'catalog_set_provider_key',
        'catalog_clear_provider_key',
        'catalog_add_provider_model',
        'catalog_remove_provider_model',
        'catalog_select_model',
      ]) {
        expect(
          RegExp("case '$t':").allMatches(src).length,
          greaterThanOrEqualTo(2),
          reason: '$t must appear in both the RO gate and write list',
        );
      }
    });
  });

  group('robustness', () {
    test('malformed tool args never abort the run (B2 guard present)', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('invalid arguments JSON for'));
      // The old unguarded cast must be gone.
      expect(
        src,
        isNot(contains("jsonDecode(fn['arguments'] ?? '{}') as Map<String, dynamic>")),
      );
    });
  });
}
