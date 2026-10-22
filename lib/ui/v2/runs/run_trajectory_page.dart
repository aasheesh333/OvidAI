import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../core/format.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'timeline.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2RunTrajectoryStatus { loading, empty, error, ready }

enum V2RunStepKind { message, plan, search, write, preview, finish }

/// What happened to one step.
///
/// Only these three states are real: a step is running, finished, or the tool
/// reported a failure. There is no invented "queued" or progress value.
enum V2RunStepStatus { running, completed, failed }

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
}

/// A source the run looked at.
@immutable
class V2RunSource {
  const V2RunSource({required this.label});

  final String label;
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
    this.expandedDetail,
    this.startedAt,
    this.status = V2RunStepStatus.completed,
    this.errorMessage,
    this.toolName,
  });

  final String id;
  final String title;

  /// The one-line summary shown under the title.
  final String detail;
  final String durationLabel;
  final V2RunStepKind kind;
  final List<V2RunSource> sources;

  /// A file the step wrote, when there is one.
  final String? fileName;
  final String? fileMeta;

  /// Plain-English extra detail shown when the step is expanded.
  final String? expandedDetail;

  /// When the step started. Supplied only when the runtime records it; steps
  /// without a timestamp keep the caller's transcript order.
  final DateTime? startedAt;

  final V2RunStepStatus status;

  /// The failure the tool reported. Shown once, on the failing step.
  final String? errorMessage;

  /// The tool this step invoked, e.g. "fs_write".
  final String? toolName;
}

/// Immutable state for [RunTrajectoryPage].
@immutable
class V2RunTrajectoryPageData {
  const V2RunTrajectoryPageData({
    required this.title,
    required this.runLabel,
    this.steps = const [],
    this.subagents = const [],
    this.startedAt,
    this.endedAt,
    this.status = V2RunTrajectoryStatus.ready,
    this.errorMessage = 'We could not load this run.',
  });

  final String title;
  final String runLabel;
  final List<V2RunStep> steps;
  final List<V2SubagentLaunch> subagents;

  /// When the run started, when the runtime records it.
  ///
  /// Only used with [endedAt] for the summary strip's duration. A caller that
  /// records neither timestamp shows no measured duration instead of a guess.
  final DateTime? startedAt;

  /// When the run settled, or null while it is still going.
  ///
  /// A started run without an end is what keeps the strip from printing a
  /// duration that is still growing.
  final DateTime? endedAt;

  final V2RunTrajectoryStatus status;
  final String errorMessage;

  /// "1 subagent" / "3 subagents".
  String get subagentCountLabel =>
      subagents.length == 1 ? '1 subagent' : '${subagents.length} subagents';

  /// "1 step" / "12 steps".
  String get stepCountLabel =>
      steps.length == 1 ? '1 step' : '${steps.length} steps';

  /// How many steps actually invoked a tool.
  ///
  /// A tool step is the only kind that records a tool name; messages, plans and
  /// run updates carry none, so this counts real calls rather than rows.
  int get toolStepCount =>
      steps.where((step) => step.toolName?.trim().isNotEmpty ?? false).length;

  /// True while any step or subagent is still in flight.
  bool get hasRunningWork =>
      steps.any((step) => step.status == V2RunStepStatus.running) ||
      subagents.any(
        (launch) => launch.status == V2SubagentLaunchStatus.running,
      );

  /// True while work is in flight or the run has not reported an end.
  bool get isRunning =>
      hasRunningWork || (startedAt != null && endedAt == null);

  /// Measured run time, or null when either end is unknown.
  Duration? get elapsed {
    final start = startedAt;
    final end = endedAt;
    if (start == null || end == null) return null;
    final measured = end.difference(start);
    return measured.isNegative ? Duration.zero : measured;
  }

  /// The count segments, in reading order, with no duration.
  List<String> get _countSegments => <String>[
    stepCountLabel,
    if (toolStepCount > 0)
      toolStepCount == 1 ? '1 tool' : '$toolStepCount tools',
    if (subagents.isNotEmpty) subagentCountLabel,
  ];

  /// The one-line summary above the timeline: counts first, duration last.
  ///
  /// While the run is still going it reports only what has arrived ("12 steps
  /// so far"): a total that keeps growing is noise, not shape.
  String get statStripLabel {
    if (isRunning) return '$stepCountLabel so far';
    final duration = elapsed;
    final durationLabel = duration == null
        ? '—'
        : formatCompactDuration(duration);
    return [..._countSegments, durationLabel].join(' · ');
  }

