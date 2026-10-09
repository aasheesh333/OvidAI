/// Live collaboration client reducer (Wave 1).
///
/// Pure and inert: [CollaborationReducer.apply] takes a state and a validated
/// [CollaborationEvent] and returns a new state. It holds no dependencies,
/// accepts no callbacks, and performs no I/O. Remote events only update
/// presentation projections (messages, model status, usage, presence,
/// membership); they can never cause local execution.
///
/// Spec: docs/superpowers/specs/2026-10-09-live-collaboration-design.md
library;

import 'dart:collection';

import 'models.dart';

enum CollaborationStatus { live, resyncRequired, closed }

enum CloseReason { localRemoved, sessionClosed }

/// Result of the most recent reduction, for diagnostics and tests.
enum ReduceOutcome {
  bootstrapped,
  applied,
  duplicate,
  buffered,
  rejectedForeignSession,
  rejectedCapacity,
  rejectedUnauthorized,
  ignoredInactiveAuthor,
  ignoredClosed,
  ignoredResyncRequired,
  resyncRequired,
}

/// A rendered session message attributed to its author.
class CollaborationMessage {
  const CollaborationMessage({
    required this.sequence,
    required this.clientEventId,
    required this.author,
    required this.createdAt,
    required this.text,
  });

  final int sequence;
  final String clientEventId;
  final String author;
  final String createdAt;
  final String text;
}

/// Immutable client projection of a collaboration session.
class CollaborationState {
  CollaborationState._({
    required this.session,
    required Map<String, Member> members,
    required this.localParticipantId,
    required this.lastSequence,
    required List<CollaborationMessage> messages,
    required Map<String, ParticipantModelState> modelStates,
    required Map<String, PresenceState> presence,
    required Set<String> seenEventIds,
    required Map<int, CollaborationEvent> buffer,
    required this.status,
    required this.closeReason,
    required this.capacityViolations,
    required this.lastOutcome,
  }) : members = UnmodifiableMapView(Map.of(members)),
       messages = List.unmodifiable(messages),
       modelStates = UnmodifiableMapView(Map.of(modelStates)),
       presence = UnmodifiableMapView(Map.of(presence)),
       _seenEventIds = Set.unmodifiable(seenEventIds),
       _buffer = UnmodifiableMapView(Map.of(buffer));

  /// Installs bounded server bootstrap state. Throws [ArgumentError] when the
  /// bootstrap violates the owner/capacity invariants.
  factory CollaborationState.bootstrap({
    required CollaborationSession session,
    required List<Member> members,
    required String localParticipantId,
    required int lastSequence,
  }) {
    if (lastSequence < 0) throw ArgumentError.value(lastSequence, 'lastSequence');
    final byId = <String, Member>{};
    for (final m in members) {
      if (byId.containsKey(m.participantId)) throw ArgumentError('duplicate member');
      byId[m.participantId] = m;
    }
    final ownerEntry = byId[session.ownerParticipantId];
    if (ownerEntry == null || ownerEntry.role != MemberRole.owner) {
      throw ArgumentError('owner missing');
    }
    if (byId.values.where((m) => m.role == MemberRole.owner).length != 1) {
      throw ArgumentError('exactly one owner required');
    }
    if (byId.values.where((m) => m.isActive).length > maxActiveMembers) {
      throw ArgumentError('active member capacity exceeded');
    }
    final local = byId[localParticipantId];
    final closed = session.lifecycle == SessionLifecycle.closed;
    final localGone = local == null || !local.isActive;
    return CollaborationState._(
      session: session,
      members: byId,
      localParticipantId: localParticipantId,
      lastSequence: lastSequence,
      messages: const [],
      modelStates: const {},
      presence: const {},
      seenEventIds: const {},
      buffer: const {},
      status: localGone || closed ? CollaborationStatus.closed : CollaborationStatus.live,
      closeReason: localGone
          ? CloseReason.localRemoved
          : (closed ? CloseReason.sessionClosed : null),
      capacityViolations: 0,
      lastOutcome: ReduceOutcome.bootstrapped,
    );
  }

  final CollaborationSession session;
  final Map<String, Member> members;
  final String localParticipantId;

  /// Highest contiguously applied sequence.
  final int lastSequence;
  final List<CollaborationMessage> messages;
  final Map<String, ParticipantModelState> modelStates;
  final Map<String, PresenceState> presence;
  final Set<String> _seenEventIds;
  final Map<int, CollaborationEvent> _buffer;
  final CollaborationStatus status;
  final CloseReason? closeReason;

  /// Membership events rejected because they would exceed [maxActiveMembers].
  final int capacityViolations;
  final ReduceOutcome lastOutcome;

  int get bufferedCount => _buffer.length;

  List<Member> get activeMembers =>
      List.unmodifiable(members.values.where((m) => m.isActive));

