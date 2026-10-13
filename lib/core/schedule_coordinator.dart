import 'dart:async';
import 'dart:math';

/// A view of a persisted session-owned task, not a second copy of its state.
class ScheduleEntry {
  final String sessionId;
  final Map<String, dynamic> task;
  ScheduleEntry(this.sessionId, this.task);
}

class ScheduleResult {
  final String status;
  final String? error;
  final bool safeToRetry;
  const ScheduleResult.completed()
    : status = 'completed',
      error = null,
      safeToRetry = false;
  const ScheduleResult.failed(this.error)
    : status = 'failed',
      safeToRetry = false;
  const ScheduleResult.retryable(this.error)
    : status = 'failed',
      safeToRetry = true;
}

/// What to do with an occurrence that fell due while Ovid was not running
/// (phone off, process killed, alarm deferred by the OS).
enum CatchUp {
  /// Not missed (still in the future, or within the on-time tolerance).
  onTime,

  /// Run once now. Several missed occurrences of a recurring task collapse
  /// into this single run; the next slot is computed after it finishes.
  runNow,

  /// Recurring task missed by more than its grace window: do not run late,
  /// move to the next future slot.
  skipToNext,

  /// One-off task missed by more than a day: never fire a stale action by
  /// surprise; pause it so the user can review and resume.
  pauseForReview,
}

/// Missed-run catch-up policy, applied once when the runtime starts (cold
/// start, boot, restart after the OS killed Ovid).
class MissedRunPolicy {
  const MissedRunPolicy._();

  /// Delays below this count as on time (alarm/boot jitter).
  static const tolerance = Duration(minutes: 2);

  /// One-off tasks still run when at most this late.
  static const oneOffGrace = Duration(hours: 24);

  /// Upper bound of a recurring task's grace window.
  static const recurringGraceCap = Duration(hours: 6);

  /// Grace window: half the period for interval tasks (capped), 6 h daily.
  static Duration graceFor(Map<String, dynamic> task) {
    final every = task['every'];
    if (every is num && every > 0) {
      final half = Duration(seconds: every.toInt() ~/ 2);
      return half < recurringGraceCap ? half : recurringGraceCap;
    }
    if (task['dailyAt'] != null) return recurringGraceCap;
    return oneOffGrace;
  }

  static bool isRecurring(Map<String, dynamic> task) =>
      (task['every'] is num && (task['every'] as num) > 0) ||
      task['dailyAt'] is String;

  static CatchUp decide(Map<String, dynamic> task, DateTime due, DateTime now) {
    final late = now.difference(due);
    if (late <= tolerance) return CatchUp.onTime;
    if (late <= graceFor(task)) return CatchUp.runNow;
    return isRecurring(task) ? CatchUp.skipToNext : CatchUp.pauseForReview;
  }

  /// First recurring slot strictly after [now].
  static DateTime nextSlot(Map<String, dynamic> task, DateTime due, DateTime now) {
    final daily = task['dailyAt'];
    if (daily is String) return ScheduleCoordinator.nextDaily(daily, now);
    final interval = (task['every'] as num).toInt();
    final steps = now.difference(due).inSeconds ~/ interval + 1;
    return due.add(Duration(seconds: interval * steps));
  }
}

/// At-most-once automatic dispatch of each occurrence. External effects cannot
/// be made exactly-once: a process lost after claiming is paused for review.
class ScheduleCoordinator {
  final Iterable<ScheduleEntry> Function() entries;
  final DateTime Function() clock;
  Future<void> Function() persist;
  final bool Function(String) isBusy;
  Future<ScheduleResult> Function(ScheduleEntry) execute;
  final void Function(String) cancel;
  final void Function() changed;

  /// Observes each finished occurrence (notifications). [willRetry] is true
  /// when the task is re-queued for another attempt.
  void Function(ScheduleEntry entry, ScheduleResult result, bool willRetry)?
  onResult;
  bool stopped = false;
  bool _ticking = false;
  bool get dispatching => _ticking;

  /// True while a tick runs or any claimed occurrence is still executing.
  bool get busy => _ticking || _executions.isNotEmpty;
  final Set<String> _activeSessions = {};
  final Set<Map<String, dynamic>> _activeTasks = Set.identity();
  final Set<Future<void>> _executions = {};
  final _random = Random.secure();

  ScheduleCoordinator({
    required this.entries,
    required this.clock,
    required this.persist,
    required this.isBusy,
    required this.execute,
    required this.cancel,
    required this.changed,
    this.onResult,
  });

