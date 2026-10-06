import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/grant_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Settings → Permissions.
///
/// A premium-styled surface over the strict permission model, organised into
/// three calm sections with one-line explainers:
///
/// * **Session autonomy** — the policy the agent runs under. Today the only
///   state backing autonomy is the legacy "all-sessions" grant list, which is
///   intentionally **ignored** at runtime. The section still renders so the
///   user can see and clean up those stale entries. Nothing here mutates
///   runtime policy.
/// * **Granted scopes** — allow/deny decisions THIS session holds, each with
///   a status pill, its exact coverage, and a confirmed revoke action that
///   preserves the recursive/exact-path and host/path distinctions in
///   [PermissionGrant].
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
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AetherSectionTitle(
                      eyebrow: 'Autonomy',
                      subtitle: 'What the agent may decide on its own here.',
                    ),
                    const SizedBox(height: AetherSpacing.space3),
                    _AutonomyCard(
                      legacy: legacy,
                      onRevoke: (g) => _revokeGlobal(context, g),
                    ),
                    const SizedBox(height: AetherSpacing.space6),
                    const AetherSectionTitle(
                      eyebrow: 'Granted scopes',
                      subtitle:
                          'Allow and Deny decisions remembered for this '
                          'conversation.',
                    ),
                    const SizedBox(height: AetherSpacing.space3),
                    _GrantedScopesCard(
                      grants: sessionGrants,
                      onRevoke: (g) => _revokeSession(context, g),
                    ),
                    const SizedBox(height: AetherSpacing.space6),
                    const AetherSectionTitle(
                      eyebrow: 'Pending requests',
                      subtitle:
                          'Live approvals appear in the chat overlay, not '
                          'here.',
                    ),
                    const SizedBox(height: AetherSpacing.space3),
                    const _PendingRequestsCard(),
                  ],
                ),
              ),
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

/// Autonomy card. One-line policy explainer plus, when present, the legacy
/// all-sessions grant list with per-row status pills and revoke actions.
class _AutonomyCard extends StatelessWidget {
  const _AutonomyCard({required this.legacy, required this.onRevoke});

  final List<PermissionGrant> legacy;
  final Future<void> Function(PermissionGrant) onRevoke;

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(AetherSpacing.space4),
      title: const Text('Session autonomy'),
      trailing: AetherPill(
        label: 'SESSION ONLY',
        color: Aether.accentC,
        icon: Icons.shield_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'The agent asks before paths outside the workspace or hosts off '
            'the allowlist; remembered decisions stay in this conversation.',
            style: AetherType.bodyMuted,
          ),
          if (legacy.isNotEmpty) ...[
            const SizedBox(height: AetherSpacing.space4),
            Divider(height: 1, thickness: 1, color: Aether.hairline),
            const SizedBox(height: AetherSpacing.space3),
            Text(
              'Legacy all-sessions grants',
              style: AetherType.label.copyWith(color: Aether.textMuted),
            ),
            const SizedBox(height: AetherSpacing.space1),
            Text(
              'From older builds — ignored at runtime; safe to remove.',
              style: AetherType.caption,
            ),
            const SizedBox(height: AetherSpacing.space2),
            for (final g in legacy)
              Padding(
                padding: const EdgeInsets.only(bottom: AetherSpacing.space2),
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

/// Granted scopes retain the full value, a status pill, the exact coverage
/// and a confirmed revoke action. The empty state is a designed
/// [AetherEmptyState], not a bare text line.
class _GrantedScopesCard extends StatelessWidget {
  const _GrantedScopesCard({required this.grants, required this.onRevoke});

  final List<PermissionGrant> grants;
  final Future<void> Function(PermissionGrant) onRevoke;

  @override
  Widget build(BuildContext context) {
    if (grants.isEmpty) {
      return const AetherCard(
        padding: EdgeInsets.zero,
        child: AetherEmptyState(
          icon: Icons.verified_user_outlined,
          title: 'No decisions for this session yet',
          message: 'Allow or Deny in chat and the decision appears here.',
        ),
      );
    }

    return AetherCard(
      padding: const EdgeInsets.all(AetherSpacing.space4),
      title: Text('${grants.length} grant${grants.length == 1 ? '' : 's'}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in grants)
            Padding(
              padding: const EdgeInsets.only(bottom: AetherSpacing.space2),
              child: _GrantRow(grant: g, global: false, onRevoke: () => onRevoke(g)),
            ),
        ],
      ),
    );
  }
}

/// One grant: kind icon, exact target, coverage line, status pill, and a
/// confirmed revoke action. The pill carries the decision state so the row
/// stays one scannable line instead of a prose sentence.
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
    final pillLabel = global
        ? 'LEGACY'
        : (grant.isDeny ? 'DENIED' : 'ALLOWED');
    final pillColor = global
        ? Aether.textMuted
        : (grant.isDeny ? Aether.dangerC : Aether.successC);
    final coverage = isPath
        ? (grant.recursive ? 'Directory and descendants' : 'Exact path')
        : 'Host and subdomains, all ports and paths';

    return Container(
      padding: const EdgeInsets.all(AetherSpacing.space3),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: grant.isDeny ? Aether.dangerC : Aether.accentC,
              ),
              const SizedBox(width: AetherSpacing.space2),
              Expanded(
                child: Text(
                  _target(grant),
                  style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AetherSpacing.space2),
              AetherPill(label: pillLabel, color: pillColor),
            ],
          ),
          const SizedBox(height: AetherSpacing.space1),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(coverage, style: AetherType.caption),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Tooltip(
              message: 'Revoke',
              child: TextButton.icon(
                key: ValueKey('revoke-${global ? 'global' : 'session'}-${grant.kind}-${grant.value}'),
                style: TextButton.styleFrom(foregroundColor: Aether.dangerC),
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
          ),
        ],
      ),
    );
  }
}

/// Pending-requests card. The permissions screen is a passive viewer of
/// persisted state. There is no pending-request feed backing this panel, so
/// it states where prompts actually appear and offers no fake controls.
class _PendingRequestsCard extends StatelessWidget {
  const _PendingRequestsCard();

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.all(AetherSpacing.space4),
      title: const Text('Approval prompts appear in chat'),
      child: Text(
        'Respond in the overlay; remembered decisions appear under Granted '
        'scopes.',
        style: AetherType.bodyMuted,
      ),
    );
  }
}

/// The grant target without a decision suffix — the row title.
String _target(PermissionGrant g) =>
    g.kind == PermissionGrant.kindPath ? 'path ${g.value}' : 'host ${g.value}';

String _label(PermissionGrant g) {
  final deny = g.isDeny ? ' · denied' : '';
  return '${_target(g)}$deny';
}
