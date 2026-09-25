import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/grant_store.dart';
import '../core/state.dart';
import '../core/theme.dart';

/// Settings → Permissions: the path/host decisions THIS SESSION holds, with
/// revoke.
///
/// STRICTLY PER-SESSION (2026-09-24): grants are recorded per session and per
/// mode, and an "Always Allow" never applies to another conversation. The old
/// "All sessions" section is gone because global grants are no longer consulted
/// by the agent — showing them as active would have been a lie. Any left on disk
/// by an older build are listed as inert with a one-tap cleanup.
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions')),
      body: ListenableBuilder(
        listenable: AppState.I,
        builder: (context, _) {
          final legacy = AppState.I.globalPermissionGrants;
          final sessionGrants = _currentSessionGrants();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _section(
                'This session',
                'Granted for THIS conversation and the mode it was granted '
                    'in — never for any other session. They persist across '
                    'restarts and are removed when the session is deleted.',
                sessionGrants
                    .map(
                      (g) => _GrantTile(
                        grant: g,
                        global: false,
                        onRevoke: () => _revokeSession(context, g),
                      ),
                    )
                    .toList(),
                empty:
                    'No grants for this session yet. They appear here when '
                    'you pick "Always Allow" on an approval card.',
              ),
              if (legacy.isNotEmpty) ...[
                const SizedBox(height: 16),
                _section(
                  'Legacy all-sessions grants (not applied)',
                  'These were recorded by an older build when a grant could '
                      'be scoped to every session. They are IGNORED now — '
                      'nothing is granted by them. Remove them to tidy up.',
                  legacy
                      .map(
                        (g) => _GrantTile(
                          grant: g,
                          global: true,
                          onRevoke: () => _revokeGlobal(context, g),
                        ),
                      )
                      .toList(),
                  empty: '',
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _section(
    String title,
    String subtitle,
    List<Widget> tiles, {
    required String empty,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 2),
          child: Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            subtitle,
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
        ),
        if (tiles.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              empty,
              style: TextStyle(fontSize: 12, color: Aether.textFaint),
            ),
          )
        else
          ...tiles,
      ],
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
    setState(() {});
  }

  Future<void> _revokeSession(
    BuildContext context,
    PermissionGrant grant,
  ) async {
    await AgentService.I.revokeSessionPermissionGrant(grant);
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Revoked: ${_label(grant)}')));
    setState(() {});
  }
}

/// Grants held by the current session (session-scoped only — global grants
/// are shown in their own section above).
List<PermissionGrant> _currentSessionGrants() {
  final session = AgentService.I.currentSession;
  if (session == null) return const [];
  return session.grants
      .where((g) => g.scope != PermissionGrant.scopeGlobal)
      .toList();
}

class _GrantTile extends StatelessWidget {
  const _GrantTile({
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
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(
          isPath ? Icons.folder_outlined : Icons.public_outlined,
          size: 20,
        ),
        title: Text(_label(grant), style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '${isPath ? 'Path' : 'Host'} · ${global ? 'always allow (all sessions)' : 'always allow (this session)'}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: 'Revoke',
          onPressed: () async {
            final confirm = await showDialog<bool>(
              context: context,
              builder: (d) => AlertDialog(
                backgroundColor: Aether.surface,
                title: const Text(
                  'Revoke grant?',
                  style: TextStyle(fontSize: 15),
                ),
                content: Text(
                  'The agent will ask again before accessing ${_label(grant)}.',
                  style: const TextStyle(fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(d).pop(false),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(d).pop(true),
                    style: TextButton.styleFrom(foregroundColor: Aether.danger),
                    child: const Text('Revoke'),
                  ),
                ],
              ),
            );
            if (confirm == true) await onRevoke();
          },
        ),
      ),
    );
  }
}

String _label(PermissionGrant g) {
  final what = g.kind == PermissionGrant.kindPath
      ? 'path ${g.value}'
      : 'host ${g.value}';
  // Grants are mode-scoped now, so name the mode — two entries for the same
  // path in two modes are two different decisions.
  final mode = g.mode.isEmpty ? 'general (legacy)' : g.mode;
  final deny = g.isDeny ? ' · denied' : '';
  return '$what · $mode$deny';
}
