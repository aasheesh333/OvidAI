import 'package:flutter/foundation.dart';

import 'background_notifications.dart';

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

/// No-op until Task 12 removes the headless boot block.
///
/// P8 Task 13 deleted the on-device sandbox/Studio setup coordinator, so
/// there is no long-job watcher left to attach.
void attachBackgroundJobWatchers() {}
