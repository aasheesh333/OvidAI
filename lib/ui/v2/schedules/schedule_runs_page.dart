import 'package:flutter/material.dart';

import '../../../core/cloud/schedule_client.dart'
    if (dart.library.js_interop) 'schedule_run_dto_web.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'run_timeline.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2ScheduleRunsStatus { loading, content, empty, error }

/// The one summary line above the timeline: "66.7 % · 3 runs".
String scheduleRunsSummaryLine({required int succeeded, required int total}) {
  final percent = total == 0 ? 0.0 : succeeded / total * 100;
  final runs = total == 1 ? '1 run' : '$total runs';
  return '${percent.toStringAsFixed(1)} % · $runs';
}

/// The wire status of one scheduled occurrence, plus [unknown] for a value this
/// build does not recognise (which must never be shown as a success).
enum V2RunStatus {
  succeeded,
  failed,
  running,
  retryScheduled,
  skipped,
  unknown,
}

/// "1m 12s", "18s", "2h 3m". Negative or zero spans read as "<1s".
String formatRunDuration(Duration duration) {
  final total = duration.inSeconds;
  if (total <= 0) return '<1s';
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  if (hours > 0) return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
  if (minutes > 0) {
    return seconds == 0 ? '${minutes}m' : '${minutes}m ${seconds}s';
  }
  return '${seconds}s';
}

/// The plain day heading a run belongs to, relative to [now].
String runDayLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final offset = day.difference(today).inDays;
  final month = _monthShort[local.month - 1];
  if (offset == 0) return 'Today — $month ${local.day}';
  if (offset == -1) return 'Yesterday — $month ${local.day}';
  return '$month ${local.day}';
}

const _monthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

@immutable
class V2ScheduleRun {
  const V2ScheduleRun({
    required this.id,
    required this.timeLabel,
    this.durationLabel,
    required this.status,
    required this.summary,
    this.startedAt,
    this.finishedAt,
    this.scheduledFor,
    this.error,
    this.attempt = 1,
    this.ranLate = false,
    this.failureTitle,
    this.failureDetail,
    this.resultPreview,
    this.artifactName,
  });

  /// Maps one `GET /schedules/:id/runs` row onto the view model. Status and
  /// duration come from the server's own fields — nothing is assumed.
  factory V2ScheduleRun.fromDto(ScheduleRunDto dto, {DateTime? now}) {
    final started = dto.startedAt?.toLocal();
    final finished = dto.finishedAt?.toLocal();
    final at = started ?? dto.scheduledFor?.toLocal();
    final status = switch (dto.status) {
      'succeeded' => V2RunStatus.succeeded,
      'failed' => V2RunStatus.failed,
      'running' => V2RunStatus.running,
      'retry_scheduled' => V2RunStatus.retryScheduled,
      'skipped' => V2RunStatus.skipped,
      _ => V2RunStatus.unknown,
    };
    final duration = started != null && finished != null
        ? formatRunDuration(finished.difference(started))
        : started != null && status == V2RunStatus.running
        ? formatRunDuration((now ?? DateTime.now()).difference(started))
        : null;
    final error = dto.error?.trim();
    return V2ScheduleRun(
      id: dto.id,
      timeLabel: at == null ? 'Not scheduled' : _clockLabel(at),
      durationLabel: duration,
      status: status,
      // A failure's reason is rendered once, in [failureDetail]. Repeating it
      // as the summary made every failed row say the same thing twice.
      summary: status == V2RunStatus.succeeded
          ? 'Run finished.'
          : status == V2RunStatus.failed
          ? ''
          : error != null && error.isNotEmpty
          ? error
          : '',
      startedAt: started,
      finishedAt: finished,
      scheduledFor: dto.scheduledFor?.toLocal(),
      error: error,
      attempt: dto.attempt,
      ranLate: dto.ranLate,
      failureTitle: status == V2RunStatus.failed && error != null
          ? 'Run failed · $error'
          : null,
      failureDetail: status == V2RunStatus.failed ? error : null,
    );
  }

  final String id;
  final String timeLabel;

  /// "1m 12s" when the server recorded a start and finish, otherwise null.
  final String? durationLabel;
  final V2RunStatus status;
  final String summary;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? scheduledFor;
  final String? error;
  final int attempt;
  final bool ranLate;
  final String? failureTitle;
  final String? failureDetail;
  final String? resultPreview;
  final String? artifactName;

