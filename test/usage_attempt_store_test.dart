import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_store.dart';

UsageAttempt attempt(
  String id, {
  int revision = 1,
  UsageOutcome outcome = UsageOutcome.succeeded,
  UsageDispatchStage stage = UsageDispatchStage.completed,
  int tokens = 4,
  int day = 1,
}) => UsageAttempt(
  attemptId: id,
  requestId: 'request-$id',
  revision: revision,
  sourceDevice: 'device',
  provider: 'provider',
  requestedModel: 'auto',
  purpose: 'chat',
  startedAt: DateTime.utc(2026, 10, day),
  dispatchStage: stage,
  outcome: outcome,
  inputTokens: UsageTokenCount.reported(tokens),
  outputTokens: UsageTokenCount.unknown(),
);

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('usage-store-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'identical delivery is durable once and snapshots are immutable',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      final record = attempt('a');
      expect(await store.upsert(record), isTrue);
      final snapshot = store.snapshot;
      expect(await store.upsert(record), isFalse);
      expect(store.revision, 1);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      await store.upsert(attempt('b'));
      expect(snapshot, [record]);
      final reopened = await UsageAttemptStore.open(accountRoot: root);
      expect(reopened.snapshot.map((a) => a.attemptId), ['a', 'b']);
      expect(reopened.revision, 2);
    },
  );

  test(
    'conflicting and stale revisions cannot replace durable records',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      final original = attempt('a', revision: 2);
      await store.upsert(original);
      await expectLater(
        store.upsert(attempt('a', revision: 2, tokens: 9)),
        throwsStateError,
      );
      expect(await store.upsert(attempt('a')), isFalse);
      expect(store.revision, 1);
      expect(store.snapshot, [original]);
      await store.upsert(attempt('a', revision: 3, tokens: 9));
      expect(store.snapshot.single.inputTokens!.value, 9);
      expect(store.snapshot.length, 1);
      expect(store.revision, 2);
    },
  );

  test(
    'restart classifies pending once without inventing usage or completion',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      for (final stage in [
        UsageDispatchStage.prepared,
        UsageDispatchStage.transmitted,
      ]) {
        await store.upsert(
          attempt(stage.name, outcome: UsageOutcome.pending, stage: stage),
        );
      }
      final reopened = await UsageAttemptStore.open(accountRoot: root);
      expect(reopened.pending, isEmpty);
      expect(
        reopened.snapshot.map((a) => a.outcome),
        everyElement(UsageOutcome.interrupted),
      );
      expect(reopened.snapshot.map((a) => a.dispatchStage), [
        UsageDispatchStage.prepared,
        UsageDispatchStage.transmitted,
      ]);
      for (final record in reopened.snapshot) {
        expect(record.revision, 2);
        expect(record.completedAt, isNull);
        expect(record.elapsed, isNull);
        expect(record.inputTokens, UsageTokenCount.reported(4));
        expect(record.outputTokens, UsageTokenCount.unknown());
      }
      expect(reopened.revision, 4);
      expect((await UsageAttemptStore.open(accountRoot: root)).revision, 4);
    },
  );

  test(
    'terminal retention keeps newest history and never prunes pending',
    () async {
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      await store.upsert(
        attempt(
          'pending',
          outcome: UsageOutcome.pending,
          stage: UsageDispatchStage.transmitted,
        ),
      );
      await store.upsert(attempt('new', day: 3));
      await store.upsert(attempt('old', day: 2));
      expect(store.pending.single.attemptId, 'pending');
      expect(store.terminal.single.attemptId, 'new');
      expect(store.historyTruncated, isTrue);
      final reopened = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      expect(
        reopened.terminal.map((record) => record.attemptId),
        contains('new'),
      );
      expect(reopened.historyTruncated, isTrue);
    },
  );

  test('account roots remain independent', () async {
    final a = await UsageAttemptStore.open(
      accountRoot: Directory('${root.path}/a'),
    );
    final b = await UsageAttemptStore.open(
      accountRoot: Directory('${root.path}/b'),
    );
    await a.upsert(attempt('same', tokens: 1));
    await b.upsert(attempt('same', tokens: 8));
    expect(
      (await UsageAttemptStore.open(
        accountRoot: Directory('${root.path}/a'),
      )).snapshot.single.inputTokens!.value,
      1,
    );
    expect(
      (await UsageAttemptStore.open(
        accountRoot: Directory('${root.path}/b'),
      )).snapshot.single.inputTokens!.value,
      8,
    );
  });

  test(
    'new pending attempts coexist with previously interrupted history',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      await store.upsert(attempt('old', outcome: UsageOutcome.interrupted));
      await store.upsert(attempt('new', outcome: UsageOutcome.pending));
      final reopened = await UsageAttemptStore.open(accountRoot: root);
      expect(reopened.snapshot.length, 2);
      expect(
        reopened.snapshot.map((a) => a.outcome),
        everyElement(UsageOutcome.interrupted),
      );
    },
  );

  test(
    'reopening applies a reduced terminal limit even without pending work',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      await store.upsert(attempt('old', day: 1));
      await store.upsert(attempt('new', day: 2));
      final reopened = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      expect(reopened.snapshot.single.attemptId, 'new');
      expect(reopened.historyTruncated, isTrue);
      expect(reopened.revision, 3);
      expect(
        (await UsageAttemptStore.open(
          accountRoot: root,
        )).snapshot.single.attemptId,
        'new',
      );
    },
  );

  test(
    'failed staged write preserves committed bytes, memory and revision; retry works',
    () async {
      var fail = false;
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        writeStagedFile: (file, bytes) async {
          await file.writeAsBytes(bytes.take(10).toList());
          if (fail) throw const FileSystemException('injected failure');
          await file.writeAsBytes(bytes);
        },
      );
      await store.upsert(attempt('a'));
      final before = await File(
        '${root.path}/usage_attempts.json',
      ).readAsBytes();
      fail = true;
      await expectLater(
        store.upsert(attempt('a', revision: 2)),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.revision, 1);
      expect(store.snapshot.single.revision, 1);
      expect(
        await File('${root.path}/usage_attempts.json').readAsBytes(),
        before,
      );
      expect(store.snapshot.single.revision, 1);
      fail = false;
      await store.upsert(attempt('a', revision: 2));
      expect(store.revision, 2);
    },
  );

  test(
    'concurrent updates serialize and are invisible until persistence completes',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        writeStagedFile: (file, bytes) async {
          if (!entered.isCompleted) {
            entered.complete();
            await gate.future;
          }
          await file.writeAsBytes(bytes);
        },
      );
      final first = store.upsert(attempt('a'));
      await entered.future;
      final second = store.upsert(attempt('a', revision: 2));
      expect(store.snapshot, isEmpty);
      expect(store.revision, 0);
      gate.complete();
      await Future.wait<bool>([first, second]);
      expect(store.snapshot.single.revision, 2);
      expect((await UsageAttemptStore.open(accountRoot: root)).revision, 2);
    },
  );

  test('malformed journals fail closed and preserve original bytes', () async {
    final valid = <String, dynamic>{
      'schemaVersion': 1,
      'revision': 1,
      'historyTruncated': false,
      'attempts': [attempt('a').toJson()],
    };
    final cases = <String>[
      '{',
      'null',
      '[]',
      jsonEncode({...valid, 'schemaVersion': 1.0}),
      jsonEncode({...valid, 'schemaVersion': 2}),
      jsonEncode({...valid, 'revision': -1}),
      jsonEncode({...valid, 'revision': 1.0}),
      jsonEncode({...valid, 'extra': true}),
      jsonEncode({...valid}..remove('historyTruncated')),
      jsonEncode({...valid, 'historyTruncated': 'false'}),
      jsonEncode({
        ...valid,
        'attempts': [attempt('a').toJson(), attempt('a').toJson()],
      }),
      jsonEncode({
        ...valid,
        'attempts': [
          {'attemptId': 'bad'},
        ],
      }),
    ];
    final file = File('${root.path}/usage_attempts.json');
    for (final text in cases) {
      await file.writeAsString(text);
      await expectLater(
        UsageAttemptStore.open(accountRoot: root),
        throwsA(isA<FormatException>()),
        reason: text,
      );
      expect(await file.readAsString(), text);
    }
  });

  test(
    'bounded input and output fail explicitly rather than dropping pending',
    () async {
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        maxJournalBytes: 100,
      );
      await expectLater(
        store.upsert(attempt('pending', outcome: UsageOutcome.pending)),
        throwsA(isA<StateError>()),
      );
      expect(store.snapshot, isEmpty);
      expect(store.revision, 0);
      await File('${root.path}/usage_attempts.json').writeAsString(' ' * 101);
      await expectLater(
        UsageAttemptStore.open(accountRoot: root, maxJournalBytes: 100),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'restart persistence failure is reported and does not overwrite pending',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      await store.upsert(attempt('a', outcome: UsageOutcome.pending));
      await expectLater(
        UsageAttemptStore.open(
          accountRoot: root,
          writeStagedFile: (_, _) async {
            throw const FileSystemException('injected');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      final data = jsonDecode(
        await File('${root.path}/usage_attempts.json').readAsString(),
      );
      expect(data['attempts'][0]['outcome'], 'pending');
      expect(data['revision'], 1);
    },
  );

  test(
    'terminal pruning leaves durable tombstones that reject replay',
    () async {
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 0,
      );
      await store.upsert(attempt('pruned'));
      expect(store.snapshot, isEmpty);
      expect(await store.upsert(attempt('pruned', revision: 2)), isFalse);
      expect(store.revision, 1);
      final reopened = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 0,
      );
      expect(await reopened.upsert(attempt('pruned', revision: 99)), isFalse);
      expect(reopened.revision, 1);
    },
  );

  test('journal input is capped before whole-file allocation', () async {
    final file = File('${root.path}/usage_attempts.json');
    await file.writeAsString('x' * 1000);
    await expectLater(
      UsageAttemptStore.open(accountRoot: root, maxJournalBytes: 10),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'legacy migration runs once, preserves equal duplicates, and marks provenance',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      final first = attempt('legacy-1', tokens: 7);
      final second = attempt('legacy-2', tokens: 7);
      expect(
        await store.migrateLegacy(marker: 'state-v1', records: [first, second]),
        2,
      );
      expect(store.snapshot.length, 2);
      expect(
        store.snapshot.map((record) => record.inputTokens!.provenance),
        everyElement(UsageProvenance.legacyUnspecified),
      );
      expect(
        await store.migrateLegacy(
          marker: 'state-v1',
          records: [attempt('other')],
        ),
        0,
      );
      final reopened = await UsageAttemptStore.open(accountRoot: root);
      expect(reopened.snapshot.map((record) => record.attemptId), [
        'legacy-1',
        'legacy-2',
      ]);
      expect(reopened.migrationMarkers, contains('state-v1'));
    },
  );

  test(
    'owner fence rejects stale account callbacks before persistence',
    () async {
      var current = true;
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        ownerFence: () => current,
      );
      current = false;
      await expectLater(store.upsert(attempt('stale')), throwsStateError);
      expect(store.snapshot, isEmpty);
      expect(store.revision, 0);
    },
  );

  test('directory sync hook is invoked after atomic rename', () async {
    var synced = 0;
    final store = await UsageAttemptStore.open(
      accountRoot: root,
      syncDirectory: (_) async {
        synced++;
      },
    );
    await store.upsert(attempt('a'));
    expect(synced, 1);
  });

  test(
    'restart retention writes tombstones for records pruned during recovery',
    () async {
      final store = await UsageAttemptStore.open(accountRoot: root);
      await store.upsert(attempt('old', outcome: UsageOutcome.pending, day: 1));
      await store.upsert(
        attempt('new', outcome: UsageOutcome.succeeded, day: 2),
      );
      final reopened = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      expect(await reopened.upsert(attempt('old', revision: 3)), isFalse);
    },
  );

  test(
    'directory sync failure invalidates the instance and prevents later overwrite',
    () async {
      var fail = true;
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        syncDirectory: (_) async {
          if (fail) throw const FileSystemException('sync failed');
        },
      );
      await expectLater(
        store.upsert(attempt('a')),
        throwsA(isA<FileSystemException>()),
      );
      fail = false;
      await expectLater(store.upsert(attempt('b')), throwsStateError);
      final reopened = await UsageAttemptStore.open(accountRoot: root);
      expect(reopened.snapshot.map((record) => record.attemptId), ['a']);
    },
  );

  test(
    'owner fence is checked during open recovery and immediately before rename',
    () async {
      var owned = true;
      final recovered = UsageAttempt(
        attemptId: 'pending',
        requestId: 'request-pending',
        revision: 1,
        sourceDevice: 'device',
        provider: 'provider',
        requestedModel: 'auto',
        purpose: 'chat',
        startedAt: DateTime.utc(2026, 10, 1),
        dispatchStage: UsageDispatchStage.transmitted,
        outcome: UsageOutcome.pending,
      );
      final seed = await UsageAttemptStore.open(accountRoot: root);
      await seed.upsert(recovered);
      owned = false;
      await expectLater(
        UsageAttemptStore.open(accountRoot: root, ownerFence: () => owned),
        throwsStateError,
      );

      owned = true;
      var staged = false;
      final store = await UsageAttemptStore.open(
        accountRoot: Directory('${root.path}/other'),
        ownerFence: () {
          if (staged) owned = false;
          return owned;
        },
        writeStagedFile: (file, bytes) async {
          staged = true;
          await file.writeAsBytes(bytes);
        },
      );
      await expectLater(store.upsert(attempt('late')), throwsStateError);
      expect(store.snapshot, isEmpty);
    },
  );

  test(
    'legacy migration applies retention before committing its marker',
    () async {
      final store = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      final result = await store.migrateLegacy(
        marker: 'legacy',
        records: [attempt('old', day: 1), attempt('new', day: 2)],
      );
      expect(result, 2);
      expect(store.terminal.map((record) => record.attemptId), ['new']);
      expect(store.historyTruncated, isTrue);
      final reopened = await UsageAttemptStore.open(
        accountRoot: root,
        terminalHistoryLimit: 1,
      );
      expect(reopened.migrationMarkers, contains('legacy'));
      expect(await reopened.upsert(attempt('old', revision: 2)), isFalse);
    },
  );

  test('capped reader requests no chunk beyond remaining limit', () async {
    final file = File('${root.path}/usage_attempts.json');
    await file.writeAsString('x' * 100);
    final reads = <int>[];
    await expectLater(
      UsageAttemptStore.open(
        accountRoot: root,
        maxJournalBytes: 10,
        readChunk: (handle, count) async {
          reads.add(count);
          return handle.read(count);
        },
      ),
      throwsA(isA<FormatException>()),
    );
    expect(reads, everyElement(lessThanOrEqualTo(11)));
  });

  test('same-root reopen waits for an older writer to settle', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final store = await UsageAttemptStore.open(
      accountRoot: root,
      writeStagedFile: (file, bytes) async {
        entered.complete();
        await release.future;
        await file.writeAsBytes(bytes, flush: true);
      },
    );
    final write = store.upsert(attempt('old'));
    await entered.future;

    var reopenedCompleted = false;
    final reopened = UsageAttemptStore.open(accountRoot: root).then((value) {
      reopenedCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(reopenedCompleted, isFalse);

    release.complete();
    final next = await reopened;
    expect(next.snapshot.map((record) => record.attemptId), ['old']);
    await write;
  });

  test('each store instance stages through a unique file', () async {
    final paths = <String>[];
    Future<void> writer(File file, List<int> bytes) async {
      paths.add(file.path);
      await file.writeAsBytes(bytes, flush: true);
    }

    final first = await UsageAttemptStore.open(
      accountRoot: Directory('${root.path}/first'),
      writeStagedFile: writer,
    );
    final second = await UsageAttemptStore.open(
      accountRoot: Directory('${root.path}/second'),
      writeStagedFile: writer,
    );

    await Future.wait([
      first.upsert(attempt('a')),
      second.upsert(attempt('b')),
    ]);

    expect(paths, hasLength(2));
    expect(paths.toSet(), hasLength(2));
    expect(paths.every((path) => path.contains('.tmp.')), isTrue);
  });

  test(
    'replacement invalidates the prior store instance before later writes',
    () async {
      final old = await UsageAttemptStore.open(accountRoot: root);
      await old.upsert(attempt('old'));

      final replacement = await UsageAttemptStore.open(accountRoot: root);

      await expectLater(old.upsert(attempt('stale')), throwsStateError);
      await replacement.upsert(attempt('new'));
      expect(replacement.snapshot.map((record) => record.attemptId), [
        'old',
        'new',
      ]);
    },
  );

  test(
    'stale A to B to A retirement cannot detach the current registry',
    () async {
      final firstA = await UsageAttemptStore.open(accountRoot: root);
      final b = await UsageAttemptStore.open(accountRoot: root);
      final secondA = await UsageAttemptStore.open(accountRoot: root);

      await firstA.retire();
      await secondA.upsert(attempt('current'));
      await b.retire();
      await secondA.upsert(attempt('still-current'));
      expect(secondA.snapshot.map((record) => record.attemptId), [
        'current',
        'still-current',
      ]);
    },
  );
}
