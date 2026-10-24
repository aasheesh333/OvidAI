import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/cloud/trajectory_projection.dart';
import '../../../core/format.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'subagent_summary.dart';

// TODO(l10n): extract this screen's English copy during the ARB pass.

enum V2SubagentStatus { loading, empty, error, ready }

enum V2SubagentLogTone { normal, success, accent }

/// One line in the subagent log. The page previews the most recent rows and
/// keeps the full log one action away.
@immutable
class V2SubagentLogLine {
  const V2SubagentLogLine({
    required this.time,
    required this.text,
    this.tone = V2SubagentLogTone.normal,
  });

  final String time;
  final String text;
  final V2SubagentLogTone tone;
}

/// Immutable state for [SubagentPage].
@immutable
class V2SubagentPageData {
  const V2SubagentPageData({
    required this.name,
    required this.instanceLabel,
    required this.stepLabel,
    required this.goal,
    required this.startedLabel,
    required this.elapsedLabel,
    required this.timeLimitLabel,
    required this.remainingLabel,
    required this.totalLogLines,
    this.working = true,
    this.progress = 0,
    this.progressKnown = true,
    this.files = const [],
    this.logLines = const [],
    this.logPath = '',
    this.summary,
    this.status = V2SubagentStatus.ready,
    this.errorMessage = 'We could not load this subagent.',
    this.reportedStatus,
    this.createdAt,
    this.finishedAt,
    this.trajectoryWorker,
  });

  final String name;

  /// Retained for hosts. The page shows the status, not the runtime instance.
  final String instanceLabel;

  /// True while the session's live agent state is `running`.
  final bool working;
  final double progress;

  /// False when the runtime reports no progress measurement.
  final bool progressKnown;

  /// The host's label for the live agent state (`Working`, `Finished`,
  /// `Stopped`, `Failed`) or, when the host records one, the step the run is
  /// on. Rendered as the one-line progress line while the run is in flight;
  /// also the legacy fallback in [runStatus] for the two terminal states a
  /// summary cannot supply.
  final String stepLabel;

  /// What the subagent was asked to do, shown as one line.
  final String goal;

  /// The files the run has written so far, from its recorded tool rows.
  final List<String> files;

  final String startedLabel;

  /// The elapsed time the host measured. While [working] the page ticks this
  /// forward from real time; when the run ends the value freezes.
  final String elapsedLabel;
  final String timeLimitLabel;
  final String remainingLabel;

  /// The most recent log rows, previewed as a tail. The full log stays one
  /// action away through [SubagentPage.onViewLog] or [logPath].
  final List<V2SubagentLogLine> logLines;

  /// How many log rows the run has recorded in total, so the tail can say what
  /// it is a tail of.
  final int totalLogLines;

  /// Absolute path of the full log, e.g.
  /// `/workspace/.ovid/logs/subagent_ab12.log`. Empty when the host records
  /// none; the page then offers no file action.
  final String logPath;

  /// The strict JSON summary the subagent returned, when it has finished.
  final V2SubagentSummaryData? summary;

  final V2SubagentStatus status;
  final String errorMessage;

  /// The runtime's typed lifecycle state, when the host has one.
  ///
  /// Hosts should pass this instead of relying on [stepLabel]: a display
  /// string is copy, not a state machine. Null keeps the summary/legacy
  /// fallback below.
  final V2SubagentRunStatus? reportedStatus;

  /// When the run really started. When supplied, the elapsed clock is
  /// measured from this instant instead of parsed back out of
  /// [elapsedLabel].
  final DateTime? createdAt;

  /// When the run really ended, or null while it is still running.
  final DateTime? finishedAt;

  /// Canonical read-only worker projection used by live Trajectory routes.
  final TrajectoryWorker? trajectoryWorker;

  /// The run's real state.
  ///
  /// The host's typed [reportedStatus] wins when present. Otherwise a
  /// terminal summary wins because it is the subagent's own report. Without
  /// either, a live `running` session is running, a failed or stopped session
  /// is failed or cancelled, and a finished session is **unknown** — never
  /// completed, because no summary means no completion claim.
  V2SubagentRunStatus get runStatus {
    final canonical = trajectoryWorker;
    if (canonical != null) return v2SubagentRunStatusOf(canonical.status);
    final typed = reportedStatus;
    if (typed != null) return typed;
    final reported = v2SubagentRunStatusOf(summary?.status);
    if (reported != V2SubagentRunStatus.unknown) return reported;
    if (working) return V2SubagentRunStatus.running;
    return switch (stepLabel.trim().toLowerCase()) {
      'failed' => V2SubagentRunStatus.failed,
      'stopped' || 'cancelled' || 'canceled' => V2SubagentRunStatus.cancelled,
      _ => V2SubagentRunStatus.unknown,
    };
  }
}

