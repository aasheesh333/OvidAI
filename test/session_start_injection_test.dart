import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';

/// End-to-end: a SessionStart hook's context (the mechanism real [CC] plugins
/// like `obra/superpowers` use) must reach the model request, not just be
/// captured. This is the wiring that makes such a plugin actually work.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('session-ctx-');
    SessionLedger.rootOverrideForTest = tmp;
    SessionSearch.dbPathOverrideForTest = '${tmp.path}/search.db';
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open(
            '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
          );
        }
      });
    }
    app = AppState.I;
    await app.initialize();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
    HookService.I.resetForTest();
    AgentService.retryDelaysForTest = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.setRunSessionForTest('');
    HookService.I.resetForTest();
  });

  ChatSession makeSession() {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: 'ctx-1',
      title: 'Titled',
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  void registerSuperpowersHook() {
    final m = NormalizedPluginManifest(
      id: 'jesse-vincent/superpowers',
      name: 'superpowers',
      version: '6.4.1',
      format: PluginFormat.claudeCode,
      rootPath: '/plugin',
      hooks: [
        PluginHook(
          pluginId: 'jesse-vincent/superpowers',
          event: 'session_start',
          ordinal: 0,
          type: 'command',
          payload: '"\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd" session-start',
          matcher: 'startup|clear|compact',
          timeoutS: 5,
        ),
      ],
    );
    PluginContributionRegistry.I.register(
      m,
      activation: PluginActivation.sessionActive,
      immediateSessionId: 'ctx-1',
    );
    addTearDown(
      () => PluginContributionRegistry.I.unregisterPlugin(m.id),
    );
  }

  test(
    'a SessionStart hook context is injected into the model request',
    () async {
      final s = makeSession();
      registerSuperpowersHook();
      HookService.I.executorForTest = (cmd, env) async => jsonEncode({
        'hookSpecificOutput': {
          'hookEventName': 'SessionStart',
          'additionalContext': 'You have superpowers. Use skills.',
        },
      });

      await HookService.I.fire(
        'session_start',
        s.id,
        payload: {'reason': 'created'},
      );
      expect(
        HookService.I.sessionContextFor(s.id),
        'You have superpowers. Use skills.',
      );

      List<Map<String, dynamic>>? captured;
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        captured = List<Map<String, dynamic>>.from(msgs);
        return {
          'role': 'assistant',
          'content': 'ok',
          'finish_reason': 'stop',
        };
      };

      await AgentService.I
          .runTask('hi', sessionId: s.id)
          .timeout(const Duration(seconds: 20));

      expect(captured, isNotNull);
      final injected = captured!.where(
        (m) =>
            m['role'] == 'system' &&
            (m['content'] as String).contains('You have superpowers'),
      );
      expect(
        injected,
        isNotEmpty,
        reason: 'the SessionStart context must be a system message',
      );
    },
  );

  test('no SessionStart context means no extra system message', () async {
    final s = makeSession();
    List<Map<String, dynamic>>? captured;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      captured = List<Map<String, dynamic>>.from(msgs);
      return {'role': 'assistant', 'content': 'ok', 'finish_reason': 'stop'};
    };
    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));
    expect(
      captured!.any(
        (m) => (m['content'] as String).contains('superpowers'),
      ),
      isFalse,
    );
  });
}