  CollaborationState _copy({
    CollaborationSession? session,
    Map<String, Member>? members,
    int? lastSequence,
    List<CollaborationMessage>? messages,
    Map<String, ParticipantModelState>? modelStates,
    Map<String, PresenceState>? presence,
    Set<String>? seenEventIds,
    Map<int, CollaborationEvent>? buffer,
    CollaborationStatus? status,
    CloseReason? closeReason,
    int? capacityViolations,
    required ReduceOutcome lastOutcome,
  }) => CollaborationState._(
    session: session ?? this.session,
    members: members ?? this.members,
    localParticipantId: localParticipantId,
    lastSequence: lastSequence ?? this.lastSequence,
    messages: messages ?? this.messages,
    modelStates: modelStates ?? this.modelStates,
    presence: presence ?? this.presence,
    seenEventIds: seenEventIds ?? _seenEventIds,
    buffer: buffer ?? _buffer,
    status: status ?? this.status,
    closeReason: closeReason ?? this.closeReason,
    capacityViolations: capacityViolations ?? this.capacityViolations,
    lastOutcome: lastOutcome,
  );

  CollaborationState _withOutcome(ReduceOutcome outcome) => _copy(lastOutcome: outcome);

  /// Value snapshot for equality checks in tests. Contains no session token.
  Map<String, Object?> debugSnapshot() => {
    'session': session.toWire(),
    'members': [for (final m in members.values) m.toWire()],
    'localParticipantId': localParticipantId,
    'lastSequence': lastSequence,
    'messages': [for (final m in messages) '${m.sequence}:${m.author}:${m.text}'],
    'modelStates': {for (final e in modelStates.entries) e.key: e.value.toWire()},
    'presence': {for (final e in presence.entries) e.key: e.value.name},
    'seen': _seenEventIds.toList()..sort(),
    'buffer': _buffer.keys.toList()..sort(),
    'status': status.name,
    'closeReason': closeReason?.name,
    'capacityViolations': capacityViolations,
  };
}

/// Stateless, dependency-free reducer.
class CollaborationReducer {
  const CollaborationReducer();

  /// Out-of-order events held while waiting for a missing sequence. Beyond
  /// this bound the client requires a resync rather than growing memory.
  static const int maxBufferedEvents = 100;

  /// Applies one event. Out-of-order events are buffered; contiguous buffered
  /// events are drained immediately.
  CollaborationState apply(CollaborationState state, CollaborationEvent event) {
    if (state.status == CollaborationStatus.closed) {
      return state._withOutcome(ReduceOutcome.ignoredClosed);
    }
    if (state.status == CollaborationStatus.resyncRequired) {
      return state._withOutcome(ReduceOutcome.ignoredResyncRequired);
    }
    if (event.sessionId != state.session.sessionId) {
      return state._withOutcome(ReduceOutcome.rejectedForeignSession);
    }
    if (event.sequence <= state.lastSequence || state._buffer.containsKey(event.sequence)) {
      return state._withOutcome(ReduceOutcome.duplicate);
    }
    if (event.sequence > state.lastSequence + 1) {
      if (state._buffer.length >= maxBufferedEvents) {
        return state._copy(
          status: CollaborationStatus.resyncRequired,
          buffer: const {},
          lastOutcome: ReduceOutcome.resyncRequired,
        );
      }
      return state._copy(
        buffer: {...state._buffer, event.sequence: event},
        lastOutcome: ReduceOutcome.buffered,
      );
    }

    var next = _applyContiguous(state, event);
    final firstOutcome = next.lastOutcome;
    // Drain the buffer while contiguous.
    while (next.status == CollaborationStatus.live) {
      final pending = next._buffer[next.lastSequence + 1];
      if (pending == null) break;
      final rest = Map.of(next._buffer)..remove(pending.sequence);
      next = _applyContiguous(next._copy(buffer: rest, lastOutcome: next.lastOutcome), pending);
    }
    if (next.status == CollaborationStatus.closed && next._buffer.isNotEmpty) {
      next = next._copy(buffer: const {}, lastOutcome: next.lastOutcome);
    }
    return next._withOutcome(firstOutcome);
  }

  /// Applies a replay page (any order). If a gap remains once the page is
  /// consumed, the state requires a resync (bootstrap + replay).
  CollaborationState applyPage(CollaborationState state, Iterable<CollaborationEvent> page) {
    var next = state;
    for (final event in page) {
      next = apply(next, event);
    }
    if (next.status == CollaborationStatus.live && next.bufferedCount > 0) {
      return next._copy(
        status: CollaborationStatus.resyncRequired,
        buffer: const {},
        lastOutcome: ReduceOutcome.resyncRequired,
      );
    }
    return next;
  }

