import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'run_timeline.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2ScheduleRunsStatus { loading, content, empty, error }

enum V2RunStatus { succeeded, failed }

enum V2RunsFilter { all, succeeded, failed }

@immutable
class V2ScheduleRun {
  const V2ScheduleRun({
    required this.id,
    required this.timeLabel,
    required this.durationLabel,
    required this.status,
    required this.summary,
    this.failureTitle,
    this.failureDetail,
    this.resultPreview,
    this.artifactName,
  });

  final String id;
  final String timeLabel;
  final String durationLabel;
  final V2RunStatus status;
  final String summary;
  final String? failureTitle;
  final String? failureDetail;
  final String? resultPreview;
  final String? artifactName;
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
    this.sessionTitle,
    this.total = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.avgRuntimeLabel = '—',
    this.groups = const <V2RunGroup>[],
    this.errorMessage =
        'We could not load the run history. Check your connection and try again.',
  });

  final V2ScheduleRunsStatus status;

  /// The schedule these runs belong to, shown above the stats.
  final String? scheduleTitle;

  /// The chat the schedule runs in, shown for context.
  final String? sessionTitle;
  final int total;
  final int succeeded;
  final int failed;
  final String avgRuntimeLabel;
  final List<V2RunGroup> groups;
  final String errorMessage;
}

/// The run history for one schedule, grouped by day.
class ScheduleRunsPage extends StatefulWidget {
  const ScheduleRunsPage({
    super.key,
    required this.data,
    this.onRetryRun,
    this.onOpenChat,
    this.onViewArtifact,
    this.onBackToSchedule,
    this.onMore,
    this.onRetry,
  });

  final V2ScheduleRunsData data;
  final ValueChanged<V2ScheduleRun>? onRetryRun;
  final ValueChanged<V2ScheduleRun>? onOpenChat;
  final ValueChanged<V2ScheduleRun>? onViewArtifact;
  final VoidCallback? onBackToSchedule;
  final VoidCallback? onMore;
  final VoidCallback? onRetry;

  @override
  State<ScheduleRunsPage> createState() => _ScheduleRunsPageState();
}

class _ScheduleRunsPageState extends State<ScheduleRunsPage> {
  V2RunsFilter _filter = V2RunsFilter.all;

  List<V2ScheduleRun> get _filteredRuns {
    if (_filter == V2RunsFilter.all) {
      return [for (final group in widget.data.groups) ...group.runs];
    }
    final wanted = _filter == V2RunsFilter.succeeded
        ? V2RunStatus.succeeded
        : V2RunStatus.failed;
    return [
      for (final group in widget.data.groups)
        ...group.runs.where((run) => run.status == wanted),
    ];
  }

  /// The day label each run belongs to, keyed by run id, so the timeline keeps
  /// the history's own grouping.
  Map<String, String> get _dayLabels => {
    for (final group in widget.data.groups)
      for (final run in group.runs) run.id: group.label,
  };

  V2ScheduleRun? _runById(String id) {
    for (final group in widget.data.groups) {
      for (final run in group.runs) {
        if (run.id == id) return run;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final session = widget.data.sessionTitle;
    return OScaffold(
      appBar: OAppBar(
        title: 'Schedule runs',
        subtitle: session != null && session.trim().isNotEmpty
            ? 'Source session: $session'
            : null,
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'More options',
            onPressed: widget.onMore,
          ),
        ],
      ),
      body: OFadeSlide(
        child: OAnimatedSwap(
          child: switch (widget.data.status) {
            V2ScheduleRunsStatus.loading => const OSkeletonList(rows: 6),
            V2ScheduleRunsStatus.error => OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
            V2ScheduleRunsStatus.empty => _empty(c),
            V2ScheduleRunsStatus.content =>
              widget.data.groups.isEmpty ? _empty(c) : _content(c),
          },
        ),
      ),
    );
  }

