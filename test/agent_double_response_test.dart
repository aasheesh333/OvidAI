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

/// Regression: a transient provider failure mid-stream used to APPEND the
/// retry's output to the failed attempt's partial bubble (or leave the
/// partial beside a fresh bubble), so the user saw a doubled / garbled
/// answer. The retry wrapper must discard the failed attempt's live bubble
/// and buffers before the next attempt.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ledgerDir;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ledgerDir = Directory.systemTemp.createTempSync('double-resp-');
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
    // No real backoff sleeps during the retry.
    AgentService.retryDelaysForTest = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ];
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.runRetryWaitForTest = null;
    AgentService.setRunSessionForTest('');
  });

  tearDownAll(() {
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

  ChatSession makeSession() {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['test-model']
      ..selectedModel = 'test-model';
    final s = ChatSession(
      id: 'double-1',
      title: 'Custom title', // prevents the fire-and-forget title LLM call
      providerId: provider.id,
      model: 'test-model',
      mode: 'auto',
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  test(
    'transient mid-stream retry does not append the failed attempt',
    () async {
      final s = makeSession();
      var attempt = 0;
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        attempt++;
        if (attempt == 1) {
          // First attempt streams a partial answer, then dies transiently.
          AgentService.I.streamToBubbleForTest(session, 'PARTIAL ');
          AgentService.I.lastError = 'stream error: boom';
          return null;
        }
        // Retry succeeds with the real answer.
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

      final assistantText = s.messages
          .where((m) => m.role == 'assistant' && m.kind == MsgKind.text)
          .toList();
      expect(
        assistantText.length,
        1,
        reason: 'a retry must produce exactly one assistant bubble',
      );
      expect(assistantText.single.content, 'FINAL ANSWER');
      expect(
        s.messages.any((m) => (m.content).contains('PARTIAL')),
        isFalse,
        reason: 'the failed attempt partial must be discarded',
      );
    },
  );

  test(
    'a fully failed transient run leaves no partial bubble behind',
    () async {
      final s = makeSession();
      AgentService.runRetryWaitForTest = (_) => Duration.zero;
      var attempt = 0;
      AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
        attempt++;
        // Every attempt streams a partial then fails transiently.
        AgentService.I.streamToBubbleForTest(session, 'PARTIAL $attempt ');
        AgentService.I.lastError = 'stream error: boom';
        return null;
      };

      await AgentService.I
          .runTask('hi', sessionId: s.id)
          .timeout(const Duration(seconds: 30));

      // No partial assistant text should survive; only the error notice.
      final assistantText = s.messages
          .where((m) => m.role == 'assistant' && m.kind == MsgKind.text)
          .toList();
      expect(
        assistantText.where((m) => m.content.contains('PARTIAL')).length,
        0,
        reason: 'failed-attempt partials must never persist in the transcript',
      );
    },
  );
}
