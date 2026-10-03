import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_ledger.dart';

void main() {
  late Directory root;
  final ledger = SessionLedger.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ledger-acceptance-');
    SessionLedger.rootOverrideForTest = root;
  });

  tearDown(() async {
    for (final id in ledger.sinkOpensForTest.keys.toList()) {
      await ledger.close(id);
    }
    SessionLedger.rootOverrideForTest = null;
    await root.delete(recursive: true);
  });

  test(
    'payload cannot forge durable sequence, timestamp or event kind',
    () async {
      final before = DateTime.now();
      await ledger.append('envelope', 'checkpoint', {
        'seq': 700,
        't': 'forged',
        'kind': 'note',
        'state': 'idle',
      });
      await ledger.append('envelope', 'note', {'text': 'next'});
      await ledger.flush('envelope');
      final events = File(
        '${root.path}/envelope.jsonl',
      ).readAsLinesSync().map((line) => jsonDecode(line) as Map).toList();
      expect(events.map((e) => e['seq']), [1, 2]);
      expect(events.first['kind'], 'checkpoint');
      expect(events.first['state'], 'idle');
      final timestamp = DateTime.parse(events.first['t'] as String);
      expect(timestamp.isBefore(before), isFalse);
      expect(timestamp.isAfter(DateTime.now()), isFalse);
      expect(await ledger.lastCheckpointSeq('envelope'), 1);
    },
  );

  test(
    'colliding legacy IDs have independent files, sequences and deletion',
    () async {
      const ids = ['team/a', 'team:a', 'team_a'];
      await Future.wait([
        for (final id in ids) ledger.append(id, 'note', {'owner': id}),
      ]);
      for (final id in ids) {
        final events = await ledger.read(id);
        expect(events, hasLength(1));
        expect(events.single['owner'], id);
        expect(events.single['seq'], 1);
      }
      expect(root.listSync().whereType<File>(), hasLength(3));
      await ledger.close(ids.first);
      for (final id in ids.skip(1)) {
        expect((await ledger.read(id)).single['owner'], id);
      }
    },
  );

  test('ambiguous legacy history is neither adopted nor deleted', () async {
    final legacy = File('${root.path}/team_a.jsonl');
    const bytes = '{"seq":41,"kind":"note","text":"private legacy"}\n';
    await legacy.writeAsString(bytes);
    for (final id in ['team/a', 'team:a', 'team_a']) {
      expect(await ledger.read(id), isEmpty);
      await ledger.append(id, 'note', {'owner': id});
      expect((await ledger.read(id)).single['seq'], 1);
      await ledger.close(id);
      expect(await legacy.readAsString(), bytes);
      await ledger.delete(id);
      expect(await legacy.readAsString(), bytes);
    }
  });

  test('long and Unicode IDs remain usable without aliasing', () async {
    final ids = ['x' * 400, '部屋/一', '部屋:一', '', '../outside'];
    for (final id in ids) {
      await ledger.append(id, 'note', {'owner': id});
      expect((await ledger.read(id)).single['owner'], id);
    }
    expect(root.listSync().whereType<File>(), hasLength(ids.length));
  });

  test(
    'unambiguous legacy names that need hashing preserve original bytes',
    () async {
      for (final id in ['', 'a' * 245]) {
        final legacy = File('${root.path}/$id.jsonl');
        const original = '{"seq":18,"kind":"checkpoint"}\n';
        await legacy.writeAsString(original);
        expect((await ledger.read(id)).single['seq'], 18);
        final migrated = root.listSync().whereType<File>().singleWhere(
          (file) => file.path.endsWith('.jsonl'),
        );
        expect(await migrated.readAsString(), original);
        await ledger.append(id, 'note', {'owner': id});
        expect((await ledger.read(id)).map((e) => e['seq']), [18, 19]);
        expect(legacy.existsSync(), isFalse);
        await ledger.delete(id);
        expect(await ledger.read(id), isEmpty);
      }
    },
  );

  test(
    'mutating read results cannot corrupt later replay or projection',
    () async {
      await ledger.append('cache', 'turn_start', {
        'nested': {'value': 'durable'},
      });
      final first = await ledger.read('cache');
      first.single['kind'] = 'note';
      (first.single['nested'] as Map)['value'] = 'mutated';
      final next = await ledger.read('cache');
      expect(next.single['kind'], 'turn_start');
      expect((next.single['nested'] as Map)['value'], 'durable');
      expect((await ledger.projection('cache')).turns, 1);
    },
  );

  test('mutating an appended payload cannot change warmed replay', () async {
    await ledger.append('payload', 'note', {});
    await ledger.read('payload');
    final nested = {'value': 'durable'};
    await ledger.append('payload', 'note', {'nested': nested});
    nested['value'] = 'mutated';
    expect(
      ((await ledger.read('payload')).last['nested'] as Map)['value'],
      'durable',
    );
  });

  test(
    'paged replay skips damaged records and leaves full-history consumers intact',
    () async {
      final file = File('${root.path}/pages.jsonl');
      await file.writeAsString(
        '{"seq":9,"kind":"checkpoint"}\n'
        'damaged\n'
        '[1,2]\n'
        '{"seq":2,"kind":"turn_start"}\n'
        '{"seq":15,"kind":"tool_start","tool":"read"}\n'
        '{"seq":16,"kind":"tool_end","ms":21}\n'
        '{"seq":17,"kind":"note"}',
      );
      expect(
        (await ledger.read('pages', offset: 1, limit: 2)).map((e) => e['seq']),
        [2, 15],
      );
      expect(
        (await ledger.read('pages', offset: 3, limit: 2)).map((e) => e['seq']),
        [16, 17],
      );
      expect(await ledger.read('pages', offset: 5, limit: 2), isEmpty);
      expect(await ledger.read('pages', limit: 0), isEmpty);
      expect((await ledger.read('pages')).map((e) => e['seq']), [
        9,
        2,
        15,
        16,
        17,
      ]);
      expect(await ledger.lastCheckpointSeq('pages'), 9);
      final projection = await ledger.projection('pages');
      expect(projection.turns, 1);
      expect(projection.steps, 1);
      expect(projection.toolMs, 21);
      expect(projection.toolCounts, {'read': 1});
      await ledger.append('pages', 'note', {});
      expect(
        (await ledger.read('pages', offset: 5, limit: 2)).single['seq'],
        18,
      );
    },
  );

  test('negative replay bounds fail explicitly', () {
    expect(() => ledger.read('pages', offset: -1), throwsRangeError);
    expect(() => ledger.read('pages', limit: -1), throwsRangeError);
  });

  test(
    'bounded replay reads a large history without truncating default reads',
    () async {
      final file = File('${root.path}/large.jsonl');
      await file.writeAsString(
        [
          for (var i = 1; i <= 2500; i++)
            jsonEncode({'seq': i, 'kind': 'note'}),
        ].join('\n'),
      );
      expect(
        (await ledger.read(
          'large',
          offset: 2498,
          limit: 10,
        )).map((e) => e['seq']),
        [2499, 2500],
      );
      expect(await ledger.read('large'), hasLength(2500));
      expect(await ledger.read('large', limit: 1), hasLength(1));
    },
  );

  test(
    'explicit deletion prevents queued and later append resurrection',
    () async {
      final before = ledger.append('deleted', 'note', {'text': 'pending open'});
      final deletion = ledger.delete('deleted');
      final queued = ledger.append('deleted', 'note', {'text': 'queued late'});
      await Future.wait([before, deletion, queued]);
      await ledger.append('deleted', 'note', {'text': 'later'});
      expect(await ledger.read('deleted'), isEmpty);
      expect(File('${root.path}/deleted.jsonl').existsSync(), isFalse);
      expect(ledger.sinkOpensForTest['deleted'], isNull);
      // Compatibility close must not undo an explicit deletion.
      await ledger.close('deleted');
      await ledger.append('deleted', 'note', {});
      expect(File('${root.path}/deleted.jsonl').existsSync(), isFalse);
    },
  );

  test(
    'durable deletion blocks reopening even without in-memory state',
    () async {
      // A prior process left both a tombstone and pre-deletion bytes (e.g. it
      // exited after the marker was flushed but before unlinking the ledger).
      await File(
        '${root.path}/restart-deleted.jsonl.deleted',
      ).writeAsString('');
      final file = File('${root.path}/restart-deleted.jsonl');
      const original = '{"seq":8,"kind":"note"}\n';
      await file.writeAsString(original);
      expect(await ledger.read('restart-deleted'), isEmpty);
      await ledger.append('restart-deleted', 'note', {});
      expect(await file.readAsString(), original);
      await ledger.delete('restart-deleted');
      expect(file.existsSync(), isFalse);
    },
  );

  test(
    'deletion is scoped to storage root, allowing fresh fixture reuse',
    () async {
      await ledger.delete('reused');
      final otherRoot = await Directory('${root.path}/other').create();
      SessionLedger.rootOverrideForTest = otherRoot;
      try {
        await ledger.append('reused', 'note', {'text': 'new store'});
        expect((await ledger.read('reused')).single['seq'], 1);
      } finally {
        await ledger.close('reused');
        SessionLedger.rootOverrideForTest = root;
      }
      await ledger.append('reused', 'note', {});
      expect(await ledger.read('reused'), isEmpty);
    },
  );

  test(
    'failed deletion marker write reports failure and permits retry',
    () async {
      await ledger.append('delete-failure', 'note', {});
      final marker = Directory('${root.path}/delete-failure.jsonl.deleted');
      await marker.create();
      await expectLater(
        ledger.delete('delete-failure'),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${root.path}/delete-failure.jsonl').existsSync(), isTrue);
      await marker.delete();
      await ledger.delete('delete-failure');
      await ledger.append('delete-failure', 'note', {});
      expect(await ledger.read('delete-failure'), isEmpty);
    },
  );
}
