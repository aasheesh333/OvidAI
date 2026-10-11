import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/grant_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Settings → Permissions.
///
/// A premium-styled surface over the strict permission model:
///
/// * **Autonomy** — the policy the agent runs under. Today the only state
///   backing autonomy is the legacy "all-sessions" grant list, which is
///   intentionally **ignored** at runtime. The section still renders so the
///   user can see and clean up those stale entries. Nothing here mutates
///   runtime policy.
/// * **Granted scopes** — every remembered decision in EVERY chat, grouped
///   by chat title (F-110): file and website allow/deny grants (persisted
///   per chat) and tool-level "Always allow" approvals and remembered
///   denials (in memory, F-109). Each chat has Open chat and Revoke all;
///   the section has a global Revoke all.
/// * **Pending requests** — reserved for interactive approval prompts routed
///   through the main overlay. The permissions screen is a passive viewer of
///   the current state and does not host active prompts, so this section
///   explains that explicitly and is empty by design.
///
/// Session grants come from each [ChatSession.grants], tool decisions from
/// [AgentService.alwaysAllowedToolsFor] / [AgentService.rememberedDenialsFor],
/// legacy all-sessions grants from [AppState.globalPermissionGrants]; every
/// revoke routes through the owner methods on [AgentService] and
/// [AppState.revokeGlobalPermissionGrant]. No new state is introduced.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        title: const Text('Permissions'),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([AppState.I, AgentService.I]),
        builder: (context, _) {
          final legacy = AppState.I.globalPermissionGrants;
          final groups = _decisionGroups();
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AetherSectionTitle(
                  eyebrow: 'Autonomy',
                  subtitle:
                      'How much the agent may decide on its own. Legacy '
                      'all-sessions grants from older builds are listed as '
                      'inert and can be removed; the agent never consults '
                      'them at runtime.',
                ),
                const SizedBox(height: 12),
                _AutonomyCard(
                  legacy: legacy,
                  onRevoke: (g) => _revokeGlobal(context, g),
                ),
                const SizedBox(height: 24),
                const AetherSectionTitle(
                  eyebrow: 'Granted scopes',
                  subtitle:
                      'Decisions you made in each chat. File and website '
                      'decisions persist across restarts until the chat is '
                      'deleted; tool decisions last until the app closes.',
                ),
                const SizedBox(height: 12),
                if (groups.isEmpty)
                  const _NoDecisionsCard()
                else ...[
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const ValueKey('revoke-all-decisions'),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Revoke all'),
                      onPressed: () => _revokeEverything(context),
                    ),
                  ),
                  for (final group in groups)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ChatDecisionsCard(
                        group: group,
                        onOpenChat: () => _openChat(context, group.session),
                        onRevokeAll: () => _revokeChat(context, group.session),
                        onRevokeGrant: (g) =>
                            _revokeSession(context, group.session, g),
                        onRevokeTool: (tool) =>
                            _revokeTool(context, group.session, tool),
                        onRevokeDenial: (d) =>
                            _revokeDenial(context, group.session, d),
                      ),
                    ),
                ],
                const SizedBox(height: 24),
                const AetherSectionTitle(
                  eyebrow: 'Pending requests',
                  subtitle:
                      'Interactive approval prompts appear in the chat '
                      'overlay as the agent runs. This panel shows no live '
                      'requests on its own.',
                ),
                const SizedBox(height: 12),
                const _PendingRequestsCard(),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _revokeGlobal(
    BuildContext context,
    PermissionGrant grant,
  ) async {
    final siblings = AppState.I.globalPermissionGrants
        .where((g) => g.kind == grant.kind && g.value == grant.value)
        .toList();
    if (!_isSingleGrantIdentity(siblings, grant)) {
      _showRevokeMessage(
        context,
        'Not revoked: another saved decision has the same scope. This screen cannot safely remove only the selected identity.',
      );
      return;
    }

    final ok = await AppState.I.revokeGlobalPermissionGrant(
      grant.kind,
      grant.value,
    );
    if (!context.mounted) return;
    final remaining = AppState.I.globalPermissionGrants.any(
      (g) => _sameGrantIdentity(g, grant),
    );
    _showRevokeMessage(
      context,
      ok && !remaining
          ? 'Removed from current settings: ${_label(grant)}. Persistence is not confirmed; retry if it returns after reopening.'
          : 'No durable change confirmed for ${_label(grant)}. Retry.',
      retry: () => _revokeGlobal(context, grant),
    );
    if (mounted) setState(() {});
  }

  Future<void> _revokeSession(
    BuildContext context,
    ChatSession session,
    PermissionGrant grant,
  ) async {
    // Each row is bound to ITS chat; a confirmation left open while the
    // chat is deleted or the decision changes must not touch another one.
    final live = AppState.I.sessions.any((s) => identical(s, session));
    if (!live ||
        !_isSingleGrantIdentity(
          session.grants
              .where((g) => g.kind == grant.kind && g.value == grant.value)
              .toList(),
          grant,
        )) {
      _showRevokeMessage(
        context,
        'This decision is no longer saved in "${_chatTitle(session)}".',
      );
      return;
    }
    await AgentService.I.revokeSessionPermissionGrant(grant, session: session);
    if (!context.mounted) return;
    final remaining = session.grants.any((g) => _sameGrantIdentity(g, grant));
    _showRevokeMessage(
      context,
      !remaining
          ? 'Removed from "${_chatTitle(session)}": ${_label(grant)}. Persistence is not confirmed; retry if it returns after reopening.'
          : 'No durable change confirmed for ${_label(grant)}. Retry.',
      retry: () => _revokeSession(context, session, grant),
    );
    if (mounted) setState(() {});
  }

  Future<void> _revokeTool(
    BuildContext context,
    ChatSession session,
    String tool,
  ) async {
    if (!await _confirm(
      context,
      title: 'Stop always allowing $tool?',
      body:
          'The agent will ask before using $tool again in '
          '"${_chatTitle(session)}".',
    )) {
      return;
    }
    final removed = AgentService.I.revokeAlwaysAllowedTool(session.id, tool);
    if (!context.mounted) return;
    _showRevokeMessage(
      context,
      removed
          ? '$tool will ask again in "${_chatTitle(session)}".'
          : 'This decision is no longer remembered.',
    );
  }

  Future<void> _revokeDenial(
    BuildContext context,
    ChatSession session,
    RememberedToolDenial denial,
  ) async {
    final removed = AgentService.I.revokeRememberedDenial(session.id, denial);
    if (!context.mounted) return;
    _showRevokeMessage(
      context,
      removed
          ? '${denial.tool} will ask again in "${_chatTitle(session)}".'
          : 'This decision is no longer remembered.',
    );
  }

  Future<void> _revokeChat(BuildContext context, ChatSession session) async {
    if (!await _confirm(
      context,
      title: 'Revoke all decisions in this chat?',
      body:
          'Removes every remembered file, website and tool decision in '
          '"${_chatTitle(session)}". The agent will ask again.',
    )) {
      return;
    }
    await AgentService.I.revokeAllSessionDecisions(session);
    if (!context.mounted) return;
    _showRevokeMessage(
      context,
      'Removed all remembered decisions in "${_chatTitle(session)}".',
    );
  }

  Future<void> _revokeEverything(BuildContext context) async {
    if (!await _confirm(
      context,
      title: 'Revoke all remembered decisions?',
      body:
          'Removes every remembered file, website and tool decision in '
          'every chat. The agent will ask again.',
    )) {
      return;
    }
    await AgentService.I.revokeAllRememberedDecisions();
    if (!context.mounted) return;
    _showRevokeMessage(context, 'Removed all remembered decisions.');
  }

  void _openChat(BuildContext context, ChatSession session) {
    AppState.I.selectSession(session.id);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        scrollable: true,
        backgroundColor: Aether.surface,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: Text(body, style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(d).pop(false),
          ),
          TextButton(
            child: const Text('Revoke'),
            onPressed: () => Navigator.of(d).pop(true),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _showRevokeMessage(
    BuildContext context,
    String message, {
    VoidCallback? retry,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: retry == null
            ? null
            : SnackBarAction(label: 'Retry', onPressed: retry),
      ),
    );
  }
}

