import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): extract this widget's English copy during the ARB pass.

/// The four states a run history list can be in.
enum V2RunTimelineStatus { loading, content, empty, error }

/// How a single scheduled run ended.
enum V2RunOutcome { succeeded, failed }

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
    required this.durationLabel,
    required this.outcome,
    required this.summary,
    this.artifactName,
    this.failureDetail,
  });

  final String id;

  /// Plain date heading this run belongs to, e.g. "Today — May 18".
  final String dayLabel;

  /// Clock label for when the run started, e.g. "9:00 AM".
  final String timeLabel;

  /// How long the run took, e.g. "1m 12s".
  final String durationLabel;

  final V2RunOutcome outcome;

  /// One line describing what happened, e.g. "Saved 12 items to daily.md".
  final String summary;

  /// A file the run produced. When set, the row offers a link to open it.
  final String? artifactName;

  /// Plain-English reason shown under a failed run.
  final String? failureDetail;

  bool get failed => outcome == V2RunOutcome.failed;

  String get outcomeLabel => failed ? 'Failed' : 'Completed';
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
  List<V2TimelineDay> get days {
    final groups = <V2TimelineDay>[];
    for (final run in runs) {
      if (groups.isNotEmpty && groups.last.label == run.dayLabel) {
        final last = groups.removeLast();
        groups.add(V2TimelineDay(label: last.label, runs: [...last.runs, run]));
      } else {
        groups.add(V2TimelineDay(label: run.dayLabel, runs: [run]));
      }
    }
    return groups;
  }
}

/// A schedule's run history as a vertical timeline.
///
/// Each day is a heading plus a rail of runs. A run shows a status dot, when
/// it started, how long it took, what it did, a link to any file it made and a
/// retry action when it failed.
///
/// The widget is a section, not a page: it returns a [Column] in the content
/// state and never owns scrolling, so a host can place it inside its own list.
/// All data is injected; callbacks leave the widget.
class RunTimeline extends StatelessWidget {
  const RunTimeline({
    super.key,
    required this.data,
    this.onOpenArtifact,
    this.onRetryRun,
    this.onRetry,
    this.onBackToSchedule,
  });

  final V2RunTimelineData data;

  /// Open the file a successful run made.
  final ValueChanged<V2TimelineRun>? onOpenArtifact;

  /// Run a failed job again now.
  final ValueChanged<V2TimelineRun>? onRetryRun;

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
      message:
          'When this schedule runs, you will see the result and any files it made right here.',
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
              onRetryRun: onRetryRun,
            ),
          ],
        ],
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, this.onOpenArtifact, this.onRetryRun});

  final V2TimelineDay day;
  final ValueChanged<V2TimelineRun>? onOpenArtifact;
  final ValueChanged<V2TimelineRun>? onRetryRun;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final count = day.runs.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
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
              '$count ${count == 1 ? 'run' : 'runs'}',
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ),
        const SizedBox(height: OSpace.s),
        OStagger(
          children: [
            for (var i = 0; i < day.runs.length; i++)
              _RunRow(
                run: day.runs[i],
                isLast: i == day.runs.length - 1,
                onOpenArtifact: onOpenArtifact,
                onRetryRun: onRetryRun,
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
    this.onRetryRun,
  });

  final V2TimelineRun run;
  final bool isLast;
  final ValueChanged<V2TimelineRun>? onOpenArtifact;
  final ValueChanged<V2TimelineRun>? onRetryRun;

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
                          const SizedBox(height: OSpace.xs),
                          Text(
                            run.summary,
                            style: OType.bodySm.copyWith(color: c.text),
                          ),
                          if (run.failureDetail != null) ...[
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
                  if (run.failed) ...[
                    const SizedBox(height: OSpace.s),
                    OButton(
                      label: 'Retry run',
                      icon: Icons.replay_rounded,
                      variant: OButtonVariant.secondary,
                      expand: true,
                      onPressed: onRetryRun == null
                          ? null
                          : () => onRetryRun!(run),
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

  /// Time and duration wrap onto separate lines instead of squeezing at
  /// 320 dp or 200 % text.
  Widget _metaLine(OColors c) {
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
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
              run.durationLabel,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ],
    );
  }

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
    final detail = run.failureDetail;
    return '${run.outcomeLabel} run at ${run.timeLabel}, '
        'took ${run.durationLabel}. ${run.summary}'
        '${detail == null ? '' : ' $detail'}';
  }
}

/// A status dot with a shape cue: a check for success, a cross for failure.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.run});

  final V2TimelineRun run;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = run.failed ? c.danger : c.success;
    return Container(
      key: ValueKey<String>('run-status-${run.id}'),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Icon(
        run.failed ? Icons.close_rounded : Icons.check_rounded,
        size: 12,
        color: color,
      ),
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
