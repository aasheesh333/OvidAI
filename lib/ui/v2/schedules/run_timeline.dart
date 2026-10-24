import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this widget's English copy during the ARB pass.

/// The four states a run history list can be in.
enum V2RunTimelineStatus { loading, content, empty, error }

/// How a single scheduled run ended. [unknown] is a run the server recorded
/// without an outcome — it must never be painted as a success.
enum V2RunOutcome { succeeded, failed, running, skipped, unknown }

/// One run on the vertical history rail.
///
/// [dayLabel] groups consecutive runs (for example "Today — May 18"). The
/// widget keeps the caller's order, so pass runs newest first.
@immutable
class V2TimelineRun {
  const V2TimelineRun({
    required this.id,
    required this.dayLabel,
    required this.timeLabel,
    this.durationLabel,
    required this.outcome,
    required this.summary,
    this.statusLabel,
    this.artifactName,
    this.failureDetail,
  });

  final String id;

  /// Plain date heading this run belongs to, e.g. "Today — May 18".
  final String dayLabel;

  /// Clock label for when the run started, e.g. "9:00 AM".
  final String timeLabel;

  /// How long the run took, e.g. "1m 12s". Null when the server did not record
  /// both a start and a finish; the row says so instead of inventing a value.
  final String? durationLabel;

  final V2RunOutcome outcome;

  /// One line describing what happened, e.g. "Saved 12 items to daily.md".
  /// Empty when the run produced no result yet.
  final String summary;

  /// Overrides the default status word, e.g. "Retry scheduled".
  final String? statusLabel;

  /// A file the run produced. When set, the row offers a link to open it.
  final String? artifactName;

  /// Plain-English reason shown under a failed run.
  final String? failureDetail;

  bool get failed => outcome == V2RunOutcome.failed;
  bool get succeeded => outcome == V2RunOutcome.succeeded;
  bool get running => outcome == V2RunOutcome.running;

  /// Only a run that already finished badly offers the action. A run still in
  /// flight has no result yet, so there is nothing to run again.
  bool get canRunNow => failed && !running;

  String get outcomeLabel =>
      statusLabel ??
      switch (outcome) {
        V2RunOutcome.succeeded => 'Completed',
        V2RunOutcome.failed => 'Failed',
        V2RunOutcome.running => 'Running',
        V2RunOutcome.skipped => 'Skipped',
        V2RunOutcome.unknown => 'No result',
      };

  /// The summary, or an honest line when the run has no result yet.
  ///
  /// Empty when a failed run already prints its reason in [failureDetail]: one
  /// row never states the same thing twice. A failure with no detail still
  /// says so.
  String get summaryLabel {
    final text = summary.trim();
    if (text.isNotEmpty) return text;
    if (failed && failureDetail?.trim().isNotEmpty == true) return '';
    return switch (outcome) {
      V2RunOutcome.running => 'Still running.',
      V2RunOutcome.skipped => 'Skipped before it produced a result.',
      V2RunOutcome.failed => 'Failed without a summary.',
      _ => 'No result was recorded for this run.',
    };
  }

  String get durationText => durationLabel?.trim().isNotEmpty == true
      ? durationLabel!
      : 'Not recorded';
}

/// A consecutive set of runs that share a [V2TimelineRun.dayLabel].
@immutable
class V2TimelineDay {
  const V2TimelineDay({required this.label, required this.runs});

  final String label;
  final List<V2TimelineRun> runs;
}

/// Immutable state for [RunTimeline].
@immutable
class V2RunTimelineData {
  const V2RunTimelineData({
    this.status = V2RunTimelineStatus.content,
    this.runs = const <V2TimelineRun>[],
    this.errorMessage =
        'We could not load the run history. Check your connection and try again.',
  });

  final V2RunTimelineStatus status;

  /// Runs in display order. Consecutive runs with the same day label form one
  /// group on the rail.
  final List<V2TimelineRun> runs;

  final String errorMessage;

  /// Runs bucketed into consecutive day groups. Empty groups are dropped.
  ///
  /// Accumulates into one list per day. The previous version rebuilt the
  /// group list on every run, which was O(n²) for a single long day.
  List<V2TimelineDay> get days {
    final groups = <V2TimelineDay>[];
    List<V2TimelineRun>? current;
    var label = '';
    for (final run in runs) {
      if (current != null && label == run.dayLabel) {
        current.add(run);
      } else {
        label = run.dayLabel;
        current = <V2TimelineRun>[run];
        groups.add(V2TimelineDay(label: label, runs: current));
      }
    }
    return groups;
  }
}