  bool get failed => status == V2RunStatus.failed;

  /// The real duration, or null when the server did not record one.
  String? durationText(DateTime now) {
    final label = durationLabel?.trim();
    if (label != null && label.isNotEmpty) return label;
    final started = startedAt;
    final finished = finishedAt;
    if (started != null && finished != null) {
      return formatRunDuration(finished.difference(started));
    }
    if (started != null && status == V2RunStatus.running) {
      return formatRunDuration(now.difference(started));
    }
    return null;
  }

  /// An honest line when the run has no result yet.
  ///
  /// A failed run with a recorded error returns an empty string: the timeline
  /// prints that error once, as the failure detail, so the row does not repeat
  /// itself. A failure with no detail still gets a truthful line from the
  /// timeline.
  String get summaryText {
    final text = summary.trim();
    if (text.isNotEmpty) return text;
    if (failed) return '';
    return switch (status) {
      V2RunStatus.running => 'Still running.',
      V2RunStatus.retryScheduled => 'Waiting to retry.',
      V2RunStatus.skipped => 'Skipped before it produced a result.',
      V2RunStatus.unknown => 'No result was recorded for this run.',
      _ => 'No result was recorded for this run.',
    };
  }
}

String _clockLabel(DateTime at) {
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${at.hour < 12 ? 'AM' : 'PM'}';
}

@immutable
class V2RunGroup {
  const V2RunGroup({required this.label, this.runs = const <V2ScheduleRun>[]});

  /// Plain date heading, e.g. "Today — May 18".
  final String label;
  final List<V2ScheduleRun> runs;
}

@immutable
class V2ScheduleRunsData {
  const V2ScheduleRunsData({
    this.status = V2ScheduleRunsStatus.content,
    this.scheduleTitle,
    this.total = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.avgRuntimeLabel = '—',
    this.groups = const <V2RunGroup>[],
    this.now,
    this.errorMessage =
        'We could not load the run history. Check your connection and try again.',
  });

  /// Builds the page state from the wire rows: newest first, grouped by day,
  /// with counts and the average runtime derived from the rows themselves.
  factory V2ScheduleRunsData.fromRuns(
    List<ScheduleRunDto> rows, {
    String? scheduleTitle,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final runs = [
      for (final row in rows) V2ScheduleRun.fromDto(row, now: clock),
    ];
    final groups = <V2RunGroup>[];
    for (final run in runs) {
      final at = run.startedAt ?? run.scheduledFor;
      final label = at == null ? 'Earlier' : runDayLabel(at, clock);
      if (groups.isNotEmpty && groups.last.label == label) {
        final last = groups.removeLast();
        groups.add(
          V2RunGroup(label: label, runs: <V2ScheduleRun>[...last.runs, run]),
        );
      } else {
        groups.add(V2RunGroup(label: label, runs: <V2ScheduleRun>[run]));
      }
    }
    final finished = [
      for (final run in runs)
        if (run.startedAt != null && run.finishedAt != null)
          run.finishedAt!.difference(run.startedAt!),
    ];
    final average = finished.isEmpty
        ? null
        : Duration(
            milliseconds:
                finished.fold<int>(
                  0,
                  (sum, value) => sum + value.inMilliseconds,
                ) ~/
                finished.length,
          );
    return V2ScheduleRunsData(
      status: runs.isEmpty
          ? V2ScheduleRunsStatus.empty
          : V2ScheduleRunsStatus.content,
      scheduleTitle: scheduleTitle,
      total: runs.length,
      succeeded: runs
          .where((run) => run.status == V2RunStatus.succeeded)
          .length,
      failed: runs.where((run) => run.failed).length,
      avgRuntimeLabel: average == null ? '—' : formatRunDuration(average),
      groups: groups,
      now: clock,
    );
  }

  final V2ScheduleRunsStatus status;

  /// The schedule these runs belong to; the page header carries its name.
  final String? scheduleTitle;
  final int total;
  final int succeeded;
  final int failed;
  final String avgRuntimeLabel;
  final List<V2RunGroup> groups;

  /// Clock used to age a running run's duration. Injected for deterministic
  /// tests; defaults to now.
  final DateTime? now;
  final String errorMessage;
}

/// The run history for one schedule: one summary line, then the timeline.
class ScheduleRunsPage extends StatelessWidget {
  const ScheduleRunsPage({
    super.key,
    required this.data,
    this.onRetryRun,
    this.onViewArtifact,
    this.onBackToSchedule,
    this.onMore,
    this.onRetry,
  });

