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
/// * **Granted scopes** — allow/deny decisions THIS session holds, with full
///   scope descriptions and revoke actions that preserve the recursive/
///   exact-path and host/path distinctions in [PermissionGrant].
/// * **Pending requests** — reserved for interactive approval prompts routed
///   through the main overlay. The permissions screen is a passive viewer of
///   the current state and does not host active prompts, so this section
///   explains that explicitly and is empty by design.
///
/// All existing semantics are preserved: session grants come from
/// [AgentService.currentSession.grants], legacy all-sessions grants come from
/// [AppState.globalPermissionGrants], and revocation routes through the same
/// owner methods ([AgentService.revokeSessionPermissionGrant] and
/// [AppState.revokeGlobalPermissionGrant]). No new state is introduced.
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
          final sessionGrants = _currentSessionGrants();
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
                      'Decisions apply across modes in THIS conversation. '
                      'They persist across restarts and are removed when the '
                      'session is deleted.',
                ),
                const SizedBox(height: 12),
                _GrantedScopesCard(
                  grants: sessionGrants,
                  onRevoke: (g) => _revokeSession(context, g),
                ),
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
    final ok = await AppState.I.revokeGlobalPermissionGrant(
      grant.kind,
      grant.value,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Revoked: ${_label(grant)}' : 'Nothing to revoke'),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _revokeSession(
    BuildContext context,
    PermissionGrant grant,
  ) async {
    // A confirmation can remain open while the selected conversation changes.
    // Do not let its old row revoke an identically named scope in the new one.
    if (AgentService.I.currentSession?.grants.contains(grant) != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This decision is no longer in the current session.')),
      );
      return;
    }
    await AgentService.I.revokeSessionPermissionGrant(grant);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Revoked: ${_label(grant)}')));
    if (mounted) setState(() {});
  }
}

/// Session-scoped grants held by the current session (global grants are shown
/// in the Autonomy section as inert, matching their runtime status).
List<PermissionGrant> _currentSessionGrants() {
  final session = AgentService.I.currentSession;
  if (session == null) return const [];
  return session.grants
      .where((g) => g.scope != PermissionGrant.scopeGlobal)
      .toList();
}

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

/// Granted scopes retain the full value, coverage description and revoke action.
class _GrantedScopesCard extends StatelessWidget {
  const _GrantedScopesCard({required this.grants, required this.onRevoke});

  final List<PermissionGrant> grants;
  final Future<void> Function(PermissionGrant) onRevoke;

  @override
  Widget build(BuildContext context) {
    if (grants.isEmpty) {
      return AetherCard(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 20, color: Aether.textFaint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'No decisions for this session yet. File and host access '
                'appear here after Allow, Always allow, or Deny.',
                style: AetherType.bodyMuted,
              ),
            ),
          ],
        ),
      );
    }

    return AetherCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${grants.length} grant${grants.length == 1 ? '' : 's'}',
            style: AetherType.title,
          ),
          const SizedBox(height: 8),
          Wrap(
            children: [
              _PermissionScopeBadge(
                label: 'THIS SESSION',
                color: Aether.textMuted,
                icon: Icons.chat_bubble_outline,
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final g in grants)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _GrantRow(grant: g, global: false, onRevoke: () => onRevoke(g)),
            ),
        ],
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
        '${global ? 'legacy (not applied)' : 'this session, all modes'}';

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
            key: ValueKey('revoke-${global ? 'global' : 'session'}-${grant.kind}-${grant.value}'),
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