/// One subagent: its status, the five contract fields, the live progress the
/// run records (step, goal, files touched, log tail) and one log action.
class SubagentPage extends StatefulWidget {
  const SubagentPage({
    super.key,
    required this.data,
    this.onStop,
    this.onViewLog,
    this.onReadFullLog,
    this.onFileTap,
    this.onBackToChat,
    this.onRetry,
    this.clock,
  });

  final V2SubagentPageData data;
  final VoidCallback? onStop;
  final VoidCallback? onViewLog;

  /// Opens the full log at [V2SubagentPageData.logPath] in the device's
  /// viewer or editor. Used when the host has no in-app log viewer.
  final ValueChanged<String>? onReadFullLog;
  final ValueChanged<String>? onFileTap;
  final VoidCallback? onBackToChat;
  final VoidCallback? onRetry;

  /// Time source for the elapsed ticker. Production uses [DateTime.now]; tests
  /// inject a clock so the tick can be observed.
  final DateTime Function()? clock;

  @override
  State<SubagentPage> createState() => _SubagentPageState();
}

class _SubagentPageState extends State<SubagentPage> {
  /// The runtime's hard ceiling for one subagent run.
  static const Duration _ceiling = Duration(hours: 8);

  Timer? _ticker;

  /// The elapsed time the host last measured, and when it measured it.
  Duration? _baseElapsed;
  DateTime? _anchoredAt;

  /// The last value shown while running, kept after the run ends so the
  /// display freezes instead of continuing to count.
  Duration? _frozenElapsed;

  bool _running = false;

  @override
  void initState() {
    super.initState();
    _adopt(widget.data);
  }

