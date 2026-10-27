/// Client-side transcript projection for Ovid Cloud session events (P8 Task 7,
/// extended by Wave 1b).
///
/// Folds the multiplexer's (already seq-deduped) [CloudSessionEvent] stream
/// for ONE session into the existing KEPT transcript model (`Message` /
/// `MsgKind`, lib/core/state.dart) — the thin client's replacement for
/// the retired local service's in-process streaming pipeline.
/// `CloudAgentFacade` creates one [TranscriptProjection] +
/// [EventTranscriptProjector] per session and feeds it from
/// `WsMultiplexer.subscribe(sessionId)`; the projector itself does no
/// routing and no I/O.
///
/// The fold table is the binding contract:
///
/// | Event | Projection |
/// |---|---|
/// | `run_started{runId}` | busy=true, activeRunId, live `streaming` bubble, statusLine cleared |
/// | `message_delta{runId,text}` | epoch-gated append into the live bubble (a fresh bubble is armed lazily after a tool round, or for a run whose `run_started` the client never saw — CH-002) + [TranscriptProjection.liveBubbleTicks] tick; the run's FIRST delta also ends the bubble's thinking phase |
/// | `message_segment{runId,content}` | Wave 1b (CH-005): the intermediate turn's settled text — the live bubble becomes a settled text row with that content (or a row is appended when no bubble streamed, e.g. a history rebuild) |
/// | `message_completed{messageId,content}` | the live bubble REPLACED by the server-authoritative text Message (appended when no bubble is live); a message already present (same id) is replaced in place, never duplicated |
/// | `run_started_retry{attempt,nextBackoffMs}` | the composer status line; stays busy; the failed attempt's partial is DISCARDED and a fresh empty bubble re-armed |
/// | `run_failed{code,message?}` / `run_cancelled{runId,reason?}` | busy=false, error fields, still-running tool rows settle, turn-tail row |
/// | `run_completed{runId,usage?}` | busy=false, statusLine cleared, [TranscriptProjection.lastUsage] |
/// | `tool_started{runId,callId,name,args}` | the live bubble settles (CH-005 turn separation) and a `MsgKind.tool` row keyed by callId is appended (`running`) |
/// | `tool_completed{callId,isError,content,truncated}` | that row's state, detail and summary |
/// | `artifact_created{artifactId,name,sizeBytes,contentType,url,expiresAt}` | an artifact-chip row (consecutive artifacts share one row) |
/// | `todo_updated{todos}` / `goal_updated{goal}` | [TranscriptProjection.todos] / [TranscriptProjection.goal] |
/// | `plan_mode_changed{planMode}` | [TranscriptProjection.planMode] |
/// | `subagent_started{childSessionId,childRunId,agentType,prompt}` | links the running `dispatch_agent` row to its child session (the live activity card) |
/// | `subagent_completed{childRunId,status}` | that card's final state |
/// | `compaction_completed{folded,retained}` | legacy minimal event: a `MsgKind.compact` row; rich actor diagnostics: no ordinary-chat row |
/// | `workspace_hibernated` / `workspace_hydrated` | the "Waking your workspace…" phase of the next run |
/// | `system_note{code,message?}` | a turn-tail row with plain-language copy for known codes; a note with nothing to say renders NOTHING (CH-018) |
/// | `approval_requested` / `approval_resolved` | [TranscriptProjection.pendingApproval] |
///
/// Any OTHER event type is a NO-OP (forward compatibility).
///
/// Payload field names mirror the BUILT emitters exactly (camelCase). The
/// server is the contract; when this file and the server disagree, fix this
/// file.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../state.dart';
import 'cloud_errors.dart';
import 'cloud_ws.dart';
import 'tool_labels.dart';

/// `Message.toolName` marker of an artifact-chip row (Wave 1b CH-004): an
/// assistant row whose [Message.attachments] are the run's created files.
const String kArtifactRowTool = 'artifact_created';

/// The live approval prompt folded from `approval_requested`. Field names
/// mirror the emitter exactly; the payload carries NO runId — the prompt
/// belongs to whichever run the session had active.
@immutable
class CloudApprovalPrompt {
  const CloudApprovalPrompt({
    required this.approvalId,
    required this.tool,
    required this.kind,
    required this.summary,
    required this.detail,
    required this.allowAlways,
    this.expiresAt,
  });

  final String approvalId;

  /// The tool asking ("bash", "exit_plan_mode", …).
  final String tool;

  /// 'tool' | 'question' | 'plan' (agent-core ports.ts ApprovalRequest).
  final String kind;

  final String summary;
  final String detail;

  /// Whether the card may offer "Always Allow" (plain tool approvals only).
  final bool allowAlways;

  /// When the bridge timeout-denies, or null for an attended question/plan.
  final DateTime? expiresAt;
}

/// Token usage of the latest finished run (`run_completed.usage`, Wave 1b
/// CH-028). [contextTokens] is the conversation's size after that run's
/// last turn — what the context ring shows against the model window.
@immutable
class CloudRunUsage {
  const CloudRunUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.contextTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int contextTokens;
}

/// The transcript + run-status state for ONE cloud session, folded from
/// session events. Structural transcript changes notify listeners; per-delta
/// content growth does NOT — it publishes through [liveBubbleTicks] instead,
/// so a streaming token repaints only the tail row.
class TranscriptProjection extends ChangeNotifier {
  /// The transcript for this session, oldest-first.
  final List<Message> messages = <Message>[];

