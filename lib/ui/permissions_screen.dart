import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/grant_store.dart';
import '../core/state.dart';
import '../core/theme.dart';

/// Settings → Permissions: every path/host "always allow" grant the agent
/// holds — global (all sessions) and current-session — with revoke.
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
          final globalGrants = AppState.I.globalPermissionGrants;
          final sessionGrants = _currentSessionGrants();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              _section(
                'All sessions',
                'Applies to every session. Revoking one takes effect '
                    'immediately; the next access asks again.',
                globalGrants
                    .map(
                      (g) => _GrantTile(
                        grant: g,
                        global: true,
                        onRevoke: () => _revokeGlobal(context, g),
                      ),
                    )
                    .toList(),
                empty:
                    'No always-allow grants. New ones appear here when '
                    'you pick "Always Allow" (all sessions) on an approval '
                    'card.',
              ),
              const SizedBox(height: 16),
              _section(
                'This session',
                'Granted for the current session only — they disappear '
                    'when the session ends.',
                sessionGrants
                    .map(
                      (g) => _GrantTile(
                        grant: g,
                        global: false,
                        onRevoke: () => _revokeSession(context, g),
                      ),
                    )
                    .toList(),
                empty: 'No session grants yet.',
              ),
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

String _label(PermissionGrant g) =>
    g.kind == PermissionGrant.kindPath ? 'path ${g.value}' : 'host ${g.value}';
