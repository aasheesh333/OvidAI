import 'package:flutter/material.dart';

import '../core/agent_notification_service.dart';
import '../core/agent_service.dart';
import '../core/format.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'schedule_screen.dart';
import 'subagent_screen.dart';
import 'trajectory_screen.dart';
import 'widgets/aether_primitives.dart';

/// The hub's four operational tabs, in display order.
enum ActivityTab { jobs, agents, schedules, events }

/// Activity hub — one premium tabbed screen consolidating the per-session
/// operational views:
///
///   * **Jobs** — live background jobs (`AgentService.jobsFor`), each a card
///     with a status pill, one-line elapsed/output summary and one clear
///     action (Kill for a running job).
///   * **Agents** — the session's dispatched subagents ([SubagentListView]);
///     a card opens the child's slim transcript view ([SubagentScreen]).
///   * **Schedules** — [ScheduleTasksView] without its banner; the hub owns
///     the single status strip.
///   * **Events** — [TrajectoryEventsView] over the append-only session
///     ledger, one-line summaries with JSON behind a disclosure.
///
/// Exactly one status strip sits under the tab switcher (never stacked
/// banners): background-execution state, a live-work count line, and the
/// background Stop/Resume toggle. All service contracts stay untouched.
class ActivityScreen extends StatefulWidget {
  final String sessionId;
  const ActivityScreen({super.key, required this.sessionId});

