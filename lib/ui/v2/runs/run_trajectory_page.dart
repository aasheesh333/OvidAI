import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'timeline.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2RunTrajectoryStatus { loading, empty, error, ready }

enum V2RunStepKind { message, plan, search, write, preview, finish }

/// Where a subagent launch ended up.
enum V2SubagentLaunchStatus { running, completed, failed, timedOut, cancelled }

/// One subagent the main agent launched during the run.
@immutable
class V2SubagentLaunch {
  const V2SubagentLaunch({
    required this.id,
    required this.agentName,
    required this.taskSummary,
    required this.timeLabel,
    required this.durationLabel,
    this.startedAt,
    this.status = V2SubagentLaunchStatus.completed,
    this.statusLabel,
  });

  final String id;

  /// The agent preset or role the main agent dispatched, e.g. "Frontend
  /// builder".
  final String agentName;

  /// One line describing what the subagent was asked to do.
  final String taskSummary;

  /// Clock label for when the launch happened, e.g. "10:41".
  final String timeLabel;

  /// How long the subagent ran, e.g. "4m 12s".
  final String durationLabel;

  /// When the launch happened. Used to order the timeline; null keeps the
  /// caller's order.
  final DateTime? startedAt;

  final V2SubagentLaunchStatus status;

  /// Overrides the default label for [status] when the runtime reports one.
  final String? statusLabel;

  String get effectiveStatusLabel =>
      statusLabel ??
      switch (status) {
        V2SubagentLaunchStatus.running => 'Running',
        V2SubagentLaunchStatus.completed => 'Completed',
        V2SubagentLaunchStatus.failed => 'Failed',
        V2SubagentLaunchStatus.timedOut => 'Timed out',
        V2SubagentLaunchStatus.cancelled => 'Cancelled',
      };
}

/// A source the run looked at, shown as a chip under a step.
@immutable
class V2RunSource {
  const V2RunSource({required this.label, this.icon = Icons.public_rounded});

  final String label;
  final IconData icon;
}

/// One step in the run timeline.
@immutable
class V2RunStep {
  const V2RunStep({
    required this.id,
    required this.title,
    required this.detail,
    required this.durationLabel,
    this.kind = V2RunStepKind.message,
    this.sources = const [],
    this.fileName,
    this.fileMeta,
    this.previewLabel,
    this.previewStatus = 'Ready',
    this.expandedDetail,
  });

  final String id;
  final String title;
  final String detail;
  final String durationLabel;
  final V2RunStepKind kind;
  final List<V2RunSource> sources;

  /// A file the step wrote, when there is one.
  final String? fileName;
  final String? fileMeta;

  /// Label under a live preview thumbnail, when the step has one.
  final String? previewLabel;
  final String previewStatus;

  /// Plain-English extra detail shown when the step is expanded.
  final String? expandedDetail;
}

/// Immutable state for [RunTrajectoryPage].
@immutable
class V2RunTrajectoryPageData {
  const V2RunTrajectoryPageData({
    required this.title,
    required this.runLabel,
    required this.prompt,
    required this.model,
    required this.tokensLabel,
    required this.durationLabel,
    this.steps = const [],
    this.subagents = const [],
    this.status = V2RunTrajectoryStatus.ready,
    this.errorMessage = 'We could not load this run.',
  });

  final String title;
  final String runLabel;
  final String prompt;
  final List<V2RunStep> steps;
  final List<V2SubagentLaunch> subagents;
  final String model;
  final String tokensLabel;
  final String durationLabel;
  final V2RunTrajectoryStatus status;
  final String errorMessage;

  /// "1 subagent" / "3 subagents".
  String get subagentCountLabel =>
      subagents.length == 1 ? '1 subagent' : '${subagents.length} subagents';