  @override
  void didUpdateWidget(covariant SubagentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasRunning = _running;
    final previous = _computedElapsed;
    final timestampsChanged =
        oldWidget.data.createdAt != widget.data.createdAt ||
        oldWidget.data.finishedAt != widget.data.finishedAt ||
        oldWidget.data.elapsedLabel != widget.data.elapsedLabel;
    if (timestampsChanged) {
      _baseElapsed = _elapsedFrom(widget.data);
      _anchoredAt = _baseElapsed == null ? null : _now();
    }
    _running = widget.data.runStatus == V2SubagentRunStatus.running;
    if (wasRunning && !_running) {
      _frozenElapsed = previous ?? _baseElapsed;
    } else if (_running) {
      _frozenElapsed = null;
    }
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _adopt(V2SubagentPageData data) {
    _baseElapsed = _elapsedFrom(data);
    _anchoredAt = _baseElapsed == null ? null : _now();
    _running = data.runStatus == V2SubagentRunStatus.running;
    _syncTicker();
  }

  DateTime _now() => (widget.clock ?? DateTime.now)();

  /// The host's measured elapsed time.
  ///
  /// Real timestamps win. A host that only supplies [elapsedLabel] still
  /// works, but the route layer passes [createdAt]/[finishedAt] so the clock
  /// is never reconstructed by parsing display copy.
  Duration? _elapsedFrom(V2SubagentPageData data) {
    final started = data.createdAt;
    if (started == null) return _parseDuration(data.elapsedLabel);
    final running = data.runStatus == V2SubagentRunStatus.running;
    final end = data.finishedAt ?? (running ? _now() : started);
    final elapsed = end.difference(started);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// The real elapsed time: the host's measurement plus the time observed
  /// since, only while the run is actually running.
  Duration? get _computedElapsed {
    final base = _baseElapsed;
    if (base == null) return null;
    if (!_running) return _frozenElapsed ?? base;
    final anchor = _anchoredAt;
    if (anchor == null) return base;
    final delta = _now().difference(anchor);
    return delta.isNegative ? base : base + delta;
  }

  /// The status shown on screen. A run still marked running past the 8 hour
  /// ceiling is timed out, because the runtime cannot run one longer.
  V2SubagentRunStatus get _status {
    if (widget.data.trajectoryWorker != null) return widget.data.runStatus;
    final reported = widget.data.runStatus;
    if (reported != V2SubagentRunStatus.running) return reported;
    final elapsed = _computedElapsed;
    if (elapsed != null && elapsed > _ceiling) {
      return V2SubagentRunStatus.timedOut;
    }
    return reported;
  }

  void _syncTicker() {
    final shouldTick =
        _running &&
        _baseElapsed != null &&
        _status == V2SubagentRunStatus.running;
    if (!shouldTick) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (_status != V2SubagentRunStatus.running) _syncTicker();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final name = data.name.trim();
    final title = 'Subagent';
    return OScreen(
      title: title,
      subtitle: name.isEmpty || name.toLowerCase() == title.toLowerCase()
          ? null
          : name,
      padding: false,
      // One calm reading column: never wider than 640, whatever the window.
      maxWidth: 640,
      actions: [
        if (data.trajectoryWorker == null &&
            data.status == V2SubagentStatus.ready &&
            _status == V2SubagentRunStatus.running &&
            widget.onStop != null)
          OIconButton(
            icon: Icons.stop_circle_outlined,
            semanticLabel: 'Stop subagent',
            onPressed: widget.onStop,
          ),
      ],
      child: switch (data.status) {
        V2SubagentStatus.loading => const OSkeletonList(rows: 5),
        V2SubagentStatus.error => OErrorState(
          message: data.errorMessage,
          onRetry: widget.onRetry,
        ),
        V2SubagentStatus.empty => _empty(),
        V2SubagentStatus.ready =>
          data.trajectoryWorker == null
              ? _content(context)
              : _canonicalContent(context),
      },
    );
  }

  Widget _canonicalContent(BuildContext context) {
    final worker = widget.data.trajectoryWorker!;
    final c = OColors.of(context);
    final runtime = workerRuntimeDuration(worker);
    final deferred = workerDeferredAge(worker);
    final compaction = worker.compaction;
    final logAction =
        worker.hasTranscript &&
            worker.logAvailable == true &&
            widget.onViewLog != null
        ? OButton(
            label: 'View log',
            semanticLabel: 'View subagent log',
            icon: Icons.terminal_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: widget.onViewLog,
          )
        : null;

    Widget field(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: OSpace.m),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: OType.overline.copyWith(color: c.textFaint)),
          const SizedBox(height: OSpace.xs),
          Text(value, style: OType.bodySm.copyWith(color: c.text)),
        ],
      ),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        field('STATUS', _canonicalStatusLabel(worker.status)),
        if (worker.launchReason != null)
          field('LAUNCH REASON', worker.launchReason!),
        if (worker.schedulingReason != null)
          field('SCHEDULING REASON', worker.schedulingReason!),
        if (worker.prompt == null)
          field('PROMPT UNAVAILABLE', trajectoryUnknownValue)
        else
          field('PROMPT PREVIEW', worker.prompt!),
        field(
          'LOGICAL WORKER',
          worker.logicalWorkerId ?? trajectoryUnknownValue,
        ),
        field('ATTEMPT', worker.attemptId ?? trajectoryUnknownValue),
        field('ROOT TASK', worker.rootTaskRunId ?? trajectoryUnknownValue),
        field(
          'REQUESTED',
          worker.requestedAt?.toLocal().toIso8601String() ??
              trajectoryUnknownValue,
        ),
        field(
          'ADMITTED',
          worker.admittedAt?.toLocal().toIso8601String() ??
              trajectoryUnknownValue,
        ),
        field(
          'STARTED',
          worker.startedAt?.toLocal().toIso8601String() ??
              trajectoryUnknownValue,
        ),
        field(
          'ENDED',
          worker.endedAt?.toLocal().toIso8601String() ?? trajectoryUnknownValue,
        ),
        field(
          'RUNTIME',
          runtime == null
              ? trajectoryUnknownValue
              : formatCompactDuration(runtime),
        ),
        if (worker.isDeferred)
          field(
            'DEFERRED AGE',
            deferred == null
                ? trajectoryUnknownValue
                : formatCompactDuration(deferred),
          ),
        field('ACTIVITY', worker.lastActivity ?? trajectoryUnknownValue),
        field(
          'ACTIVITY AT',
          worker.lastActivityAt?.toLocal().toIso8601String() ??
              trajectoryUnknownValue,
        ),
        if (worker.summary != null) field('SUMMARY', worker.summary!),
        if (worker.error != null) field('ERROR', worker.error!),
        if (worker.report != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OSpace.m),
            child: TrajectoryReportCard(report: worker.report!),
          ),
        if (compaction != null) ...[
          field('COMPACTION', compaction.compactionId),
          field('CHECKPOINT', compaction.checkpointId),
          field('MODEL', compaction.model),
          field('CONTEXT LIMIT', '${compaction.contextLimit}'),
          field('BEFORE TOKENS', '${compaction.beforeTokens}'),
          field('AFTER TOKENS', '${compaction.afterTokens}'),
          field('USAGE SOURCE', compaction.usageSource),
          field('CONTINUATION', compaction.continuation),
        ],
        field('LOG', switch (worker.logAvailable) {
          true => 'Log available',
          false => 'Log unavailable',
          null => trajectoryUnknownValue,
        }),
        ?logAction,
      ],
    );
  }

  String _canonicalStatusLabel(String status) => switch (status) {
    'awaiting_next_user_task' => 'Awaiting next user task',
    'running' => 'Running',
    'completed' => 'Completed',
    'failed' => 'Failed',
    'cancelled' => 'Cancelled',
    'timeout' => 'Timed out',
    _ => trajectoryUnknownValue,
  };

  Widget _empty() {
    return OEmptyState(
      icon: Icons.smart_toy_outlined,
      title: 'No subagent is running',
      message: 'Start one from a chat.',
      action: widget.onBackToChat == null
          ? null
          : OButton(
              label: 'Back to chat',
              icon: Icons.arrow_back_rounded,
              onPressed: widget.onBackToChat,
            ),
    );
  }

  Widget _content(BuildContext context) {
    final data = widget.data;
    final log = _logAction;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.l,
      ),
      children: [
        _statusField(context),
        if (_status == V2SubagentRunStatus.running &&
            data.stepLabel.trim().isNotEmpty) ...[
          const SizedBox(height: OSpace.s),
          _progressLine(context),
        ],
        const SizedBox(height: OSpace.l),
        SubagentSummaryCard(
          summary: data.summary,
          status: data.summary == null
              ? V2SubagentSummaryStatus.empty
              : V2SubagentSummaryStatus.ready,
          // The status above is the live run state and already covers this
          // field, so the card does not repeat it.
          showStatus: false,
          onFileTap: widget.onFileTap,
          onRetry: widget.onRetry,
        ),
        if (data.goal.trim().isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _goalField(context),
        ],
        if (data.files.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _filesField(context),
        ],
        if (data.logLines.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _logTail(context),
        ],
        if (log != null) ...[const SizedBox(height: OSpace.l), log],
        const SizedBox(height: OSpace.l),
        _nestingNote(context),
      ],
    );
  }

  /// The contract's first field: the real run status, with the real clock.
  Widget _statusField(BuildContext context) {
    final c = OColors.of(context);
    final status = _status;
    final label = v2SubagentRunStatusLabel(status);
    final spokenStatus = status == V2SubagentRunStatus.unknown
        ? v2SubagentNotReported
        : label;
    final started = _startedText;
    final elapsed = _elapsedText;
    final visible = [
      if (started.isNotEmpty) 'Started $started',
      if (elapsed.isNotEmpty) elapsed,
    ];
    final spoken = [
      'Status: $spokenStatus',
      if (started.isNotEmpty) 'Started at $started',
      if (elapsed.isNotEmpty) 'Elapsed $elapsed',
    ].join('. ');
    return Semantics(
      container: true,
      label: spoken,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('STATUS', style: OType.overline.copyWith(color: c.textFaint)),
          const SizedBox(height: OSpace.xs),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OPill(
                label: label,
                tone: v2SubagentRunStatusTone(status),
                dot: status == V2SubagentRunStatus.running,
              ),
              if (visible.isNotEmpty)
                Text(
                  visible.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// One live line while the run is in flight: the host's step label and how
  /// many tool rows it has recorded so far. Nothing here is invented — both
  /// values come from the run's own record.
  Widget _progressLine(BuildContext context) {
    final c = OColors.of(context);
    final rows = widget.data.totalLogLines;
    final parts = <String>[
      widget.data.stepLabel.trim(),
      if (rows > 0) '$rows ${rows == 1 ? 'tool row' : 'tool rows'}',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: OSpace.xxs),
            child: Icon(Icons.autorenew_rounded, size: 14, color: c.textFaint),
          ),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
      ],
    );
  }

  /// What the run was asked to do, on one line.
  Widget _goalField(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('GOAL', style: OType.overline.copyWith(color: c.textFaint)),
        const SizedBox(height: OSpace.xs),
        Text(
          widget.data.goal.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: OType.bodySm.copyWith(color: c.text),
        ),
      ],
    );
  }

  /// The files the run has written, as chips. A chip only becomes a control
  /// when the host wires [SubagentPage.onFileTap].
  Widget _filesField(BuildContext context) {
    final c = OColors.of(context);
    final onFileTap = widget.onFileTap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('FILES', style: OType.overline.copyWith(color: c.textFaint)),
        const SizedBox(height: OSpace.xs),
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            for (final file in widget.data.files)
              OChip(
                label: file,
                icon: Icons.description_outlined,
                semanticLabel: onFileTap == null
                    ? 'file $file'
                    : 'Open file $file',
                onTap: onFileTap == null ? null : () => onFileTap(file),
              ),
          ],
        ),
      ],
    );
  }

  /// The most recent log rows, as a compact tail. The full log stays one tap
  /// away through the log action below it.
  Widget _logTail(BuildContext context) {
    final c = OColors.of(context);
    final lines = widget.data.logLines;
    // The page shows a tail, never the whole log: the full record is one
    // action away, and a long log must not push the rest of the screen down.
    const preview = 5;
    final shown = lines.length <= preview
        ? lines
        : lines.sublist(lines.length - preview);
    final total = widget.data.totalLogLines > lines.length
        ? widget.data.totalLogLines
        : lines.length;
    final caption = total == shown.length
        ? '$total ${total == 1 ? 'row' : 'rows'}'
        : 'Last ${shown.length} of $total rows';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('LOG', style: OType.overline.copyWith(color: c.textFaint)),
        const SizedBox(height: OSpace.xs),
        Text(caption, style: OType.caption.copyWith(color: c.textFaint)),
        const SizedBox(height: OSpace.s),
        for (final line in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: OSpace.xs),
            child: Text(
              '[${line.time}] ${line.text}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OType.mono.copyWith(
                color: switch (line.tone) {
                  V2SubagentLogTone.normal => c.textMuted,
                  V2SubagentLogTone.success => c.success,
                  V2SubagentLogTone.accent => c.warn,
                },
              ),
            ),
          ),
      ],
    );
  }

  /// The one rule the screen states in words: a subagent cannot dispatch
  /// another. No control here implies it can.
  Widget _nestingNote(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(top: OSpace.xxs),
            child: Icon(
              Icons.account_tree_outlined,
              size: 14,
              color: c.textFaint,
            ),
          ),
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            'A subagent cannot dispatch another subagent.',
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ),
      ],
    );
  }

  /// The elapsed time as shown: ticking while running, frozen when finished.
  String get _elapsedText {
    final computed = _computedElapsed;
    if (computed != null) {
      return formatCompactDuration(
        computed.isNegative ? Duration.zero : computed,
      );
    }
    return _cleanElapsed(widget.data.elapsedLabel);
  }

  String get _startedText {
    var text = widget.data.startedLabel.trim();
    final lower = text.toLowerCase();
    for (final prefix in const ['started at ', 'started ']) {
      if (lower.startsWith(prefix)) {
        text = text.substring(prefix.length).trim();
        break;
      }
    }
    return text;
  }

  static String _cleanElapsed(String raw) {
    final text = raw.trim();
    const suffix = ' elapsed';
    if (text.toLowerCase().endsWith(suffix)) {
      return text.substring(0, text.length - suffix.length).trim();
    }
    return text;
  }

  static final RegExp _durationPart = RegExp(r'(\d+(?:\.\d+)?)\s*([hms])');

  /// Reads the host's compact duration (`6m`, `2m 10s`, `1h 2m`) back into a
  /// [Duration] so it can keep counting. Returns null when the label carries
  /// no duration, in which case the raw label is shown unchanged.
  static Duration? _parseDuration(String raw) {
    final text = raw.toLowerCase();
    var milliseconds = 0.0;
    var found = false;
    for (final match in _durationPart.allMatches(text)) {
      final value = double.tryParse(match.group(1) ?? '');
      if (value == null) continue;
      found = true;
      milliseconds += switch (match.group(2)) {
        'h' => value * Duration.millisecondsPerHour,
        'm' => value * Duration.millisecondsPerMinute,
        _ => value * Duration.millisecondsPerSecond,
      };
    }
    return found ? Duration(milliseconds: milliseconds.round()) : null;
  }

  /// One log action: the in-app viewer when wired, otherwise the file viewer.
  ///
  /// Absent when neither reaches a real log, so there is never a dead control.
  Widget? get _logAction {
    final onViewLog = widget.onViewLog;
    if (onViewLog != null) {
      return OButton(
        label: 'View log',
        semanticLabel: 'View subagent log',
        icon: Icons.terminal_rounded,
        variant: OButtonVariant.secondary,
        expand: true,
        onPressed: onViewLog,
      );
    }
    final logPath = widget.data.logPath.trim();
    final onReadFullLog = widget.onReadFullLog;
    if (onReadFullLog != null && logPath.isNotEmpty) {
      return OButton(
        label: 'View log',
        semanticLabel: 'View subagent log',
        icon: Icons.terminal_rounded,
        variant: OButtonVariant.secondary,
        expand: true,
        onPressed: () => onReadFullLog(logPath),
      );
    }
    return null;
  }
}
