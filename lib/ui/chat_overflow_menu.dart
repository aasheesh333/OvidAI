import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat_integration_ports.dart';
import '../core/chat_pins.dart';
import '../core/cloud/agent_surface.dart';
import '../core/cloud/cloud_agent_facade.dart';
import '../core/cloud/projects.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'artifacts_screen.dart';
import 'conversation_share_sheet.dart';
import 'projects_section.dart';
import 'session_actions.dart';
import 'trajectory_screen.dart';
import 'usage_screen.dart';

/// P8 Task 19 — the cloud facade is the only agent implementation.
AgentSurface get _agent => CloudAgentFacade.I;

/// Items of the chat header's ⋮ menu.
enum ChatMenuAction {
  share,
  newChat,
  jobs,
  rename,
  addToProject,
  pin,
  artifacts,
  trajectory,
  usage,
  delete,
}

/// The items the ⋮ menu shows for [session] with [jobCount] background jobs.
///
/// Share and New chat only make sense once the chat has content, so an empty
/// chat hides them; everything else stays reachable. Subagent sessions are
/// owned by their parent, so share/rename/delete are not offered there.
///
/// A cloud session keeps `ChatSession.messages` empty — its transcript is the
/// facade's live projection — so callers pass that as [transcript] (the chat
/// screen's `_messagesOf` parity); it wins over the session's own rows.
List<ChatMenuAction> chatMenuActionsFor(
  ChatSession? session,
  int jobCount, {
  List<Message>? transcript,
  bool projectsAvailable = false,
}) {
  final messages = transcript ?? session?.messages;
  final hasChat = messages != null && messages.isNotEmpty;
  final own = session != null && !session.isSubagent;
  return [
    if (hasChat && own) ChatMenuAction.share,
    if (hasChat) ChatMenuAction.newChat,
    if (jobCount > 0) ChatMenuAction.jobs,
    if (own) ChatMenuAction.rename,
    if (own && projectsAvailable) ChatMenuAction.addToProject,
    // Pin is always available: W1's port when it owns pinning, otherwise the
    // account-scoped local store (visible in the chat header).
    if (own) ChatMenuAction.pin,
    ChatMenuAction.artifacts,
    if (session != null) ChatMenuAction.trajectory,
    ChatMenuAction.usage,
    if (own) ChatMenuAction.delete,
  ];
}

/// The chat header's ⋮ overflow menu. A small badge on the glyph signals
/// running background jobs (the old header jobs button lives in here now).
class ChatOverflowMenu extends StatelessWidget {
  const ChatOverflowMenu({
    super.key = const ValueKey('chat-header-more'),
    required this.session,
    required this.onJobs,
  });

  final ChatSession? session;