  /// Launches in start order.
  ///
  /// Timestamped launches sort first, oldest first; launches without a
  /// timestamp keep the order the caller supplied after the dated ones.
  List<V2SubagentLaunch> get orderedSubagents {
    final indexed = [
      for (var i = 0; i < subagents.length; i++) (i, subagents[i]),
    ];
    indexed.sort((a, b) {
      final at = a.$2.startedAt;
      final bt = b.$2.startedAt;
      if (at != null && bt != null) {
        final byTime = at.compareTo(bt);
        if (byTime != 0) return byTime;
      } else if (at != null) {
        return -1;
      } else if (bt != null) {
        return 1;
      }
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }
}

/// A run shown as a step-by-step timeline.
class RunTrajectoryPage extends StatelessWidget {
  const RunTrajectoryPage({
    super.key,
    required this.data,
    this.onShareRun,
    this.onRerun,
    this.onOpenSource,
    this.onOpenFile,
    this.onOpenPreview,
    this.onOpenSubagent,
    this.onRetry,
  });

  final V2RunTrajectoryPageData data;
  final VoidCallback? onShareRun;
  final VoidCallback? onRerun;
  final ValueChanged<String>? onOpenSource;
  final ValueChanged<String>? onOpenFile;
  final VoidCallback? onOpenPreview;
  final ValueChanged<String>? onOpenSubagent;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(title: 'Run trajectory'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: switch (data.status) {
            V2RunTrajectoryStatus.loading => const OSkeletonList(rows: 6),
            V2RunTrajectoryStatus.error => OErrorState(
              message: data.errorMessage,
              onRetry: onRetry,
            ),
            V2RunTrajectoryStatus.empty => _empty(context),
            V2RunTrajectoryStatus.ready =>
              data.steps.isEmpty ? _empty(context) : _content(context),
          },
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.timeline_rounded,
      title: 'No steps to show',
      message: 'This run has not recorded any steps yet.',
      action: OButton(
        label: 'Reload run',
        icon: Icons.refresh_rounded,
        onPressed: onRetry,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        OFadeSlide(
          child: OStagger(
            children: [
              _OverviewCard(data: data, onRerun: onRerun),
              const SizedBox(height: OSpace.l),
              if (data.subagents.isNotEmpty) ...[
                OSectionHeader(
                  label: 'Subagents (${data.subagents.length})',
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, OSpace.m),
                ),
                V2Timeline(
                  items: [
                    for (final launch in data.orderedSubagents)
                      _launchItem(
                        context,
                        launch,
                        opensDetail: onOpenSubagent != null,
                      ),
                  ],
                  onItemTap: onOpenSubagent,
                  semanticLabel: 'Subagent launches',
                ),
                const SizedBox(height: OSpace.l),
              ],
              OSectionHeader(
                label: 'Execution trajectory (${data.steps.length} steps)',
                padding: const EdgeInsets.fromLTRB(0, OSpace.s, 0, OSpace.m),
              ),
              _Timeline(
                steps: data.steps,
                onOpenSource: onOpenSource,
                onOpenFile: onOpenFile,
                onOpenPreview: onOpenPreview,
              ),
              const SizedBox(height: OSpace.l),
              _FooterCard(onShareRun: onShareRun),
              const SizedBox(height: OSpace.s),
              Text(
                'Shared runs never include your files or connectors.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.data, this.onRerun});

  final V2RunTrajectoryPageData data;
  final VoidCallback? onRerun;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data.title, style: OType.h2.copyWith(color: c.text)),
                    const SizedBox(height: OSpace.xs),
                    Text(
                      data.runLabel,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              OIconButton(
                icon: Icons.refresh_rounded,
                semanticLabel: 'Run again',
                onPressed: onRerun,
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Container(
            padding: const EdgeInsets.all(OSpace.m),
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 18,
                  color: c.accent,
                ),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Started with',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        data.prompt,
                        style: OType.bodySm.copyWith(color: c.text),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.l,
            runSpacing: OSpace.s,
            children: [
              if (data.model.isNotEmpty)
                _MetaItem(
                  icon: Icons.memory_rounded,
                  label: data.model,
                  color: c.accent,
                ),
              _MetaItem(
                icon: Icons.smart_toy_outlined,
                label: data.subagentCountLabel,
                color: c.accent,
              ),
              _MetaItem(
                icon: Icons.generating_tokens_rounded,
                label: data.tokensLabel,
                color: c.success,
              ),
              _MetaItem(
                icon: Icons.timer_outlined,
                label: data.durationLabel,
                color: c.textMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A subagent launch as a [V2TimelineItem]: when it started, which agent ran,
/// what it was asked to do, how it ended and how long it took.
///
/// [opensDetail] adds a quiet "View details" footer when the page has an
/// `onOpenSubagent` callback, keeping the affordance the old custom rail had.
V2TimelineItem _launchItem(
  BuildContext context,
  V2SubagentLaunch launch, {
  required bool opensDetail,
}) {
  final c = OColors.of(context);
  return V2TimelineItem(
    id: launch.id,
    title: launch.agentName,
    description: launch.taskSummary,
    timeLabel: launch.timeLabel,
    durationLabel: launch.durationLabel,
    status: switch (launch.status) {
      V2SubagentLaunchStatus.running => V2TimelineStatus.running,
      V2SubagentLaunchStatus.completed => V2TimelineStatus.success,
      V2SubagentLaunchStatus.failed => V2TimelineStatus.danger,
      V2SubagentLaunchStatus.timedOut => V2TimelineStatus.warning,
      V2SubagentLaunchStatus.cancelled => V2TimelineStatus.neutral,
    },
    statusLabel: launch.effectiveStatusLabel,
    icon: switch (launch.status) {
      V2SubagentLaunchStatus.running => Icons.smart_toy_rounded,
      V2SubagentLaunchStatus.completed => Icons.check_rounded,
      V2SubagentLaunchStatus.failed => Icons.error_outline_rounded,
      V2SubagentLaunchStatus.timedOut => Icons.timer_off_outlined,
      V2SubagentLaunchStatus.cancelled => Icons.block_rounded,
    },
    footer: opensDetail
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'View details',
                style: OType.caption.copyWith(color: c.accent),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: c.accent,
              ),
            ],
          )
        : null,
  );
}

class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.steps,
    this.onOpenSource,
    this.onOpenFile,
    this.onOpenPreview,
  });

  final List<V2RunStep> steps;
  final ValueChanged<String>? onOpenSource;
  final ValueChanged<String>? onOpenFile;
  final VoidCallback? onOpenPreview;

  @override
  Widget build(BuildContext context) {
    return OStagger(
      initialDelay: OMotion.stagger,
      children: [
        for (var i = 0; i < steps.length; i++)
          _RunStepTile(
            step: steps[i],
            isLast: i == steps.length - 1,
            onOpenSource: onOpenSource,
            onOpenFile: onOpenFile,
            onOpenPreview: onOpenPreview,
          ),
      ],
    );
  }
}

class _RunStepTile extends StatefulWidget {
  const _RunStepTile({
    required this.step,
    required this.isLast,
    this.onOpenSource,
    this.onOpenFile,
    this.onOpenPreview,
  });

  final V2RunStep step;
  final bool isLast;
  final ValueChanged<String>? onOpenSource;
  final ValueChanged<String>? onOpenFile;
  final VoidCallback? onOpenPreview;

  @override
  State<_RunStepTile> createState() => _RunStepTileState();
}

class _RunStepTileState extends State<_RunStepTile> {
  bool _expanded = false;

  void _toggle() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final step = widget.step;
    final canExpand = step.expandedDetail != null;
    final nodeColor = step.kind == V2RunStepKind.finish ? c.success : c.accent;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 26,
            child: Column(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: c.bg,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.hairline),
                  ),
                  child: Icon(_iconFor(step.kind), size: 14, color: nodeColor),
                ),
                if (!widget.isLast)
                  Expanded(child: Container(width: 2, color: c.hairline)),
              ],
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.isLast ? 0 : OSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  OPressable(
                    onTap: canExpand ? _toggle : null,
                    semanticLabel: canExpand
                        ? '${step.title}, ${_expanded ? 'hide' : 'show'} details'
                        : step.title,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minHeight: OSpace.touch,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _header(context, c, canExpand),
                      ),
                    ),
                  ),
                  Text(
                    step.detail,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  if (canExpand && _expanded) ...[
                    const SizedBox(height: OSpace.s),
                    OFadeSlide(
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(OSpace.m),
                        decoration: BoxDecoration(
                          color: c.surfaceAlt,
                          borderRadius: BorderRadius.circular(ORadius.m),
                          border: Border.all(color: c.hairline),
                        ),
                        child: Text(
                          step.expandedDetail!,
                          style: OType.bodySm.copyWith(color: c.textMuted),
                        ),
                      ),
                    ),
                  ],
                  if (step.sources.isNotEmpty) ...[
                    const SizedBox(height: OSpace.s),
                    Wrap(
                      spacing: OSpace.s,
                      runSpacing: 0,
                      children: [
                        for (final source in step.sources)
                          _SourceChip(
                            source: source,
                            onTap: widget.onOpenSource == null
                                ? null
                                : () => widget.onOpenSource!(source.label),
                          ),
                      ],
                    ),
                  ],
                  if (step.fileName != null) ...[
                    const SizedBox(height: OSpace.s),
                    OCard(
                      padding: const EdgeInsets.all(OSpace.m),
                      onTap: widget.onOpenFile == null
                          ? null
                          : () => widget.onOpenFile!(step.fileName!),
                      semanticLabel: 'Open ${step.fileName}',
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: c.accentSoft,
                              borderRadius: BorderRadius.circular(ORadius.s),
                            ),
                            child: Icon(
                              Icons.description_outlined,
                              size: 19,
                              color: c.accent,
                            ),
                          ),
                          const SizedBox(width: OSpace.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  step.fileName!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: OType.bodySm.copyWith(
                                    color: c.text,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (step.fileMeta != null) ...[
                                  const SizedBox(height: OSpace.xs),
                                  Text(
                                    step.fileMeta!,
                                    style: OType.caption.copyWith(
                                      color: c.textMuted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: c.textFaint,
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (step.previewLabel != null) ...[
                    const SizedBox(height: OSpace.s),
                    _PreviewCard(
                      label: step.previewLabel!,
                      status: step.previewStatus,
                      onOpen: widget.onOpenPreview,
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

  /// Title plus duration. Large text stacks the two so neither is clipped.
  Widget _header(BuildContext context, OColors c, bool canExpand) {
    final step = widget.step;
    final title = Text(
      step.title,
      style: OType.bodySm.copyWith(color: c.text, fontWeight: FontWeight.w600),
    );
    final duration = Text(
      step.durationLabel,
      style: OType.caption.copyWith(color: c.textFaint),
    );
    final chevron = canExpand
        ? Icon(
            _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 18,
            color: c.textFaint,
          )
        : null;

    if (_largeText(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          title,
          const SizedBox(height: OSpace.xs),
          Row(
            children: [
              Flexible(child: duration),
              if (chevron != null) ...[
                const SizedBox(width: OSpace.xs),
                chevron,
              ],
            ],
          ),
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: title),
        const SizedBox(width: OSpace.s),
        duration,
        if (chevron != null) ...[const SizedBox(width: OSpace.xs), chevron],
      ],
    );
  }

  IconData _iconFor(V2RunStepKind kind) => switch (kind) {
    V2RunStepKind.message => Icons.chat_bubble_outline_rounded,
    V2RunStepKind.plan => Icons.psychology_rounded,
    V2RunStepKind.search => Icons.travel_explore_rounded,
    V2RunStepKind.write => Icons.terminal_rounded,
    V2RunStepKind.preview => Icons.desktop_windows_rounded,
    V2RunStepKind.finish => Icons.flag_rounded,
  };
}

/// True once the user's text size is large enough that a label and its
/// trailing value stop fitting side by side; layouts stack instead of clipping.
bool _largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(12) > 16;

/// Source chip whose label can shrink. The shared [OChip] paints its label at
/// its intrinsic width, which runs off a 320 dp screen at 200 % text.
class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.source, this.onTap});

  final V2RunSource source;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final chip = Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(source.icon, size: 15, color: c.textMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              source.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(
                color: c.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return Semantics(label: source.label, child: chip);
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Open ${source.label}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: chip,
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.label, required this.status, this.onOpen});

  final String label;
  final String status;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final stacked = _largeText(context);
    final label = Text(
      this.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: OType.caption.copyWith(color: c.textMuted),
    );
    final status = Text(
      this.status,
      textAlign: stacked ? TextAlign.start : TextAlign.end,
      style: OType.caption.copyWith(
        color: c.success,
        fontWeight: FontWeight.w600,
      ),
    );
    final dots = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: c.hairlineStrong,
              shape: BoxShape.circle,
            ),
          ),
          if (i < 2) const SizedBox(width: OSpace.xs),
        ],
      ],
    );

    return OCard(
      padding: EdgeInsets.zero,
      onTap: onOpen,
      semanticLabel: 'Open preview',
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.m,
              vertical: OSpace.s,
            ),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          dots,
                          const SizedBox(width: OSpace.s),
                          Expanded(child: label),
                        ],
                      ),
                      const SizedBox(height: OSpace.xs),
                      status,
                    ],
                  )
                : Row(
                    children: [
                      dots,
                      const SizedBox(width: OSpace.s),
                      Expanded(child: label),
                      const SizedBox(width: OSpace.s),
                      status,
                    ],
                  ),
          ),
          Container(
            constraints: const BoxConstraints(minHeight: 120),
            padding: const EdgeInsets.all(OSpace.s),
            decoration: BoxDecoration(
              color: c.codeBg,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(ORadius.l),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 80),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.web_rounded, size: 32, color: c.accent),
                        const SizedBox(height: OSpace.s),
                        Text(
                          'Live preview',
                          textAlign: TextAlign.center,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: OSpace.s,
                      vertical: OSpace.xs,
                    ),
                    decoration: BoxDecoration(
                      color: c.surfaceRaised,
                      borderRadius: BorderRadius.circular(ORadius.pill),
                      border: Border.all(color: c.hairline),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 14,
                          color: c.accent,
                        ),
                        const SizedBox(width: OSpace.xs),
                        Flexible(
                          child: Text(
                            'Open preview',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterCard extends StatelessWidget {
  const _FooterCard({this.onShareRun});

  final VoidCallback? onShareRun;

  @override
  Widget build(BuildContext context) {
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OButton(
            label: 'Share run',
            icon: Icons.share_rounded,
            expand: true,
            onPressed: onShareRun,
          ),
        ],
      ),
    );
  }
}

class _MetaItem extends StatelessWidget {
  const _MetaItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: OSpace.xs),
        Flexible(
          child: Text(
            label,
            style: OType.caption.copyWith(
              color: c.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
