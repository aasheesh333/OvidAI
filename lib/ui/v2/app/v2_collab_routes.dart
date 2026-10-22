import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/collaboration/models.dart';
import '../../../core/collaboration/production.dart';
import '../../../core/collaboration/reducer.dart';
import '../../../core/state.dart';
import '../collab/collab_live_page.dart';
import '../collab/collab_members_page.dart';

/// Routes for the live-collaboration surfaces.
///
/// The collaboration projection is the only source: when this account has no
/// live session the screens open in their empty state. Member counts, turns
/// and messages come from that projection, never from a placeholder.
class V2CollabRoutes {
  const V2CollabRoutes._();

  static Future<void> openLive(BuildContext context, String sessionId) async {
    final controller = AppState.I.collaboration;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _LiveCollabRoute(controller: controller, sessionId: sessionId),
      ),
    );
  }

  static Future<void> openMembers(
    BuildContext context,
    String sessionId,
  ) async {
    final controller = AppState.I.collaboration;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            _CollabMembersRoute(controller: controller, sessionId: sessionId),
      ),
    );
  }

  /// The live projection for [sessionId], or null when there is none.
  @visibleForTesting
  static CollaborationState? collaborationStateFor(String sessionId) =>
      stateFor(AppState.I.collaboration, sessionId);

  /// The controller's projection for [sessionId], or null when it belongs to
  /// another live session.
  @visibleForTesting
  static CollaborationState? stateFor(
    CollaborationProduction? controller,
    String sessionId,
  ) {
    final state = controller?.state;
    if (state == null) return null;
    if (sessionId.isEmpty) return state;
    return state.session.sessionId == sessionId ? state : null;
  }

  /// Maps a live projection onto the shared live-chat screen.
  ///
  /// [connection] is the real transport state (see [connectionFor]); the
  /// screen locks the composer when it is not connected. The projection never
  /// infers connection from the last frame.
  @visibleForTesting
  static V2CollabLivePageData liveDataFor(
    CollaborationState? state, {
    V2CollabLiveConnection connection = V2CollabLiveConnection.connected,
  }) {
    if (state == null) {
      return V2CollabLivePageData(
        totalMembers: 0,
        turnHolderName: '',
        turnTimeLeftLabel: '',
        creatorPaysStorage: false,
        status: V2CollabLiveStatus.empty,
        connection: connection,
      );
    }

    final active = state.activeMembers;
    final last = state.messages.isEmpty ? null : state.messages.last;
    final ended = state.status == CollaborationStatus.closed;
    final localName = state.names[state.localParticipantId] ?? '';
    final chatTitle = _chatTitle(state);
    final holderId = turnHolderId(state);
    final holderName = holderId == null ? '' : state.nameOf(holderId);
    // Turn timing is only ever the server's. A closed room keeps no countdown.
    final turn = ended ? null : state.session.turn;

    return V2CollabLivePageData(
      title: chatTitle.isEmpty ? 'Team chat' : chatTitle,
      subtitle: active.length == 1
          ? '1 member · up to $maxActiveMembers'
          : '${active.length} members · up to $maxActiveMembers',
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
      turnHolderName: holderName,
      turnTimeLeftLabel: '',
      queueLabel: null,
      messages: [
        for (final message in state.messages)
          _messageFor(
            state,
            message,
            isTurnHolder:
                holderId != null &&
                message.clientEventId == last?.clientEventId &&
                !message.isAssistant,
          ),
      ],
      // The collaboration contract makes the creator's plan pay for the room.
      creatorPaysStorage: true,
      capacity: maxActiveMembers,
      // A free turn is this device's turn; a held turn belongs to its author.
      // A closed room takes no turns.
      isMyTurn: !ended && (holderId == null || holderId == state.localParticipantId),
      status: ended ? V2CollabLiveStatus.ended : V2CollabLiveStatus.ready,
      errorMessage: 'We could not load this live chat.',
      endedMessage: state.closeReason == CloseReason.localRemoved
          ? 'You were removed from this live chat.'
          : 'This live chat has ended.',
      connection: connection,
      turnStartedAt: turn?.startedAt,
      turnDuration: turn?.duration ?? const Duration(seconds: 90),
    );
  }

  /// Maps the controller's real transport state to the screen's connection
  /// enum. A projection that exists is connected until the coordinator reports
  /// it stale; before the first projection the room is still connecting.
  ///
  /// A missing controller or an unavailable account has no live socket, so the
  /// empty room stays neutral instead of claiming a dropped connection.
  @visibleForTesting
  static V2CollabLiveConnection connectionFor(
    CollaborationProduction? controller,
  ) {
    if (controller == null || !controller.available) {
      return V2CollabLiveConnection.connected;
    }
    if (controller.state == null) return V2CollabLiveConnection.connecting;
    return controller.stale
        ? V2CollabLiveConnection.disconnected
        : V2CollabLiveConnection.connected;
  }

  /// True when the room already holds [maxActiveMembers] active members. The
  /// route refuses to mint another invite at the cap; the screen disables the
  /// control for the same reason, and the server rejects the join.
  @visibleForTesting
  static bool atCapacity(CollaborationState? state) =>
      state != null && state.activeMembers.length >= maxActiveMembers;

  /// The participant who currently holds the single-sender turn, or null when
  /// the turn is free.
  ///
  /// A server-published lease is authoritative. Otherwise a running/queued
  /// model status is the strongest signal. Failing both, the author of the
  /// last unanswered message holds the turn until an assistant reply lands.
  @visibleForTesting
  static String? turnHolderId(CollaborationState state) {
    final leaseHolder = state.session.turn?.participantId;
    if (leaseHolder != null) return leaseHolder;
    for (final entry in state.modelStates.entries) {
      if (entry.value.status == ModelExecutionStatus.running ||
          entry.value.status == ModelExecutionStatus.queued) {
        return entry.key;
      }
    }
    if (state.messages.isEmpty) return null;
    final last = state.messages.last;
    if (last.isAssistant) return null;
    return last.author;
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
    final local = state.localParticipantId;
    final isOwner = local == state.session.ownerParticipantId;

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
            isYou: member.participantId == local,
            isCreator: member.participantId == state.session.ownerParticipantId,
            canRemove:
                isOwner &&
                member.participantId != local &&
                member.status == MemberStatus.active,
            online:
                state.presence[member.participantId] == PresenceState.online,
            initials: _initials(state.nameOf(member.participantId)),
          ),
      ],
      memberCount: active.length,
      capacity: maxActiveMembers,
      creatorName: owner == null ? '' : state.nameOf(owner.participantId),
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
  // Actions
  // ---------------------------------------------------------------------------

  /// The real send path. It throws a user-facing reason (a String) so the
  /// screen keeps the draft and shows the failure inline instead of dropping
  /// it into a toast. It never reports success it did not get.
  static Future<void> _send(
    CollaborationProduction controller,
    CollaborationState state,
    String text,
  ) async {
    final holder = turnHolderId(state);
    // The screen releases an expired server turn locally; the send path uses
    // the same rule instead of refusing after the deadline has passed.
    final lease = state.session.turn;
    final released = lease != null && lease.isExpiredAt(DateTime.now());
    if (!released &&
        holder != null &&
        holder != state.localParticipantId) {
      throw 'Wait for ${state.nameOf(holder)} to finish the turn.';
    }
    final model = _defaultModel();
    if (model == null) {
      throw 'Add a key or sign in to reply.';
    }
    try {
      await controller.sendTurn(
        text,
        providerId: model.$1,
        model: model.$2,
        modelLabel: model.$2,
      );
    } catch (error) {
      throw collaborationErrorMessage(error);
    }
  }

  /// This device's own provider/model pair, never another participant's.
  static (String, String)? _defaultModel() {
    final app = AppState.I;
    final usable = [
      for (final provider in app.providers)
        if (provider.hasKey || !provider.requiresApiKey) provider,
    ];
    for (final provider in usable) {
      for (final model in provider.models) {
        if (model.trim().isEmpty) continue;
        if (provider.id == app.lastSelectedProviderId &&
            model == app.lastSelectedModel) {
          return (provider.id, model);
        }
      }
    }
    for (final provider in usable) {
      for (final model in provider.models) {
        if (model.trim().isNotEmpty) return (provider.id, model);
      }
    }
    return null;
  }

  static Future<void> _invite(
    BuildContext context,
    CollaborationProduction controller,
  ) async {
    if (!controller.isOwner) {
      _snack(context, 'Only the creator can invite.');
      return;
    }
    // The route enforces the same hard cap as the roster and the server: a
    // full room cannot mint another invite link.
    if (atCapacity(controller.state)) {
      _snack(
        context,
        'This room is full ($maxActiveMembers of $maxActiveMembers).',
      );
      return;
    }
    try {
      await controller.newLink();
      final link = controller.shareLink;
      if (link == null) {
        if (context.mounted) {
          _snack(context, 'We could not create an invite link.');
        }
        return;
      }
      await Clipboard.setData(ClipboardData(text: link));
      if (context.mounted) {
        _snack(context, 'Invite link copied.');
      }
    } catch (error) {
      if (context.mounted) _snack(context, collaborationErrorMessage(error));
    }
  }

  static Future<void> _leave(
    BuildContext context,
    CollaborationProduction controller,
  ) async {
    final owner = controller.isOwner;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(owner ? 'End this live chat?' : 'Leave this live chat?'),
        content: Text(
          owner
              ? 'Everyone is disconnected and the link stops working.'
              : 'You can rejoin later with a valid link. The creator keeps '
                    'the storage.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(owner ? 'End chat' : 'Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.leaveOrClose();
      if (context.mounted) Navigator.of(context).maybePop();
    } catch (error) {
      if (context.mounted) _snack(context, collaborationErrorMessage(error));
    }
  }

  static Future<void> _memberMenu(
    BuildContext context,
    CollaborationProduction controller,
    V2CollabMember member,
  ) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                member.name,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('Remove from this room'),
              onTap: () => Navigator.pop(sheetContext, true),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (remove != true || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${member.name}?'),
        content: const Text(
          'They leave the room and cannot rejoin with the current link.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.revokeMember(member.id);
      if (context.mounted) _snack(context, '${member.name} was removed.');
    } catch (error) {
      if (context.mounted) _snack(context, collaborationErrorMessage(error));
    }
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  static String _chatTitle(CollaborationState state) =>
      AppState.I.sessionById(state.session.sessionId)?.title ?? '';

  static V2CollabMessage _messageFor(
    CollaborationState state,
    CollaborationMessage message, {
    required bool isTurnHolder,
  }) {
    final assistant = message.isAssistant;
    return V2CollabMessage(
      id: message.clientEventId,
      speakerName: assistant
          ? (message.model ?? state.nameOf(message.author))
          : _authorName(state, message),
      timeLabel: _timeLabel(message.createdAt),
      text: message.text,
      kind: assistant ? V2CollabMessageKind.agent : V2CollabMessageKind.person,
      initials: _initials(_authorName(state, message)),
      isTurnHolder: isTurnHolder,
      agentStatus: assistant ? message.model : null,
    );
  }

  static String _authorName(
    CollaborationState state,
    CollaborationMessage message,
  ) => message.authorName ?? state.nameOf(message.author);

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

/// Live chat route: rebuilds from the controller so new messages, presence and
/// turns appear without reopening the screen.
class _LiveCollabRoute extends StatefulWidget {
  const _LiveCollabRoute({required this.controller, required this.sessionId});

  final CollaborationProduction? controller;
  final String sessionId;

  @override
  State<_LiveCollabRoute> createState() => _LiveCollabRouteState();
}

class _LiveCollabRouteState extends State<_LiveCollabRoute> {
  @override
  void initState() {
    super.initState();
    final controller = widget.controller;
    if (controller != null) {
      controller.live = true;
      controller.refresh();
    }
  }

  @override
  void dispose() {
    widget.controller?.live = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return CollabLivePage(data: V2CollabRoutes.liveDataFor(null));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = V2CollabRoutes.stateFor(controller, widget.sessionId);
        return CollabLivePage(
          data: V2CollabRoutes.liveDataFor(
            state,
            connection: V2CollabRoutes.connectionFor(controller),
          ),
          onOpenMembers: () =>
              V2CollabRoutes.openMembers(context, widget.sessionId),
          // No server turn-queue endpoint exists, so no request control is
          // drawn. A handler that silently did nothing would be a dead button.
          onRequestTurnAsync: null,
          onSendAsync: state == null
              ? null
              : (text) => V2CollabRoutes._send(controller, state, text),
          // The deadline is the server's; when it passes, re-read the room so
          // the host's projection can catch up.
          onTurnExpired: controller.refresh,
          onRetry: controller.refresh,
        );
      },
    );
  }
}

/// Member route: the roster and its owner actions track the live projection.
class _CollabMembersRoute extends StatefulWidget {
  const _CollabMembersRoute({
    required this.controller,
    required this.sessionId,
  });

  final CollaborationProduction? controller;
  final String sessionId;

  @override
  State<_CollabMembersRoute> createState() => _CollabMembersRouteState();
}

class _CollabMembersRouteState extends State<_CollabMembersRoute> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller == null) {
      return CollabMembersPage(data: V2CollabRoutes.membersDataFor(null));
    }
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = V2CollabRoutes.stateFor(controller, widget.sessionId);
        // The wire model carries owner/participant only and exposes no role
        // change operation, so `onRoleChanged` stays null and the screen hides
        // the control instead of offering a change that could not persist.
        return CollabMembersPage(
          data: V2CollabRoutes.membersDataFor(state),
          onInvite: controller.available
              ? () => V2CollabRoutes._invite(context, controller)
              : null,
          onLeave: () => V2CollabRoutes._leave(context, controller),
          onMemberMenu: (member) =>
              V2CollabRoutes._memberMenu(context, controller, member),
          onRetry: controller.refresh,
        );
      },
    );
  }
}
