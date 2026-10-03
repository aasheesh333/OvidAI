import 'dart:ffi' as ffi;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final agent = AgentService.I;
  late AppState app;
  late ChatSession current;
  late ChatSession other;
  setUpAll(() {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
    SessionSearch.dbPathOverrideForTest = ':memory:';
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    current = ChatSession(id: 'current', title: 'Current', model: 'm');
    other = ChatSession(
      id: 'other',
      title: 'NamedSession',
      model: 'm',
      messages: [
        Message(role: 'user', content: 'private needle at the beginning'),
        for (var i = 0; i < 20; i++)
          Message(role: 'assistant', content: 'row $i'),
      ],
    );
    app.sessions.addAll([current, other]);
    app.activeSessionId = current.id;
    AgentService.setRunSessionForTest(current.id);
  });
  tearDown(() {
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
  });
  Future<String> read(String id) =>
      agent.dispatchForTest('session_read', {'session_id': id});

  test(
    'explicit named reference permits full read with sharing off, only here',
    () async {
      final expanded = await agent.expandReferences(
        'Use @NamedSession',
        current,
      );
      expect(expanded, contains('referenced session "NamedSession"'));
      expect(await read(other.id), contains('private needle at the beginning'));
      expect(app.shareSessionMemory, isFalse);
      final third = ChatSession(id: 'third', title: 'Third', model: 'm');
      app.sessions.add(third);
      AgentService.setRunSessionForTest(third.id);
      expect(await read(other.id), contains('DENIED'));
      expect(
        other.messages,
        hasLength(21),
        reason: 'reference access is read-only',
      );
      final restored = ChatSession.fromJson(current.toJson());
      app.sessions.remove(current);
      app.sessions.add(restored);
      AgentService.setRunSessionForTest(restored.id);
      expect(await read(other.id), contains('private needle'));
    },
  );

  test(
    'ambiguous exact titles grant neither transcript; ID resolves explicitly',
    () async {
      app.sessions.add(
        ChatSession(
          id: 'duplicate',
          title: 'NamedSession',
          model: 'm',
          messages: [Message(role: 'assistant', content: 'duplicate secret')],
        ),
      );
      final expanded = await agent.expandReferences(
        '@session:NamedSession',
        current,
      );
      expect(expanded, contains('ambiguous'));
      expect(expanded, isNot(contains('duplicate secret')));
      expect(await read('other'), contains('DENIED'));
      await agent.expandReferences('@session:other', current);
      expect(await read('other'), contains('private needle'));
      expect(await read('duplicate'), contains('DENIED'));
    },
  );

  test('broad search/read denied until sharing is enabled', () async {
    expect(await read('other'), contains('DENIED'));
    final denied = await agent.dispatchForTest('session_search', {
      'query': 'needle',
      'scope': 'all',
    });
    expect(denied, contains('DENIED'));
    expect(denied, isNot(contains('private needle')));
    app.shareSessionMemory = true;
    expect(await read('other'), contains('private needle'));
    expect(
      await agent.dispatchForTest('session_search', {
        'query': 'needle',
        'scope': 'all',
      }),
      contains('needle'),
    );
    app.shareSessionMemory = false;
    expect(await read('other'), contains('DENIED'));
  });

  test('search defaults to current chat; explicit grant allows scoped search only', () async {
    current.messages.add(Message(role: 'user', content: 'local needle'));
    final local = await agent.dispatchForTest('session_search', {'query': 'needle'});
    expect(local, contains('local'));
    expect(local, isNot(contains('private')));
    await agent.expandReferences('@NamedSession', current);
    final referenced = await agent.dispatchForTest('session_search', {
      'query': 'needle', 'session_id': other.id,
    });
    expect(referenced, contains('private'));
    expect(referenced, isNot(contains('local')));
    expect(await agent.dispatchForTest('session_search', {
      'query': 'needle', 'scope': 'all',
    }), contains('DENIED'));
    final child = app.createSubagentSession(parent: current, label: 'Child', mode: 'auto');
    AgentService.setRunSessionForTest(child.id);
    expect(await read(other.id), contains('DENIED'));
  });

  test('quoted title references page the selected transcript', () async {
    other.title = 'Named Session';
    await agent.expandReferences('Use @"Named Session"', current);
    final page = await agent.dispatchForTest('session_read', {
      'session_id': other.id, 'offset': 10, 'limit': 2,
    });
    expect(page, contains('rows 10–12 of 21'));
    expect(page, contains('row 9'));
    expect(page, contains('row 10'));
    expect(page, isNot(contains('row 11')));
    expect(page, isNot(contains('private needle')));
  });

  test('ambiguous partial name never grants access', () async {
    app.sessions.add(ChatSession(id: 'another', title: 'NamedOther', model: 'm'));
    expect(await agent.expandReferences('@Named', current), contains('ambiguous'));
    expect(current.referencedSessionIds, isEmpty);
  });
}
