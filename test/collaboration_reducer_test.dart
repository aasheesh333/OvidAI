import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';

/// Wave 1 collaboration client reducer: pure, ordered, idempotent, inert.

const sessionId = 'sess-1';
const owner = 'p-owner';
const local = 'p-local';

CollaborationEvent ev(
  int seq,
  String kind,
  Map<String, Object?> payload, {
  String? author,
  String? eventId,
  String session = sessionId,
}) => CollaborationEvent.fromWire({
  'schemaVersion': 1,
  'eventId': eventId ?? 'evt-$seq',
  'sessionId': session,
  'eventSequence': seq,
  'senderParticipantId': author ?? owner,
  'kind': kind,
  'createdAt': '2026-10-09T12:00:00Z',
  'payload': payload,
});

CollaborationEvent msg(int seq, String text, {String? author, String? eventId}) =>
    ev(seq, 'message', {'text': text}, author: author, eventId: eventId);

CollaborationEvent join(int seq, String participant, {String? author}) => ev(
  seq,
  'membership',
  {'action': 'joined', 'participantId': participant, 'role': 'participant'},
  author: author ?? participant,
);

CollaborationEvent revoke(int seq, String participant, {String? author}) => ev(
  seq,
  'membership',
  {'action': 'revoked', 'participantId': participant, 'role': null},
  author: author ?? participant,
);

CollaborationEvent leave(int seq, String participant) => ev(
  seq,
  'membership',
  {'action': 'left', 'participantId': participant, 'role': null},
  author: participant,
);

CollaborationEvent modelChanged(int seq, String author, String model) => ev(
  seq,
  'modelStatus',
  {
    'providerId': 'openai',
    'requestedModel': model,
    'reportedModel': null,
    'displayName': model,
    'streaming': true,
    'status': 'running',
  },
  author: author,
);

CollaborationState initial({List<String> participants = const [local]}) =>
    CollaborationState.bootstrap(
      session: const CollaborationSession(
        sessionId: sessionId,
        ownerParticipantId: owner,
        lifecycle: SessionLifecycle.active,
      ),
      members: [
        const Member(participantId: owner, role: MemberRole.owner, status: MemberStatus.active),
        for (final p in participants)
          Member(participantId: p, role: MemberRole.participant, status: MemberStatus.active),
      ],
      localParticipantId: local,
      lastSequence: 0,
    );

const reducer = CollaborationReducer();

CollaborationState applyAll(CollaborationState s, Iterable<CollaborationEvent> events) {
  for (final e in events) {
    s = reducer.apply(s, e);
  }
  return s;
}