/// A schedule's run history as a vertical timeline.
///
/// Each day is a heading plus a rail of runs. A run shows a status dot, when
/// it started, how long it took, what it did, a link to any file it made and,
/// when it failed, a run-now action that starts a fresh run.
///
/// The widget is a section, not a page: it returns a [Column] in the content
/// state and never owns scrolling, so a host can place it inside its own list.
/// All data is injected; callbacks leave the widget.
class RunTimeline extends StatelessWidget {
  const RunTimeline({
    super.key,
    required this.data,
    this.onOpenArtifact,
    this.onRunNow,
    this.onRetry,
    this.onBackToSchedule,
  });

  final V2RunTimelineData data;

  /// Open the file a successful run made.
  final ValueChanged<V2TimelineRun>? onOpenArtifact;

  /// Start a new run of the schedule now. This never re-attempts the failed
  /// occurrence above: the server has no per-run retry, so a fresh run starts.
  final ValueChanged<V2TimelineRun>? onRunNow;

  /// Reload the history after an error.
  final VoidCallback? onRetry;

  /// Leave the history when there is nothing to show yet.
  final VoidCallback? onBackToSchedule;

  @override
  Widget build(BuildContext context) {
    final groups = data.days;
    return switch (data.status) {
      V2RunTimelineStatus.loading => const _TimelineSkeleton(),
      V2RunTimelineStatus.error => OErrorState(
        message: data.errorMessage,
        onRetry: onRetry,
      ),
      V2RunTimelineStatus.empty => _empty(),
      V2RunTimelineStatus.content =>
        groups.isEmpty ? _empty() : _content(groups),
    };
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.history_rounded,
      title: 'No runs yet',
      message: 'Results and files appear here after a run.',
      action: OButton(
        label: 'Back to schedule',
        icon: Icons.arrow_back_rounded,
        onPressed: onBackToSchedule,
      ),
    );
  }

  Widget _content(List<V2TimelineDay> groups) {
    return OFadeSlide(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < groups.length; i++) ...[
            if (i > 0) const SizedBox(height: OSpace.m),
            _DayGroup(
              day: groups[i],
              onOpenArtifact: onOpenArtifact,
              onRunNow: onRunNow,
            ),
          ],
        ],
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, this.onOpenArtifact, this.onRunNow});

  final V2TimelineDay day;
  final ValueChanged<V2TimelineRun>? onOpenArtifact;
  final ValueChanged<V2TimelineRun>? onRunNow;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final count = day.runs.length;
    final countLabel = '$count ${count == 1 ? 'run' : 'runs'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One node per day so a screen reader hears the date and its count
        // together, then the runs in visual order.
        Semantics(
          container: true,
          header: true,
          label: '${day.label}, $countLabel',
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    day.label.toUpperCase(),
                    style: OType.overline.copyWith(color: c.textMuted),
                  ),
                ),
                const SizedBox(width: OSpace.s),
                Text(
                  countLabel,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: OSpace.s),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < day.runs.length; i++)
              if (i >= 8)
                _RunRow(
                  run: day.runs[i],
                  isLast: i == day.runs.length - 1,
                  onOpenArtifact: onOpenArtifact,
                  onRunNow: onRunNow,
                )
              else
                // A day can hold hundreds of runs; only the first screenful
                // gets an entrance delay.
                OFadeSlide(
                  delay: OMotion.stagger * i > const Duration(milliseconds: 400)
                      ? const Duration(milliseconds: 400)
                      : OMotion.stagger * i,
                  child: _RunRow(
                    run: day.runs[i],
                    isLast: i == day.runs.length - 1,
                    onOpenArtifact: onOpenArtifact,
                    onRunNow: onRunNow,
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({
    required this.run,
    required this.isLast,
    this.onOpenArtifact,
    this.onRunNow,
  });

  final V2TimelineRun run;
  final bool isLast;
  final ValueChanged<V2TimelineRun>? onOpenArtifact;
  final ValueChanged<V2TimelineRun>? onRunNow;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                _StatusDot(run: run),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: c.hairline)),
              ],
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? OSpace.m : OSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    container: true,
                    label: _semanticLabel(run),
                    child: ExcludeSemantics(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _metaLine(c),
                          if (run.summaryLabel.isNotEmpty) ...[
                            const SizedBox(height: OSpace.xs),
                            Text(
                              run.summaryLabel,
                              style: OType.bodySm.copyWith(
                                color:
                                    run.outcome == V2RunOutcome.unknown ||
                                        run.outcome == V2RunOutcome.skipped
                                    ? c.textMuted
                                    : c.text,
                              ),
                            ),
                          ],
                          if (run.failed &&
                              run.failureDetail?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: OSpace.xs),
                            _failureLine(c, run.failureDetail!),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (run.artifactName != null) ...[
                    const SizedBox(height: OSpace.s),
                    _ArtifactLink(
                      name: run.artifactName!,
                      onTap: onOpenArtifact == null
                          ? null
                          : () => onOpenArtifact!(run),
                    ),
                  ],
                  if (run.canRunNow) ...[
                    const SizedBox(height: OSpace.s),
                    OButton(
                      label: 'Run now',
                      icon: Icons.play_arrow_rounded,
                      variant: OButtonVariant.secondary,
                      expand: true,
                      onPressed: onRunNow == null
                          ? null
                          : () => onRunNow!(run),
                    ),
                    const SizedBox(height: OSpace.xs),
                    // The server has no per-run retry: this action starts a
                    // fresh run, so the row says so instead of implying that
                    // the failed occurrence above is attempted again.
                    Text(
                      'Starts a new run.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Time, status and duration wrap onto separate lines instead of squeezing at
  /// 320 dp or 200 % text. Every run states its real outcome; a run the server
  /// recorded without a result says so instead of showing a tick.
  Widget _metaLine(OColors c) {
    final color = _outcomeColor(c);
    final recorded = run.durationLabel?.trim().isNotEmpty == true;
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          key: ValueKey<String>('run-outcome-${run.id}'),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(ORadius.pill),
          ),
          child: Text(
            run.outcomeLabel,
            style: OType.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 13, color: c.textFaint),
            const SizedBox(width: OSpace.xs),
            Text(
              run.timeLabel,
              style: OType.mono.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, size: 13, color: c.textFaint),
            const SizedBox(width: OSpace.xs),
            Text(
              run.durationText,
              style: OType.caption.copyWith(
                color: recorded ? c.textMuted : c.textFaint,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Color _outcomeColor(OColors c) => _runOutcomeColor(c, run.outcome);

  Widget _failureLine(OColors c, String detail) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 14, color: c.danger),
        const SizedBox(width: OSpace.xs),
        Expanded(
          child: Text(detail, style: OType.caption.copyWith(color: c.danger)),
        ),
      ],
    );
  }

  String _semanticLabel(V2TimelineRun run) {
    final rawDetail = run.failed ? run.failureDetail : null;
    final detail = rawDetail?.trim().isNotEmpty == true ? rawDetail : null;
    final recorded = run.durationLabel?.trim().isNotEmpty == true;
    final duration = recorded
        ? 'took ${run.durationLabel}'
        : 'duration not recorded';
    return '${run.outcomeLabel} run at ${run.timeLabel}, $duration. '
        '${run.summaryLabel}'
        '${detail == null ? '' : ' $detail'}';
  }
}