/// Everything one chat remembers, for the Granted scopes section.
class _ChatDecisions {
  const _ChatDecisions({
    required this.session,
    required this.isCurrent,
    required this.grants,
    required this.tools,
    required this.denials,
  });

  final ChatSession session;
  final bool isCurrent;
  final List<PermissionGrant> grants;
  final List<String> tools;
  final List<RememberedToolDenial> denials;
}

/// Remembered decisions of EVERY chat (F-110), current chat first, then in
/// the session list's order; chats with nothing remembered are omitted.
List<_ChatDecisions> _decisionGroups() {
  final current =
      AgentService.I.currentSession ?? AppState.I.activeSession;
  final out = <_ChatDecisions>[];
  for (final session in AppState.I.sessions) {
    final grants = session.grants
        .where(
          (g) =>
              g.scope == PermissionGrant.scopeSession &&
              g.sessionId == session.id,
        )
        .toList();
    final tools = AgentService.I.alwaysAllowedToolsFor(session.id).toList()
      ..sort();
    final denials = AgentService.I.rememberedDenialsFor(session.id);
    if (grants.isEmpty && tools.isEmpty && denials.isEmpty) continue;
    out.add(
      _ChatDecisions(
        session: session,
        isCurrent: current != null && current.id == session.id,
        grants: grants,
        tools: tools,
        denials: denials,
      ),
    );
  }
  out.sort((a, b) => (b.isCurrent ? 1 : 0) - (a.isCurrent ? 1 : 0));
  return out;
}