  /// Open the hub for [sessionId]. Safe with a stale id — shows a calm
  /// "gone" state instead of crashing.
  static Future<void> open(BuildContext context, String sessionId) =>
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ActivityScreen(sessionId: sessionId)),
      );

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  ActivityTab _tab = ActivityTab.jobs;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (context, _) {
        final session = AppState.I.sessionById(widget.sessionId);
        if (session == null) {
          return Scaffold(
            backgroundColor: Aether.bg,
            appBar: AppBar(
              leading: const BackButton(),
              title: const Text('Activity'),
            ),
            body: const SingleChildScrollView(
              child: AetherEmptyState(
                icon: Icons.inventory_2_outlined,
                title: 'This session is gone.',
              ),
            ),
          );
        }
        return Scaffold(
          backgroundColor: Aether.bg,
          appBar: AppBar(
            leading: const BackButton(),
            title: Tooltip(
              message: 'Activity · ${session.title}',
              child: Text(
                'Activity · ${session.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                  child: Center(
                    child: AetherSegmentedControl<ActivityTab>(
                      options: const [
                        (
                          value: ActivityTab.jobs,
                          label: 'Jobs',
                          icon: Icons.terminal_outlined,
                        ),
                        (
                          value: ActivityTab.agents,
                          label: 'Agents',
                          icon: Icons.account_tree_outlined,
                        ),
                        (
                          value: ActivityTab.schedules,
                          label: 'Schedules',
                          icon: Icons.schedule_outlined,
                        ),
                        (
                          value: ActivityTab.events,
                          label: 'Events',
                          icon: Icons.timeline_outlined,
                        ),
                      ],
                      value: _tab,
                      onChanged: (tab) => setState(() => _tab = tab),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: _ActivityStatusStrip(sessionId: session.id),
                ),
                Expanded(
                  child: switch (_tab) {
                    ActivityTab.jobs => _JobsView(sessionId: session.id),
                    ActivityTab.agents =>
                      SubagentListView(sessionId: session.id),
                    ActivityTab.schedules => ScheduleTasksView(
                        sessionId: session.id,
                        showStatusStrip: false,
                      ),
                    ActivityTab.events =>
                      TrajectoryEventsView(sessionId: session.id),
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The hub's single status strip: background-execution state, a live-work
/// count line, and the background Stop/Resume toggle — the same service
/// calls the standalone schedule screen uses.
class _ActivityStatusStrip extends StatelessWidget {
  final String sessionId;
  const _ActivityStatusStrip({required this.sessionId});

  Future<void> _toggle(BuildContext context, bool stopped) async {
    try {
      if (stopped) {
        await AgentService.I.resumeScheduledBackground();
      } else {
        await AgentNotificationService.I.stopBackground();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, AgentService.I]),
      builder: (context, _) {
        final agent = AgentService.I;
        final stopped = agent.schedules.stopped ||
            AgentNotificationService.I.backgroundStopped;
        final session = AppState.I.sessionById(sessionId);
        final jobs = agent
            .jobsFor(sessionId)
            .where((j) => j.state == 'running')
            .length;
        final agents = AppState.I
            .childrenOf(sessionId)
            .where((c) => agent.busyFor(c.id))
            .length;
        final tasks = (session?.schedules ?? const <Map<String, dynamic>>[])
            .where((t) => t['status'] == 'pending' || t['status'] == 'running')
            .length;
        final counts = <String>[
          if (jobs > 0) '$jobs ${jobs == 1 ? 'job' : 'jobs'}',
          if (agents > 0) '$agents ${agents == 1 ? 'agent' : 'agents'}',
          if (tasks > 0) '$tasks ${tasks == 1 ? 'task' : 'tasks'}',
        ];
        final color = stopped ? Aether.warn : Aether.success;
        return AetherCard(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          child: Row(
            children: [
              AetherStatusDot(color: color, pulsing: !stopped),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      stopped
                          ? 'Background execution paused'
                          : 'Background execution active',
                      style: AetherType.title.copyWith(fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      counts.isEmpty ? 'No live work' : counts.join(' · '),
                      style: AetherType.caption,
                    ),
                  ],
                ),
              ),
              AetherGhostButton(
                key: const ValueKey('activity-background-toggle'),
                label: stopped ? 'Resume' : 'Stop',
                tooltip: stopped
                    ? 'Resume background execution'
                    : 'Stop background execution',
                icon: stopped ? Icons.play_arrow : Icons.stop,
                onPressed: () => _toggle(context, stopped),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Jobs tab — live background jobs of the session, one card each: status
/// pill, `#id name`, one-line elapsed/output summary, and a Kill action for
/// a running job. Reads the same `AgentService.jobsFor` snapshot the chat
/// jobs popover uses; Kill routes through `AgentService.killJobFor`.
class _JobsView extends StatelessWidget {
  final String sessionId;
  const _JobsView({required this.sessionId});

  static Color _stateColor(String state) => switch (state) {
        'running' => Aether.accent,
        'stopping' => Aether.warnLight,
        'pending' => Aether.textFaint,
        _ => Aether.successLight,
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (context, _) {
        final jobs = AgentService.I.jobsFor(sessionId);
        if (jobs.isEmpty) {
          return const SingleChildScrollView(
            child: AetherEmptyState(
              key: ValueKey('activity-jobs-empty'),
              icon: Icons.terminal_outlined,
              title: 'No background jobs',
              message:
                  'Commands the agent runs in the background appear here.',
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            for (final job in jobs) ...[
              _JobCard(
                key: ValueKey('activity-job-${job.id}'),
                sessionId: sessionId,
                job: job,
                color: _stateColor(job.state),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

class _JobCard extends StatelessWidget {
  final String sessionId;
  final ({int id, String name, String state, int elapsedSec, int outChars})
      job;
  final Color color;
  const _JobCard({
    super.key,
    required this.sessionId,
    required this.job,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AetherPill(label: job.state, color: color),
              const Spacer(),
              if (job.state == 'running')
                AetherGhostButton(
                  key: ValueKey('activity-job-kill-${job.id}'),
                  label: 'Kill',
                  tooltip: 'Kill job',
                  icon: Icons.stop_circle_outlined,
                  onPressed: () =>
                      AgentService.I.killJobFor(sessionId, job.id),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '#${job.id} ${job.name}',
              style: AetherType.title.copyWith(fontSize: 13.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '${formatCompactDuration(Duration(seconds: job.elapsedSec))} '
              'elapsed · ${job.outChars} chars output',
              style: AetherType.bodyMuted.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
