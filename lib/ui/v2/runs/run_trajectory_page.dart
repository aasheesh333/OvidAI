import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

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

/// A source the run looked at. Retained for hosts; the minimal trajectory
/// shows one line per step and no chips.
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

  /// Retained for hosts. The one-line trajectory does not render the detail.
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

/// A run as an ordered list of steps: one line each, with its duration.
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

  /// Retained for hosts. The page has one action (share) in the header.
  final VoidCallback? onRerun;
  final ValueChanged<String>? onOpenSource;
  final ValueChanged<String>? onOpenFile;
  final VoidCallback? onOpenPreview;
  final ValueChanged<String>? onOpenSubagent;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Run trajectory',
      padding: false,
      actions: [
        if (onShareRun != null)
          OIconButton(
            icon: Icons.share_rounded,
            semanticLabel: 'Share run',
            onPressed: onShareRun,
          ),
      ],
      child: switch (data.status) {
        V2RunTrajectoryStatus.loading => const OSkeletonList(rows: 6),
        V2RunTrajectoryStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: onRetry,
        ),
        V2RunTrajectoryStatus.empty => _empty(),
        V2RunTrajectoryStatus.ready =>
          data.steps.isEmpty ? _empty() : _steps(),
      },
    );
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.timeline_rounded,
      title: 'No steps yet',
      message: 'This run recorded no steps.',
      action: onRetry == null
          ? null
          : OButton(
              label: 'Reload',
              icon: Icons.refresh_rounded,
              onPressed: onRetry,
            ),
    );
  }

  Widget _steps() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      itemCount: data.steps.length,
      itemBuilder: (context, index) {
        final step = data.steps[index];
        return _StepRow(step: step);
      },
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.step});

  final V2RunStep step;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final tint = step.kind == V2RunStepKind.finish ? c.success : c.textMuted;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(_iconFor(step.kind), size: 18, color: tint),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Text(
                step.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: OType.bodySm.copyWith(color: c.text),
              ),
            ),
            const SizedBox(width: OSpace.s),
            Text(
              step.durationLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ),
      ),
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