Color _runOutcomeColor(OColors c, V2RunOutcome outcome) => switch (outcome) {
  V2RunOutcome.succeeded => c.success,
  V2RunOutcome.failed => c.danger,
  V2RunOutcome.running => c.accent,
  V2RunOutcome.skipped => c.warn,
  V2RunOutcome.unknown => c.textMuted,
};

/// A status dot with a shape cue: a check for success, a cross for failure, a
/// cycle for a run still in flight and a dash for a run with no result.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.run});

  final V2TimelineRun run;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = _runOutcomeColor(c, run.outcome);
    final icon = switch (run.outcome) {
      V2RunOutcome.succeeded => Icons.check_rounded,
      V2RunOutcome.failed => Icons.close_rounded,
      V2RunOutcome.running => Icons.autorenew_rounded,
      V2RunOutcome.skipped => Icons.skip_next_rounded,
      V2RunOutcome.unknown => Icons.help_outline_rounded,
    };
    return Container(
      key: ValueKey<String>('run-status-${run.id}'),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Icon(icon, size: 16, color: color),
    );
  }
}

/// A file the run made, as a full-width 48 dp link.
class _ArtifactLink extends StatelessWidget {
  const _ArtifactLink({required this.name, this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    // One clean label: the file name and the icon are decorative once the
    // label says what opening the link does.
    return Semantics(
      label: 'Open artifact $name',
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      child: OPressable(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
                border: Border.all(color: c.hairline),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.description_outlined, size: 16, color: c.accent),
                  const SizedBox(width: OSpace.s),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.label.copyWith(color: c.accent),
                    ),
                  ),
                  const SizedBox(width: OSpace.xs),
                  Icon(Icons.open_in_new_rounded, size: 14, color: c.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet placeholder for the first load. Does not own scrolling because the
/// host list does.
class _TimelineSkeleton extends StatelessWidget {
  const _TimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: OSkeleton(width: 120, height: 11),
        ),
        const SizedBox(height: OSpace.l),
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: OSpace.xl),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const OSkeleton(width: 22, height: 22, radius: ORadius.pill),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const OSkeleton(width: 104, height: 11),
                    const SizedBox(height: OSpace.s),
                    OSkeleton(width: i.isEven ? 220 : 180, height: 12),
                    const SizedBox(height: OSpace.xs),
                    const OSkeleton(width: 148, height: 12),
                  ],
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
