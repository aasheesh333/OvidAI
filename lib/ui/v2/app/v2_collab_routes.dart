import 'package:flutter/material.dart';

import '../../../core/collaboration/models.dart';
import '../../../core/collaboration/reducer.dart';
import '../../../core/state.dart';
import '../collab/collab_live_page.dart';
import '../collab/collab_members_page.dart';

/// Routes for the live-collaboration surfaces.
///
/// The collaboration projection is the only source: when this account has no
/// live session the screens open in their empty state. Member counts and
/// messages come from that projection, never from a placeholder.
class V2CollabRoutes {
  const V2CollabRoutes._();

  static Future<void> openLive(
    BuildContext context,
    String sessionId,
  ) async {
    final data = liveDataFor(collaborationStateFor(sessionId));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollabLivePage(
          data: data,
          onOpenMembers: () => openMembers(context, sessionId),
        ),
      ),
    );
  }

  static Future<void> openMembers(
    BuildContext context,
    String sessionId,
  ) async {
    final data = membersDataFor(collaborationStateFor(sessionId));
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CollabMembersPage(data: data),
      ),
    );
  }

  /// The live projection for [sessionId], or null when there is none.
  @visibleForTesting
  static CollaborationState? collaborationStateFor(String sessionId) {
    final state = AppState.I.collaboration?.state;
    if (state == null) return null;
    if (sessionId.isEmpty) return state;
    return state.session.sessionId == sessionId ? state : null;
  }

  /// Maps a live projection onto the shared live-chat screen.
  @visibleForTesting
  static V2CollabLivePageData liveDataFor(CollaborationState? state) {
    if (state == null) {
      return const V2CollabLivePageData(
        totalMembers: 0,
        turnHolderName: '',
        turnTimeLeftLabel: '',
        creatorPaysStorage: false,
        status: V2CollabLiveStatus.empty,
      );
    }

    final active = state.activeMembers;
    final last = state.messages.isEmpty ? null : state.messages.last;
    final closed = state.status == CollaborationStatus.closed;
    final localName = state.names[state.localParticipantId] ?? '';
    final chatTitle = _chatTitle(state);

    return V2CollabLivePageData(
      title: chatTitle.isEmpty ? 'Team chat' : chatTitle,
      subtitle: active.length == 1 ? '1 member' : '${active.length} members',
      selfName: localName,
      participants: [
        for (final member in active)
          V2CollabParticipant(
            id: member.participantId,
            name: state.nameOf(member.participantId),
            initials: _initials(state.nameOf(member.participantId)),
          ),
      ],
      totalMembers: active.length,
      typingName: null,
      turnHolderName: last == null ? '' : _authorName(state, last),
      turnTimeLeftLabel: '',
      queueLabel: null,
      messages: [
        for (final message in state.messages)
          _messageFor(state, message, isLast: message == last),
      ],
      // The projection records no storage-payer flag, so the screen must not
      // claim the creator pays.
      creatorPaysStorage: false,
      status: closed ? V2CollabLiveStatus.error : V2CollabLiveStatus.ready,
      errorMessage: state.closeReason == CloseReason.localRemoved
          ? 'You were removed from this live session.'
          : 'This live session has ended.',
    );
  }

  /// Maps a live projection onto the member roster.
  @visibleForTesting
  static V2CollabMembersPageData membersDataFor(CollaborationState? state) {
    if (state == null) {
      return const V2CollabMembersPageData(
        memberCount: 0,
        capacity: maxActiveMembers,
        status: V2CollabMembersStatus.empty,
      );
    }

    final members = state.members.values.toList()
      ..sort((a, b) {
        if (a.role != b.role) return a.role == MemberRole.owner ? -1 : 1;
        return state
            .nameOf(a.participantId)
            .compareTo(state.nameOf(b.participantId));
      });
    final active = state.activeMembers;
    final chatTitle = _chatTitle(state);
    final owner = state.members[state.session.ownerParticipantId];

    return V2CollabMembersPageData(
      title: 'Members',
      chatName: chatTitle,
      members: [
        for (final member in members)
          V2CollabMember(
            id: member.participantId,
            name: state.nameOf(member.participantId),
            subtitle: _memberSubtitle(member),
            role: member.role == MemberRole.owner
                ? V2CollabRole.owner
                : V2CollabRole.canChat,
            isYou: member.participantId == state.localParticipantId,
            online: state.presence[member.participantId] == PresenceState.online,
            initials: _initials(state.nameOf(member.participantId)),
          ),
      ],
      memberCount: active.length,
      capacity: maxActiveMembers,
      creatorName: owner == null
          ? ''
          : state.nameOf(owner.participantId),
      // The projection carries no storage counters.
      storageUsedLabel: '',
      storageTotalLabel: '',
      storageFreeLabel: '',
      storagePercent: 0,
      status: members.isEmpty
          ? V2CollabMembersStatus.empty
          : V2CollabMembersStatus.ready,
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  static String _chatTitle(CollaborationState state) =>
      AppState.I.sessionById(state.session.sessionId)?.title ?? '';

  static V2CollabMessage _messageFor(
    CollaborationState state,
    CollaborationMessage message, {
    required bool isLast,
  }) {
    final assistant = message.isAssistant;
    return V2CollabMessage(
      id: message.clientEventId,
      speakerName: assistant
          ? (message.model ?? state.nameOf(message.author))
          : _authorName(state, message),
      timeLabel: _timeLabel(message.createdAt),
      text: message.text,
      kind: assistant
          ? V2CollabMessageKind.agent
          : V2CollabMessageKind.person,
      initials: _initials(_authorName(state, message)),
      isTurnHolder: isLast && !assistant,
      agentStatus: assistant ? message.model : null,
    );
  }

  static String _authorName(
    CollaborationState state,
    CollaborationMessage message,
  ) =>
      message.authorName ?? state.nameOf(message.author);

  static String _memberSubtitle(Member member) => switch (member.status) {
    MemberStatus.active => '',
    MemberStatus.left => 'Left',
    MemberStatus.revoked => 'Removed',
  };

  static String _timeLabel(String raw) {
    final at = DateTime.tryParse(raw);
    if (at == null) return '';
    final local = at.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String? _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty || words.first.isEmpty) return null;
    if (words.length == 1) {
      return words.first.characters.take(1).toString().toUpperCase();
    }
    final first = words.first.characters.take(1).toString();
    final second = words[1].characters.take(1).toString();
    return '$first$second'.toUpperCase();
  }
}
