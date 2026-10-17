import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/cloud/agent_surface.dart';
import '../core/cloud/cloud_agent_facade.dart';
import '../core/distribution.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'artifacts_screen.dart';
import 'conversation_share_sheet.dart';
import 'session_actions.dart';
import 'trajectory_screen.dart';
import 'usage_screen.dart';

/// P8 Task 10 — the shared dual-path binding (same pattern as
/// chat_screen/sidebar).
AgentSurface get _agent =>
    Distribution.cloudExecution ? CloudAgentFacade.I : AgentService.I;

/// Items of the chat header's ⋮ menu.
enum ChatMenuAction {
  share,
  newChat,
  jobs,
  rename,
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
List<ChatMenuAction> chatMenuActionsFor(ChatSession? session, int jobCount) {
  final hasChat = session != null && session.messages.isNotEmpty;
  final own = session != null && !session.isSubagent;
  return [
    if (hasChat && own) ChatMenuAction.share,
    if (hasChat) ChatMenuAction.newChat,
    if (jobCount > 0) ChatMenuAction.jobs,
    if (own) ChatMenuAction.rename,
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
      animation: _agent,
      builder: (context, _) {
        final s = session;
        final jobs = s == null ? const [] : _agent.jobsFor(s.id);
        final running = jobs.where((j) => j.state == 'running').length;
        final l10n = context.l10n;
        final actions = chatMenuActionsFor(s, jobs.length);
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
          onSelected: (a) => _run(context, a),
          itemBuilder: (_) => [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0 && _startsGroup(actions[i - 1], actions[i]))
                const PopupMenuDivider(height: 8),
              _item(context, actions[i], jobs.length),
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
    int jobCount,
  ) {
    final l10n = context.l10n;
    final (IconData icon, String label) = switch (a) {
      ChatMenuAction.share => (Icons.ios_share_outlined, l10n.chatMenuShare),
      ChatMenuAction.newChat => (Icons.edit_square, l10n.chatMenuNewChat),
      ChatMenuAction.jobs => (
        Icons.terminal_outlined,
        l10n.chatMenuJobs(jobCount),
      ),
      ChatMenuAction.rename => (Icons.edit_outlined, l10n.chatMenuRename),
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

  void _run(BuildContext context, ChatMenuAction a) {
    final s = session;
    final nav = Navigator.of(context);
    switch (a) {
      case ChatMenuAction.share:
        if (s != null) showConversationShareSheet(context, s);
      case ChatMenuAction.newChat:
        AppState.I.newSession();
      case ChatMenuAction.jobs:
        if (s != null) onJobs(s.id);
      case ChatMenuAction.rename:
        if (s != null) showRenameSessionDialog(context, s);
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
}
