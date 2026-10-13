import 'package:flutter/foundation.dart';

import 'background_notifications.dart';
import 'studio_setup_coordinator.dart';

/// Turns the end of a long job into a notification. Pure over its inputs so
/// it is unit-testable with any [Listenable].
class JobCompletionWatcher {
  JobCompletionWatcher({
    required Listenable source,
    required this.running,
    required this.onFinished,
    required this.post,
  }) {
    _wasRunning = running();
    source.addListener(_changed);
  }

  final bool Function() running;
  final OvidNotification? Function() onFinished;
  final Future<NotificationDelivery> Function(OvidNotification) post;
  late bool _wasRunning;

  void _changed() {
    final now = running();
    if (_wasRunning && !now) {
      final n = onFinished();
      if (n != null) post(n);
    }
    _wasRunning = now;
  }
}

/// Notification for a finished sandbox (Studio) setup, or null if idle.
OvidNotification? sandboxSetupNotification(
  StudioSetupStatus status,
  String? error,
) => switch (status) {
  StudioSetupStatus.ready => OvidNotification.jobDone(
    title: 'Sandbox ready',
    body: 'The on-device Linux sandbox finished setting up.',
    key: 'job:sandbox',
  ),
  StudioSetupStatus.partial => OvidNotification.jobDone(
    title: 'Sandbox partly ready',
    body: error ?? 'Some runtimes could not be installed. Open Ovid to retry.',
    key: 'job:sandbox',
  ),
  StudioSetupStatus.failed ||
  StudioSetupStatus.unsupported => OvidNotification.jobDone(
    title: 'Sandbox setup failed',
    body: error ?? 'Open Ovid to see what went wrong.',
    key: 'job:sandbox',
  ),
  StudioSetupStatus.idle || StudioSetupStatus.running => null,
};

JobCompletionWatcher? _sandboxWatcher;

/// Installs the long-job watchers once (main.dart). Image batches are agent
/// tool runs and are reported by the run-finished notification.
void attachBackgroundJobWatchers() {
  final setup = StudioSetupCoordinator.I;
  _sandboxWatcher ??= JobCompletionWatcher(
    source: setup,
    running: () => setup.running,
    onFinished: () => sandboxSetupNotification(setup.status, setup.error),
    post: BackgroundNotifier.I.post,
  );
}
