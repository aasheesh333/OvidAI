import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';

/// Dynamic session naming (ChatGPT/Gemini style): the heuristic first-message
/// title is replaced by an LLM title after the first exchange; a user rename
/// is never overwritten; a failure keeps the heuristic and can be retried;
/// and a manual regenerate forces a fresh title.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('title-');
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
    AgentService.resetTitleStateForTest();
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentService.resetTitleStateForTest();
    app.sessions.clear();
    app.activeSessionId = null;
  });

  ChatSession session({String title = 'New chat'}) {
    final provider = app.providerById('ollama-local')!;
    provider
      ..baseUrl = 'http://127.0.0.1:1/v1'
      ..models = ['m']
      ..selectedModel = 'm'
      ..apiKey = 'k';
    final s = ChatSession(
      id: 'title-1',
      title: title,
      providerId: provider.id,
      model: 'm',
      mode: 'auto',
    );
    s.messages.add(Message(role: 'user', content: 'how do i parse json in dart'));
    s.messages.add(Message(role: 'assistant', content: 'Use jsonDecode.'));
    app.sessions.add(s);
    app.activeSessionId = s.id;
    return s;
  }

  Future<Map<String, dynamic>> titleReply(String text) async => {
    'choices': [
      {
        'message': {'content': text},
      },
    ],
  };

  test('an LLM title replaces the heuristic', () async {
    final s = session();
    AgentService.titleLlmForTest = (p, msgs, sess) => titleReply(
      'Parsing JSON in Dart',
    );
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, 'Parsing JSON in Dart');
  });

  test('quotes, a Title: prefix and trailing punctuation are stripped',
      () async {
    final s = session();
    AgentService.titleLlmForTest = (p, msgs, sess) =>
        titleReply('  "Title: Parsing JSON in Dart."  ');
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, 'Parsing JSON in Dart');
  });

  test('a user rename is never overwritten', () async {
    final s = session(title: 'My own name');
    var called = false;
    AgentService.titleLlmForTest = (p, msgs, sess) {
      called = true;
      return titleReply('Generated');
    };
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, 'My own name');
    expect(called, isFalse);
  });

  test('a failure keeps the heuristic and can be retried', () async {
    final heuristic = AppState.autoTitle('how do i parse json in dart');
    final s = session(title: heuristic);
    AgentService.titleLlmForTest = (p, msgs, sess) async => null;
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, heuristic);

    // Retry succeeds later.
    AgentService.titleLlmForTest = (p, msgs, sess) =>
        titleReply('Parsing JSON');
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, 'Parsing JSON');
  });

  test('an over-long title is rejected (heuristic stays)', () async {
    final s = session(title: 'heuristic title');
    AgentService.titleLlmForTest = (p, msgs, sess) =>
        titleReply('x' * 200);
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.title, 'heuristic title');
  });

  test('regenerate forces a fresh title even after a user rename', () async {
    final s = session(title: 'My own name');
    AgentService.titleLlmForTest = (p, msgs, sess) =>
        titleReply('Fresh Title');
    await AgentService.I.regenerateSessionTitle(s);
    expect(s.title, 'Fresh Title');
  });

  test('the generated flag persists across a restart', () async {
    final s = session();
    AgentService.titleLlmForTest = (p, msgs, sess) =>
        titleReply('Persisted Title');
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(s.titleGenerated, isTrue);

    final restored = ChatSession.fromJson(s.toJson());
    expect(restored.titleGenerated, isTrue);
  });

  test('a generated session is not re-titled on the next run', () async {
    final s = session();
    var calls = 0;
    AgentService.titleLlmForTest = (p, msgs, sess) {
      calls++;
      return titleReply('Only Once');
    };
    await AgentService.I.maybeGenerateSessionTitle(s);
    await AgentService.I.maybeGenerateSessionTitle(s);
    expect(calls, 1);
    expect(s.title, 'Only Once');
  });
}