  final V2ScheduleRunsData data;
  final ValueChanged<V2ScheduleRun>? onRetryRun;
  final ValueChanged<V2ScheduleRun>? onViewArtifact;
  final VoidCallback? onBackToSchedule;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;

  /// The day label each run belongs to, keyed by run id, so the timeline keeps
  /// the history's own grouping.
  Map<String, String> get _dayLabels => {
    for (final group in data.groups)
      for (final run in group.runs) run.id: group.label,
  };

  V2ScheduleRun? _runById(String id) {
    for (final group in data.groups) {
      for (final run in group.runs) {
        if (run.id == id) return run;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final name = data.scheduleTitle?.trim() ?? '';
    return OScreen(
      title: name.isEmpty ? 'Schedule runs' : name,
      showBack: true,
      actions: [
        if (onMore != null)
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: onMore,
          ),
      ],
      child: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (data.status) {
            V2ScheduleRunsStatus.loading => const OSkeletonList(rows: 6),
            V2ScheduleRunsStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: onRetry,
            ),
            V2ScheduleRunsStatus.empty => RunTimeline(
              data: const V2RunTimelineData(status: V2RunTimelineStatus.empty),
              onBackToSchedule: onBackToSchedule,
            ),
            V2ScheduleRunsStatus.content =>
              data.groups.isEmpty
                  ? RunTimeline(
                      data: const V2RunTimelineData(
                        status: V2RunTimelineStatus.empty,
                      ),
                      onBackToSchedule: onBackToSchedule,
                    )
                  : _content(c),
          },
        ),
      ),
    );
  }

  Widget _content(OColors c) {
    final runs = [for (final group in data.groups) ...group.runs];
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      children: [
        Text(
          scheduleRunsSummaryLine(succeeded: data.succeeded, total: data.total),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.bodySm.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: OSpace.l),
        RunTimeline(
          data: V2RunTimelineData(runs: _timelineRuns(runs)),
          onOpenArtifact: onViewArtifact == null
              ? null
              : (run) {
                  final source = _runById(run.id);
                  if (source != null) onViewArtifact!(source);
                },
          onRetryRun: onRetryRun == null
              ? null
              : (run) {
                  final source = _runById(run.id);
                  if (source != null) onRetryRun!(source);
                },
          onBackToSchedule: onBackToSchedule,
        ),
      ],
    );
  }

  List<V2TimelineRun> _timelineRuns(List<V2ScheduleRun> runs) {
    final labels = _dayLabels;
    final now = data.now ?? DateTime.now();
    final out = <V2TimelineRun>[];
    for (final run in runs) {
      final rawDetail = run.failed
          ? run.failureDetail ?? run.failureTitle
          : null;
      final detail = rawDetail?.trim().isNotEmpty == true ? rawDetail : null;
      final summary = run.summaryText;
      out.add(
        V2TimelineRun(
          id: run.id,
          dayLabel: labels[run.id] ?? '',
          timeLabel: run.timeLabel,
          durationLabel: run.durationText(now),
          outcome: _outcomeOf(run.status),
          // Never print the same reason as both the summary and the detail.
          summary: detail != null && _sameLine(detail, summary) ? '' : summary,
          statusLabel: run.status == V2RunStatus.retryScheduled
              ? 'Retry scheduled'
              : null,
          artifactName: run.artifactName,
          failureDetail: detail,
        ),
      );
    }
    return out;
  }

  bool _sameLine(String a, String b) =>
      a.trim().toLowerCase() == b.trim().toLowerCase();

  V2RunOutcome _outcomeOf(V2RunStatus status) => switch (status) {
    V2RunStatus.succeeded => V2RunOutcome.succeeded,
    V2RunStatus.failed => V2RunOutcome.failed,
    V2RunStatus.running => V2RunOutcome.running,
    V2RunStatus.retryScheduled => V2RunOutcome.running,
    V2RunStatus.skipped => V2RunOutcome.skipped,
    V2RunStatus.unknown => V2RunOutcome.unknown,
  };
}