String _chatTitle(ChatSession s) =>
    s.title.trim().isEmpty ? 'Untitled chat' : s.title.trim();

bool _isSingleGrantIdentity(
  List<PermissionGrant> candidates,
  PermissionGrant selected,
) =>
    candidates.length == 1 &&
    candidates.every((g) => _sameGrantIdentity(g, selected));

bool _sameGrantIdentity(PermissionGrant a, PermissionGrant b) =>
    a.kind == b.kind &&
    a.value == b.value &&
    a.scope == b.scope &&
    a.sessionId == b.sessionId &&
    a.mode == b.mode &&
    a.decision == b.decision &&
    a.recursive == b.recursive &&
    a.grantedAt == b.grantedAt;

/// Autonomy card. Explains session scope and, if any, renders
/// a per-row list of legacy all-sessions grants with a revoke affordance.
class _AutonomyCard extends StatelessWidget {
  const _AutonomyCard({required this.legacy, required this.onRevoke});

  final List<PermissionGrant> legacy;
  final Future<void> Function(PermissionGrant) onRevoke;

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Agent autonomy', style: AetherType.title),
          const SizedBox(height: 8),
          Wrap(
            children: [
              _PermissionScopeBadge(
                label: 'SESSION ONLY',
                color: Aether.accentC,
                icon: Icons.shield_outlined,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'In workspace-confined modes, the agent asks before accessing '
            'paths outside its workspace or hosts outside the allowlist, '
            'unless a session decision already applies. Full Access mode has '
            'different access rules. Remembered decisions belong only to '
            'the owning session; mode-specific restrictions still apply.',
            style: AetherType.bodyMuted,
          ),
          const SizedBox(height: 16),
          _AutonomyMode(
            label: 'Workspace boundaries',
            description:
                'Workspace-confined modes enforce path boundaries and a '
                'network allowlist, with session decisions for extra access.',
            active: true,
          ),
          const SizedBox(height: 8),
          _AutonomyMode(
            label: 'Session decisions',
            description:
                'Remembered Allow, Always allow, and Deny decisions apply to '
                'this conversation only.',
            active: true,
          ),
          const SizedBox(height: 8),
          _AutonomyMode(
            label: 'All sessions (ignored)',
            description:
                'Older builds could grant globally. These grants are no '
                'longer consulted and only appear below so they can be '
                'cleared.',
            active: false,
          ),
          if (legacy.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(height: 1, thickness: 1, color: Aether.hairline),
            const SizedBox(height: 12),
            Text(
              'Legacy all-sessions grants',
              style: AetherType.label.copyWith(color: Aether.textMuted),
            ),
            const SizedBox(height: 8),
            for (final g in legacy)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _GrantRow(
                  grant: g,
                  global: true,
                  onRevoke: () => onRevoke(g),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Wrapping a badge does not constrain its label; the inner text must flex.
class _PermissionScopeBadge extends StatelessWidget {
  const _PermissionScopeBadge({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutonomyMode extends StatelessWidget {
  const _AutonomyMode({
    required this.label,
    required this.description,
    required this.active,
  });

  final String label;
  final String description;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = active ? Aether.accentC : Aether.textFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: active ? Aether.accent.withValues(alpha: 0.06) : Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(
          color: active ? Aether.accent.withValues(alpha: 0.4) : Aether.hairline,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            active ? Icons.info_outline : Icons.history,
            size: 16,
            color: c,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(description, style: AetherType.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state: no chat remembers any decision.
class _NoDecisionsCard extends StatelessWidget {
  const _NoDecisionsCard();

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, size: 20, color: Aether.textFaint),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No remembered decisions in any chat yet. File, website and '
              'tool access appear here after Allow, Always allow, or Deny.',
              style: AetherType.bodyMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// One chat's remembered decisions: grants with full scope descriptions,
/// always-allowed tools and remembered denials, each revocable, plus Open
/// chat and Revoke all for the chat.
class _ChatDecisionsCard extends StatelessWidget {
  const _ChatDecisionsCard({
    required this.group,
    required this.onOpenChat,
    required this.onRevokeAll,
    required this.onRevokeGrant,
    required this.onRevokeTool,
    required this.onRevokeDenial,
  });

  final _ChatDecisions group;
  final VoidCallback onOpenChat;
  final Future<void> Function() onRevokeAll;
  final Future<void> Function(PermissionGrant) onRevokeGrant;
  final Future<void> Function(String tool) onRevokeTool;
  final Future<void> Function(RememberedToolDenial) onRevokeDenial;

  @override
  Widget build(BuildContext context) {
    final sid = group.session.id;
    final count = group.grants.length + group.tools.length + group.denials.length;
    return AetherCard(
      key: ValueKey('chat-decisions-$sid'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _chatTitle(group.session),
            style: AetherType.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            '$count decision${count == 1 ? '' : 's'}'
            '${group.isCurrent ? ' · current chat' : ''}',
            style: AetherType.caption,
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                key: ValueKey('open-chat-$sid'),
                icon: const Icon(Icons.chat_bubble_outline, size: 18),
                label: const Text('Open chat'),
                onPressed: onOpenChat,
              ),
              TextButton.icon(
                key: ValueKey('revoke-chat-$sid'),
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Revoke all'),
                onPressed: onRevokeAll,
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final g in group.grants)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _GrantRow(
                grant: g,
                global: false,
                onRevoke: () => onRevokeGrant(g),
              ),
            ),
          if (group.tools.isNotEmpty || group.denials.isNotEmpty) ...[
            Text(
              'Tools in this chat',
              style: AetherType.label.copyWith(color: Aether.textMuted),
            ),
            const SizedBox(height: 6),
            for (final tool in group.tools)
              _ToolDecisionRow(
                key: ValueKey('tool-allowed-$sid-$tool'),
                title: tool,
                subtitle: 'Always allowed · until the app closes',
                denied: false,
                revokeKey: ValueKey('revoke-tool-$sid-$tool'),
                revokeTooltip: 'Stop always allowing $tool',
                onRevoke: () => onRevokeTool(tool),
              ),
            for (final d in group.denials)
              _ToolDecisionRow(
                key: ValueKey('tool-denied-$sid-${d.key}'),
                title: d.tool,
                subtitle: [
                  'Denied',
                  if (d.summary.isNotEmpty) d.summary,
                ].join(' · '),
                denied: true,
                revokeKey: ValueKey('revoke-denial-$sid-${d.key}'),
                revokeTooltip: 'Forget denial of ${d.tool}',
                onRevoke: () => onRevokeDenial(d),
              ),
          ],
        ],
      ),
    );
  }
}

/// One tool-level remembered decision with a revoke button.
class _ToolDecisionRow extends StatelessWidget {
  const _ToolDecisionRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.denied,
    required this.revokeKey,
    required this.revokeTooltip,
    required this.onRevoke,
  });

  final String title;
  final String subtitle;
  final bool denied;
  final Key revokeKey;
  final String revokeTooltip;
  final Future<void> Function() onRevoke;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        decoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(AetherRadius.rMd),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(
          children: [
            Icon(
              denied ? Icons.block_outlined : Icons.build_outlined,
              size: 18,
              color: denied ? Aether.dangerC : Aether.accentC,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    subtitle,
                    style: AetherType.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              key: revokeKey,
              tooltip: revokeTooltip,
              icon: const Icon(Icons.close, size: 18),
              onPressed: onRevoke,
            ),
          ],
        ),
      ),
    );
  }
}

/// Readable scope details with an explicit, confirmed revoke action.
class _GrantRow extends StatelessWidget {
  const _GrantRow({
    required this.grant,
    required this.global,
    required this.onRevoke,
  });

  final PermissionGrant grant;
  final bool global;
  final Future<void> Function() onRevoke;

  @override
  Widget build(BuildContext context) {
    final isPath = grant.kind == PermissionGrant.kindPath;
    final icon = isPath
        ? (grant.recursive ? Icons.folder_outlined : Icons.description_outlined)
        : Icons.public_outlined;
    final subtitle =
        '${isPath ? (grant.recursive ? 'Directory and descendants' : 'Exact path') : 'Host and subdomains, all ports and paths'} · '
        '${grant.isDeny ? 'denied' : 'allowed'} · '
        '${global ? 'legacy (not applied)' : 'this chat, all modes'}';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: grant.isDeny ? Aether.dangerC : Aether.accentC,
          ),
          const SizedBox(height: 8),
          Text(
            _label(grant),
            style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: AetherType.caption),
          Tooltip(
            message: 'Revoke',
            child: TextButton.icon(
              key: ValueKey(
                global
                    ? 'revoke-global-${grant.kind}-${grant.value}'
                    : 'revoke-session-${grant.sessionId}-${grant.kind}-${grant.value}',
              ),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Revoke'),
              onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (d) => AlertDialog(
                  scrollable: true,
                  backgroundColor: Aether.surface,
                  title: const Text(
                    'Revoke grant?',
                    style: TextStyle(fontSize: 15),
                  ),
                  content: Text(
                    global
                        ? 'Remove the legacy entry for ${_label(grant)}? It is already ignored at runtime.'
                        : 'Remove the saved decision for ${_label(grant)}? Future access follows the current mode and any remaining session decisions.',
                    style: const TextStyle(fontSize: 13),
                  ),
                  actions: [
                    TextButton(
                      child: const Text('Cancel'),
                      onPressed: () => Navigator.of(d).pop(false),
                    ),
                    TextButton(
                      child: const Text('Revoke'),
                      onPressed: () => Navigator.of(d).pop(true),
                    ),
                  ],
                ),
              );
              if (confirm == true) await onRevoke();
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Pending-requests card. The permissions screen is a passive viewer of
/// persisted state. There is no pending-request feed backing this panel.
class _PendingRequestsCard extends StatelessWidget {
  const _PendingRequestsCard();

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Approval prompts appear in chat', style: AetherType.title),
          const SizedBox(height: 12),
          Text(
            'When the agent needs access the overlay will prompt you. '
            'Respond there. Remembered file and host decisions appear in '
            'Granted scopes above.',
            style: AetherType.bodyMuted,
          ),
        ],
      ),
    );
  }
}

String _label(PermissionGrant g) {
  final what = g.kind == PermissionGrant.kindPath
      ? 'path ${g.value}'
      : 'host ${g.value}';
  final deny = g.isDeny ? ' · denied' : '';
  return '$what$deny';
}