  Widget _empty(OColors c) {
    final empty = RunTimeline(
      data: const V2RunTimelineData(status: V2RunTimelineStatus.empty),
      onBackToSchedule: widget.onBackToSchedule,
    );
    if (!_hasContext) return empty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _contextCard(c),
        const SizedBox(height: OSpace.xl),
        empty,
      ],
    );
  }

  bool get _hasContext {
    final title = widget.data.scheduleTitle;
    return title != null && title.trim().isNotEmpty;
  }

  /// The schedule these runs belong to, above the stats. The chat it runs in
  /// is named in the app bar.
  Widget _contextCard(OColors c) {
    final title = widget.data.scheduleTitle!;
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              Icons.calendar_month_rounded,
              size: 20,
              color: c.accent,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SCHEDULE',
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(OColors c) {
    final runs = _filteredRuns;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        if (_hasContext) ...[_contextCard(c), const SizedBox(height: OSpace.m)],
        _summary(c),
        const SizedBox(height: OSpace.m),
        _filters(),
        const SizedBox(height: OSpace.l),
        if (runs.isEmpty)
          OEmptyState(
            compact: true,
            icon: Icons.filter_alt_off_rounded,
            title: _filter == V2RunsFilter.failed
                ? 'No failed runs'
                : 'No succeeded runs',
            message: 'Try another filter to see the rest of the history.',
            action: OButton(
              label: 'Show all runs',
              variant: OButtonVariant.secondary,
              onPressed: () => setState(() => _filter = V2RunsFilter.all),
            ),
          )
        else
          RunTimeline(
            data: V2RunTimelineData(runs: _timelineRuns(runs)),
            onOpenArtifact: (run) {
              final source = _runById(run.id);
              if (source != null) widget.onViewArtifact?.call(source);
            },
            onRetryRun: (run) {
              final source = _runById(run.id);
              if (source != null) widget.onRetryRun?.call(source);
            },
            onBackToSchedule: widget.onBackToSchedule,
          ),
      ],
    );
  }

  List<V2TimelineRun> _timelineRuns(List<V2ScheduleRun> runs) {
    final labels = _dayLabels;
    return [
      for (final run in runs)
        V2TimelineRun(
          id: run.id,
          dayLabel: labels[run.id] ?? '',
          timeLabel: run.timeLabel,
          durationLabel: run.durationLabel,
          outcome: run.status == V2RunStatus.succeeded
              ? V2RunOutcome.succeeded
              : V2RunOutcome.failed,
          summary: run.summary,
          artifactName: run.artifactName,
          failureDetail: run.failureDetail ?? run.failureTitle,
        ),
    ];
  }

  Widget _summary(OColors c) {
    final data = widget.data;
    final percent = data.total == 0 ? 0.0 : data.succeeded / data.total * 100;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${data.total} runs · ${data.succeeded} succeeded · ${data.failed} failed',
            style: OType.h3.copyWith(color: c.text),
          ),
          const SizedBox(height: OSpace.m),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Container(
              height: 6,
              color: c.surfaceRaised,
              child: Row(
                children: [
                  if (data.succeeded > 0)
                    Expanded(
                      flex: data.succeeded,
                      child: Container(color: c.success),
                    ),
                  if (data.failed > 0)
                    Expanded(
                      flex: data.failed,
                      child: Container(color: c.danger),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: OSpace.s),
          Wrap(
            spacing: OSpace.m,
            runSpacing: OSpace.xs,
            children: [
              Text(
                '${percent.toStringAsFixed(1)}% success',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              Text(
                'Avg runtime ${data.avgRuntimeLabel}',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filters() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          OChip(
            label: 'All (${widget.data.total})',
            icon: Icons.apps_rounded,
            selected: _filter == V2RunsFilter.all,
            onTap: () => setState(() => _filter = V2RunsFilter.all),
          ),
          const SizedBox(width: OSpace.s),
          OChip(
            label: 'Succeeded (${widget.data.succeeded})',
            icon: Icons.check_circle_outline_rounded,
            selected: _filter == V2RunsFilter.succeeded,
            onTap: () => setState(() => _filter = V2RunsFilter.succeeded),
          ),
          const SizedBox(width: OSpace.s),
          OChip(
            label: 'Failed (${widget.data.failed})',
            icon: Icons.error_outline_rounded,
            selected: _filter == V2RunsFilter.failed,
            onTap: () => setState(() => _filter = V2RunsFilter.failed),
          ),
        ],
      ),
    );
  }
}