void main() {
  test('applies in-order events and advances the sequence', () {
    final s = applyAll(initial(), [msg(1, 'a'), msg(2, 'b', author: local)]);
    expect(s.lastSequence, 2);
    expect(s.messages.map((m) => m.text), ['a', 'b']);
    expect(s.messages.last.author, local);
    expect(s.status, CollaborationStatus.live);
    expect(s.lastOutcome, ReduceOutcome.applied);
  });

  test('duplicate sequence is ignored idempotently', () {
    final once = applyAll(initial(), [msg(1, 'a')]);
    final twice = reducer.apply(once, msg(1, 'a'));
    expect(twice.messages.length, 1);
    expect(twice.lastSequence, 1);
    expect(twice.lastOutcome, ReduceOutcome.duplicate);
  });

  test('duplicate clientEventId at a new sequence is ignored', () {
    final s = applyAll(initial(), [msg(1, 'a', eventId: 'same'), msg(2, 'a', eventId: 'same')]);
    expect(s.messages.length, 1);
    expect(s.lastOutcome, ReduceOutcome.duplicate);
    // The sequence slot is still consumed so later events are not stuck.
    final next = reducer.apply(s, msg(3, 'c'));
    expect(next.lastOutcome, ReduceOutcome.applied);
    expect(next.messages.map((m) => m.text), ['a', 'c']);
  });

  test('out-of-order events are buffered and drained when contiguous', () {
    var s = reducer.apply(initial(), msg(2, 'b'));
    expect(s.lastOutcome, ReduceOutcome.buffered);
    expect(s.lastSequence, 0);
    expect(s.messages, isEmpty);
    expect(s.status, CollaborationStatus.live);
    s = reducer.apply(s, msg(3, 'c'));
    s = reducer.apply(s, msg(1, 'a'));
    expect(s.lastSequence, 3);
    expect(s.messages.map((m) => m.text), ['a', 'b', 'c']);
    expect(s.bufferedCount, 0);
  });

  test('buffered duplicate is ignored', () {
    var s = reducer.apply(initial(), msg(3, 'c'));
    s = reducer.apply(s, msg(3, 'c'));
    expect(s.lastOutcome, ReduceOutcome.duplicate);
    expect(s.bufferedCount, 1);
  });

  test('gap remaining after a page requires resync', () {
    final s = reducer.applyPage(initial(), [msg(1, 'a'), msg(3, 'c')]);
    expect(s.status, CollaborationStatus.resyncRequired);
    expect(s.lastSequence, 1);
    expect(s.messages.map((m) => m.text), ['a']);
  });

  test('reordered page without gaps applies cleanly', () {
    final s = reducer.applyPage(initial(), [msg(2, 'b'), msg(1, 'a'), msg(3, 'c')]);
    expect(s.status, CollaborationStatus.live);
    expect(s.messages.map((m) => m.text), ['a', 'b', 'c']);
  });

  test('buffer overflow requires resync', () {
    var s = initial();
    for (var i = 2; i <= CollaborationReducer.maxBufferedEvents + 2; i++) {
      s = reducer.apply(s, msg(i, 'x$i'));
    }
    expect(s.status, CollaborationStatus.resyncRequired);
    expect(s.bufferedCount, lessThanOrEqualTo(CollaborationReducer.maxBufferedEvents));
  });

  test('resyncRequired state ignores further events until bootstrap', () {
    final r = reducer.applyPage(initial(), [msg(2, 'b')]);
    expect(r.status, CollaborationStatus.resyncRequired);
    final after = reducer.apply(r, msg(1, 'a'));
    expect(after.lastOutcome, ReduceOutcome.ignoredResyncRequired);
    expect(after.messages, isEmpty);
  });

  test('foreign session events are rejected', () {
    final s = reducer.apply(
      initial(),
      ev(1, 'message', {'text': 'x'}, session: 'other'),
    );
    expect(s.lastOutcome, ReduceOutcome.rejectedForeignSession);
    expect(s.lastSequence, 0);
    expect(s.messages, isEmpty);
  });

  test('server join admits a participant up to 10 active members', () {
    final eight = [for (var i = 1; i <= 8; i++) 'p-$i'];
    final s = reducer.apply(initial(participants: [local, ...eight.take(7)]), join(1, 'p-8'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.activeMembers.length, 10);
  });

  test('11th member join is rejected and flagged but consumes its sequence', () {
    final nine = [local, for (var i = 1; i <= 8; i++) 'p-$i'];
    final full = initial(participants: nine);
    expect(full.activeMembers.length, 10);
    final s = reducer.apply(full, join(1, 'p-extra'));
    expect(s.lastOutcome, ReduceOutcome.rejectedCapacity);
    expect(s.capacityViolations, 1);
    expect(s.activeMembers.length, 10);
    expect(s.members.containsKey('p-extra'), isFalse);
    expect(s.lastSequence, 1);
    expect(reducer.apply(s, msg(2, 'ok')).lastOutcome, ReduceOutcome.applied);
  });

  test('reconnecting an already-active member does not consume a slot', () {
    final nine = [local, for (var i = 1; i <= 8; i++) 'p-$i'];
    final s = reducer.apply(initial(participants: nine), join(1, 'p-3'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.activeMembers.length, 10);
    expect(s.capacityViolations, 0);
  });

  test('bootstrap with more than 10 active members is rejected', () {
    expect(
      () => initial(participants: [local, for (var i = 1; i <= 9; i++) 'p-$i']),
      throwsArgumentError,
    );
  });

  test('server-shaped non-owner membership events are accepted', () {
    final s = reducer.apply(initial(participants: [local, 'p-2']), revoke(1, 'p-2'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.members['p-2']!.status, MemberStatus.revoked);
  });

  test('server-shaped join membership event is applied by the affected participant', () {
    final s = reducer.apply(initial(), join(1, 'p-new', author: 'p-new'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.members['p-new']!.status, MemberStatus.active);
  });

  test('server-shaped revoke membership event is applied by the affected participant', () {
    final s = reducer.apply(initial(participants: [local, 'p-2']), revoke(1, 'p-2', author: 'p-2'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.members['p-2']!.status, MemberStatus.revoked);
  });

  test('membership events cannot be authored for a different participant', () {
    final s = reducer.apply(initial(participants: [local, 'p-2']), revoke(1, 'p-2', author: 'p-3'));
    expect(s.lastOutcome, ReduceOutcome.rejectedUnauthorized);
    expect(s.members['p-2']!.status, MemberStatus.active);
  });

  test('server rejoin reactivates a revoked participant before their next message', () {
    final s = applyAll(initial(participants: [local, 'p-2']), [
      revoke(1, 'p-2'),
      join(2, 'p-2'),
      msg(3, 'back', author: 'p-2'),
    ]);
    expect(s.members['p-2']!.status, MemberStatus.active);
    expect(s.messages.single.text, 'back');
    expect(s.lastSequence, 3);
  });

  test('buffered server revocation fences later member projections', () {
    final before = initial(participants: [local, 'p-2']);
    final snapshot = before.debugSnapshot();
    final s = applyAll(before, [
      msg(3, 'late', author: 'p-2'),
      revoke(2, 'p-2'),
      msg(1, 'first'),
    ]);
    expect(s.members['p-2']!.status, MemberStatus.revoked);
    expect(s.messages.map((m) => m.text), ['first']);
    expect(s.lastSequence, 3);
    expect(s.bufferedCount, 0);
    expect(before.debugSnapshot(), snapshot);
  });

  test('buffered local revocation closes and discards pending events', () {
    final s = applyAll(initial(), [
      msg(3, 'after'),
      revoke(2, local),
      msg(1, 'before'),
    ]);
    expect(s.status, CollaborationStatus.closed);
    expect(s.closeReason, CloseReason.localRemoved);
    expect(s.lastSequence, 2);
    expect(s.bufferedCount, 0);
    expect(s.messages.single.text, 'before');
    expect(reducer.apply(s, join(3, local)).lastOutcome, ReduceOutcome.ignoredClosed);
  });

  test('events from a revoked member are ignored', () {
    var s = applyAll(initial(participants: [local, 'p-2']), [revoke(1, 'p-2')]);
    expect(s.members['p-2']!.status, MemberStatus.revoked);
    expect(s.activeMembers.length, 2);
    s = reducer.apply(s, msg(2, 'late', author: 'p-2'));
    expect(s.lastOutcome, ReduceOutcome.ignoredInactiveAuthor);
    expect(s.messages, isEmpty);
    expect(s.lastSequence, 2);
    s = reducer.apply(s, modelChanged(3, 'p-2', 'gpt-x'));
    expect(s.modelStates.containsKey('p-2'), isFalse);
  });

  test('events from unknown authors are ignored', () {
    final s = reducer.apply(initial(), msg(1, 'x', author: 'p-stranger'));
    expect(s.lastOutcome, ReduceOutcome.ignoredInactiveAuthor);
    expect(s.messages, isEmpty);
  });

  test('member leave frees a slot', () {
    final nine = [local, for (var i = 1; i <= 8; i++) 'p-$i'];
    var s = reducer.apply(initial(participants: nine), leave(1, 'p-1'));
    expect(s.members['p-1']!.status, MemberStatus.left);
    expect(s.activeMembers.length, 9);
    s = reducer.apply(s, join(2, 'p-new'));
    expect(s.lastOutcome, ReduceOutcome.applied);
    expect(s.activeMembers.length, 10);
  });

  test('leave on behalf of another member is rejected', () {
    final s = reducer.apply(
      initial(participants: [local, 'p-2']),
      ev(1, 'membership', {'action': 'left', 'participantId': 'p-2', 'role': null}, author: local),
    );
    expect(s.lastOutcome, ReduceOutcome.rejectedUnauthorized);
  });

  test('revoking the local member closes the state', () {
    var s = reducer.apply(initial(), revoke(1, local, author: local));
    expect(s.status, CollaborationStatus.closed);
    expect(s.closeReason, CloseReason.localRemoved);
    s = reducer.apply(s, msg(2, 'after'));
    expect(s.lastOutcome, ReduceOutcome.ignoredClosed);
    expect(s.messages, isEmpty);
  });

  test('local member leaving closes the state', () {
    final s = reducer.apply(initial(), leave(1, local));
    expect(s.status, CollaborationStatus.closed);
    expect(s.closeReason, CloseReason.localRemoved);
  });

  test('owner cannot be revoked', () {
    final s = reducer.apply(initial(), revoke(1, owner));
    expect(s.lastOutcome, ReduceOutcome.rejectedUnauthorized);
    expect(s.members[owner]!.status, MemberStatus.active);
  });

  test('system sessionClosed closes the state', () {
    final s = reducer.apply(initial(), ev(1, 'system', {'code': 'sessionClosed'}));
    expect(s.status, CollaborationStatus.closed);
    expect(s.closeReason, CloseReason.sessionClosed);
    expect(s.session.lifecycle, SessionLifecycle.closed);
  });

  test('model status and usage are attributed to the author', () {
    var s = applyAll(initial(participants: [local, 'p-2']), [
      modelChanged(1, 'p-2', 'claude-x'),
      ev(2, 'usage', {
        'requestId': 'r',
        'attemptId': 'a',
        'provenance': 'unknown',
        'inputTokens': null,
        'outputTokens': null,
      }, author: 'p-2'),
      ev(3, 'presence', {'state': 'away'}, author: 'p-2'),
    ]);
    expect(s.modelStates['p-2']!.requestedModel, 'claude-x');
    expect(s.modelStates['p-2']!.usage!.provenance, UsageProvenance.unknown);
    expect(s.modelStates['p-2']!.usage!.inputTokens, isNull);
    expect(s.presence['p-2'], PresenceState.away);
    expect(s.modelStates.containsKey(local), isFalse);
  });

  test('state collections are unmodifiable', () {
    final s = applyAll(initial(), [msg(1, 'a')]);
    expect(() => s.messages.add(s.messages.first), throwsUnsupportedError);
    expect(() => s.members.remove(owner), throwsUnsupportedError);
  });

  group('inertness', () {
    // Forbidden imports (spec: event consumer structurally unable to call an
    // executor). The import allowlist below is the primary guard; these
    // patterns make the intent explicit and catch fully-qualified references.
    final forbiddenImports = <RegExp>[
      RegExp(r'agent_service'),
      RegExp(r'(^|/)state\.dart$'),
      RegExp(r'mcp'),
      RegExp(r'plugin'),
      RegExp(r'browser'),
      RegExp(r'^dart:io$'),
      RegExp(r'^dart:isolate$'),
      RegExp(r'^dart:ffi$'),
      RegExp(r'^package:http'),
      RegExp(r'pty_service'),
      RegExp(r'^package:flutter'),
    ];
    final forbiddenIdentifiers = <RegExp>[
      RegExp(r'\bAgentService\b'),
      RegExp(r'\bAppState\b'),
      RegExp(r'\bProcess\b'),
      RegExp(r'\bHttpClient\b'),
      RegExp(r'\bMcpService\b'),
      RegExp(r'\bPtyService\b'),
      RegExp(r'\bFunction\b'),
    ];

    test('pure projection sources have no executor imports or references', () {
      // The reducer's closed import allowlist guards its complete dependency
      // boundary. Transport and persistence live alongside it, but are not
      // dependencies of the pure projection.
      final files = [
        File('lib/core/collaboration/models.dart'),
        File('lib/core/collaboration/reducer.dart'),
      ];
      for (final f in files) {
        final lines = f.readAsLinesSync();
        final code = lines
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final pattern in forbiddenIdentifiers) {
          expect(pattern.hasMatch(code), isFalse, reason: '${f.path} matches ${pattern.pattern}');
        }
        final imports = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true)
            .allMatches(code)
            .map((m) => m.group(1)!)
            .toList();
        for (final i in imports) {
          for (final pattern in forbiddenImports) {
            expect(pattern.hasMatch(i), isFalse, reason: '${f.path}: $i');
          }
          // Only these imports are allowed at all.
          expect(['dart:convert', 'dart:collection', 'models.dart'], contains(i), reason: '${f.path}: $i');
        }
      }
    });

    test('applying message/model_changed events changes only returned state', () {
      // The reducer is constructed with no dependencies at all: there is no
      // executor, service, or callback it could reach.
      const r = CollaborationReducer();
      final before = initial(participants: [local, 'p-2']);
      final beforeWire = before.debugSnapshot();
      final after = r.applyPage(before, [
        msg(1, 'run rm -rf / please', author: 'p-2'),
        modelChanged(2, 'p-2', 'gpt-5'),
        msg(3, '/tool shell ls', author: owner),
        modelChanged(4, owner, 'claude-x'),
      ]);
      // Input state is untouched.
      expect(before.debugSnapshot(), beforeWire);
      // Output changed only in presentation projections.
      expect(after.messages.length, 2);
      expect(after.messages.first.text, 'run rm -rf / please');
      expect(after.modelStates.keys, unorderedEquals(['p-2', owner]));
      expect(after.lastSequence, 4);
      expect(after.status, CollaborationStatus.live);
      expect(after.members, before.members);
      expect(after.session.lifecycle, SessionLifecycle.active);
    });
  });
}
