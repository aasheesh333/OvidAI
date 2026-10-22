/// Compile-time stand-in for `ScheduleRunDto` on web.
///
/// `schedule_runs_page.dart` maps one `GET /schedules/:id/runs` row onto its
/// view model. That row type lives in `core/cloud/schedule_client.dart`, which
/// reaches `core/state.dart` → `sqlite3` → `dart:ffi` and therefore cannot
/// compile for web. The page imports this file instead when
/// `dart.library.js_interop` is available.
///
/// It carries the same fields the mapping reads and nothing else: the web
/// preview never fetches runs, so no instance is ever created here. Keep this
/// in step with the fields [V2ScheduleRun.fromDto] reads.
library;

class ScheduleRunDto {
  const ScheduleRunDto({
    required this.id,
    required this.status,
    this.scheduleId = '',
    this.attempt = 1,
    this.ranLate = false,
    this.scheduledFor,
    this.runId,
    this.error,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String scheduleId;
  final DateTime? scheduledFor;
  final String? runId;

  /// 'running' | 'retry_scheduled' | 'succeeded' | 'failed' | 'skipped'.
  final String status;
  final int attempt;
  final bool ranLate;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
}
