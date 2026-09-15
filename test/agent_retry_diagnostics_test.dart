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

/// Retry diagnostics: when a turn hits transient provider failures, the
/// think row must show the request size and the recovery — otherwise a
/// slow turn (e.g. 20s on a big session) is indistinguishable from a hang.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('retry-diag-');
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
    AgentService.retryDelaysForTest = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
    AgentService.runRetryWaitForTest = (_) => Duration.zero;
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.runRetryWaitForTest = null;
    AgentService.retryDelaysForTest = const [
      Duration(seconds: 3),
      Duration(seconds: 9),
      Duration(seconds: 27),
      Duration(seconds: 60),
    ];
    AgentService.setRunSessionForTest('');
  });

  ChatSession makeSession(String id) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: id,
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  // Think rows land on the zone-pinned run bucket (capped at 120), so
  // read them back from the session bucket after the run completes.
  String thinkText(String sessionId) => AgentService.I
      .runBucketForTest(sessionId)
      .runEvents
      .where((e) => e.kind == 'think')
      .map((e) => e.text)
      .join('\n');

  test('LLM retry line shows request size and recovery', () async {
    final s = makeSession('retry-diag-1');
    var attempt = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      attempt++;
      if (attempt == 1) {
        AgentService.I.streamToBubbleForTest(session, 'PARTIAL ');
        AgentService.I.lastError = 'stream error: boom';
        return null;
      }
      AgentService.I.streamToBubbleForTest(session, 'FINAL ANSWER');
      return {
        'role': 'assistant',
        'content': 'FINAL ANSWER',
        'finish_reason': 'stop',
      };
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 20));

    final thinks = thinkText(s.id);
    expect(thinks, contains('KB request'));
    expect(thinks, contains('recovered after 2 attempts'));
  });

  test('run-level retry line shows context size', () async {
    final s = makeSession('retry-diag-2');
    var attempt = 0;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      attempt++;
      // Exhaust the whole inner retry budget (5 attempts), then succeed on
      // the run-level retry so the outer hiccup line fires.
      if (attempt <= 5) {
        AgentService.I.lastError = 'stream error: boom';
        return null;
      }
      AgentService.I.streamToBubbleForTest(session, 'FINAL ANSWER');
      return {
        'role': 'assistant',
        'content': 'FINAL ANSWER',
        'finish_reason': 'stop',
      };
    };

    await AgentService.I
        .runTask('hi', sessionId: s.id)
        .timeout(const Duration(seconds: 30));

    expect(thinkText(s.id), contains('tokens in context'));
  });
}
