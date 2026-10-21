import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
    this.total = 0,
    this.succeeded = 0,
    this.failed = 0,
    this.avgRuntimeLabel = '—',
    this.groups = const <V2RunGroup>[],
    this.errorMessage = 'We could not load the run history. Check your connection and try again.',
  });

  final V2ScheduleRunsStatus status;
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
  final Set<String> _expanded = <String>{};

  List<V2RunGroup> get _filteredGroups {
    if (_filter == V2RunsFilter.all) return widget.data.groups;
    final wanted = _filter == V2RunsFilter.succeeded
        ? V2RunStatus.succeeded
        : V2RunStatus.failed;
    return [
      for (final group in widget.data.groups)
        if (group.runs.any((run) => run.status == wanted))
          V2RunGroup(
            label: group.label,
            runs: group.runs.where((run) => run.status == wanted).toList(),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Schedule runs',
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
            V2ScheduleRunsStatus.content => widget.data.groups.isEmpty
                ? _empty(c)
                : _content(c),
          },
        ),
      ),
    );
  }

  Widget _empty(OColors c) {
    return OEmptyState(
      icon: Icons.history_rounded,
      title: 'No runs yet',
      message:
          'When this schedule runs, you will see the result and any files it made right here.',
      action: OButton(
        label: 'Back to schedule',
        icon: Icons.arrow_back_rounded,
        onPressed: widget.onBackToSchedule,
      ),
    );
  }

  Widget _content(OColors c) {
    final groups = _filteredGroups;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xxl,
      ),
      children: [
        _summary(c),
        const SizedBox(height: OSpace.m),
        _filters(),
        const SizedBox(height: OSpace.l),
        if (groups.isEmpty)
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
          for (final group in groups) ...[
            _groupHeader(c, group),
            const SizedBox(height: OSpace.s),
            OStagger(
              children: [
                for (final run in group.runs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: OSpace.m),
                    child: _runCard(c, run),
                  ),
              ],
            ),
            const SizedBox(height: OSpace.s),
          ],
      ],
    );
  }

  Widget _summary(OColors c) {
    final data = widget.data;
    final percent = data.total == 0
        ? 0.0
        : data.succeeded / data.total * 100;
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

  Widget _groupHeader(OColors c, V2RunGroup group) {
    return Row(
      children: [
        Expanded(
          child: Text(
            group.label.toUpperCase(),
            style: OType.overline.copyWith(color: c.textMuted),
          ),
        ),
        Text(
          '${group.runs.length} ${group.runs.length == 1 ? 'run' : 'runs'}',
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }

  Widget _runCard(OColors c, V2ScheduleRun run) {
    final failed = run.status == V2RunStatus.failed;
    final expanded = _expanded.contains(run.id);
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      onTap: failed ? () => _toggle(run.id) : null,
      semanticLabel: '${run.timeLabel}, ${failed ? 'failed' : 'completed'}. ${run.summary}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: failed
                      ? c.danger.withValues(alpha: 0.12)
                      : c.success.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  failed ? Icons.close_rounded : Icons.check_rounded,
                  size: 16,
                  color: failed ? c.danger : c.success,
                ),
              ),
              Text(
                run.timeLabel,
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '•',
                style: OType.caption.copyWith(color: c.textFaint),
              ),
              Text(
                run.durationLabel,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              OPill(
                label: failed ? 'Failed' : 'Completed',
                tone: failed ? OPillTone.danger : OPillTone.success,
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(
            run.summary,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          if (failed) ...[
            const SizedBox(height: OSpace.xs),
            Text(
              run.failureTitle ?? 'Last run failed. Your rule is still saved.',
              style: OType.caption.copyWith(
                color: c.danger,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (expanded) ...[
              const SizedBox(height: OSpace.s),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(ORadius.s),
                  border: Border.all(
                    color: c.danger.withValues(alpha: 0.30),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 15,
                          color: c.danger,
                        ),
                        const SizedBox(width: OSpace.xs),
                        Flexible(
                          child: Text(
                            'What happened',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(
                              color: c.danger,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      run.failureDetail ??
                          'Ovid could not finish this run. Your schedule is still saved and will try again.',
                      style: OType.caption.copyWith(color: c.danger),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: OSpace.m),
              Wrap(
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OButton(
                    label: 'Retry now',
                    icon: Icons.replay_rounded,
                    onPressed: () => widget.onRetryRun?.call(run),
                  ),
                  TextButton(
                    onPressed: () => _toggle(run.id),
                    child: Text(
                      'Hide details',
                      style: OType.label.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
            ] else ...[
              const SizedBox(height: OSpace.xs),
              TextButton(
                onPressed: () => _toggle(run.id),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        'Show details',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.label.copyWith(color: c.danger),
                      ),
                    ),
                    const SizedBox(width: OSpace.xs),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: c.danger,
                    ),
                  ],
                ),
              ),
            ],
          ],
          if (!failed && run.resultPreview != null) ...[
            const SizedBox(height: OSpace.s),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(OSpace.m),
              decoration: BoxDecoration(
                color: c.codeBg,
                borderRadius: BorderRadius.circular(ORadius.s),
                border: Border.all(color: c.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'RESULT',
                          style: OType.overline.copyWith(color: c.textFaint),
                        ),
                      ),
                      Icon(
                        Icons.terminal_rounded,
                        size: 14,
                        color: c.textFaint,
                      ),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    run.resultPreview!,
                    style: OType.mono.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(height: OSpace.s),
            _runActions(run),
          ],
        ],
      ),
    );
  }

  /// Open chat / view artifact. Side by side normally; one per row when the
  /// text scale would otherwise squeeze each label to a few characters.
  Widget _runActions(V2ScheduleRun run) {
    final actions = <Widget>[
      OButton(
        label: 'Open chat',
        icon: Icons.chat_bubble_outline_rounded,
        expand: true,
        onPressed: () => widget.onOpenChat?.call(run),
      ),
      if (run.artifactName != null)
        OButton(
          label: 'View artifact',
          icon: Icons.description_outlined,
          variant: OButtonVariant.secondary,
          expand: true,
          onPressed: () => widget.onViewArtifact?.call(run),
        ),
    ];
    if (MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) const SizedBox(height: OSpace.s),
            actions[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: actions.first),
        if (actions.length > 1) ...[
          const SizedBox(width: OSpace.s),
          Expanded(child: actions[1]),
        ],
      ],
    );
  }

  void _toggle(String id) {
    setState(() {
      if (!_expanded.add(id)) _expanded.remove(id);
    });
  }
}
