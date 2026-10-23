// One sender at a time in a Collab room.
//
// The gate existed, but `turnHolderId` only recognised a peer that was
// `running` or `queued`. A peer whose agent is still producing text can be
// reported with `streaming: true` and `status: idle` (between tool calls), and
// in that window the room fell through to "the last message was the
// assistant's, so nobody holds the turn" — every other member could send.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/client.dart'
    show CollaborationClientException;
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/ui/v2/app/v2_collab_routes.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';

CollaborationState _room({String local = 'p2'}) =>
    CollaborationState.bootstrap(
      session: const CollaborationSession(
        sessionId: 'collab-1',
        ownerParticipantId: 'p1',
        lifecycle: SessionLifecycle.active,
      ),
      members: const [
        Member(
          participantId: 'p1',
          role: MemberRole.owner,
          status: MemberStatus.active,
          displayName: 'Priya Patel',
        ),
        Member(
          participantId: 'p2',
          role: MemberRole.participant,
          status: MemberStatus.active,
          displayName: 'Rahul Verma',
        ),
      ],
      localParticipantId: local,
      lastSequence: 0,
    );

CollaborationEvent _event({
  required String id,
  required int sequence,
  required String author,
  required CollaborationPayload payload,
  required CollaborationEventType kind,
}) =>
    CollaborationEvent.fromWire({
      'schemaVersion': 1,
      'eventId': id,
      'sessionId': 'collab-1',
      'eventSequence': sequence,
      'senderParticipantId': author,
      'kind': kind.name,
      'createdAt': DateTime.utc(2026, 10, 23, 10).toIso8601String(),
      'payload': payload.toWire(),
    });

ModelStatusPayload _modelStatus({
  required bool streaming,
  required ModelExecutionStatus status,
}) =>
    ModelStatusPayload(
      providerId: 'ovid-cloud',
      requestedModel: 'auto',
      reportedModel: 'glm-5.3-flash',
      displayName: 'Auto',
      streaming: streaming,
      status: status,
    );

void main() {
  _mentionKindsContract();

  test('a peer streaming with an idle status still holds the turn', () {
    final state = _room();
    final applied = const CollaborationReducer().apply(
      state,
      _event(
        id: 'e1',
        sequence: 1,
        author: 'p1',
        kind: CollaborationEventType.modelStatus,
        payload: _modelStatus(streaming: true, status: ModelExecutionStatus.idle),
      ),
    );

    expect(V2CollabRoutes.turnHolderId(applied), 'p1');
    // The local member is p2, so its composer must be locked.
    expect(V2CollabRoutes.liveDataFor(applied).isMyTurn, isFalse);
  });

  test('the holder can send while it is the one streaming', () {
    final state = _room(local: 'p1');
    final applied = const CollaborationReducer().apply(
      state,
      _event(
        id: 'e1',
        sequence: 1,
        author: 'p1',
        kind: CollaborationEventType.modelStatus,
        payload: _modelStatus(streaming: true, status: ModelExecutionStatus.idle),
      ),
    );

    expect(V2CollabRoutes.liveDataFor(applied).isMyTurn, isTrue);
  });

  test('a finished peer frees the turn', () {
    final state = _room();
    final applied = const CollaborationReducer().apply(
      state,
      _event(
        id: 'e1',
        sequence: 1,
        author: 'p1',
        kind: CollaborationEventType.modelStatus,
        payload: _modelStatus(
          streaming: false,
          status: ModelExecutionStatus.completed,
        ),
      ),
    );

    expect(V2CollabRoutes.liveDataFor(applied).isMyTurn, isTrue);
  });

  test('a turn_locked refusal is one plain sentence, never a code', () {
    const error = CollaborationClientException(
      'raw upstream copy',
      statusCode: 409,
      code: 'turn_locked',
    );

    final sentence = collaborationErrorMessage(error);
    expect(sentence, collabTurnLockedSentence);
    expect(
      sentence,
      "Another participant's reply is still streaming. Send when it finishes.",
    );
    // The same words the web client shows, and no machine code in sight.
    expect(sentence.contains('_'), isFalse);
    expect(sentence.contains('raw upstream copy'), isFalse);
  });

  test('a gateway without /chat says so, and keeps the read-only path', () {
    final sentence = collaborationErrorMessage(
      const CollaborationClientException(
        'Live sessions are unavailable',
        statusCode: 404,
        code: 'collab_unavailable',
      ),
    );
    expect(sentence, collabUnavailableSentence);
    expect(sentence.contains('_'), isFalse);
    expect(sentence.toLowerCase(), contains('read-only'));
  });
}

// Spec §2.B.4: the @ picker lists sessions, projects AND active subagents.
void _mentionKindsContract() {
  test('a subagent candidate is addressable with @subagent:<id>', () {
    const row = V2MentionCandidate.subagent(id: 'child-9', title: 'auth fix');
    expect(row.isSubagent, isTrue);
    expect(row.token, '@subagent:child-9 ');
    expect(V2MentionTokens.subagentIdTag.firstMatch(row.token)?.group(1), 'child-9');
  });

  test('the picker surfaces subagents alongside sessions and projects', () {
    final rows = rankV2Mentions(
      const [V2MentionCandidate.session(id: 's1', title: 'Chat one', subtitle: '')],
      const [V2MentionCandidate.project(id: 'p1', title: 'Project one')],
      '',
      limit: 5,
      subagents: const [
        V2MentionCandidate.subagent(id: 'c1', title: 'Worker one'),
      ],
    );
    expect(rows.map((r) => r.kind), contains(V2MentionKind.subagent));
  });

  test('typing @subagent: filters to workers only', () {
    final rows = rankV2Mentions(
      const [V2MentionCandidate.session(id: 's1', title: 'subagent work', subtitle: '')],
      const [],
      'subagent:worker',
      subagents: const [
        V2MentionCandidate.subagent(id: 'c1', title: 'Worker one'),
        V2MentionCandidate.subagent(id: 'c2', title: 'Other'),
      ],
    );
    expect(rows.map((r) => r.id), ['c1']);
  });
}
