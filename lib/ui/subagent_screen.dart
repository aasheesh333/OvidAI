import 'package:flutter/material.dart';

import '../core/cloud/cloud_agent_facade.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Subagent session view.
///
/// Subagent transcripts are produced by the cloud agent core (P3 subagent
/// events). Until that feed exists the facade exposes an empty job list, so
/// this screen renders an honest empty state instead of a local child run.
class SubagentScreen extends StatelessWidget {
  final String sessionId;
  const SubagentScreen({super.key, required this.sessionId});

  /// Open [sessionId]'s transcript. Safe to call with a stale id — it shows
  /// a "gone" state instead of crashing.
  static Future<void> open(BuildContext context, String sessionId) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SubagentScreen(sessionId: sessionId)),
      );

  @override
  Widget build(BuildContext context) {
    final session = AppState.I.sessionById(sessionId);
    final jobs = CloudAgentFacade.I.jobsFor(sessionId);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          session?.agentLabel ?? session?.title ?? 'Subagent',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: session == null
          ? const AetherEmptyState(
              key: ValueKey('subagent-gone'),
              icon: Icons.link_off,
              title: 'This subagent is no longer available',
              message: 'Its chat was deleted or the session has ended.',
            )
          : jobs.isEmpty
          ? const AetherEmptyState(
              key: ValueKey('subagent-empty'),
              icon: Icons.account_tree_outlined,
              title: 'No subagent activity yet',
              message:
                  'Ovid Cloud streams subagent transcripts when the server '
                  'emits subagent events. Nothing has arrived for this chat.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                const AetherSectionTitle(eyebrow: 'Background jobs'),
                const SizedBox(height: 10),
                for (final job in jobs)
                  AetherCard(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Icon(Icons.terminal, size: 18, color: Aether.accent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            job.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AetherType.title,
                          ),
                        ),
                        Text(job.state, style: AetherType.caption),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
