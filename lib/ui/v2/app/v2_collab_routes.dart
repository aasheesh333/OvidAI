import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/collaboration/models.dart';
import '../../../core/collaboration/production.dart';
import '../../../core/collaboration/reducer.dart';
import '../../../core/state.dart';
import '../collab/collab_live_page.dart';
import '../collab/collab_members_page.dart';
import '../../collab_attachment_picker.dart';
import '../../collab_report_sheet.dart';

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
    List<String> pendingAttachmentNames = const [],
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
    final ended = state.status == CollaborationStatus.closed;
    final localName = state.names[state.localParticipantId] ?? '';
    final chatTitle = _chatTitle(state);
    final holderId = turnHolderId(state);
    final holderName = holderId == null ? '' : state.nameOf(holderId);
    // Turn timing is only ever the server's. A closed room keeps no countdown.
    final turn = ended ? null : state.session.turn;
    final transcript = <({int sequence, V2CollabMessage message})>[
      for (final message in state.messages)
        (sequence: message.sequence, message: _messageFor(state, message)),
      for (final tool in state.tools.values)
        (sequence: tool.sequence, message: _toolFor(tool)),
      for (final artifact in state.artifacts.values)
        (sequence: artifact.sequence, message: _artifactFor(state, artifact)),
    ]..sort((left, right) => left.sequence.compareTo(right.sequence));

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
      messages: [for (final row in transcript) row.message],
      // The collaboration contract makes the creator's plan pay for the room.
      creatorPaysStorage: true,
      capacity: maxActiveMembers,
      // Only an absent server lease admits a new turn. Even this device's own
      // accepted run keeps sending locked until fresh server state releases it.
      isMyTurn: !ended && holderId == null,
      status: ended ? V2CollabLiveStatus.ended : V2CollabLiveStatus.ready,
      errorMessage: 'We could not load this live chat.',
      endedMessage: state.closeReason == CloseReason.localRemoved
          ? 'You were removed from this live chat.'
          : 'This live chat has ended.',
      connection: connection,
      turnStartedAt: turn?.startedAt,
      pendingAttachmentNames: pendingAttachmentNames,
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

  /// The holder of the authoritative full-run lease, or null only when fresh
  /// server state publishes no lease. Replay text/status never infers a turn.
  @visibleForTesting
  static String? turnHolderId(CollaborationState state) =>
      state.session.turn?.holderParticipantId;

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
    String text, {
    List<CollaborationAttachmentInput> attachments = const [],
  }) async {
    final holder = turnHolderId(state);
    if (holder != null) {
      throw holder == state.localParticipantId
          ? 'Your reply is still running. Send when it finishes.'
          : 'Wait for ${state.nameOf(holder)} to finish the turn.';
    }
    final model = _defaultModel();
    if (model == null) {
      throw 'No chat model is available for this account.';
    }
    try {
      await controller.sendTurn(
        text,
        model: model,
        attachments: attachments,
      );
    } catch (error) {
      throw collaborationErrorMessage(error);
    }
  }

  /// Server-populated Ovid Cloud catalog choices for this sender. Local
  /// provider keys, host credentials and other participants' choices are not
  /// consulted or uploaded.
  static String? _defaultModel() {
    final app = AppState.I;
    final provider = app.providerById(AppState.ovidCloudProviderId);
    if (provider == null) return null;
    final models = provider.models.where((model) => model.trim().isNotEmpty);
    if (models.contains(app.lastSelectedModel)) return app.lastSelectedModel;
    return models.isEmpty ? null : models.first;
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
    final action = await showModalBottomSheet<String>(
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
              leading: const Icon(Icons.flag_outlined),
              title: const Text('Report participant'),
              onTap: () => Navigator.pop(sheetContext, 'report'),
            ),
            ListTile(
              leading: const Icon(Icons.block_outlined),
              title: const Text('Block participant'),
              onTap: () => Navigator.pop(sheetContext, 'block'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: const Text('Unblock participant'),
              onTap: () => Navigator.pop(sheetContext, 'unblock'),
            ),
            if (member.canRemove)
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: const Text('Remove from this room'),
                onTap: () => Navigator.pop(sheetContext, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'report') {
      await showCollaborationReportSheet(
        context,
        controller,
        kind: 'collab_participant',
        targetId: member.id,
      );
      return;
    }
    if (action == 'block' || action == 'unblock') {
      try {
        if (action == 'block') {
          await controller.block(member.id);
        } else {
          await controller.unblock(member.id);
        }
        if (context.mounted) {
          _snack(context, '${member.name} ${action == 'block' ? 'blocked' : 'unblocked'}.');
        }
      } catch (error) {
        if (context.mounted) _snack(context, collaborationErrorMessage(error));
      }
      return;
    }
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
    CollaborationMessage message,
  ) {
    final assistant = message.isAssistant;
    return V2CollabMessage(
      id: message.clientEventId,
      authorId: message.author,
      canReport: message.author != state.localParticipantId &&
          collaborationIsCanonicalMessageSource(message.clientEventId),
      canRemove: state.localParticipantId == state.session.ownerParticipantId &&
          collaborationIsCanonicalMessageSource(message.clientEventId),
      speakerName: assistant
          ? (message.model ?? state.nameOf(message.author))
          : _authorName(state, message),
      timeLabel: _timeLabel(message.createdAt),
      text: message.text,
      kind: assistant ? V2CollabMessageKind.agent : V2CollabMessageKind.person,
      initials: _initials(_authorName(state, message)),
      agentStatus: assistant ? message.model : null,
    );
  }

  static V2CollabMessage _toolFor(CollaborationToolState tool) {
    final name = tool.name ?? 'Tool activity';
    return V2CollabMessage(
      id: tool.eventId,
      speakerName: 'Ovid',
      timeLabel: '',
      text: name,
      kind: V2CollabMessageKind.agent,
      toolName: name,
      toolResult: tool.isError == true ? 'Failed' : tool.status.name,
      agentStatus: tool.status.name,
    );
  }

  static V2CollabMessage _artifactFor(
    CollaborationState state,
    CollaborationArtifact artifact,
  ) {
    final name = artifact.name ?? 'Artifact';
    return V2CollabMessage(
      id: artifact.eventId,
      speakerName: artifact.author.isEmpty ? 'Ovid' : state.nameOf(artifact.author),
      timeLabel: '',
      text: name,
      kind: V2CollabMessageKind.agent,
      artifactName: name,
      artifactId: artifact.artifactId,
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
  List<CollaborationAttachmentInput> _attachments = const [];

  Future<void> _attach() async {
    try {
      final picked = await pickCollaborationAttachments();
      if (picked == null || !mounted) return;
      setState(() => _attachments = [..._attachments, ...picked]);
    } catch (error) {
      if (!mounted) return;
      V2CollabRoutes._snack(
        context,
        error is StateError ? error.message : 'Could not read that file.',
      );
    }
  }

  void _removeAttachment(int index) {
    setState(() => _attachments = [
      for (var i = 0; i < _attachments.length; i++)
        if (i != index) _attachments[i],
    ]);
  }

  Future<void> _send(
    CollaborationProduction controller,
    CollaborationState state,
    String text,
  ) async {
    await V2CollabRoutes._send(
      controller,
      state,
      text,
      attachments: _attachments,
    );
    if (mounted) setState(() => _attachments = const []);
  }

  Future<void> _openArtifact(
    CollaborationProduction controller,
    String artifactId,
  ) async {
    try {
      final minted = await controller.objectUrl(artifactId: artifactId);
      final opened = await launchUrl(
        minted.url,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        V2CollabRoutes._snack(context, 'Could not open the artifact.');
      }
    } catch (error) {
      if (mounted) V2CollabRoutes._snack(context, collaborationErrorMessage(error));
    }
  }

  Future<void> _reportMessage(
    CollaborationProduction controller,
    V2CollabMessage message,
  ) =>
      showCollaborationReportSheet(
        context,
        controller,
        kind: 'collab_message',
        targetId: collaborationCanonicalMessageId(message.id),
      );

  Future<void> _removeMessage(
    CollaborationProduction controller,
    V2CollabMessage message,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this message from the room?'),
        content: const Text('The server keeps canonical history for moderation.'),
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
      await controller.removeMessage(collaborationCanonicalMessageId(message.id));
      if (mounted) V2CollabRoutes._snack(context, 'Message removed from the room.');
    } catch (error) {
      if (mounted) V2CollabRoutes._snack(context, collaborationErrorMessage(error));
    }
  }

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
            pendingAttachmentNames: [
              for (final attachment in _attachments) attachment.name,
            ],
          ),
          onOpenMembers: () =>
              V2CollabRoutes.openMembers(context, widget.sessionId),
          // No server turn-queue endpoint exists, so no request control is
          // drawn. A handler that silently did nothing would be a dead button.
          onRequestTurnAsync: null,
          onSendAsync: state == null ? null : (text) => _send(controller, state, text),
          onAttach: state == null ? null : _attach,
          onRemoveAttachment: state == null ? null : _removeAttachment,
          onOpenArtifact: state == null ? null : (id) => _openArtifact(controller, id),
          onReportMessage: state == null
              ? null
              : (message) {
                  if (!collaborationIsCanonicalMessageSource(message.id) ||
                      message.authorId == state.localParticipantId) {
                    return;
                  }
                  _reportMessage(controller, message);
                },
          onRemoveMessage: state == null || !controller.isOwner
              ? null
              : (message) {
                  if (!collaborationIsCanonicalMessageSource(message.id)) return;
                  _removeMessage(controller, message);
                },
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
          onMemberActions: (member) =>
              V2CollabRoutes._memberMenu(context, controller, member),
          onRetry: controller.refresh,
        );
      },
    );
  }
}
