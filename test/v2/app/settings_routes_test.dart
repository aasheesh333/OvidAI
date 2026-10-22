import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_routes.dart';
import 'package:ovid_ai/ui/v2/settings/memory_page.dart';

/// A memory API that behaves like the gateway: chat-scope by default, the
/// shared scope when [shared] is true, revision-checked writes and 404-style
/// deletes.
class _FakeMemoryClient extends AccountSettingsClient {
  _FakeMemoryClient({this.shared = false, Map<String, String>? files})
    : files = files ?? <String, String>{},
      super(rest: CloudRestClient());

  bool shared;
  final Map<String, String> files;
  final Map<String, String> revisions = <String, String>{};
  final List<String> deleted = <String>[];
  int writes = 0;

  @override
  Future<MemoryListing> memoryFiles(String sessionId) async => MemoryListing([
    for (final entry in files.entries)
      MemoryFileSummary(name: entry.key, sizeBytes: entry.value.length),
  ], shared: shared);

  @override
  Future<MemoryFile> readMemory(String sessionId, String name) async =>
      MemoryFile(
        name: name,
        content: files[name] ?? '',
        revision: revisions[name] ?? 'r1',
      );

  @override
  Future<MemoryFile> writeMemory(
    String sessionId,
    String name,
    String content, {
    String? ifRevision,
  }) async {
    writes++;
    files[name] = content;
    revisions[name] = 'r${writes + 1}';
    return MemoryFile(name: name, content: content, revision: revisions[name]!);
  }

  @override
  Future<void> deleteMemory(String sessionId, String name) async {
    deleted.add(name);
    files.remove(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() => AppState.resetTestInstance());

  group('memory facts', () {
    test('bullets become facts and headings/fences are skipped', () {
      final facts = memoryFactsFrom(
        'MEMORY.md',
        '# Memory\n\n- Prefers plain English.\n* Works as a designer.\n'
            '```\n- not a fact\n```\n1. Ships on Fridays.\n',
      );

      expect(facts.map((fact) => fact.text), [
        'Prefers plain English.',
        'Works as a designer.',
        'Ships on Fridays.',
      ]);
      expect(facts.first.fileName, 'MEMORY.md');
      expect(facts.first.id, 'MEMORY.md#2');
    });

    test('removing a fact deletes only its line', () {
      const content = '# Memory\n- One\n- Two\n- Three\n';
      final fact = memoryFactsFrom('MEMORY.md', content)[1];

      final next = removeMemoryFact(content, fact);

      expect(next, '# Memory\n- One\n- Three\n');
    });

    test('a changed file refuses to delete the wrong line', () {
      const content = '- One\n- Two\n';
      final fact = memoryFactsFrom('MEMORY.md', content)[1];

      expect(removeMemoryFact('- Two changed\n- One\n', fact), isNull);
    });
  });

  group('memory source', () {
    test('a chat-scope listing keeps files and has no global facts', () async {
      final client = _FakeMemoryClient(
        files: {'MEMORY.md': '- Likes short answers.'},
      );
      final snapshot = await V2MemorySource(client: client).load('s1');

      expect(snapshot.shared, isFalse);
      expect(snapshot.files, hasLength(1));
      expect(snapshot.facts, isEmpty);
    });

    test('a shared listing turns file lines into global facts', () async {
      final client = _FakeMemoryClient(
        shared: true,
        files: {
          'MEMORY.md': '- Likes short answers.\n- Timezone IST.',
          'notes.md': '# Notes\n- Uses Flutter.',
        },
      );
      final snapshot = await V2MemorySource(client: client).load('s1');

      expect(snapshot.shared, isTrue);
      expect(snapshot.facts.map((fact) => fact.text), [
        'Likes short answers.',
        'Timezone IST.',
        'Uses Flutter.',
      ]);
    });

    test(
      'forgetting a global fact rewrites the file without that line',
      () async {
        final client = _FakeMemoryClient(
          shared: true,
          files: {'MEMORY.md': '- One\n- Two\n- Three\n'},
        );
        final source = V2MemorySource(client: client);
        final snapshot = await source.load('s1');

        await source.forget(
          sessionId: 's1',
          scope: V2MemoryScope.global,
          id: snapshot.facts[1].id,
          snapshot: snapshot,
        );

        expect(client.files['MEMORY.md'], '- One\n- Three\n');
        expect(client.deleted, isEmpty);
      },
    );

    test('forgetting the last global fact deletes the empty file', () async {
      final client = _FakeMemoryClient(
        shared: true,
        files: {'MEMORY.md': '- Only fact\n'},
      );
      final source = V2MemorySource(client: client);
      final snapshot = await source.load('s1');

      await source.forget(
        sessionId: 's1',
        scope: V2MemoryScope.global,
        id: snapshot.facts.single.id,
        snapshot: snapshot,
      );

      expect(client.deleted, ['MEMORY.md']);
    });

    test('forgetting a session row deletes that file', () async {
      final client = _FakeMemoryClient(
        files: {'MEMORY.md': '- A', 'spec.md': '- B'},
      );
      final source = V2MemorySource(client: client);
      final snapshot = await source.load('s1');

      await source.forget(
        sessionId: 's1',
        scope: V2MemoryScope.session,
        id: 'spec.md',
        snapshot: snapshot,
      );

      expect(client.deleted, ['spec.md']);
      expect(client.files.containsKey('MEMORY.md'), isTrue);
    });
  });

  group('export selection', () {
    test('rows carry real sizes, message counts and selection', () {
      final older = ChatSession(
        id: 'a',
        title: 'Older chat',
        model: 'auto',
        createdAt: DateTime(2026, 1, 1),
      )..messages.add(Message(role: 'user', content: 'hello'));
      final newer =
          ChatSession(
              id: 'b',
              title: 'Newer chat',
              model: 'auto',
              createdAt: DateTime(2026, 2, 1),
            )
            ..messages.addAll([
              Message(role: 'user', content: 'one'),
              Message(role: 'assistant', content: 'two'),
            ]);
      final empty = ChatSession(
        id: 'c',
        title: 'Empty',
        model: 'auto',
        createdAt: DateTime(2026, 3, 1),
      );

      final rows = V2SettingsRoutes.exportSessionsFor(
        [older, newer, empty],
        {'a': false},
      );

      // Newest first; a chat with no messages has nothing to export.
      expect(rows.map((row) => row.id), ['b', 'a']);
      expect(rows.first.detail, '2 messages');
      expect(rows.first.sizeBytes, greaterThan(0));
      expect(rows.last.detail, '1 message');
      expect(rows.last.selected, isFalse);
      expect(rows.first.selected, isTrue);
    });
  });
}
