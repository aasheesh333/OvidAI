import 'package:flutter/material.dart';

import '../core/agent_notification_service.dart';
import '../core/agent_service.dart';
import '../core/schedule_coordinator.dart';
import '../core/state.dart';

class ScheduleScreen extends StatelessWidget {
  final String sessionId;
  const ScheduleScreen({super.key, required this.sessionId});

  Future<void> _action(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = AgentService.I;
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, agent]),
      builder: (context, _) {
        final session = AppState.I.sessionById(sessionId);
        final tasks = session?.schedules ?? [];
        final stopped = agent.schedules.stopped || AgentNotificationService.I.backgroundStopped;
        return Scaffold(
          appBar: AppBar(title: Text('Schedule · ${session?.title ?? 'session'}')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(stopped ? 'Background execution paused by user' : 'Background execution is best-effort',
                style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('Tasks run while the runtime is available, even with the app in the background. '
                'Android may delay alarms or stop execution. After process loss, reopen Ovid to '
                'reconcile tasks. Interrupted runs pause for review; they are not replayed automatically.'),
              if (AgentNotificationService.I.backgroundConstraint case final String constraint)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('System constraint: $constraint')),
              if (!AppState.I.keepAliveEnabled)
                const Text('Background keep-alive is off. Future tasks may wait until you reopen Ovid.'),
              if (!AppState.I.notificationsEnabled)
                const Text('Notifications are off; background service visibility is unavailable.'),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: Icon(stopped ? Icons.play_arrow : Icons.stop),
                  label: Text(stopped ? 'Resume background execution' : 'Stop background execution'),
                  onPressed: () => _action(context, stopped
                    ? agent.resumeScheduledBackground
                    : AgentNotificationService.I.stopBackground),
                ),
              ),
              const Divider(),
              if (tasks.isEmpty)
                const Padding(padding: EdgeInsets.all(24), child: Text(
                  'No scheduled tasks. Ask the agent to schedule a one-off, daily, or recurring task.')),
              for (final task in tasks) _taskCard(context, ScheduleEntry(sessionId, task)),
            ],
          ),
        );
      },
    );
  }

  Widget _taskCard(BuildContext context, ScheduleEntry entry) {
    final t = entry.task;
    final status = t['status'] as String? ?? 'pending';
    final next = DateTime.tryParse(t['fireAt'] as String? ?? '')?.toLocal();
    final active = ['pending', 'running', 'paused'].contains(status);
    final agent = AgentService.I;
    final recurrence = t['dailyAt'] != null ? 'Daily ${t['dailyAt']} · device-local'
        : t['every'] != null ? 'Every ${t['every']} seconds · fixed interval' : 'One-off · fixed instant';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(t['prompt'] as String? ?? '', style: Theme.of(context).textTheme.titleMedium)),
            const SizedBox(width: 8),
            Chip(label: Text(status)),
          ]),
          Text(recurrence),
          Text('${active ? 'Next' : 'Scheduled'}: ${next?.toString().split('.').first ?? 'Invalid date'} ${next?.timeZoneName ?? ''}'),
          if (status == 'pending' && next != null && next.isBefore(DateTime.now()))
            const Text('Overdue — waiting for runtime/session availability'),
          if (t['lastStatus'] != null) Text('Last run: ${t['lastStatus']}'),
          if (t['error'] != null) Text('${t['error']}'),
          Text('Retries: ${t['attempt'] ?? 0}/${t['maxRetries'] ?? 0} · pre-execution failures only'),
          Wrap(children: [
            IconButton(tooltip: 'Edit schedule', icon: const Icon(Icons.edit_outlined),
              onPressed: status == 'running' ? null : () => _edit(context, entry)),
            if (status == 'pending' || status == 'running')
              IconButton(tooltip: 'Pause schedule', icon: const Icon(Icons.pause),
                onPressed: () => _action(context, () => agent.schedules.cancelTask(entry, pause: true))),
            if (status == 'paused' || status == 'failed')
              TextButton.icon(icon: const Icon(Icons.play_arrow), label: const Text('Resume task'),
                onPressed: () => _action(context, () => agent.schedules.resumeTask(entry))),
            if (status != 'cancelled' && status != 'completed')
              IconButton(tooltip: 'Cancel schedule', icon: const Icon(Icons.cancel_outlined),
                onPressed: () => _action(context, () => agent.schedules.cancelTask(entry))),
          ]),
        ]),
      ),
    );
  }

  Future<void> _edit(BuildContext context, ScheduleEntry entry) async {
    final t = entry.task;
    var kind = t['dailyAt'] != null ? 'daily_at' : t['every'] != null ? 'every_seconds' : 'at';
    final prompt = TextEditingController(text: t['prompt'] as String?);
    final time = TextEditingController(text: '${t['dailyAt'] ?? t['every'] ?? t['fireAt'] ?? ''}');
    final retries = TextEditingController(text: '${t['maxRetries'] ?? 0}');
    String? error;
    await showDialog<void>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Edit schedule'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: prompt, decoration: const InputDecoration(labelText: 'Task'), maxLines: 3),
          DropdownButton<String>(value: kind, isExpanded: true, items: const [
            DropdownMenuItem(value: 'at', child: Text('One-off date/time')),
            DropdownMenuItem(value: 'daily_at', child: Text('Daily (device-local)')),
            DropdownMenuItem(value: 'every_seconds', child: Text('Recurring interval')),
          ], onChanged: (v) => setState(() { kind = v!; time.clear(); })),
          TextField(controller: time, decoration: InputDecoration(labelText:
            kind == 'at' ? 'YYYY-MM-DD HH:mm or ISO with offset' : kind == 'daily_at' ? 'HH:mm' : 'Seconds (minimum 300)')),
          TextField(controller: retries, decoration: const InputDecoration(labelText: 'Safe retries (0–3)')),
          if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          FilledButton(onPressed: () async {
            try {
              await AgentService.I.editSchedule(entry, {
                'prompt': prompt.text,
                kind: kind == 'every_seconds' ? int.tryParse(time.text) ?? -1 : time.text,
                'max_retries': int.tryParse(retries.text) ?? -1,
              });
              if (context.mounted) Navigator.pop(context);
            } catch (e) {
              if (context.mounted) setState(() => error = '$e');
            }
          }, child: const Text('Save')),
        ],
      ),
    ));
    // Dialog reverse animation still owns the fields until its route settles.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    prompt.dispose(); time.dispose(); retries.dispose();
  }
}
