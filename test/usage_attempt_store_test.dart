import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/usage_attempt.dart';
import '../lib/core/usage_attempt_store.dart';

UsageAttempt attempt(String id, {
  int revision = 1,
  UsageOutcome outcome = UsageOutcome.succeeded,
  UsageDispatchStage stage = UsageDispatchStage.completed,
  int tokens = 4,
  int day = 1,
}) => UsageAttempt(
  attemptId: id, requestId: 'request-$id', revision: revision,
  sourceDevice: 'device', provider: 'provider', requestedModel: 'auto',
  purpose: 'chat', startedAt: DateTime.utc(2026, 10, day),
  dispatchStage: stage, outcome: outcome,
  inputTokens: UsageTokenCount.reported(tokens),
  outputTokens: UsageTokenCount.unknown(),
);

void main() {
  late Directory root;
  setUp(() async { root = await Directory.systemTemp.createTemp('usage-store-'); });
  tearDown(() async { await root.delete(recursive: true); });

  test('identical delivery is durable once and snapshots are immutable', () async {
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
  });

  test('conflicting and stale revisions cannot replace durable records', () async {
    final store = await UsageAttemptStore.open(accountRoot: root);
    final original = attempt('a', revision: 2);
    await store.upsert(original);
    await expectLater(store.upsert(attempt('a', revision: 2, tokens: 9)),
        throwsStateError);
    expect(await store.upsert(attempt('a')), isFalse);
    expect(store.revision, 1);
    expect((await UsageAttemptStore.open(accountRoot: root)).snapshot, [original]);
    await store.upsert(attempt('a', revision: 3, tokens: 9));
    expect(store.snapshot.single.inputTokens!.value, 9);
    expect(store.snapshot.length, 1);
    expect(store.revision, 2);
  });

  test('restart classifies pending once without inventing usage or completion', () async {
    final store = await UsageAttemptStore.open(accountRoot: root);
    for (final stage in [UsageDispatchStage.prepared, UsageDispatchStage.transmitted]) {
      await store.upsert(attempt(stage.name, outcome: UsageOutcome.pending, stage: stage));
    }
    final reopened = await UsageAttemptStore.open(accountRoot: root);
    expect(reopened.pending, isEmpty);
    expect(reopened.snapshot.map((a) => a.outcome), everyElement(UsageOutcome.interrupted));
    expect(reopened.snapshot.map((a) => a.dispatchStage),
        [UsageDispatchStage.prepared, UsageDispatchStage.transmitted]);
    for (final record in reopened.snapshot) {
      expect(record.revision, 2);
      expect(record.completedAt, isNull);
      expect(record.elapsed, isNull);
      expect(record.inputTokens, UsageTokenCount.reported(4));
      expect(record.outputTokens, UsageTokenCount.unknown());
    }
    expect(reopened.revision, 4);
    expect((await UsageAttemptStore.open(accountRoot: root)).revision, 4);
  });

  test('terminal retention keeps newest history and never prunes pending', () async {
    final store = await UsageAttemptStore.open(accountRoot: root, terminalHistoryLimit: 1);
    await store.upsert(attempt('pending', outcome: UsageOutcome.pending,
        stage: UsageDispatchStage.transmitted));
    await store.upsert(attempt('new', day: 3));
    await store.upsert(attempt('old', day: 2));
    expect(store.pending.single.attemptId, 'pending');
    expect(store.terminal.single.attemptId, 'new');
    expect(store.historyTruncated, isTrue);
    final reopened = await UsageAttemptStore.open(accountRoot: root, terminalHistoryLimit: 1);
    expect(reopened.terminal.map((record) => record.attemptId), contains('new'));
    expect(reopened.historyTruncated, isTrue);
  });

  test('account roots remain independent', () async {
    final a = await UsageAttemptStore.open(accountRoot: Directory('${root.path}/a'));
    final b = await UsageAttemptStore.open(accountRoot: Directory('${root.path}/b'));
    await a.upsert(attempt('same', tokens: 1));
    await b.upsert(attempt('same', tokens: 8));
    expect((await UsageAttemptStore.open(accountRoot: Directory('${root.path}/a')))
        .snapshot.single.inputTokens!.value, 1);
    expect((await UsageAttemptStore.open(accountRoot: Directory('${root.path}/b')))
        .snapshot.single.inputTokens!.value, 8);
  });

  test('new pending attempts coexist with previously interrupted history', () async {
    final store = await UsageAttemptStore.open(accountRoot: root);
    await store.upsert(attempt('old', outcome: UsageOutcome.interrupted));
    await store.upsert(attempt('new', outcome: UsageOutcome.pending));
    final reopened = await UsageAttemptStore.open(accountRoot: root);
    expect(reopened.snapshot.length, 2);
    expect(reopened.snapshot.map((a) => a.outcome),
        everyElement(UsageOutcome.interrupted));
  });

  test('reopening applies a reduced terminal limit even without pending work', () async {
    final store = await UsageAttemptStore.open(accountRoot: root);
    await store.upsert(attempt('old', day: 1));
    await store.upsert(attempt('new', day: 2));
    final reopened = await UsageAttemptStore.open(accountRoot: root, terminalHistoryLimit: 1);
    expect(reopened.snapshot.single.attemptId, 'new');
    expect(reopened.historyTruncated, isTrue);
    expect(reopened.revision, 3);
    expect((await UsageAttemptStore.open(accountRoot: root)).snapshot.single.attemptId, 'new');
  });

  test('failed staged write preserves committed bytes, memory and revision; retry works', () async {
    var fail = false;
    final store = await UsageAttemptStore.open(accountRoot: root,
      writeStagedFile: (file, bytes) async {
        await file.writeAsBytes(bytes.take(10).toList());
        if (fail) throw const FileSystemException('injected failure');
        await file.writeAsBytes(bytes);
      });
    await store.upsert(attempt('a'));
    final before = await File('${root.path}/usage_attempts.json').readAsBytes();
    fail = true;
    await expectLater(store.upsert(attempt('a', revision: 2)), throwsA(isA<FileSystemException>()));
    expect(store.revision, 1);
    expect(store.snapshot.single.revision, 1);
    expect(await File('${root.path}/usage_attempts.json').readAsBytes(), before);
    expect((await UsageAttemptStore.open(accountRoot: root)).snapshot.single.revision, 1);
    fail = false;
    await store.upsert(attempt('a', revision: 2));
    expect(store.revision, 2);
  });

  test('concurrent updates serialize and are invisible until persistence completes', () async {
    final gate = Completer<void>();
    final entered = Completer<void>();
    final store = await UsageAttemptStore.open(accountRoot: root,
      writeStagedFile: (file, bytes) async {
        if (!entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
        await file.writeAsBytes(bytes);
      });
    final first = store.upsert(attempt('a'));
    await entered.future;
    final second = store.upsert(attempt('a', revision: 2));
    expect(store.snapshot, isEmpty);
    expect(store.revision, 0);
    gate.complete();
    await Future.wait<bool>([first, second]);
    expect(store.snapshot.single.revision, 2);
    expect((await UsageAttemptStore.open(accountRoot: root)).revision, 2);
  });

  test('malformed journals fail closed and preserve original bytes', () async {
    final valid = <String, dynamic>{
      'schemaVersion': 1, 'revision': 1, 'historyTruncated': false,
      'attempts': [attempt('a').toJson()],
    };
    final cases = <String>[
      '{', 'null', '[]',
      jsonEncode({...valid, 'schemaVersion': 1.0}),
      jsonEncode({...valid, 'schemaVersion': 2}),
      jsonEncode({...valid, 'revision': -1}),
      jsonEncode({...valid, 'revision': 1.0}),
      jsonEncode({...valid, 'extra': true}),
      jsonEncode({...valid}..remove('historyTruncated')),
      jsonEncode({...valid, 'historyTruncated': 'false'}),
      jsonEncode({...valid, 'attempts': [attempt('a').toJson(), attempt('a').toJson()]}),
      jsonEncode({...valid, 'attempts': [{'attemptId': 'bad'}]}),
    ];
    final file = File('${root.path}/usage_attempts.json');
    for (final text in cases) {
      await file.writeAsString(text);
      await expectLater(UsageAttemptStore.open(accountRoot: root),
          throwsA(isA<FormatException>()), reason: text);
      expect(await file.readAsString(), text);
    }
  });

  test('bounded input and output fail explicitly rather than dropping pending', () async {
    final store = await UsageAttemptStore.open(accountRoot: root, maxJournalBytes: 100);
    await expectLater(store.upsert(attempt('pending', outcome: UsageOutcome.pending)),
        throwsA(isA<StateError>()));
    expect(store.snapshot, isEmpty);
    expect(store.revision, 0);
    await File('${root.path}/usage_attempts.json').writeAsString(' ' * 101);
    await expectLater(UsageAttemptStore.open(accountRoot: root, maxJournalBytes: 100),
        throwsA(isA<FormatException>()));
  });

  test('restart persistence failure is reported and does not overwrite pending', () async {
    final store = await UsageAttemptStore.open(accountRoot: root);
    await store.upsert(attempt('a', outcome: UsageOutcome.pending));
    await expectLater(UsageAttemptStore.open(accountRoot: root,
      writeStagedFile: (_, __) async { throw const FileSystemException('injected'); }),
      throwsA(isA<FileSystemException>()));
    final data = jsonDecode(await File('${root.path}/usage_attempts.json').readAsString());
    expect(data['attempts'][0]['outcome'], 'pending');
    expect(data['revision'], 1);
  });
}
