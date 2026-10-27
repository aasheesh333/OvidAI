import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/cloud/cloud_agent_facade.dart';
import '../../../core/cloud/cloud_session_store.dart';
import '../../../core/cloud/trajectory_api.dart';
import '../../../core/cloud/trajectory_client.dart'
    as legacy
    show TrajectoryApi;
import '../../../core/conversation_share_service.dart';
import '../../../core/format.dart';
import '../../../core/state.dart';
import '../runs/run_trajectory_page.dart';
import '../runs/subagent_page.dart';
import '../runs/subagent_summary.dart';

/// Routes for the run surfaces (trajectory and subagent detail).
///
/// A subagent is a real [ChatSession] parented to the chat that dispatched it,
/// so both screens are built from that session's own transcript and analytics.
/// Anything the session does not record is shown as not reported; no token
/// counts, durations or progress values are invented.
class V2RunRoutes {
  const V2RunRoutes._();

  /// Shown when a session carries no analytics for the value.
  static const String notReported = 'Not reported';

  /// The runtime's hard ceiling for one subagent run.
  static const Duration _subagentCeiling = Duration(hours: 8);

  static Future<void> openTrajectory(
    BuildContext context,
    String sessionId,
  ) async {
    final store = CloudSessionStore.I;
    await store.ready;
    final serverId = store.serverIdFor(sessionId) ?? sessionId;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => _CanonicalTrajectoryHost(
          api: TrajectoryApi(),
          sessionId: serverId,
          title: AppState.I.sessionById(sessionId)?.title ?? 'Run',
          onShareRun: () {
            final session = AppState.I.sessionById(sessionId);
            if (session != null) _shareRun(routeContext, session);
          },
        ),
      ),
    );
  }

  static Future<void> openSubagent(
    BuildContext context,
    String sessionId,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => AnimatedBuilder(
          animation: AppState.I,
          builder: (context, _) {
            final session = AppState.I.sessionById(sessionId);
            final data = subagentDataFor(session);
            return SubagentPage(
              data: data,
              onStop: data.working && session != null
                  ? () => _stopSubagent(routeContext, session.id)
                  : null,
              onViewLog: session == null
                  ? null
                  : () => _showFullLog(routeContext, session),
              onBackToChat: () => Navigator.of(routeContext).maybePop(),
              // A load failure is recoverable: reload the session store and
              // let the AnimatedBuilder rebuild from it.
              onRetry: () => AppState.I.loadSessions(),
            );
          },
        ),
      ),
    );
  }

  static Future<void> openCanonicalSubagent(
    BuildContext context,
    TrajectoryWorker worker,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => SubagentPage(
          data: V2SubagentPageData(
            name: worker.agentType ?? worker.logicalWorkerId ?? 'Subagent',
            instanceLabel: worker.attemptId ?? '',
            stepLabel: worker.lastActivity ?? '',
            // Canonical dispatch text is a bounded preview, not a full goal.
            goal: '',
            startedLabel: worker.startedAt?.toLocal().toIso8601String() ?? '',
            elapsedLabel: '',
            timeLimitLabel: notReported,
            remainingLabel: '',
            totalLogLines: 0,
            trajectoryWorker: worker,
          ),
          onBackToChat: () => Navigator.of(routeContext).maybePop(),
          // No lifecycle mutation, deferred transcript, or fabricated log
          // action is wired on the canonical read-only route.
        ),
      ),
    );
  }

  /// Maps a real session onto the trajectory screen.
  ///
  /// The screen shows the workers this session dispatched and nothing else,
  /// so a session with no child sessions is empty no matter how much of its
  /// own work the transcript records.
  @visibleForTesting
  static V2RunTrajectoryPageData trajectoryDataFor(
    ChatSession? session, {
    List<ChatSession>? allSessions,
  }) {
    if (session == null) {
      return const V2RunTrajectoryPageData(
        title: 'Run',
        runLabel: '',
        status: V2RunTrajectoryStatus.error,
        errorMessage: 'This run is no longer available.',
      );
    }

    final launches = _subagentLaunches(session, allSessions);
    if (launches.isEmpty) {
      return V2RunTrajectoryPageData(
        title: session.title,
        runLabel: '',
        status: V2RunTrajectoryStatus.empty,
      );
    }

    return V2RunTrajectoryPageData(
      title: session.title,
      // The header carries no count: the summary strip below it already
      // reports the workers, their tools and the measured duration.
      runLabel: '',
      subagents: launches,
      startedAt: session.createdAt,
      // A run that is still working has no end yet, so the summary strip says
      // "so far" instead of printing a duration that keeps growing.
      endedAt: session.agentState == 'running' ? null : session.lastActivityAt,
    );
  }

  /// Maps a real subagent session onto the subagent screen.
  ///
  /// A root chat has no subagent to show (empty); a missing session is an
  /// error.
  @visibleForTesting
  static V2SubagentPageData subagentDataFor(
    ChatSession? session, {
    DateTime? now,
  }) {
    if (session == null) {
      return const V2SubagentPageData(
        name: 'Subagent',
        instanceLabel: '',
        stepLabel: '',
        goal: '',
        startedLabel: '',
        elapsedLabel: '',
        timeLimitLabel: notReported,
        remainingLabel: '',
        totalLogLines: 0,
        status: V2SubagentStatus.error,
        errorMessage: 'This subagent is no longer available.',
      );
    }
    if (!session.isSubagent) {
      return V2SubagentPageData(
        name: session.title,
        instanceLabel: '',
        stepLabel: '',
        goal: '',
        startedLabel: '',
        elapsedLabel: '',
        timeLimitLabel: notReported,
        remainingLabel: '',
        totalLogLines: 0,
        status: V2SubagentStatus.empty,
      );
    }

    final state = session.agentState;
    final working = state == 'running';
    final logLines = _logLines(session);
    final clock = now ?? DateTime.now();
    final end = working ? clock : session.lastActivityAt;
    final measured = end.difference(session.createdAt);
    final elapsed = measured.isNegative ? Duration.zero : measured;
    // The runtime cannot run a subagent longer than eight hours. A live run
    // measured past that ceiling has timed out; report it from the real
    // timestamps rather than waiting for a state transition that never came.
    final timedOut = working && elapsed > _subagentCeiling;

    return V2SubagentPageData(
      name: (session.agentLabel ?? '').trim().isEmpty
          ? session.title
          : session.agentLabel!.trim(),
      instanceLabel: session.model,
      working: working && !timedOut,
      progress: state == 'finished' ? 1 : 0,
      // Only a finished run reports a definite 100 %; a running, stopped or
      // failed run has no measured progress in the session.
      progressKnown: state == 'finished',
      stepLabel: timedOut ? 'Timed out' : _agentStateLabel(state),
      goal: session.title,
      files: _filesFrom(session),
      startedLabel: _timeOfDay(session.createdAt),
      elapsedLabel: formatCompactDuration(elapsed),
      timeLimitLabel: notReported,
      remainingLabel: '',
      logLines: logLines,
      totalLogLines: _toolCount(session),
      summary: _summaryFrom(session.agentResult),
      logPath: '/workspace/.ovid/logs/subagent_${session.id}.log',
      reportedStatus: timedOut
          ? V2SubagentRunStatus.timedOut
          : _reportedStatus(state),
      createdAt: session.createdAt,
      finishedAt: timedOut ? clock : (working ? null : session.lastActivityAt),
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  static Future<void> _shareRun(
    BuildContext context,
    ChatSession session,
  ) async {
    final snapshot = ConversationSnapshot.fromSession(session);
    if (!snapshot.withinLimits) {
      _snack(context, 'This run has no shareable text yet.');
      return;
    }
    try {
      final share = await ConversationShareService.production().create(
        snapshot,
        requestId: 'v2-run-${DateTime.now().microsecondsSinceEpoch}',
      );
      await Clipboard.setData(ClipboardData(text: share.url.toString()));
      if (context.mounted) _snack(context, 'Share link copied.');
    } catch (_) {
      if (context.mounted) _snack(context, 'We could not create a share link.');
    }
  }

  static Future<void> _stopSubagent(
    BuildContext context,
    String sessionId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop this subagent?'),
        content: const Text(
          'Ovid asks the server to stop this run. It keeps the changes it has '
          'already made.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // A subagent has its own server run; cancel that run, not the parent
    // turn. Local state alone would hide the Stop control while the server
    // kept working, so a missing run is reported instead of faked.
    final requested = CloudAgentFacade.I.stopRequested(sessionId: sessionId);
    if (!requested && context.mounted) {
      _snack(context, 'Nothing is running to stop.');
    }
  }

  /// The full tool log for one subagent, as a scrollable sheet. The page's
  /// preview only shows the last five rows; this shows every recorded row.
  static Future<void> _showFullLog(BuildContext context, ChatSession session) {
    final lines = _allLogLines(session);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Recorded tool rows · ${lines.length} '
                  '${lines.length == 1 ? 'line' : 'lines'}',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: lines.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No tool rows were recorded.'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        itemCount: lines.length,
                        itemBuilder: (context, index) {
                          final line = lines[index];
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('[${line.time}] ${line.text}'),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static void _snack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  /// Child sessions dispatched by [session], in the order they started.
  static List<V2SubagentLaunch> _subagentLaunches(
    ChatSession session,
    List<ChatSession>? allSessions,
  ) {
    if (allSessions == null) return const [];
    final children = [
      for (final child in allSessions)
        if (child.parentId == session.id) child,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return [
      for (final child in children)
        V2SubagentLaunch(
          id: child.id,
          agentName: (child.agentLabel ?? '').trim().isEmpty
              ? child.title
              : child.agentLabel!.trim(),
          taskSummary: child.title,
          timeLabel: _timeOfDay(child.createdAt),
          durationLabel: _durationFor(child),
          startedAt: child.createdAt,
          status: _launchStatus(child.agentState),
          // The worker's own recorded tool calls, so the summary line counts
          // the workers' activity rather than the main agent's.
          toolCount: _toolCount(child),
          statusLabel:
              const {
                'running',
                'finished',
                'failed',
                'stopped',
              }.contains(child.agentState)
              ? null
              : 'Not reported',
        ),
    ];
  }

  static V2SubagentLaunchStatus _launchStatus(String? state) => switch (state) {
    'running' => V2SubagentLaunchStatus.running,
    'finished' => V2SubagentLaunchStatus.completed,
    'failed' => V2SubagentLaunchStatus.failed,
    'stopped' => V2SubagentLaunchStatus.cancelled,
    _ => V2SubagentLaunchStatus.cancelled,
  };

  static String _durationFor(ChatSession session) {
    final end = session.agentState == 'running'
        ? DateTime.now()
        : session.lastActivityAt;
    final elapsed = end.difference(session.createdAt);
    return elapsed.isNegative ? '' : formatCompactDuration(elapsed);
  }

  static int _toolCount(ChatSession session) =>
      session.messages.where((message) => message.kind == MsgKind.tool).length;

  /// Decodes the subagent's strict JSON contract from its final answer.
  ///
  /// A missing or non-contract answer returns null so the card shows its
  /// honest "No summary yet" state instead of inventing fields.
  @visibleForTesting
  static V2SubagentSummaryData? summaryFrom(String? raw) => _summaryFrom(raw);

  static V2SubagentSummaryData? _summaryFrom(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = decoded;

    final reported = <String>{};
    String status = '';
    if (map['status'] is String) {
      status = (map['status'] as String).trim();
      reported.add('status');
    }
    List<String> strings(String key) {
      final value = map[key];
      if (value is! List) return const [];
      return [
        for (final item in value)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
    }

    List<String> listField(String key) {
      if (map[key] is! List) return const [];
      reported.add(key);
      return strings(key);
    }

    final files = listField('files_modified');
    final artifacts = listField('artifacts_created');
    final findings = listField('key_findings');
    String? error;
    if (map.containsKey('error_if_any')) {
      final value = map['error_if_any'];
      if (value == null || value is String) {
        reported.add('error_if_any');
        if (value is String && value.trim().isNotEmpty) error = value.trim();
      }
    }
    if (reported.isEmpty) return null;
    return V2SubagentSummaryData(
      status: status,
      filesModified: files,
      artifactsCreated: artifacts,
      keyFindings: findings,
      errorIfAny: error,
      reported: reported,
    );
  }

  /// The runtime's lifecycle state as the typed status the screen expects.
  ///
  /// `finished` deliberately maps to null: only the subagent's own summary
  /// may claim completion.
  static V2SubagentRunStatus? _reportedStatus(String? state) => switch (state) {
    'running' => V2SubagentRunStatus.running,
    'failed' => V2SubagentRunStatus.failed,
    'stopped' => V2SubagentRunStatus.cancelled,
    _ => null,
  };

  /// The file a tool step wrote, when the tool card records one. Read-only
  /// tools carry a path too, so only mutating tools count as writes.
  static String? _toolFile(Message message) {
    final name = (message.toolName ?? '').toLowerCase();
    final writes =
        name.contains('write') ||
        name.contains('edit') ||
        name.contains('create') ||
        name.contains('append') ||
        name.contains('replace') ||
        name.contains('delete') ||
        name.contains('move');
    if (!writes) return null;
    final input = message.toolInput;
    if (input != null && input.isNotEmpty) {
      final path = _pathFromToolInput(input);
      if (path != null) return path;
    }
    return null;
  }

  static String? _pathFromToolInput(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      for (final key in const ['path', 'file', 'file_path', 'filename']) {
        final value = decoded[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
    } catch (_) {
      // A malformed tool input is not a path.
    }
    return null;
  }

  static List<String> _filesFrom(ChatSession session) {
    final files = <String>[];
    for (final message in session.messages) {
      if (message.kind != MsgKind.tool) continue;
      final path = _toolFile(message);
      if (path != null && !files.contains(path)) files.add(path);
    }
    return files;
  }

  /// The most recent tool rows, shown as the log preview.
  static List<V2SubagentLogLine> _logLines(ChatSession session) {
    final all = _allLogLines(session);
    const preview = 5;
    return all.length <= preview ? all : all.sublist(all.length - preview);
  }

  /// Every recorded tool row, in transcript order.
  static List<V2SubagentLogLine> _allLogLines(ChatSession session) => [
    for (final message in session.messages)
      if (message.kind == MsgKind.tool)
        V2SubagentLogLine(
          time: _timeOfDaySeconds(message.time),
          text: _toolLogText(message),
          tone: switch (message.toolState) {
            'ok' => V2SubagentLogTone.success,
            'error' => V2SubagentLogTone.accent,
            _ => V2SubagentLogTone.normal,
          },
        ),
  ];

  static String _toolLogText(Message message) {
    final summary = (message.toolSummary ?? '').trim();
    if (summary.isNotEmpty) return summary;
    final title = (message.toolTitle ?? '').trim();
    if (title.isNotEmpty) return title;
    final name = (message.toolName ?? '').trim();
    return name.isEmpty ? 'Tool' : name;
  }

  static String _agentStateLabel(String? state) => switch (state) {
    'running' => 'Working',
    'finished' => 'Finished',
    'stopped' => 'Stopped',
    'failed' => 'Failed',
    _ => 'State not reported',
  };

  static String _timeOfDay(DateTime at) {
    final local = at.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _timeOfDaySeconds(DateTime at) {
    final local = at.toLocal();
    final s = local.second.toString().padLeft(2, '0');
    return '${_timeOfDay(local)}:$s';
  }
}

/// Owns the navigator in which Trajectory drill-down routes are covered.
/// RouteObserver must belong to this same navigator; an observer attached to
/// an ancestor cannot report these pushes to the root trajectory route.
class _CanonicalTrajectoryHost extends StatefulWidget {
  const _CanonicalTrajectoryHost({
    required this.api,
    required this.sessionId,
    required this.title,
    this.onShareRun,
  });

  final legacy.TrajectoryApi api;
  final String sessionId;
  final String title;
  final VoidCallback? onShareRun;

  @override
  State<_CanonicalTrajectoryHost> createState() =>
      _CanonicalTrajectoryHostState();
}

class _CanonicalTrajectoryHostState extends State<_CanonicalTrajectoryHost> {
  final RouteObserver<ModalRoute<void>> _observer =
      RouteObserver<ModalRoute<void>>();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      observers: <NavigatorObserver>[_observer],
      onGenerateInitialRoutes: (_, _) => <Route<void>>[
        MaterialPageRoute<void>(
          builder: (_) => CanonicalTrajectoryPage(
            api: widget.api,
            sessionId: widget.sessionId,
            title: widget.title,
            onShareRun: widget.onShareRun,
            onBack: () => Navigator.of(context, rootNavigator: true).maybePop(),
          ),
        ),
      ],
    );
  }
}

/// Live canonical Trajectory route. The controller owns visible-only refresh,
/// older-page merging and one expanded-child cursor; the page remains purely
/// presentational/read-only apart from its explicit Show raw request.
class CanonicalTrajectoryPage extends StatefulWidget {
  const CanonicalTrajectoryPage({
    super.key,
    required this.api,
    required this.sessionId,
    required this.title,
    this.onShareRun,
    this.onBack,
  });

  final legacy.TrajectoryApi api;
  final String sessionId;
  final String title;
  final VoidCallback? onShareRun;
  final VoidCallback? onBack;

  @override
  State<CanonicalTrajectoryPage> createState() =>
      _CanonicalTrajectoryPageState();
}

class _CanonicalTrajectoryPageState extends State<CanonicalTrajectoryPage>
    with WidgetsBindingObserver, RouteAware {
  late TrajectoryController _controller;
  RouteObserver<ModalRoute<void>>? _routeObserver;
  ModalRoute<void>? _subscribedRoute;
  bool _appVisible = true;
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createController();
  }

  void _createController() {
    _controller = TrajectoryController(
      api: widget.api,
      sessionId: widget.sessionId,
    )..addListener(_changed);
    if (_appVisible && !_covered) unawaited(_controller.start());
  }

  void _syncVisibility() {
    _controller.setVisible(_appVisible && !_covered);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    RouteObserver<ModalRoute<void>>? observer;
    for (final candidate in Navigator.of(context).widget.observers) {
      if (candidate is RouteObserver<ModalRoute<void>>) {
        observer = candidate;
        break;
      }
    }
    if (identical(observer, _routeObserver) &&
        identical(route, _subscribedRoute)) {
      return;
    }
    final oldObserver = _routeObserver;
    final oldRoute = _subscribedRoute;
    if (oldObserver != null && oldRoute != null) {
      oldObserver.unsubscribe(this);
    }
    _routeObserver = observer;
    _subscribedRoute = route;
    if (observer != null && route != null) {
      observer.subscribe(this, route);
    }
    _syncVisibility();
  }

  @override
  void didPushNext() {
    _covered = true;
    _syncVisibility();
  }

  @override
  void didPopNext() {
    _covered = false;
    _syncVisibility();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant CanonicalTrajectoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId == widget.sessionId &&
        oldWidget.api == widget.api) {
      return;
    }
    _controller
      ..removeListener(_changed)
      ..dispose();
    _createController();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appVisible = true;
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _appVisible = false;
    }
    _syncVisibility();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final observer = _routeObserver;
    if (observer != null && _subscribedRoute != null) {
      observer.unsubscribe(this);
    }
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final root = _controller.root;
    final empty =
        root.mainSteps.isEmpty &&
        root.workers.isEmpty &&
        root.diagnostics.isEmpty;
    final loading = _controller.loading && empty;
    final failed = _controller.error != null && empty && !_controller.loading;
    return RunTrajectoryPage(
      data: V2RunTrajectoryPageData(
        title: widget.title,
        runLabel: '',
        trajectory: root,
        status: loading
            ? V2RunTrajectoryStatus.loading
            : failed
            ? V2RunTrajectoryStatus.error
            : empty
            ? V2RunTrajectoryStatus.empty
            : V2RunTrajectoryStatus.ready,
        errorMessage: _controller.error ?? 'We could not load this trajectory.',
      ),
      onShareRun: widget.onShareRun,
      onBack: widget.onBack,
      onRetry: () => unawaited(_controller.refresh()),
      onLoadEarlier: root.earlierCursor == null
          ? null
          : () => unawaited(_controller.loadEarlier()),
      onExpandWorker: (worker) => unawaited(_controller.expandWorker(worker)),
      onCollapseWorker: _controller.collapseWorker,
      onOpenSubagent: (childSessionId) {
        for (final worker in root.workers) {
          if (worker.childSessionId == childSessionId && worker.hasTranscript) {
            unawaited(V2RunRoutes.openCanonicalSubagent(context, worker));
            return;
          }
        }
      },
      onShowRaw: (after) => widget.api.showRaw(widget.sessionId, after: after),
    );
  }
}
