import 'package:flutter_test/flutter_test.dart';
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