  /// Opens the background-jobs sheet for a session id.
  final void Function(String sessionId) onJobs;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _agent,
        ChatPinsStore.I,
        ProjectsController.I,
        if (ProjectsPort.instance != null) ProjectsPort.instance!,
      ]),
      builder: (context, _) {
        final s = session;
        final jobs = s == null ? const [] : _agent.jobsFor(s.id);
        final running = jobs.where((j) => j.state == 'running').length;
        final l10n = context.l10n;
        // Cloud rows keep session.messages empty — the live projection is
        // the transcript the gating reads.
        final projects = ProjectsPort.instance;
        final projectsAvailable = projects != null && projects.ready;
        // Pin persistence: W1's port when it owns pinning, otherwise the
        // account-scoped local store. The pin is visible in the chat header.
        final pinned = s != null &&
            (projects != null && projects.supportsPin
                ? projects.isPinned(s.id)
                : ChatPinsStore.I.isPinned(s.id));
        final actions = chatMenuActionsFor(
          s,
          jobs.length,
          transcript: s == null ? null : CloudAgentFacade.I.transcriptFor(s.id),
          projectsAvailable: projectsAvailable,
        );
        return PopupMenuButton<ChatMenuAction>(
          tooltip: jobs.isEmpty
              ? l10n.chatMenuMore
              : l10n.chatMenuMoreJobs(jobs.length),
          position: PopupMenuPosition.under,
          color: Aether.surface,
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.more_vert_rounded, size: 21),
              if (jobs.isNotEmpty)
                Positioned(
                  top: -1,
                  right: -1,
                  child: Container(
                    key: const ValueKey('chat-header-jobs-badge'),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: running > 0 ? Aether.accent : Aether.textFaint,
                      shape: BoxShape.circle,
                      border: Border.all(color: Aether.bg, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          onSelected: (a) => unawaited(_run(context, a)),
          itemBuilder: (_) => [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0 && _startsGroup(actions[i - 1], actions[i]))
                const PopupMenuDivider(height: 8),
              _item(context, actions[i], jobs.length, pinned: pinned),
            ],
          ],
        );
      },
    );
  }

  static bool _conversation(ChatMenuAction a) =>
      a == ChatMenuAction.share || a == ChatMenuAction.newChat;

  /// Dividers separate conversation actions · chat tools · delete.
  static bool _startsGroup(ChatMenuAction prev, ChatMenuAction next) =>
      next == ChatMenuAction.delete ||
      (_conversation(prev) && !_conversation(next));

  PopupMenuItem<ChatMenuAction> _item(
    BuildContext context,
    ChatMenuAction a,
    int jobCount, {
    bool pinned = false,
  }) {
    final l10n = context.l10n;
    final (IconData icon, String label) = switch (a) {
      ChatMenuAction.share => (Icons.ios_share_outlined, l10n.chatMenuShare),
      ChatMenuAction.newChat => (Icons.edit_square, l10n.chatMenuNewChat),
      ChatMenuAction.jobs => (
        Icons.terminal_outlined,
        l10n.chatMenuJobs(jobCount),
      ),
      ChatMenuAction.rename => (Icons.edit_outlined, l10n.chatMenuRename),
      ChatMenuAction.addToProject => (
        Icons.drive_file_move_outline,
        'Add to Project',
      ),
      ChatMenuAction.pin => (
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
        pinned ? 'Unpin Session' : 'Pin Session',
      ),
      ChatMenuAction.artifacts => (
        Icons.folder_copy_outlined,
        l10n.artifactsTitle,
      ),
      ChatMenuAction.trajectory => (
        Icons.timeline_outlined,
        l10n.chatMenuTrajectory,
      ),
      ChatMenuAction.usage => (Icons.insights_outlined, l10n.chatMenuUsage),
      ChatMenuAction.delete => (Icons.delete_outline, l10n.chatMenuDelete),
    };
    final danger = a == ChatMenuAction.delete;
    final color = danger ? Aether.danger : Aether.text;
    return PopupMenuItem<ChatMenuAction>(
      key: ValueKey('chat-menu-${a.name}'),
      value: a,
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: danger ? Aether.danger : Aether.textMuted,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _run(BuildContext context, ChatMenuAction a) async {
    final s = session;
    final nav = Navigator.of(context);
    switch (a) {
      case ChatMenuAction.share:
        if (s != null) {
          showConversationShareSheet(
            context,
            s,
            // Cloud rows keep session.messages empty — share the projection.
            messages: CloudAgentFacade.I.transcriptFor(s.id),
          );
        }
      case ChatMenuAction.newChat:
        AppState.I.newSession();
      case ChatMenuAction.jobs:
        if (s != null) onJobs(s.id);
      case ChatMenuAction.rename:
        if (s != null) showRenameSessionDialog(context, s);
      case ChatMenuAction.addToProject:
        if (s != null) await _showAddToProjectSheet(context, s);
      case ChatMenuAction.pin:
        if (s != null) {
          final port = ProjectsPort.instance;
          final next = !(port != null && port.supportsPin
              ? port.isPinned(s.id)
              : ChatPinsStore.I.isPinned(s.id));
          try {
            if (port != null && port.supportsPin) {
              await port.setPinned(s.id, next);
            } else {
              await ChatPinsStore.I.setPinned(s.id, next);
            }
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(next ? context.l10n.sessionPinned : context.l10n.sessionUnpinned),
                behavior: SnackBarBehavior.floating,
              ),
            );
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(context.l10n.pinUpdateFailed),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      case ChatMenuAction.artifacts:
        nav.push(
          MaterialPageRoute<void>(
            builder: (_) => ArtifactsScreen(sessionId: s?.id),
          ),
        );
      case ChatMenuAction.trajectory:
        if (s != null) {
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => TrajectoryScreen(sessionId: s.id),
            ),
          );
        }
      case ChatMenuAction.usage:
        nav.push(MaterialPageRoute<void>(builder: (_) => const UsageScreen()));
      case ChatMenuAction.delete:
        if (s != null) confirmAndDeleteSession(context, s);
    }
  }

  /// W1's "Add to Project" picker, then [ProjectsController.moveSession]
  /// (null projectId = "No project"). The controller updates the session's
  /// `projectId` and the sidebar regroups before the next reconciliation.
  Future<void> _showAddToProjectSheet(
    BuildContext context,
    ChatSession session,
  ) async {
    final controller = ProjectsController.I;
    if (!controller.loadedOnce) {
      unawaited(controller.refresh());
    }
    final picked = await showAddToProjectSheet(
      context,
      sessionTitle: session.title,
      projects: controller.projects,
      currentProjectId: session.projectId,
    );
    if (picked == null) return;
    final ok = await controller.moveSession(session.id, picked.projectId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (picked.projectId == null
                    ? context.l10n.removedFromProject
                    : context.l10n.addedToProject)
              : context.l10n.moveChatFailed,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