  Map<String, dynamic> create(Map<String, dynamic> args) {
    final prompt = (args['prompt'] as String? ?? '').trim();
    if (prompt.isEmpty) throw const FormatException('prompt is required');
    if ([
          'after_seconds',
          'at',
          'every_seconds',
          'daily_at',
        ].where((k) => args[k] != null).length !=
        1) {
      throw const FormatException(
        'Supply exactly one of after_seconds, at, every_seconds, daily_at',
      );
    }
    final retries = args['max_retries'] ?? 0;
    if (retries is! int || retries < 0 || retries > 3) {
      throw const FormatException('max_retries must be 0–3');
    }
    final now = clock();
    DateTime due;
    final every = args['every_seconds'];
    final after = args['after_seconds'];
    final daily = args['daily_at'] as String?;
    if (daily != null) {
      if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(daily)) {
        throw const FormatException(
          'daily_at must be HH:mm, device-local time',
        );
      }
      due = nextDaily(daily, now);
    } else if (args['at'] != null) {
      due = parseDate(args['at'] as String);
    } else {
      final seconds = every ?? after;
      if (seconds is! int || seconds < (every != null ? 300 : 1)) {
        throw const FormatException(
          'every_seconds must be ≥300; after_seconds must be ≥1',
        );
      }
      due = now.add(Duration(seconds: seconds));
    }
    return {
      'id': 'sch-${now.microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}',
      'prompt': prompt,
      'fireAt': due.toUtc().toIso8601String(),
      'every': every,
      'dailyAt': daily,
      'timezone': daily != null ? 'device-local' : 'fixed-instant',
      'zoneOffset': now.toLocal().timeZoneOffset.inMinutes,
      if (daily != null) 'localDate': _calendarDate(due),
      'status': stopped ? 'paused' : 'pending',
      if (stopped) 'error': stoppedByUser,
      'maxRetries': retries,
      'attempt': 0,
    };
  }

  static DateTime parseDate(String value) {
    final m = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::([0-5]\d)(?:\.\d{1,6})?)?(Z|[+-](?:[01]\d|2[0-3]):[0-5]\d)?$',
    ).firstMatch(value);
    if (m == null) {
      throw const FormatException(
        'Use YYYY-MM-DD HH:mm or ISO-8601 with offset',
      );
    }
    final year = int.parse(m[1]!);
    final month = int.parse(m[2]!);
    final day = int.parse(m[3]!);
    final date = DateTime.utc(year, month, day);
    if (date.year != year ||
        date.month != month ||
        date.day != day ||
        int.parse(m[4]!) > 23 ||
        int.parse(m[5]!) > 59) {
      throw const FormatException('Invalid calendar date/time');
    }
    return DateTime.parse(value.replaceAll(' ', 'T'));
  }

  static DateTime nextDaily(String time, DateTime after) {
    final parts = time.split(':').map(int.parse).toList();
    final local = after.toLocal();
    var next = DateTime(local.year, local.month, local.day, parts[0], parts[1]);
    if (!next.isAfter(after)) {
      next = DateTime(
        local.year,
        local.month,
        local.day + 1,
        parts[0],
        parts[1],
      );
    }
    return next;
  }

  static String _calendarDate(DateTime date) {
    final d = date.toLocal();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  DateTime? _due(Map<String, dynamic> t) {
    if (t['dailyAt'] != null &&
        t['localDate'] != null &&
        (t['attempt'] ?? 0) == 0) {
      // Reinterpret the saved calendar date in the current device timezone.
      // DST offsets are resolved by DateTime for THAT date, not today's offset.
      return DateTime.tryParse('${t['localDate']}T${t['dailyAt']}:00');
    }
    return DateTime.tryParse(t['fireAt'] as String? ?? '');
  }

  Future<void> recover() async {
    for (final entry in entries()) {
      final t = entry.task;
      t['status'] ??= 'pending'; // legacy reminder migration
      t['maxRetries'] ??= 0;
      t['attempt'] ??= 0;
      if (t['status'] == 'running') {
        t['status'] = 'paused';
        t['error'] =
            'Execution interrupted; outcome unknown. Review before resuming.';
      } else if (stopped && t['status'] == 'pending') {
        t['status'] = 'paused';
        t['error'] = 'Background execution stopped by user';
      }
      final due = DateTime.tryParse(t['fireAt'] as String? ?? '');
      final every = t['every'];
      final daily = t['dailyAt'];
      final validRecurrence =
          (every == null || (every is int && every >= 300)) &&
          (daily == null ||
              (daily is String &&
                  RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(daily)));
      if (due == null || !validRecurrence) {
        t['status'] = 'paused';
        t['error'] = 'Invalid saved date/recurrence; edit this schedule';
      } else {
        t['fireAt'] = due.toUtc().toIso8601String();
        if (daily != null) t['localDate'] ??= _calendarDate(due);
        if (t['status'] == 'pending' && (t['attempt'] ?? 0) == 0) {
          _catchUp(t);
        }
      }
    }
    await _save();
  }

  /// Applies [MissedRunPolicy] to a pending task on runtime start.
  void _catchUp(Map<String, dynamic> t) {
    final due = _due(t);
    if (due == null) return;
    final now = clock();
    switch (MissedRunPolicy.decide(t, due, now)) {
      case CatchUp.onTime:
      case CatchUp.runNow:
        return; // the next tick dispatches it exactly once
      case CatchUp.skipToNext:
        final next = MissedRunPolicy.nextSlot(t, due, now);
        t['fireAt'] = next.toUtc().toIso8601String();
        if (t['dailyAt'] != null) t['localDate'] = _calendarDate(next);
        t['lastStatus'] = 'skipped';
        t['skippedAt'] = due.toUtc().toIso8601String();
      case CatchUp.pauseForReview:
        t['status'] = 'paused';
        t['error'] =
            'Missed while Ovid was not running (due ${due.toLocal()}); '
            'review before resuming.';
    }
  }

  DateTime? get nextWake {
    if (stopped) return null;
    DateTime? next;
    for (final e in entries()) {
      if ((e.task['status'] ?? 'pending') != 'pending' ||
          isBusy(e.sessionId) ||
          _activeSessions.contains(e.sessionId)) {
        continue;
      }
      final due = _due(e.task);
      if (due != null && (next == null || due.isBefore(next))) next = due;
    }
    return next;
  }

  Future<void> tick() async {
    if (stopped || _ticking) return;
    _ticking = true;
    try {
      for (final entry in List.of(entries())) {
        if (stopped) break;
        final t = entry.task;
        if ((t['status'] ?? 'pending') != 'pending' ||
            isBusy(entry.sessionId) ||
            _activeSessions.contains(entry.sessionId)) {
          continue;
        }
        final now = clock();
        final due = _due(t);
        if (t['dailyAt'] != null &&
            due != null &&
            t['zoneOffset'] != now.toLocal().timeZoneOffset.inMinutes) {
          t['fireAt'] = due.toUtc().toIso8601String();
          t['zoneOffset'] = now.toLocal().timeZoneOffset.inMinutes;
          await _save();
        }
        // Stop/cancel may have run while the timezone correction was saved.
        if (stopped || (t['status'] ?? 'pending') != 'pending') continue;
        if (due == null || due.isAfter(now)) continue;
        final claim =
            '${t['id']}/${due.toUtc().toIso8601String()}/${t['attempt'] ?? 0}';
        t['runId'] = claim;
        t['occurrenceAt'] ??= due.toUtc().toIso8601String();
        t['status'] = 'running';
        t['startedAt'] = now.toUtc().toIso8601String();
        t.remove('error');
        _activeSessions.add(entry.sessionId);
        _activeTasks.add(t);
        try {
          await _save();
        } catch (e) {
          _activeSessions.remove(entry.sessionId);
          _activeTasks.remove(t);
          if (!stopped && t['status'] == 'running') {
            t['status'] = 'paused';
            t['error'] = 'Could not persist execution claim: $e';
          }
          changed();
          continue;
        }
        if (stopped || t['status'] != 'running' || !_owns(entry, claim)) {
          _activeSessions.remove(entry.sessionId);
          _activeTasks.remove(t);
          continue;
        }
        final future = _run(entry, claim);
        _executions.add(future);
        unawaited(future.whenComplete(() => _executions.remove(future)));
      }
    } finally {
      _ticking = false;
      changed();
    }
  }

  bool _owns(ScheduleEntry e, String claim, {bool requireRunning = true}) => entries().any(
    (current) =>
        current.sessionId == e.sessionId &&
        identical(current.task, e.task) &&
        current.task['runId'] == claim &&
        (!requireRunning || current.task['status'] == 'running'),
  );

  Future<void> _run(ScheduleEntry entry, String claim) async {
    final t = entry.task;
    try {
      ScheduleResult result;
      try {
        result = await execute(entry);
      } catch (e) {
        result = ScheduleResult.failed('$e');
      }
      if (!_owns(entry, claim)) return;
      t['lastStatus'] = result.status;
      t['finishedAt'] = clock().toUtc().toIso8601String();
      t['error'] = result.error;
      final attempt = (t['attempt'] as num?)?.toInt() ?? 0;
      final willRetry =
          result.safeToRetry &&
          attempt < ((t['maxRetries'] as num?)?.toInt() ?? 0);
      try {
        onResult?.call(entry, result, willRetry);
      } catch (_) {
        // Observers never affect dispatch bookkeeping.
      }
      if (willRetry) {
        t['attempt'] = attempt + 1;
        t['fireAt'] = clock()
            .add(Duration(seconds: 30 * (1 << attempt)))
            .toUtc()
            .toIso8601String();
        t['status'] = 'pending';
      } else if (result.status == 'completed' &&
          (t['every'] != null || t['dailyAt'] != null)) {
        final DateTime next;
        if (t['dailyAt'] != null) {
          next = nextDaily(t['dailyAt'] as String, clock());
        } else {
          final anchor = DateTime.parse(t['occurrenceAt'] as String);
          final interval = (t['every'] as num).toInt();
          next = anchor.add(
            Duration(
              seconds:
                  interval *
                  (max(0, clock().difference(anchor).inSeconds) ~/ interval +
                      1),
            ),
          );
        }
        t['fireAt'] = next.toUtc().toIso8601String();
        if (t['dailyAt'] != null) t['localDate'] = _calendarDate(next);
        t['status'] = 'pending';
        t['attempt'] = 0;
        t.remove('occurrenceAt');
      } else {
        t['status'] = result.status;
      }
      await _save();
    } catch (e) {
      if (!stopped &&
          !['paused', 'cancelled'].contains(t['status']) &&
          _owns(entry, claim, requireRunning: false)) {
        t['status'] = 'paused';
        t['error'] =
            'Result persistence failed; review outcome before resuming: $e';
      }
    } finally {
      _activeTasks.remove(t);
      _activeSessions.remove(entry.sessionId);
      changed();
    }
  }

  /// Marker left on tasks paused by [stop] (and on tasks created while
  /// stopped) so [resumeStopped] re-pends exactly those, never tasks the
  /// user paused one by one.
  static const stoppedByUser = 'Background execution stopped by user';

  Future<void> stop() async {
    stopped = true;
    for (final e in entries()) {
      if (['pending', 'running'].contains(e.task['status'] ?? 'pending') ||
          _activeTasks.contains(e.task)) {
        final running = _activeTasks.contains(e.task);
        e.task['status'] = 'paused';
        e.task['error'] = stoppedByUser;
        if (running) cancel(e.sessionId);
      }
    }
    await _save();
  }

  Future<void> cancelTask(ScheduleEntry e, {bool pause = false}) async {
    final running = e.task['status'] == 'running';
    e.task['status'] = pause ? 'paused' : 'cancelled';
    e.task['error'] = pause ? 'Paused by user' : 'Cancelled by user';
    if (running) cancel(e.sessionId);
    await _save();
  }

  /// Clears [stopped] and re-pends every task that [stop] paused, moving
  /// missed recurring occurrences to their next slot. One-off tasks keep
  /// their due time (a missed one runs on the next tick). Returns how many
  /// tasks were resumed.
  Future<int> resumeStopped() async {
    stopped = false;
    final now = clock();
    var resumed = 0;
    for (final e in entries()) {
      final t = e.task;
      if (t['status'] != 'paused' || t['error'] != stoppedByUser) continue;
      if (_activeTasks.contains(t) || _activeSessions.contains(e.sessionId)) {
        continue;
      }
      t['status'] = 'pending';
      t['attempt'] = 0;
      t.remove('error');
      t.remove('occurrenceAt');
      t.remove('runId');
      final due = DateTime.tryParse('${t['fireAt'] ?? ''}');
      if (due != null && !due.isAfter(now)) {
        if (t['dailyAt'] is String) {
          final next = nextDaily(t['dailyAt'] as String, now);
          t['fireAt'] = next.toUtc().toIso8601String();
          t['localDate'] = _calendarDate(next);
        } else if (t['every'] is num && (t['every'] as num) > 0) {
          final interval = (t['every'] as num).toInt();
          final steps = now.difference(due).inSeconds ~/ interval + 1;
          t['fireAt'] = due
              .add(Duration(seconds: interval * steps))
              .toUtc()
              .toIso8601String();
        }
      }
      resumed++;
    }
    if (resumed > 0) await _save();
    return resumed;
  }

  Future<void> resumeTask(ScheduleEntry e) async {
    if (stopped) throw StateError('Resume background execution first');
    if (_activeSessions.contains(e.sessionId)) {
      throw StateError('Previous run is still stopping');
    }
    e.task['status'] = 'pending';
    e.task['attempt'] = 0;
    e.task.remove('error');
    e.task.remove('occurrenceAt');
    e.task.remove('runId');
    await _save();
  }

  Future<void> _save() async {
    await persist();
    changed();
  }

  Future<void> settle() async {
    while (_executions.isNotEmpty) {
      await Future.wait(List.of(_executions));
    }
  }
}
