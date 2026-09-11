import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Coalesced per-session persistence (spec §5.4).
///
/// These tests pin the write-queue contract: rapid `persistSessions()` calls
/// collapse to a single encode, only changed sessions are re-encoded, a final
/// flush writes the latest state, and a session switch / lifecycle pause flushes
/// pending writes. The persisted transcript format and the
/// `ovid_session_bootstrap_v1` tail-50 envelope are asserted unchanged.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(AppState.resetTestInstance);

  ChatSession secondSession(String id) =>
      ChatSession(id: id, title: 'Second', model: 'test-model');

  List<Map<String, dynamic>> persistedMessages(
    List<String> raw,
    String sessionId,
  ) {
    final entry = raw
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .firstWhere((j) => j['id'] == sessionId);
    return (entry['messages'] as List).cast<Map<String, dynamic>>();
  }

  group('coalesced per-session persistence', () {
    test('N rapid persistSessions calls coalesce to one encode', () async {
      final app = AppState.createForTest();
      final activeId = app.activeSession!.id;
      app.sessionEncodeCountsForTest.clear();

      app.persistSessions();
      app.persistSessions();
      app.persistSessions();
      app.persistSessions();
      await app.flushSessionPersistenceForTest();

      expect(app.sessionEncodeCountsForTest[activeId], 1);
    });

    test('changed session is re-encoded and unchanged session is not', () async {
      final app = AppState.createForTest();
      final first = app.activeSession!;
      app.sessions.add(secondSession('second'));

      app.persistSessions();
      await app.flushSessionPersistenceForTest();
      expect(app.sessionEncodeCountsForTest[first.id], 1);
      expect(app.sessionEncodeCountsForTest['second'], 1);

      app.sessionEncodeCountsForTest.clear();
      // A direct metadata mutation is detected without an explicit dirty mark.
      app.sessions.firstWhere((s) => s.id == 'second').title = 'Renamed';
      app.persistSessions();
      await app.flushSessionPersistenceForTest();

      expect(app.sessionEncodeCountsForTest['second'], 1);
      expect(app.sessionEncodeCountsForTest[first.id], isNull);
    });

    test('a message append re-encodes only the mutated session', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      app.sessions.add(secondSession('second'));
      app.persistSessions();
      await app.flushSessionPersistenceForTest();
      app.sessionEncodeCountsForTest.clear();

      app.sendMessage('hello');

      await app.flushSessionPersistenceForTest();
      expect(app.sessionEncodeCountsForTest[active.id], 1);
      expect(app.sessionEncodeCountsForTest['second'], isNull);
    });

    test('a message edit re-encodes the edited session', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      app.sendMessage('hello');
      await app.flushSessionPersistenceForTest();
      app.sessionEncodeCountsForTest.clear();

      app.editMessage(active.id, 0, 'edited');
      await app.flushSessionPersistenceForTest();

      expect(app.sessionEncodeCountsForTest[active.id], 1);
    });

    test('an in-place edit on an earlier message is detected', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      app.sendMessage('one');
      app.sendMessage('two');
      await app.flushSessionPersistenceForTest();
      app.sessionEncodeCountsForTest.clear();

      // Agent tool cards mutate older messages in place after later appends.
      active.messages.first.toolDetail = 'streamed-tool-output';
      app.persistSessions();
      await app.flushSessionPersistenceForTest();

      expect(app.sessionEncodeCountsForTest[active.id], 1);
    });

    test('final flush writes the last state', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      app.sendMessage('first');
      app.sendMessage('last');
      await app.flushSessionPersistenceForTest();

      final prefs = await SharedPreferences.getInstance();
      final messages = persistedMessages(
        prefs.getStringList('ovid_sessions')!,
        active.id,
      );
      expect(messages.map((m) => m['content']), ['first', 'last']);
    });

    test('switching sessions flushes a pending write', () async {
      final app = AppState.createForTest();
      final first = app.activeSession!;
      app.sessions.add(secondSession('second'));
      // Hold the coalesced scheduler so only an explicit flush can write.
      app.suspendCoalescedPersistenceForTest = true;

      app.sendMessage('pending-after-switch');
      app.selectSession('second');
      await app.awaitPendingSessionWritesForTest();

      final prefs = await SharedPreferences.getInstance();
      final messages = persistedMessages(
        prefs.getStringList('ovid_sessions')!,
        first.id,
      );
      expect(
        messages.map((m) => m['content']),
        contains('pending-after-switch'),
      );
    });

    test('lifecycle pause flush writes pending state', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      app.suspendCoalescedPersistenceForTest = true;
      app.sendMessage('before-pause');

      // This is the call `_OvidShellState.didChangeAppLifecycleState` makes.
      await app.flushSessionPersistence();

      final prefs = await SharedPreferences.getInstance();
      final messages = persistedMessages(
        prefs.getStringList('ovid_sessions')!,
        active.id,
      );
      expect(messages.last['content'], 'before-pause');
    });

    test('shell wires lifecycle pause to the flush seam', () {
      final src = File('lib/ui/shell.dart').readAsStringSync();
      expect(src, contains('flushSessionPersistence'));
    });

    test('bootstrap tail-50 and fingerprint survive coalesced writes', () async {
      final app = AppState.createForTest();
      final active = app.activeSession!;
      active.messages.addAll([
        for (var i = 0; i < 80; i++)
          Message(role: 'user', content: 'message-$i'),
      ]);
      await app.flushSessionPersistenceForTest();

      final prefs = await SharedPreferences.getInstance();
      final activeRaw = prefs
          .getStringList('ovid_sessions')!
          .singleWhere((raw) => raw.startsWith('{"id":"${active.id}",'));
      final bootstrap =
          jsonDecode(prefs.getString('ovid_session_bootstrap_v1')!)
              as Map<String, dynamic>;
      final tail =
          (bootstrap['session'] as Map<String, dynamic>)['messages'] as List;
      expect(
        bootstrap['sourceFingerprint'],
        sha256.convert(utf8.encode(activeRaw)).toString(),
      );
      expect(tail, hasLength(50));
      expect((tail.first as Map<String, dynamic>)['content'], 'message-30');
      expect((tail.last as Map<String, dynamic>)['content'], 'message-79');
    });
  });
}
