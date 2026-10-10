import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/file_store.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/core/collaboration/store.dart';

const _sessionId = 'sess-1';
const _owner = 'p-owner';
const _local = 'p-local';

CollaborationEvent _message(int sequence, String text) => CollaborationEvent.fromWire({
      'schemaVersion': 1,
      'eventId': 'evt-$sequence',
      'sessionId': _sessionId,
      'eventSequence': sequence,
      'senderParticipantId': _owner,
      'kind': 'message',
      'createdAt': '2026-10-09T12:00:00Z',
      'payload': {'text': text},
    });

CollaborationState _bootstrap() => CollaborationState.bootstrap(
      session: const CollaborationSession(
        sessionId: _sessionId,
        ownerParticipantId: _owner,
        lifecycle: SessionLifecycle.active,
      ),
      members: const [
        Member(participantId: _owner, role: MemberRole.owner, status: MemberStatus.active),
        Member(participantId: _local, role: MemberRole.participant, status: MemberStatus.active),
      ],
      localParticipantId: _local,
      lastSequence: 0,
    );

void main() {
  test('acknowledgement contiguity is checked after queued bootstrap commits', () async {
    final backend = DelayedBackend(MemoryCollaborationStoreBackend());
    final store = CollaborationStore(backend, ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    await store.applyPage(ownerFence: 'account-a', sessionGeneration: 1, page: [_message(1, 'first')]);
    backend.delay = Completer<void>();
    final bootstrap = store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    await backend.started.future;
    expect(store.cursor, 1); // Old visible projection while bootstrap is flushing.
    final ack = store.applyAcknowledgement(ownerFence: 'account-a', sessionGeneration: 1,
      page: [_message(2, 'delayed ack')]);
    backend.delay!.complete();
    await bootstrap;
    expect(await ack, isFalse);
    expect(store.cursor, 0);
    expect(store.state!.status, CollaborationStatus.live);
    expect(await store.applyPage(ownerFence: 'account-a', sessionGeneration: 1,
      page: [_message(1, 'first'), _message(2, 'delayed ack')]), isTrue);
    final reopened = CollaborationStore(backend, ownerFence: 'account-a');
    await reopened.load();
    expect(reopened.state!.messages.map((m) => m.text), ['first', 'delayed ack']);
    expect(await store.applyAcknowledgement(ownerFence: 'account-a', sessionGeneration: 0,
      page: [_message(3, 'stale')]), isFalse);
  });

  test('gapped replay page cannot commit a resync projection or cursor', () async {
    final store = CollaborationStore(MemoryCollaborationStoreBackend(), ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    expect(await store.applyPage(ownerFence: 'account-a', sessionGeneration: 1,
      page: [_message(2, 'gap')]), isFalse);
    expect(store.cursor, 0);
    expect(store.state!.status, CollaborationStatus.live);
  });
  test('fence during delayed disk write cannot publish or reload old page', () async {
    final dir = await Directory.systemTemp.createTemp('collab-fence');
    addTearDown(() => dir.delete(recursive: true));
    final disk = FileCollaborationStoreBackend(File('${dir.path}/record'), ownerFence: 'account-a');
    final backend = DelayedBackend(disk);
    final store = CollaborationStore(backend, ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    backend.delay = Completer<void>();
    final write = store.applyPage(ownerFence: 'account-a', sessionGeneration: 1, page: [_message(1, 'late')]);
    await backend.started.future;
    store.fence();
    backend.delay!.complete();
    expect(await write, isFalse);
    expect(store.state, isNull);
    final reopened = CollaborationStore(disk, ownerFence: 'account-a');
    await reopened.load();
    expect(reopened.state, isNull);
  });
  test('new bootstrap wins over a write admitted under the previous generation', () async {
    final backend = DelayedBackend(MemoryCollaborationStoreBackend());
    final store = CollaborationStore(backend, ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    backend.delay = Completer<void>();
    final old = store.applyPage(ownerFence: 'account-a', sessionGeneration: 1, page: [_message(1, 'old')]);
    await backend.started.future;
    final replacement = store.installBootstrap(accountId: 'account-a', sessionGeneration: 2, state: _bootstrap());
    backend.delay!.complete();
    expect(await old, isFalse);
    await replacement;
    expect(store.sessionGeneration, 2);
    expect(store.state!.messages, isEmpty);
    final reopened = CollaborationStore(backend, ownerFence: 'account-a');
    await reopened.load();
    expect(reopened.sessionGeneration, 2);
    expect(reopened.state!.messages, isEmpty);
  });
  test('persists the account/session projection and cursor across reopen', () async {
    final backend = MemoryCollaborationStoreBackend();
    final first = CollaborationStore(backend, ownerFence: 'account-a');
    await first.installBootstrap(accountId: 'account-a', sessionGeneration: 7, state: _bootstrap());
    expect(
      await first.applyPage(
        ownerFence: 'account-a',
        sessionGeneration: 7,
        page: [_message(1, 'private text')],
      ),
      isTrue,
    );

    final reopened = CollaborationStore(backend, ownerFence: 'account-a');
    await reopened.load();
    expect(reopened.cursor, 1);
    expect(reopened.accountId, 'account-a');
    expect(reopened.sessionGeneration, 7);
    expect(reopened.state!.messages.map((message) => message.text), ['private text']);
  });

  test('commits a page atomically when backend persistence fails', () async {
    final backend = MemoryCollaborationStoreBackend();
    final store = CollaborationStore(backend, ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());
    backend.failNextWrite = true;

    await expectLater(
      store.applyPage(
        ownerFence: 'account-a',
        sessionGeneration: 1,
        page: [_message(1, 'must not partially commit')],
      ),
      throwsA(isA<CollaborationStoreException>()),
    );
    expect(store.cursor, 0);
    expect(store.state!.messages, isEmpty);

    final reopened = CollaborationStore(backend, ownerFence: 'account-a');
    await reopened.load();
    expect(reopened.cursor, 0);
    expect(reopened.state!.messages, isEmpty);
  });

  test('discards pages from a stale owner or session generation', () async {
    final backend = MemoryCollaborationStoreBackend();
    final store = CollaborationStore(backend, ownerFence: 'account-a');
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 3, state: _bootstrap());

    expect(
      await store.applyPage(
        ownerFence: 'account-b',
        sessionGeneration: 3,
        page: [_message(1, 'stale owner')],
      ),
      isFalse,
    );
    expect(
      await store.applyPage(
        ownerFence: 'account-a',
        sessionGeneration: 4,
        page: [_message(1, 'stale generation')],
      ),
      isFalse,
    );
    expect(store.cursor, 0);
  });

  test('reordered pages are reduced before the cursor commit', () async {
    final store = CollaborationStore(
      MemoryCollaborationStoreBackend(),
      ownerFence: 'account-a',
    );
    await store.installBootstrap(accountId: 'account-a', sessionGeneration: 1, state: _bootstrap());

    expect(
      await store.applyPage(
        ownerFence: 'account-a',
        sessionGeneration: 1,
        page: [_message(2, 'second'), _message(1, 'first')],
      ),
      isTrue,
    );
    expect(store.cursor, 2);
    expect(store.state!.messages.map((message) => message.text), ['first', 'second']);
  });
}

class DelayedBackend implements CollaborationStoreBackend {
  DelayedBackend(this.disk);
  final CollaborationStoreBackend disk;
  Completer<void>? delay;
  final started = Completer<void>();
  @override
  Future<Map<String, Object?>?> read() => disk.read();
  @override
  Future<void> clear() => disk.clear();
  @override
  Future<void> write(Map<String, Object?> record) async {
    if (delay != null) {
      if (!started.isCompleted) started.complete();
      await delay!.future;
    }
    await disk.write(record);
  }
}