  /// [statStripLabel] as one spoken sentence, with no separator glyphs.
  String get statStripSemantics {
    if (isRunning) return 'Run so far, $stepCountLabel';
    final duration = elapsed;
    return [
      'Run summary',
      ..._countSegments,
      duration == null
          ? 'duration not reported'
          : formatCompactDuration(duration),
    ].join(', ');
  }

  /// Steps in start order when every step carries a timestamp.
  ///
  /// A transcript is already chronological, so a caller that records no
  /// timestamps keeps its order instead of being re-sorted by an invented one.
  List<V2RunStep> get orderedSteps {
    if (steps.length < 2 || steps.any((step) => step.startedAt == null)) {
      return steps;
    }
    final indexed = [for (var i = 0; i < steps.length; i++) (i, steps[i])];
    indexed.sort((a, b) {
      final byTime = a.$2.startedAt!.compareTo(b.$2.startedAt!);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }

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

/// A run as an ordered timeline of real steps.
///
/// Rows come from [V2TimelineRow] and are built lazily, so a run with
/// thousands of messages only paints the rows on screen. A running row is the
/// only thing that animates; finished rows carry no ticker.
class RunTrajectoryPage extends StatefulWidget {
  const RunTrajectoryPage({
    super.key,
    required this.data,
    this.onShareRun,
    this.onOpenSource,
    this.onOpenSubagent,
    this.onRetry,
  });

  final V2RunTrajectoryPageData data;
  final VoidCallback? onShareRun;
  final ValueChanged<String>? onOpenSource;
  final ValueChanged<String>? onOpenSubagent;
  final VoidCallback? onRetry;

  @override
  State<RunTrajectoryPage> createState() => _RunTrajectoryPageState();
}

class _RunTrajectoryPageState extends State<RunTrajectoryPage> {
  static const String _listKey = 'run-trajectory-list';

  final ScrollController _scroll = ScrollController();
  final Set<String> _expanded = <String>{};

  /// True while the reader is close enough to the bottom that a new step
  /// should follow. Learned from the real scroll position, never assumed.
  bool _atTail = false;

  /// Set only for the duration of a follow animation, so a content-size change
  /// can re-anchor the tail without yanking a reader who opened a step.
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    // The first frame tells us where the list actually is: a long run opens at
    // the top, so appending a step must not jump to the bottom.
    _scheduleTailSync();
  }

  @override
  void didUpdateWidget(covariant RunTrajectoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldData = oldWidget.data;
    final data = widget.data;

    final oldIdentity = _identityOf(oldData);
    final newIdentity = _identityOf(data);
    final bothHaveContent = _hasContent(oldData) && _hasContent(data);
    if (bothHaveContent && oldIdentity != newIdentity) {
      // A different run replaced this one: start it at the top.
      _expanded.clear();
      _following = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(0);
        _atTail = _scroll.position.extentAfter <= OSpace.huge;
      });
      return;
    }

    if (!_hasContent(oldData)) {
      // First content after loading or empty: open at the top and learn the
      // tail before deciding whether later appends should follow.
      if (_hasContent(data)) _scheduleTailSync();
      return;
    }

    final appended =
        data.steps.length > oldData.steps.length ||
        data.subagents.length > oldData.subagents.length;
    if (!appended) return;

    // Follow a run that grows only while the reader is already at the tail.
    // Mid-history reading keeps its exact offset.
    if (!_atTail) return;
    _following = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _followTail());
  }

  void _scheduleTailSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _atTail = _scroll.position.extentAfter <= OSpace.huge;
    });
  }

  Future<void> _followTail() async {
    if (!mounted || !_scroll.hasClients) {
      _following = false;
      return;
    }
    final duration = OMove.duration(context, OMotion.base);
    await _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: duration,
      curve: OMotion.standard,
    );
    if (!mounted || !_scroll.hasClients) {
      _following = false;
      return;
    }
    // A lazily built list estimates the extent of rows it has not laid out
    // yet, so the animation can stop one row short. Land on the real bottom.
    if (_atTail && _scroll.position.extentAfter > 0.5) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
    _following = false;
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scroll.hasClients) return;
    _atTail = _scroll.position.extentAfter <= OSpace.huge;
  }

  void _setExpanded(String id, bool expanded) {
    setState(() {
      if (expanded) {
        _expanded.add(id);
      } else {
        _expanded.remove(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final runLabel = data.runLabel.trim();
    return OScreen(
      title: 'Run trajectory',
      subtitle: runLabel.isEmpty ? null : runLabel,
      padding: false,
      actions: [
        if (widget.onShareRun != null)
          OIconButton(
            icon: Icons.share_rounded,
            semanticLabel: 'Share run',
            onPressed: widget.onShareRun,
          ),
      ],
      child: switch (data.status) {
        V2RunTrajectoryStatus.loading => const OSkeletonList(rows: 6),
        V2RunTrajectoryStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: widget.onRetry,
        ),
        V2RunTrajectoryStatus.empty =>
          _hasContent(data) ? _content(data) : _empty(),
        V2RunTrajectoryStatus.ready =>
          _hasContent(data) ? _content(data) : _empty(),
      },
    );
  }

  Widget _empty() {
    return OEmptyState(
      icon: Icons.timeline_rounded,
      title: 'No steps yet',
      message: 'This run recorded no steps.',
      action: widget.onRetry == null
          ? null
          : OButton(
              label: 'Reload',
              icon: Icons.refresh_rounded,
              onPressed: widget.onRetry,
            ),
    );
  }

  Widget _content(V2RunTrajectoryPageData data) {
    final steps = data.orderedSteps;
    final subagents = data.orderedSubagents;
    final subagentSection = subagents.isEmpty ? 0 : subagents.length + 1;

    final list = ListView.builder(
      key: const ValueKey<String>(_listKey),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      itemCount: steps.length + subagentSection,
      itemBuilder: (context, index) {
        if (index < steps.length) return _step(steps, index);
        final sectionIndex = index - steps.length;
        if (sectionIndex == 0) {
          return Semantics(
            container: true,
            sortKey: OrdinalSortKey(steps.length.toDouble()),
            child: OSectionTitle(
              title: 'Subagents',
              meta: data.subagentCountLabel,
            ),
          );
        }
        return _subagent(subagents, steps.length, sectionIndex - 1);
      },
    );

    // While a follow animation runs, a row that lays out taller than the
    // estimate would leave the reader above the new bottom. Re-anchor only
    // during that animation, so opening a step never moves the list.
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (!_following || !_scroll.hasClients) return false;
        if (notification.metrics.extentAfter <= 0.5) return false;
        _scroll.jumpTo(notification.metrics.maxScrollExtent);
        return false;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A run with only subagents has no step timeline to summarise; the
          // subagent section title already states that count.
          if (steps.isNotEmpty) _statStrip(data),
          Expanded(child: list),
        ],
      ),
    );
  }

  /// One muted line of real counts above the timeline.
  ///
  /// Flat by design: no card, no tiles, no separators heavier than the middle
  /// dot. The numbers are [V2RunTrajectoryPageData.statStripLabel]'s; this only
  /// places them, using the same one-line summary treatment as Schedules.
  Widget _statStrip(V2RunTrajectoryPageData data) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, 0),
      child: Semantics(
        container: true,
        label: data.statStripSemantics,
        child: ExcludeSemantics(
          child: Text(
            data.statStripLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ),
      ),
    );
  }

  Widget _step(List<V2RunStep> steps, int index) {
    final step = steps[index];
    return V2TimelineRow(
      key: ValueKey<String>('run-step-${step.id}'),
      item: _itemForStep(step),
      index: index,
      total: steps.length,
      isLast: index == steps.length - 1,
      expanded: _expanded.contains(step.id),
      onExpandedChanged: (expanded) => _setExpanded(step.id, expanded),
    );
  }

  V2TimelineItem _itemForStep(V2RunStep step) {
    final title = step.title.trim();
    final detail = step.detail.trim();
    final error = step.errorMessage?.trim() ?? '';
    final failed = step.status == V2RunStepStatus.failed;
    final showError = failed && error.isNotEmpty;
    // A failure is shown once. Some hosts repeat the tool's failure as the
    // step's one-line detail; rendering both would print the same sentence
    // twice on the row.
    final description = showError && detail == error ? '' : detail;
    return V2TimelineItem(
      id: step.id,
      title: title.isEmpty ? 'Step' : title,
      description: description.isEmpty ? null : description,
      timeLabel: step.startedAt == null ? null : _clock(step.startedAt!),
      durationLabel: step.durationLabel.trim(),
      status: _statusFor(step),
      icon: failed ? null : _iconFor(step.kind),
      details: _detailsFor(step),
      errorMessage: showError ? error : null,
    );
  }

  List<V2TimelineDetail> _detailsFor(V2RunStep step) {
    final details = <V2TimelineDetail>[];
    final toolName = step.toolName?.trim() ?? '';
    if (toolName.isNotEmpty) {
      details.add(V2TimelineDetail(label: 'Tool', value: toolName, mono: true));
    }

    // The summary is already visible under the title; repeating it inside the
    // panel would make a step look expandable when it has nothing more to say.
    final summary = step.detail.trim();
    final error = step.errorMessage?.trim() ?? '';
    final result = step.expandedDetail?.trim() ?? '';
    if (result.isNotEmpty && result != summary && result != error) {
      details.add(V2TimelineDetail(label: 'Result', value: result));
    }

    final file = step.fileName?.trim() ?? '';
    if (file.isNotEmpty) {
      final meta = step.fileMeta?.trim() ?? '';
      details.add(
        V2TimelineDetail(
          label: 'File',
          value: meta.isEmpty ? file : '$file · $meta',
          mono: true,
        ),
      );
    }

    final sources = [
      for (final source in step.sources)
        if (source.label.trim().isNotEmpty) source.label.trim(),
    ];
    final onOpenSource = widget.onOpenSource;
    for (var i = 0; i < sources.length; i++) {
      details.add(
        V2TimelineDetail(
          label: i == 0 ? 'Sources' : null,
          value: sources[i],
          mono: true,
          onTap: onOpenSource == null ? null : () => onOpenSource(sources[i]),
        ),
      );
    }
    return details;
  }

  Widget _subagent(List<V2SubagentLaunch> launches, int stepCount, int index) {
    final launch = launches[index];
    final onOpen = widget.onOpenSubagent;
    final item = V2TimelineItem(
      id: launch.id,
      title: launch.agentName.trim().isEmpty
          ? 'Subagent'
          : launch.agentName.trim(),
      description: launch.taskSummary.trim().isEmpty
          ? null
          : launch.taskSummary.trim(),
      timeLabel: launch.timeLabel.trim(),
      durationLabel: launch.durationLabel.trim(),
      status: _statusForLaunch(launch),
      statusLabel: _statusLabelForLaunch(launch),
      icon: Icons.account_tree_rounded,
      tapHint: onOpen == null ? null : 'Open subagent',
    );
    return V2TimelineRow(
      key: ValueKey<String>('run-subagent-${launch.id}'),
      item: item,
      index: stepCount + 1 + index,
      total: launches.length,
      isLast: index == launches.length - 1,
      positionLabel: 'Subagent ${index + 1} of ${launches.length}',
      onTap: onOpen == null ? null : () => onOpen(launch.id),
    );
  }

  V2TimelineStatus _statusFor(V2RunStep step) => switch (step.status) {
    V2RunStepStatus.running => V2TimelineStatus.running,
    V2RunStepStatus.completed => V2TimelineStatus.success,
    V2RunStepStatus.failed => V2TimelineStatus.danger,
  };

  V2TimelineStatus _statusForLaunch(V2SubagentLaunch launch) =>
      switch (launch.status) {
        V2SubagentLaunchStatus.running => V2TimelineStatus.running,
        V2SubagentLaunchStatus.completed => V2TimelineStatus.success,
        V2SubagentLaunchStatus.failed => V2TimelineStatus.danger,
        V2SubagentLaunchStatus.timedOut => V2TimelineStatus.danger,
        V2SubagentLaunchStatus.cancelled => V2TimelineStatus.warning,
      };

  String? _statusLabelForLaunch(V2SubagentLaunch launch) {
    final override = launch.statusLabel?.trim();
    if (override != null && override.isNotEmpty) return override;
    return switch (launch.status) {
      V2SubagentLaunchStatus.timedOut => 'Timed out',
      V2SubagentLaunchStatus.cancelled => 'Cancelled',
      _ => null,
    };
  }

  IconData _iconFor(V2RunStepKind kind) => switch (kind) {
    V2RunStepKind.message => Icons.chat_bubble_outline_rounded,
    V2RunStepKind.plan => Icons.psychology_rounded,
    V2RunStepKind.search => Icons.travel_explore_rounded,
    V2RunStepKind.write => Icons.terminal_rounded,
    V2RunStepKind.preview => Icons.desktop_windows_rounded,
    V2RunStepKind.finish => Icons.flag_rounded,
  };

  String _clock(DateTime at) {
    final local = at.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  static bool _hasContent(V2RunTrajectoryPageData data) =>
      data.steps.isNotEmpty || data.subagents.isNotEmpty;

  static String _identityOf(V2RunTrajectoryPageData data) {
    if (data.steps.isNotEmpty) return data.steps.first.id;
    if (data.subagents.isNotEmpty) return data.subagents.first.id;
    return data.title;
  }
}