  /// Applies an event whose sequence is exactly `lastSequence + 1`. The
  /// sequence is always consumed, even when the event is ignored/rejected.
  CollaborationState _applyContiguous(CollaborationState s, CollaborationEvent e) {
    final seq = e.sequence;
    if (s._seenEventIds.contains(e.clientEventId)) {
      return s._copy(lastSequence: seq, lastOutcome: ReduceOutcome.duplicate);
    }
    final seen = {...s._seenEventIds, e.clientEventId};
    CollaborationState consume(ReduceOutcome outcome) =>
        s._copy(lastSequence: seq, seenEventIds: seen, lastOutcome: outcome);

    final authorMember = s.members[e.author];
    final authorActive = authorMember != null && authorMember.isActive;
    final isOwner = e.author == s.session.ownerParticipantId && authorActive;

    final payload = e.payload;
    switch (payload) {
      case MessagePayload(:final text):
        if (!authorActive) return consume(ReduceOutcome.ignoredInactiveAuthor);
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          messages: [
            ...s.messages,
            CollaborationMessage(
              sequence: seq,
              clientEventId: e.clientEventId,
              author: e.author,
              createdAt: e.createdAt,
              text: text,
            ),
          ],
          lastOutcome: ReduceOutcome.applied,
        );

      case ModelStatusPayload p:
        if (!authorActive) return consume(ReduceOutcome.ignoredInactiveAuthor);
        final previous = s.modelStates[e.author];
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          modelStates: {
            ...s.modelStates,
            e.author: ParticipantModelState(
              participantId: e.author,
              providerId: p.providerId,
              requestedModel: p.requestedModel,
              reportedModel: p.reportedModel,
              displayName: p.displayName,
              streaming: p.streaming,
              status: p.status,
              usage: previous?.usage,
            ),
          },
          lastOutcome: ReduceOutcome.applied,
        );

      case UsagePayload(:final usage):
        if (!authorActive) return consume(ReduceOutcome.ignoredInactiveAuthor);
        final previous = s.modelStates[e.author];
        if (previous == null) {
          // Usage without a model label: nothing to attach it to. Spec-silent;
          // consumed without projecting rather than inventing a label.
          return consume(ReduceOutcome.applied);
        }
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          modelStates: {...s.modelStates, e.author: previous.withUsage(usage)},
          lastOutcome: ReduceOutcome.applied,
        );

      case PresencePayload(:final state):
        if (!authorActive) return consume(ReduceOutcome.ignoredInactiveAuthor);
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          presence: {...s.presence, e.author: state},
          lastOutcome: ReduceOutcome.applied,
        );

      case MembershipPayload p:
        return _applyMembership(s, e, p, seq, seen, isOwner, authorActive);

      case SystemPayload(:final code):
        if (!isOwner) return consume(ReduceOutcome.rejectedUnauthorized);
        if (code == SystemCode.sessionClosing) {
          return s._copy(
            lastSequence: seq,
            seenEventIds: seen,
            session: s.session.withLifecycle(SessionLifecycle.closing),
            lastOutcome: ReduceOutcome.applied,
          );
        }
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          session: s.session.withLifecycle(SessionLifecycle.closed),
          status: CollaborationStatus.closed,
          closeReason: CloseReason.sessionClosed,
          lastOutcome: ReduceOutcome.applied,
        );
    }
  }

  CollaborationState _applyMembership(
    CollaborationState s,
    CollaborationEvent e,
    MembershipPayload p,
    int seq,
    Set<String> seen,
    bool isOwner,
    bool authorActive,
  ) {
    CollaborationState consume(ReduceOutcome outcome, {int? violations}) => s._copy(
      lastSequence: seq,
      seenEventIds: seen,
      capacityViolations: violations,
      lastOutcome: outcome,
    );

    final target = s.members[p.participantId];
    final targetIsOwner = p.participantId == s.session.ownerParticipantId;

    switch (p.action) {
      case MembershipAction.joined:
        if (!isOwner) return consume(ReduceOutcome.rejectedUnauthorized);
        if (targetIsOwner) return consume(ReduceOutcome.rejectedUnauthorized);
        if (target != null && target.isActive) {
          // Reconnect of an already-active member: no second slot.
          return consume(ReduceOutcome.applied);
        }
        if (s.activeMembers.length >= maxActiveMembers) {
          return consume(
            ReduceOutcome.rejectedCapacity,
            violations: s.capacityViolations + 1,
          );
        }
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          members: {
            ...s.members,
            p.participantId: Member(
              participantId: p.participantId,
              role: MemberRole.participant,
              status: MemberStatus.active,
            ),
          },
          lastOutcome: ReduceOutcome.applied,
        );

      case MembershipAction.revoked:
      case MembershipAction.left:
        final allowed = p.action == MembershipAction.revoked
            ? isOwner
            : authorActive && e.author == p.participantId;
        if (!allowed || targetIsOwner) return consume(ReduceOutcome.rejectedUnauthorized);
        if (target == null || !target.isActive) return consume(ReduceOutcome.applied);
        final nextStatus =
            p.action == MembershipAction.revoked ? MemberStatus.revoked : MemberStatus.left;
        final members = {...s.members, p.participantId: target.withStatus(nextStatus)};
        final presence = Map.of(s.presence)..remove(p.participantId);
        final localRemoved = p.participantId == s.localParticipantId;
        return s._copy(
          lastSequence: seq,
          seenEventIds: seen,
          members: members,
          presence: presence,
          status: localRemoved ? CollaborationStatus.closed : null,
          closeReason: localRemoved ? CloseReason.localRemoved : null,
          lastOutcome: ReduceOutcome.applied,
        );
    }
  }
}
