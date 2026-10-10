import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/outbox.dart';

class MemoryPersistence implements OutboxPersistence {
  List<int>? bytes;
  bool failWrites = false;

  @override
  Future<List<int>?> read() async => bytes == null ? null : List.of(bytes!);

  @override
  Future<void> writeAtomically(List<int> value) async {
    if (failWrites) throw StateError('write failed');
    bytes = List.of(value);
  }
}

SyncUploadRecord envelope(String id) => SyncUploadRecord(
  recordId: id,
  sourceDeviceId: 'device-1',
  conversationId: 'conversation-1',
  createdAt: '2026-10-09T12:00:00Z',
  revision: 1,
  payload: TranscriptPayload(
    messageId: id,
    parentMessageId: null,
    kind: TranscriptKind.user,
    text: 'hello',
    providerMetadataRecordId: null,
    requestPurpose: null,
    displayTitle: null,
  ),
);

void main() {
  test('enqueue deduplicates by stable idempotency key', () async {
    final persistence = MemoryPersistence();
    final outbox = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-1',
    );

    final first = await outbox.enqueue('stable-key', envelope('record-1'));
    final second = await outbox.enqueue('stable-key', envelope('record-2'));

    expect(second, first);
    expect((await outbox.entries()).map((e) => e.envelope.recordId), [
      'record-1',
    ]);
  });

  test('journal survives reopen with typed envelope and state', () async {
    final persistence = MemoryPersistence();
    final first = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-1',
    );
    await first.enqueue('stable-key', envelope('record-1'));
    await first.retry('stable-key');

    final reopened = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-2',
    );
    final entry = (await reopened.entries()).single;
    expect(entry.envelope, envelope('record-1'));
    expect(entry.state, OutboxState.retryable);
    expect(entry.attempts, 1);
  });

  test('acknowledge and terminal transitions are durable', () async {
    final persistence = MemoryPersistence();
    final outbox = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-1',
    );
    await outbox.enqueue('ack', envelope('record-1'));
    await outbox.enqueue('dead', envelope('record-2'));
    await outbox.acknowledge('ack');
    await outbox.terminal('dead', 'permanent rejection');

    final entries = await outbox.entries();
    expect(entries.map((e) => e.state), [
      OutboxState.acknowledged,
      OutboxState.terminal,
    ]);
    expect(entries.last.error, 'permanent rejection');
  });

  test('failed atomic write leaves the prior journal unchanged', () async {
    final persistence = MemoryPersistence();
    final outbox = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-1',
    );
    await outbox.enqueue('stable-key', envelope('record-1'));
    final before = utf8.decode(persistence.bytes!);
    persistence.failWrites = true;

    await expectLater(outbox.acknowledge('stable-key'), throwsStateError);
    expect(utf8.decode(persistence.bytes!), before);
    expect((await outbox.entries()).single.state, OutboxState.pending);
  });

  test('clear account removes entries and stale owners are fenced', () async {
    final persistence = MemoryPersistence();
    final oldOwner = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-1',
    );
    await oldOwner.enqueue('stable-key', envelope('record-1'));
    final newOwner = await PrivateSyncOutbox.open(
      persistence,
      accountId: 'account-1',
      ownerId: 'owner-2',
    );

    await expectLater(
      oldOwner.acknowledge('stable-key'),
      throwsA(isA<OutboxFencedException>()),
    );
    await newOwner.clearAccount();
    expect(await newOwner.entries(), isEmpty);
  });
}
