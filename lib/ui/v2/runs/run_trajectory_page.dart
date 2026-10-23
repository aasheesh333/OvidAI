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
    this.toolCount = 0,
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

  /// How many tool calls the worker recorded in its own session.
  ///
  /// A worker's own steps are inspectable through its drill-down; this count
  /// is what the summary line adds up so the screen reports the workers'
  /// activity rather than the main agent's.
  final int toolCount;
}

/// Immutable state for [RunTrajectoryPage].
///
/// The page shows the subagents a run launched and nothing else. The main
/// agent's own steps are the conversation the person is already having with
/// it; repeating them here buries the workers in noise.
@immutable
class V2RunTrajectoryPageData {
  const V2RunTrajectoryPageData({
    required this.title,
    required this.runLabel,
    this.subagents = const [],
    this.startedAt,
    this.endedAt,
    this.status = V2RunTrajectoryStatus.ready,
    this.errorMessage = 'We could not load this run.',
  });

  final String title;
  final String runLabel;
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

  /// How many tool calls the workers recorded across their own sessions.
  int get workerToolCount =>
      subagents.fold(0, (total, launch) => total + launch.toolCount);

  /// True while any worker is still in flight.
  bool get hasRunningWork => subagents.any(
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
  ///
  /// The counts describe the workers only: the main agent's own runs and
  /// tools are the conversation, not the trajectory.
  List<String> get _countSegments {
    final tools = workerToolCount;
    return <String>[
      subagentCountLabel,
      if (tools > 0) tools == 1 ? '1 tool' : '$tools tools',
    ];
  }

  /// The one-line summary above the timeline: counts first, duration last.
  ///
  /// While the run is still going it reports only what has arrived ("3
  /// subagents so far"): a total that keeps growing is noise, not shape.
  String get statStripLabel {
    if (isRunning) return '$subagentCountLabel so far';
    final duration = elapsed;
    final durationLabel = duration == null
        ? '—'
        : formatCompactDuration(duration);
    return [..._countSegments, durationLabel].join(' · ');
  }

  /// [statStripLabel] as one spoken sentence, with no separator glyphs.
  String get statStripSemantics {
    if (isRunning) return 'Run so far, $subagentCountLabel';
    final duration = elapsed;
    return [
      'Run summary',
      ..._countSegments,
      duration == null
          ? 'duration not reported'
          : formatCompactDuration(duration),
    ].join(', ');
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

/// A run as an ordered timeline of the subagents it launched.
///
/// The main agent's own steps never appear here: they are the conversation the
/// person is already having, and repeating them buries the workers. Rows come
/// from [V2TimelineRow] and are built lazily, so a run with thousands of
/// workers only paints the rows on screen. A running row is the only thing that
/// animates; finished rows carry no ticker.
class RunTrajectoryPage extends StatefulWidget {
  const RunTrajectoryPage({
    super.key,
    required this.data,
    this.onShareRun,
    this.onOpenSubagent,
    this.onRetry,
  });

  final V2RunTrajectoryPageData data;
  final VoidCallback? onShareRun;
  final ValueChanged<String>? onOpenSubagent;
  final VoidCallback? onRetry;

  @override
  State<RunTrajectoryPage> createState() => _RunTrajectoryPageState();
}

class _RunTrajectoryPageState extends State<RunTrajectoryPage> {
  static const String _listKey = 'run-trajectory-list';

  final ScrollController _scroll = ScrollController();

  /// True while the reader is close enough to the bottom that a new worker
  /// should follow. Learned from the real scroll position, never assumed.
  bool _atTail = false;

  /// Set only for the duration of a follow animation, so a content-size change
  /// can re-anchor the tail without yanking a reader who scrolled up.
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_handleScroll);
    // The first frame tells us where the list actually is: a long run opens at
    // the top, so appending a worker must not jump to the bottom.
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

    // Only the workers are rows, so only a new worker can grow the list.
    final appended = data.subagents.length > oldData.subagents.length;
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
      icon: Icons.account_tree_rounded,
      title: 'No subagents yet',
      message:
          'Workers appear here when Ovid dispatches one. The main agent\'s '
          'own steps stay in the chat.',
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
    // The workers are the only rows. The main agent's own steps are the chat
    // the person is already in, so the list is built from the launches alone.
    final subagents = data.orderedSubagents;

    final list = ListView.builder(
      key: const ValueKey<String>(_listKey),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.l,
      ),
      itemCount: subagents.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Semantics(
            container: true,
            sortKey: const OrdinalSortKey(0),
            child: OSectionTitle(
              title: 'Subagents',
              meta: data.subagentCountLabel,
            ),
          );
        }
        return _subagent(subagents, index - 1);
      },
    );

    // While a follow animation runs, a row that lays out taller than the
    // estimate would leave the reader above the new bottom. Re-anchor only
    // during that animation, so a tap never moves the list.
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
          _statStrip(data),
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

  Widget _subagent(List<V2SubagentLaunch> launches, int index) {
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
      // The section title is row 0; the timeline itself is one-based.
      index: index + 1,
      total: launches.length,
      isLast: index == launches.length - 1,
      positionLabel: 'Subagent ${index + 1} of ${launches.length}',
      onTap: onOpen == null ? null : () => onOpen(launch.id),
    );
  }

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

  static bool _hasContent(V2RunTrajectoryPageData data) =>
      data.subagents.isNotEmpty;

  static String _identityOf(V2RunTrajectoryPageData data) {
    if (data.subagents.isNotEmpty) return data.subagents.first.id;
    return data.title;
  }
}