  /// Ticks once per accepted `message_delta` so only the live tail bubble
  /// repaints.
  final ValueNotifier<int> liveBubbleTicks = ValueNotifier<int>(0);

  bool _busy = false;
  String? _activeRunId;
  String? _statusLine;
  String? _lastErrorCode;
  String? _lastErrorMessage;

  /// The run's live streaming bubble (the `MsgKind.streaming` tail row).
  Message? _liveBubble;

  /// The live bubble's text. A buffer, not repeated `String +` (CH-036):
  /// the bubble's `content` is refreshed from it once per delta.
  final StringBuffer _liveText = StringBuffer();

  /// Wall clock of the active run's `run_started` — the `elapsedMs` source.
  DateTime? _runStartedAt;

  CloudApprovalPrompt? _pendingApproval;

  /// Tool rows by callId (tool_completed / subagent folds find them here).
  final Map<String, Message> _toolRows = <String, Message>{};

  /// A subagent's child run → the `dispatch_agent` row's callId.
  final Map<String, String> _childRunToCall = <String, String>{};

  /// Child run ids by child session id (the Jobs list's kill handle).
  final Map<String, String> _childRunBySession = <String, String>{};

  /// Runs this projection already saw terminate — a late delta for one of
  /// them must never resurrect a bubble (the implicit-start guard, CH-002).
  final Set<String> _settledRuns = <String>{};

  List<Map<String, String>>? _todos;
  Map<String, dynamic>? _goal;
  bool _goalSet = false;
  bool? _planMode;
  CloudRunUsage? _lastUsage;
  bool _workspaceAsleep = false;
  bool _waking = false;

  /// The live approval affordance. The UI-facing [Message] transcript is
  /// untouched by approvals — the chat renders the prompt as the approval
  /// dock above the composer, not as a transcript row.
  CloudApprovalPrompt? get pendingApproval => _pendingApproval;

  /// Clears the prompt when [approvalId] is the live one. Notifies directly
  /// (it runs outside an `apply`). A stale id is a no-op.
  void clearPendingApproval(String approvalId) {
    final live = _pendingApproval;
    if (live == null || live.approvalId != approvalId) return;
    _pendingApproval = null;
    notifyListeners();
  }

  /// Puts a prompt back (the facade's restore after an unconfirmed answer).
  void restorePendingApproval(CloudApprovalPrompt prompt) {
    if (_pendingApproval?.approvalId == prompt.approvalId) return;
    _pendingApproval = prompt;
    notifyListeners();
  }

  bool _changed = false;

  /// While a history rebuild folds a whole page, notifications are held and
  /// published once at the end.
  bool _batching = false;

  bool get busy => _busy;

  /// The run whose events fold into the live bubble, or null when no run is
  /// in flight.
  String? get activeRunId => _activeRunId;

  /// The composer status row ("Retrying in 9s… (attempt 3)").
  String? get statusLine => _statusLine;

  String? get lastErrorCode => _lastErrorCode;

  String? get lastErrorMessage => _lastErrorMessage;

  /// The session's todo list as last folded, or null when no `todo_updated`
  /// was seen (the caller keeps whatever it had).
  List<Map<String, String>>? get todos => _todos;

  /// The session goal as last folded (null when cleared); see [goalFolded].
  Map<String, dynamic>? get goal => _goal;

  /// True once a `goal_updated` was folded (null [goal] then means "none").
  bool get goalFolded => _goalSet;

  /// The plan-mode flag as last folded, or null when never seen.
  bool? get planMode => _planMode;

  /// Usage of the latest completed run, or null.
  CloudRunUsage? get lastUsage => _lastUsage;

  /// Child run id of the subagent running in [childSessionId], or null.
  String? childRunOf(String childSessionId) =>
      _childRunBySession[childSessionId];

