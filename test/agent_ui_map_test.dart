import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

/// The agent must know where every app feature lives so it can guide the
/// user step-by-step and drive there itself in Control mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('ui-map-');
    SessionLedger.rootOverrideForTest = ledgerDir;
    SessionSearch.dbPathOverrideForTest = '${ledgerDir.path}/search.db';
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.setRunSessionForTest('');
  });

  // The map wraps lines for readability; match on unwrapped text.
  String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  test('UI map names every feature destination', () {
    final map = flat(AgentService.appUiMapForTest);
    for (final destination in [
      'Settings → Providers',
      'Settings → Plugins',
      'Studio',
      'Settings → Device health',
      'Settings → Usage',
      'accessibility service',
      'Composer',
      'Control mode',
    ]) {
      expect(map, contains(destination), reason: 'map must name $destination');
    }
  });

  test('the system prompt sent to the model includes the UI map', () async {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: 'ui-map-1',
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;

    List<Map<String, dynamic>>? sent;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      sent = msgs;
      AgentService.I.streamToBubbleForTest(session, 'ok');
      return {'role': 'assistant', 'content': 'ok', 'finish_reason': 'stop'};
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    expect(sent, isNotNull);
    final system = flat(
      sent!.firstWhere((m) => m['role'] == 'system')['content'] as String,
    );
    expect(system, contains('APP UI MAP'));
    expect(system, contains('Settings → Plugins'));
  });
}