  /// What the agent is doing right now, for the one phase-driven status row
  /// (CH-037): "Waking your workspace", the running tool's activity, or
  /// null (thinking / writing — the bubble itself shows that).
  String? get activity {
    if (!_busy) return null;
    if (_waking) return 'Waking your workspace';
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == 'user') break;
      if (m.kind == MsgKind.tool && m.toolState == 'running') {
        return m.toolSessionId != null && m.toolName == 'dispatch_agent'
            ? 'Working with ${m.toolTitle ?? 'a subagent'}'
            : _activityOf(m);
      }
    }
    return null;
  }

  static String? _activityOf(Message m) {
    final input = _decodeInput(m.toolInput);
    return cloudToolLabel(m.toolName ?? '', input).activity;
  }

  static Map<String, dynamic> _decodeInput(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    try {
      final d = jsonDecode(raw);
      return d is Map<String, dynamic> ? d : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  /// Replaces the transcript with the offline/paged cache so events fold on
  /// top. A live bubble belonging to a run still in flight stays at the tail.
  void seedFromHistory(List<Message> cached) {
    messages
      ..clear()
      ..addAll(cached);
    _reindexToolRows();
    final live = _liveBubble;
    if (live != null && _busy) messages.add(live);
    notifyListeners();
  }

  /// Rebuilds [_toolRows] from the current rows (after a seed).
  void _reindexToolRows() {
    _toolRows.clear();
    for (final m in messages) {
      final id = m.privateSyncId;
      if (m.kind == MsgKind.tool && id.startsWith('tool:')) {
        _toolRows[id.substring(5)] = m;
      }
    }
  }

  /// Takes over [other]'s complete state (Wave 1b history rebuild: a page is
  /// folded into a scratch projection, then adopted in one notification).
  void adopt(TranscriptProjection other) {
    messages
      ..clear()
      ..addAll(other.messages);
    _busy = other._busy;
    _activeRunId = other._activeRunId;
    _statusLine = other._statusLine;
    _lastErrorCode = other._lastErrorCode;
    _lastErrorMessage = other._lastErrorMessage;
    _liveBubble = other._liveBubble;
    _liveText
      ..clear()
      ..write(other._liveText.toString());
    _runStartedAt = other._runStartedAt;
    _pendingApproval = other._pendingApproval;
    _toolRows
      ..clear()
      ..addAll(other._toolRows);
    _childRunToCall
      ..clear()
      ..addAll(other._childRunToCall);
    _childRunBySession
      ..clear()
      ..addAll(other._childRunBySession);
    _settledRuns
      ..clear()
      ..addAll(other._settledRuns);
    if (other._todos != null) _todos = other._todos;
    if (other._goalSet) {
      _goal = other._goal;
      _goalSet = true;
    }
    if (other._planMode != null) _planMode = other._planMode;
    if (other._lastUsage != null) _lastUsage = other._lastUsage;
    _workspaceAsleep = other._workspaceAsleep;
    _waking = other._waking;
    notifyListeners();
  }

  /// Wave 1b (history edits): drops [index] and every later row — the
  /// server already removed them. A live bubble among them is dropped too;
  /// run state is untouched (the caller re-arms it for a new run).
  void truncateAt(int index) {
    if (index < 0 || index >= messages.length) return;
    final removed = messages.sublist(index);
    messages.removeRange(index, messages.length);
    if (_liveBubble != null && removed.contains(_liveBubble)) {
      _liveBubble = null;
      _liveText.clear();
    }
    _reindexToolRows();
    notifyListeners();
  }

  /// No run is active server-side (a history page said so) but the fold
  /// still thinks one is — its terminal event was never seen. Settle it
  /// quietly: the partial text stays, nothing shimmers, no Stop button.
  void settleIdle() {
    if (!_busy && _liveBubble == null && _pendingApproval == null) return;
    final run = _activeRunId;
    if (run != null) _settledRuns.add(run);
    _busy = false;
    _activeRunId = null;
    _statusLine = null;
    _pendingApproval = null;
    _waking = false;
    _settleRunningTools('stopped');
    _settleLiveBubble();
    notifyListeners();
  }

  @override
  void dispose() {
    liveBubbleTicks.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Internal mutators — same library as the projector, which drives them.
  // -------------------------------------------------------------------------

  void _setBusy(bool v) {
    if (_busy == v) return;
    _busy = v;
    _changed = true;
  }

  void _setActiveRunId(String? v) {
    if (_activeRunId == v) return;
    _activeRunId = v;
    _changed = true;
  }

  void _setStatusLine(String? v) {
    if (_statusLine == v) return;
    _statusLine = v;
    _changed = true;
  }

  void _setLastError(String? code, String? message) {
    if (_lastErrorCode == code && _lastErrorMessage == message) return;
    _lastErrorCode = code;
    _lastErrorMessage = message;
    _changed = true;
  }

  void _setWaking(bool v) {
    if (_waking == v) return;
    _waking = v;
    _changed = true;
  }

  /// approvalId-keyed (not identity).
  void _setPendingApproval(CloudApprovalPrompt? v) {
    if (_pendingApproval?.approvalId == v?.approvalId) return;
    _pendingApproval = v;
    _changed = true;
  }

  /// Appends the run's live streaming bubble, settling any leftover bubble
  /// first (a missed terminal event must never stack a second shimmer).
  void _appendLiveBubble(Message bubble) {
    _settleLiveBubble();
    _liveBubble = bubble;
    _liveText
      ..clear()
      ..write(bubble.content);
    messages.add(bubble);
    _changed = true;
  }

  /// Replaces the live streaming bubble with [finalized] at the bubble's
  /// position (appends when no bubble is tracked).
  void _replaceLiveBubble(Message finalized) {
    final live = _liveBubble;
    final idx = live == null ? -1 : messages.indexOf(live);
    if (idx >= 0) {
      messages[idx] = finalized;
    } else {
      messages.add(finalized);
    }
    _liveBubble = null;
    _liveText.clear();
    _changed = true;
  }

  /// Replaces an ALREADY-PRESENT message (same `privateSyncId`) with the
  /// server-authoritative [finalized] row and drops the live bubble.
  void _replaceExistingMessage(String messageId, Message finalized) {
    final live = _liveBubble;
    if (live != null) messages.remove(live);
    _liveBubble = null;
    _liveText.clear();
    final idx = messages.indexWhere((m) => m.privateSyncId == messageId);
    if (idx >= 0) {
      messages[idx] = finalized;
    } else {
      messages.add(finalized);
    }
    _changed = true;
  }

  void _appendMessage(Message m) {
    messages.add(m);
    _changed = true;
  }

  /// Settles the live streaming bubble: one with partial content is promoted
  /// to a settled text row, an empty one is removed outright.
  void _settleLiveBubble() {
    final live = _liveBubble;
    if (live == null) return;
    _liveBubble = null;
    _liveText.clear();
    if (live.content.isEmpty) {
      if (messages.remove(live)) _changed = true;
      return;
    }
    live.kind = MsgKind.text;
    live.thinking = false;
    _changed = true;
  }

  /// Every still-running tool row of the turn becomes [state] (a terminal
  /// can never leave a spinner behind).
  void _settleRunningTools(String state) {
    for (final m in _toolRows.values) {
      if (m.toolState == 'running') {
        m.toolState = state;
        _changed = true;
      }
    }
  }

  /// Discards the live bubble and re-arms [fresh] in its place at the tail
  /// (run_started_retry). No-op when no run is in flight.
  void _resetLiveBubble(Message fresh) {
    final live = _liveBubble;
    if (live == null) return;
    messages.remove(live);
    _liveBubble = fresh;
    _liveText.clear();
    messages.add(fresh);
    _changed = true;
  }

  /// The run's FIRST `message_delta` lands: the live bubble stops thinking.
  /// Any content the bubble already held is kept as a settled reasoning row
  /// inserted above it (the built wire always arms the bubble empty).
  void _beginLiveAnswer(Message live, DateTime now) {
    if (!live.thinking) return;
    final noise = live.content;
    if (noise.isNotEmpty) {
      final startedAt = _runStartedAt;
      int? elapsedMs = startedAt == null
          ? null
          : now.difference(startedAt).inMilliseconds;
      if (elapsedMs != null && elapsedMs < 0) elapsedMs = 0;
      final thought = Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        content: noise,
        elapsedMs: elapsedMs,
        time: now,
      );
      final idx = messages.indexOf(live);
      if (idx >= 0) {
        messages.insert(idx, thought);
      } else {
        messages.add(thought);
      }
      live.content = '';
      _liveText.clear();
    }
    live.thinking = false;
    _changed = true;
  }

  /// One notification per mutating `apply`.
  void _flushNotify() {
    if (!_changed || _batching) return;
    _changed = false;
    notifyListeners();
  }
}

/// Folds cloud session events into a [TranscriptProjection] target. Applies
/// only events the multiplexer has already seq-deduped; re-checks anyway
/// (monotonic seq guard).
class EventTranscriptProjector {
  /// [clock] is injectable so tests can pin `elapsedMs` deterministically.
  EventTranscriptProjector(this.target, {DateTime Function()? clock})
    : _clock = clock ?? _systemClock;

  final TranscriptProjection target;
  final DateTime Function() _clock;

  static DateTime _systemClock() => DateTime.now();

  /// Max seq already folded — the exactly-once guard at O(1) memory.
  String? _lastSeq;

  /// The timestamp rows get while a history rebuild folds (the event's own
  /// `ts`, so reloaded rows keep their real times); null = live (clock).
  DateTime? _replayTs;

  DateTime _now() => _replayTs ?? _clock();

  /// Seeds (or clears, with null) the exactly-once cursor.
  void seedCursor(String? seq) => _lastSeq = seq;

  /// The current high-water mark (test/observability seam).
  String? get cursor => _lastSeq;

  /// Wave 1b (CH-002/CH-003/CH-006): rebuilds [target] from one history
  /// page — the page's rows (oldest-first) interleaved by time with the
  /// page's settled events — so a reload shows tool rows, artifacts,
  /// intermediate text, errors and a run still in flight exactly as they
  /// streamed. Assistant rows that a `message_completed` in [events]
  /// produces are taken from the event (it carries the same id and text).
  /// When [activeRunId] is null the server has no run in flight: anything
  /// the fold left running settles quietly. The exactly-once cursor ends at
  /// [watermark] (the page's lastEventSeq) or the last event's seq.
  ///
  /// The fold runs on a scratch projection and is adopted in ONE
  /// notification.
  static void rebuild(
    TranscriptProjection target,
    EventTranscriptProjector projector, {
    required List<Message> rows,
    required List<CloudSessionEvent> events,
    required String? watermark,
    required String? activeRunId,
  }) {
    final scratch = foldPage(rows: rows, events: events);
    if (activeRunId == null) scratch.settleIdle();
    target.adopt(scratch);
    String? cursor = watermark;
    if (events.isNotEmpty) {
      final last = events.last.seq;
      if (cursor == null || _seqCompare(last, cursor) > 0) cursor = last;
    }
    projector.seedCursor(cursor);
    scratch.dispose();
  }

  /// Folds one history page into a FRESH projection (no live state is
  /// touched) — used directly for older pages, which are prepended.
  static TranscriptProjection foldPage({
    required List<Message> rows,
    required List<CloudSessionEvent> events,
  }) {
    final scratch = TranscriptProjection();
    final folder = EventTranscriptProjector(scratch);
    scratch._batching = true;
    final completedIds = <String>{
      for (final e in events)
        if (e.type == 'message_completed' && e.payload['messageId'] is String)
          e.payload['messageId'] as String,
    };
    var ri = 0;
    var ei = 0;
    while (ri < rows.length || ei < events.length) {
      final takeRow =
          ei >= events.length ||
          (ri < rows.length && !rows[ri].time.isAfter(events[ei].ts));
      if (takeRow) {
        final row = rows[ri++];
        if (row.role == 'assistant' &&
            completedIds.contains(row.privateSyncId)) {
          continue; // the event below rebuilds it in the right place
        }
        if (scratch.messages.any((m) => m.privateSyncId == row.privateSyncId)) {
          continue;
        }
        // A user prompt starts a new turn: a bubble a lost terminal left
        // open must not swallow the next answer.
        if (row.role == 'user' && scratch._liveBubble != null) {
          scratch._settleLiveBubble();
        }
        scratch.messages.add(row);
      } else {
        final event = events[ei++];
        folder._replayTs = event.ts.toLocal();
        folder.apply(event);
      }
    }
    folder._replayTs = null;
    scratch._batching = false;
    scratch._changed = false;
    return scratch;
  }

  /// Folds ONE event. Unknown types are ignored (never throw). Payload
  /// fields are parsed defensively.
  void apply(CloudSessionEvent event) {
    final last = _lastSeq;
    if (last != null && _seqCompare(event.seq, last) <= 0) return;
    _lastSeq = event.seq;
    final p = event.payload;
    switch (event.type) {
      case 'run_started':
        _onRunStarted(p);
      case 'message_delta':
        _onMessageDelta(p);
      case 'message_segment':
        _onMessageSegment(p, event.seq);
      case 'message_completed':
        _onMessageCompleted(p);
      case 'run_started_retry':
        _onRunStartedRetry(p);
      case 'run_failed':
        _onRunFailed(p);
      case 'run_cancelled':
        _onRunCancelled(p);
      case 'run_completed':
        _onRunCompleted(p);
      case 'system_note':
        _onSystemNote(p);
      case 'approval_requested':
        _onApprovalRequested(p);
      case 'approval_resolved':
        _onApprovalResolved(p);
      case 'tool_started':
        _onToolStarted(p);
      case 'tool_completed':
        _onToolCompleted(p);
      case 'artifact_created':
        _onArtifactCreated(p, event.seq);
      case 'todo_updated':
        _onTodoUpdated(p);
      case 'goal_updated':
        _onGoalUpdated(p);
      case 'plan_mode_changed':
        final next = p['planMode'];
        if (next is bool && target._planMode != next) {
          target._planMode = next;
          target._changed = true;
        }
      case 'subagent_started':
        _onSubagentStarted(p);
      case 'subagent_completed':
        _onSubagentCompleted(p);
      case 'compaction_completed':
        // Rich main/worker operational diagnostics never become ordinary chat
        // rows. The legacy minimal row remains for old installed projections;
        // rich metadata is visible only in Trajectory diagnostics/Show raw.
        if (_str(p, 'actorKind') == null &&
            p['compactionId'] == null &&
            p['checkpointId'] == null) {
          _onCompactionCompleted(p, event.seq);
        }
      case 'workspace_hibernated':
        target._workspaceAsleep = true;
      case 'workspace_hydrated':
        target._workspaceAsleep = false;
        target._setWaking(false);
      default:
        // Fold-table-absent type: no-op. Any future TERMINAL-ish event type
        // must update this switch in the same change as its emitter.
        return;
    }
    target._flushNotify();
  }

  // -------------------------------------------------------------------------
  // Run lifecycle
  // -------------------------------------------------------------------------

  void _startRun(String? runId) {
    final now = _now();
    target._setBusy(true);
    target._setActiveRunId(runId);
    target._setStatusLine(null);
    target._runStartedAt = now;
    if (target._workspaceAsleep) target._setWaking(true);
    target._appendLiveBubble(
      Message(
        role: 'assistant',
        kind: MsgKind.streaming,
        thinking: true,
        content: '',
        time: now,
      ),
    );
  }

  void _onRunStarted(Map<String, dynamic> payload) {
    final runId = _str(payload, 'runId');
    // Double-apply guard: a run_started for the run already active appends
    // exactly one bubble.
    if (runId != null && runId == target._activeRunId) return;
    _startRun(runId);
  }

  void _onMessageDelta(Map<String, dynamic> payload) {
    final runId = _str(payload, 'runId');
    final text = _str(payload, 'text');
    if (text == null || text.isEmpty || runId == null) return;
    if (runId != target._activeRunId) {
      // CH-002: a run whose run_started sits below the replay cursor (the
      // chat was reopened mid-run) still streams — start it implicitly.
      // A run this projection saw terminate, or a delta while ANOTHER run
      // is active, stays dropped (the epoch gate).
      if (target._activeRunId != null || target._settledRuns.contains(runId)) {
        return;
      }
      _startRun(runId);
    }
    target._setWaking(false);
    var live = target._liveBubble;
    if (live == null) {
      // After a tool round the next turn's text streams into a FRESH bubble
      // below the tool rows (CH-005), never into the settled text above.
      live = Message(
        role: 'assistant',
        kind: MsgKind.streaming,
        thinking: false,
        content: '',
        time: _now(),
      );
      target._appendLiveBubble(live);
    }
    target._beginLiveAnswer(live, _now());
    target._liveText.write(text);
    live.content = target._liveText.toString();
    target.liveBubbleTicks.value++;
  }

  void _onMessageSegment(Map<String, dynamic> payload, String seq) {
    final runId = _str(payload, 'runId');
    final content = _str(payload, 'content') ?? '';
    if (runId != null && runId != target._activeRunId) return;
    if (content.trim().isEmpty) {
      target._settleLiveBubble();
      return;
    }
    final live = target._liveBubble;
    final settled = Message(
      role: 'assistant',
      kind: MsgKind.text,
      content: content,
      privateSyncId: 'seg:$seq',
      time: live?.time ?? _now(),
    );
    target._replaceLiveBubble(settled);
  }

  void _onMessageCompleted(Map<String, dynamic> payload) {
    final now = _now();
    final startedAt = target._runStartedAt;
    final active = target._activeRunId != null;
    int? elapsedMs = !active || startedAt == null
        ? null
        : now.difference(startedAt).inMilliseconds;
    if (elapsedMs != null && elapsedMs < 0) elapsedMs = 0;
    final messageId = _str(payload, 'messageId');
    final run = target._activeRunId;
    // Its answer is in: a late delta of this run must never re-open it.
    if (run != null) target._settledRuns.add(run);
    final finalized = Message(
      role: 'assistant',
      kind: MsgKind.text,
      content: _str(payload, 'content') ?? '',
      privateSyncId: messageId,
      thinking: false,
      elapsedMs: elapsedMs,
      time: now,
    );
    if (messageId != null &&
        target.messages.any((m) => m.privateSyncId == messageId)) {
      // A replay overlapping a page that already holds this message.
      if (active) {
        target._replaceExistingMessage(messageId, finalized);
      } else {
        final idx = target.messages.indexWhere(
          (m) => m.privateSyncId == messageId,
        );
        if (target.messages[idx].content != finalized.content) {
          target.messages[idx] = finalized;
          target._changed = true;
        }
      }
    } else {
      // CH-002: with no run active (its run_started was never seen) the
      // answer still lands — appended after everything already shown.
      target._replaceLiveBubble(finalized);
    }
    target._setActiveRunId(null);
  }

  void _onRunStartedRetry(Map<String, dynamic> payload) {
    final attempt = _int(payload, 'attempt');
    final nextBackoffMs = _int(payload, 'nextBackoffMs');
    if (attempt == null || nextBackoffMs == null) return;
    target._resetLiveBubble(
      Message(
        role: 'assistant',
        kind: MsgKind.streaming,
        thinking: true,
        content: '',
        time: _now(),
      ),
    );
    target._setStatusLine(
      'Retrying in ${nextBackoffMs ~/ 1000}s… (attempt $attempt)',
    );
  }

  void _terminal({required String toolState}) {
    final run = target._activeRunId;
    if (run != null) target._settledRuns.add(run);
    target._setBusy(false);
    target._setStatusLine(null);
    target._setActiveRunId(null);
    target._setWaking(false);
    // A prompt cannot outlive its run.
    target._setPendingApproval(null);
    target._settleRunningTools(toolState);
    target._settleLiveBubble();
  }

  void _onRunFailed(Map<String, dynamic> payload) {
    final code = _str(payload, 'code');
    final message = _str(payload, 'message');
    target._setLastError(code, message);
    _terminal(toolState: code == 'cancelled' ? 'stopped' : 'error');
    final copy = code == null || code == 'cancelled'
        ? null
        : cloudErrorCopy(code, message: message);
    target._appendMessage(
      Message(
        role: 'assistant',
        kind: MsgKind.turnTail,
        // CH-019: plain language from the shared copy table — never a raw
        // snake_case code or provider exception text. A user stop keeps the
        // server's own words.
        content: code == 'cancelled'
            ? (message ?? humanText(code!))
            : copy == null
            ? (message ?? '')
            : copy.text,
        // The ONE surface of a run-level failure (CH-019): the row knows its
        // code (Retry / Pick model) and keeps the raw text behind "Details".
        toolName: code == 'cancelled' ? 'run_cancelled' : 'run_failed',
        toolSummary: code,
        toolDetail: copy?.detail,
        toolState: code == 'cancelled' ? 'stopped' : 'error',
        time: _now(),
      ),
    );
  }

  /// The full processor's terminal for a user-initiated cancel: folds as
  /// the compat spelling `run_failed{code:'cancelled'}`.
  void _onRunCancelled(Map<String, dynamic> payload) {
    final reason = _str(payload, 'reason');
    _onRunFailed(<String, dynamic>{
      'code': 'cancelled',
      'message': reason ?? humanText('cancelled'),
    });
  }

  void _onRunCompleted(Map<String, dynamic> payload) {
    final usage = payload['usage'];
    if (usage is Map) {
      int n(String k) => (usage[k] is num) ? (usage[k] as num).toInt() : 0;
      target._lastUsage = CloudRunUsage(
        inputTokens: n('inputTokens'),
        outputTokens: n('outputTokens'),
        cacheReadTokens: n('cacheReadTokens'),
        contextTokens: n('contextTokens'),
      );
      target._changed = true;
    }
    _terminal(toolState: 'ok');
  }

  // -------------------------------------------------------------------------
  // Agent activity (Wave 1b CH-004)
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _args(Map<String, dynamic> payload) {
    final a = payload['args'] ?? payload['input'];
    return a is Map ? Map<String, dynamic>.from(a) : const <String, dynamic>{};
  }

  /// The tool's identifying args as JSON, never a file body (the row's
  /// expanded "input" and the subagent card's name/task source).
  static String _inputJson(Map<String, dynamic> args) {
    final small = <String, dynamic>{};
    for (final e in args.entries) {
      final v = e.value;
      if (v is String) {
        small[e.key] = v.length > 400 ? '${v.substring(0, 400)}…' : v;
      } else if (v is num || v is bool || v == null) {
        small[e.key] = v;
      }
    }
    return jsonEncode(small);
  }

  void _onToolStarted(Map<String, dynamic> payload) {
    final callId = _str(payload, 'callId');
    final name = _str(payload, 'name') ?? 'tool';
    if (callId == null || target._toolRows.containsKey(callId)) return;
    final runId = _str(payload, 'runId');
    if (runId != null &&
        target._activeRunId == null &&
        !target._settledRuns.contains(runId)) {
      // CH-002: a tool of a run whose run_started was never seen.
      target._setBusy(true);
      target._setActiveRunId(runId);
    }
    target._setWaking(false);
    // CH-005: the turn's text so far is closed above the tool row.
    target._settleLiveBubble();
    final args = _args(payload);
    final label = cloudToolLabel(name, args);
    final row = Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: name,
      toolTitle: label.title,
      toolSummary: label.summary,
      toolInput: _inputJson(args),
      toolState: 'running',
      privateSyncId: 'tool:$callId',
      time: _now(),
    );
    target._toolRows[callId] = row;
    target._appendMessage(row);
  }

  void _onToolCompleted(Map<String, dynamic> payload) {
    final callId = _str(payload, 'callId');
    if (callId == null) return;
    var row = target._toolRows[callId];
    if (row == null) {
      // Its start fell outside a history window: still show what ran.
      final name = _str(payload, 'name') ?? 'tool';
      final label = cloudToolLabel(name, const <String, dynamic>{});
      row = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: name,
        toolTitle: label.title,
        toolSummary: '',
        privateSyncId: 'tool:$callId',
        time: _now(),
      );
      target._toolRows[callId] = row;
      target._appendMessage(row);
    }
    final failed = payload['isError'] == true || payload['ok'] == false;
    row.toolState = failed ? 'error' : 'ok';
    final content = _str(payload, 'content') ?? '';
    row.toolDetail = payload['truncated'] == true
        ? '$content\n… (output truncated)'
        : content;
    if ((row.toolSummary ?? '').isEmpty && content.trim().isNotEmpty) {
      final first = content.trim().split('\n').first;
      row.toolSummary = first.length > 120
          ? '${first.substring(0, 119)}…'
          : first;
    }
    target._changed = true;
  }

  void _onArtifactCreated(Map<String, dynamic> payload, String seq) {
    final name = _str(payload, 'name');
    if (name == null) return;
    // The URL carries the artifact id (presigned R2 key path, or the opaque
    // key of a W12 signed CDN URL); the chip re-mints before opening, so an
    // expired URL in history still works.
    final attachment = MessageAttachment(
      name: name,
      size: _int(payload, 'sizeBytes') ?? 0,
      url: _str(payload, 'url'),
    );
    // Consecutive artifacts of one turn share one chip row (the live bubble,
    // when one is streaming, stays below it).
    final msgs = target.messages;
    var lastIdx = msgs.length - 1;
    if (lastIdx >= 0 && identical(msgs[lastIdx], target._liveBubble)) {
      lastIdx--;
    }
    final last = lastIdx < 0 ? null : msgs[lastIdx];
    if (last != null && last.toolName == kArtifactRowTool) {
      if (last.attachments.any((a) => a.url == attachment.url)) return;
      last.attachments = <MessageAttachment>[...last.attachments, attachment];
      target._changed = true;
      return;
    }
    final live = target._liveBubble;
    final row = Message(
      role: 'assistant',
      kind: MsgKind.text,
      toolName: kArtifactRowTool,
      toolState: 'ok',
      attachments: <MessageAttachment>[attachment],
      privateSyncId: 'art:$seq',
      time: _now(),
    );
    if (live != null) {
      // Keep the streaming bubble at the tail.
      final idx = target.messages.indexOf(live);
      if (idx >= 0) {
        target.messages.insert(idx, row);
        target._changed = true;
        return;
      }
    }
    target._appendMessage(row);
  }

  void _onTodoUpdated(Map<String, dynamic> payload) {
    final raw = payload['todos'];
    if (raw is! List) return;
    target._todos = <Map<String, String>>[
      for (final t in raw)
        if (t is Map)
          <String, String>{
            for (final e in t.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          },
    ];
    target._changed = true;
  }

  void _onGoalUpdated(Map<String, dynamic> payload) {
    final g = payload['goal'];
    target._goal = g is Map ? Map<String, dynamic>.from(g) : null;
    target._goalSet = true;
    target._changed = true;
  }

  void _onSubagentStarted(Map<String, dynamic> payload) {
    final childSessionId = _str(payload, 'childSessionId');
    final childRunId = _str(payload, 'childRunId');
    if (childSessionId == null) return;
    Message? row;
    String? callId;
    // The dispatch_agent call that is waiting on this child: the newest
    // running dispatch row not yet linked to a child.
    for (final e in target._toolRows.entries.toList().reversed) {
      final m = e.value;
      if (m.toolName == 'dispatch_agent' &&
          m.toolState == 'running' &&
          m.toolSessionId == null) {
        row = m;
        callId = e.key;
        break;
      }
    }
    if (row == null) {
      // No dispatch row (its start fell outside a history window): the card
      // is still shown from the event alone.
      callId = 'sub:${childRunId ?? childSessionId}';
      final type = _str(payload, 'agentType') ?? 'Subagent';
      row = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'dispatch_agent',
        toolTitle: type,
        toolSummary: _str(payload, 'prompt') ?? '',
        toolInput: jsonEncode(<String, dynamic>{
          'agentType': type,
          'prompt': _str(payload, 'prompt') ?? '',
        }),
        toolState: 'running',
        privateSyncId: 'tool:$callId',
        time: _now(),
      );
      target._toolRows[callId] = row;
      target._settleLiveBubble();
      target._appendMessage(row);
    }
    row.toolSessionId = childSessionId;
    // W2's short @-address rides the event; keep it on the card's input so
    // the @ menu can offer the same handle the server/agent uses.
    final handle = _str(payload, 'handle');
    if (handle != null && handle.isNotEmpty) {
      var input = <String, dynamic>{};
      final raw = row.toolInput;
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) input = Map<String, dynamic>.from(decoded);
        } catch (_) {
          // A malformed input blob is not worth failing the card for.
        }
      }
      input['handle'] = handle;
      row.toolInput = jsonEncode(input);
    }
    final type = _str(payload, 'agentType');
    if (type != null && type.isNotEmpty && type != 'general-purpose') {
      row.toolTitle = type;
    }
    if (childRunId != null) {
      target._childRunToCall[childRunId] = callId!;
      target._childRunBySession[childSessionId] = childRunId;
    }
    target._changed = true;
  }

  void _onSubagentCompleted(Map<String, dynamic> payload) {
    final childRunId = _str(payload, 'childRunId');
    if (childRunId == null) return;
    final callId = target._childRunToCall[childRunId];
    final row = callId == null ? null : target._toolRows[callId];
    if (row == null || row.toolState != 'running') return;
    row.toolState = switch (_str(payload, 'status')) {
      'failed' => 'error',
      'cancelled' => 'stopped',
      _ => 'ok',
    };
    target._changed = true;
  }

  void _onCompactionCompleted(Map<String, dynamic> payload, String seq) {
    final folded = _int(payload, 'folded') ?? 0;
    final row = Message(
      role: 'assistant',
      kind: MsgKind.compact,
      content: folded > 0
          ? 'Summarized $folded earlier message${folded == 1 ? '' : 's'} to '
                'keep the conversation within the model\'s memory'
          : 'Summarized earlier messages to keep the conversation within the '
                'model\'s memory',
      privateSyncId: 'compact:$seq',
      time: _now(),
    );
    final live = target._liveBubble;
    final idx = live == null ? -1 : target.messages.indexOf(live);
    if (idx >= 0) {
      target.messages.insert(idx, row);
      target._changed = true;
    } else {
      target._appendMessage(row);
    }
  }

  /// CH-018: plain-language copy for the notes the server emits without a
  /// displayable text; null = render nothing.
  static String? systemNoteText(Map<String, dynamic> payload) {
    final code = _str(payload, 'code');
    switch (code) {
      case 'run_merged':
        return 'Your follow-up was added to the running task.';
      case 'command_blocked':
        return _str(payload, 'message') ?? 'A command was blocked for safety.';
      case 'hook_block_ignored':
      case 'compaction_summary_failed':
      case 'hook_notification':
      case 'warm_lru':
        // Operator/plugin diagnostics: never shown as chat rows.
        return null;
      case 'hibernated':
      case 'workspace_hibernated':
        return null;
    }
    if (payload['scheduleId'] != null) {
      final status = _str(payload, 'status');
      return status == 'failed'
          ? 'The scheduled run failed.'
          : 'Scheduled run finished.';
    }
    final text = _str(payload, 'text') ?? _str(payload, 'message');
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }

  void _onSystemNote(Map<String, dynamic> payload) {
    final text = systemNoteText(payload);
    if (text == null) return;
    target._appendMessage(
      Message(
        role: 'assistant',
        kind: MsgKind.turnTail,
        content: text,
        time: _now(),
      ),
    );
  }

  void _onApprovalRequested(Map<String, dynamic> payload) {
    final approvalId = _str(payload, 'approvalId');
    final tool = _str(payload, 'tool');
    if (approvalId == null || approvalId.isEmpty || tool == null) return;
    final rawExpiresAt = payload['expiresAt'];
    target._setPendingApproval(
      CloudApprovalPrompt(
        approvalId: approvalId,
        tool: tool,
        kind: _str(payload, 'kind') ?? 'tool',
        summary: _str(payload, 'summary') ?? '',
        detail: _str(payload, 'detail') ?? '',
        allowAlways: payload['allowAlways'] == true,
        expiresAt: rawExpiresAt is String
            ? DateTime.tryParse(rawExpiresAt)
            : null,
      ),
    );
  }

  void _onApprovalResolved(Map<String, dynamic> payload) {
    final live = target._pendingApproval;
    if (live == null) return;
    final approvalId = _str(payload, 'approvalId');
    if (approvalId == null || approvalId != live.approvalId) return;
    target._setPendingApproval(null);
  }

  /// Human text for the run_failed codes whose server payloads carry no
  /// message.
  @visibleForTesting
  static String humanText(String code) {
    if (code == 'cancelled') return 'Stopped by user.';
    return cloudErrorCopy(code).text;
  }

  // -------------------------------------------------------------------------
  // Defensive payload access
  // -------------------------------------------------------------------------

  static String? _str(Map<String, dynamic> payload, String key) =>
      payload[key] is String ? payload[key] as String : null;

  static int? _int(Map<String, dynamic> payload, String key) =>
      payload[key] is num ? (payload[key] as num).toInt() : null;

  /// Redis stream ids `"<ms>-<idx>"`, compared NUMERICALLY on both parts —
  /// mirrors `WsMultiplexer.compareSeq`.
  static int _seqCompare(String a, String b) {
    final ap = _seqParts(a);
    final bp = _seqParts(b);
    if (ap.$1 != bp.$1) return ap.$1 < bp.$1 ? -1 : 1;
    if (ap.$2 != bp.$2) return ap.$2 < bp.$2 ? -1 : 1;
    return 0;
  }

  /// Public numeric seq compare (the facade's never-move-backwards guard).
  static int compareSeq(String a, String b) => _seqCompare(a, b);

  static (int, int) _seqParts(String seq) {
    final dash = seq.indexOf('-');
    final ms = int.tryParse(dash == -1 ? seq : seq.substring(0, dash)) ?? 0;
    final idx = int.tryParse(dash == -1 ? '0' : seq.substring(dash + 1)) ?? 0;
    return (ms, idx);
  }
}
