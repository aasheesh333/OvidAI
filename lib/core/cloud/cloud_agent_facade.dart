/// `CloudAgentFacade` — the AgentService-shaped client over Ovid Cloud
/// (P8 Task 8).
///
/// Composes the landed client pieces behind the [AgentSurface] seam:
///
///  * `CloudRestClient` (Task 5) — send/cancel/patch/attachment endpoints;
///  * `WsMultiplexer` (Task 6) — one socket, per-session subscriptions;
///  * `EventTranscriptProjector` / `TranscriptProjection` (Task 7) — the
///    event→transcript fold.
///
/// The facade is DARK: nothing constructs it outside tests until Task 10
/// binds `chat_screen.dart` to `Distribution.cloudExecution`. It owns no
/// local execution machinery — no tool loop, no approvals, no jobs. Sections
/// whose server events have not landed yet (P2 jobs, P3 approvals/usage) are
/// explicitly inert with a marker rather than silently faked.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../agent_service.dart';
import '../state.dart';
import 'agent_surface.dart';
import 'cloud_rest.dart';
import 'cloud_ws.dart';
import 'event_projection.dart';
import 'models.dart';

/// The subset of Task 9's `CloudSessionStore` this facade consumes.
///
/// Declared here because Task 8 lands BEFORE Task 9 creates
/// `cloud_session_store.dart`; the concrete store implements this seam and
/// Task 9 replaces the constructor's type with the real class. Keeping the
/// surface minimal means the facade compiles and is testable while dark.
abstract class CloudSessionStoreSeam {
  /// The server session id for a local id (null when unmapped).
  String? serverIdFor(String localSessionId);

  /// True when the client must queue prompts instead of sending them.
  bool get offline;

  /// Queues [content] for a later FIFO flush.
  Future<void> enqueue(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
  });
}

/// AgentService-shaped facade over the cloud REST + WS surface.
class CloudAgentFacade extends ChangeNotifier implements AgentSurface {
  CloudAgentFacade({
    required CloudRestClient rest,
    required WsMultiplexer ws,
    required CloudSessionStoreSeam? store,
  })  : _rest = rest, // ignore: prefer_initializing_formals
        _ws = ws, // ignore: prefer_initializing_formals
        _store = store; // ignore: prefer_initializing_formals

  final CloudRestClient _rest;
  final WsMultiplexer _ws;
  final CloudSessionStoreSeam? _store;

  static CloudAgentFacade? _instance;

  /// The process-wide default. Nothing reads it until Task 10 flips
  /// `chat_screen.dart` onto the facade.
  static CloudAgentFacade get I => _instance ??= CloudAgentFacade(
        rest: CloudRestClient.I,
        ws: WsMultiplexer.I,
        store: null,
      );

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(CloudAgentFacade facade) => _instance = facade;

  /// Clears the singleton — test wiring only.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  final Map<String, _SessionCloudState> _sessions =
      <String, _SessionCloudState>{};
  final Map<String, ValueNotifier<bool>> _busyNotifiers =
      <String, ValueNotifier<bool>>{};

  /// Optimistic per-session mode (server id → mode) until the PATCH settles.
  /// Absent means "no explicit pick yet" — the persisted session mode is the
  /// effective value (see [mode]).
  final Map<String, AgentMode> _modes = <String, AgentMode>{};

  /// The facade's composer queue per server session. The cloud has no
  /// client-side steering channel yet: a queued row is held here and sent as
  /// the next run when the current one terminalizes (AgentService's
  /// continuation semantics). Task 9's outbox owns OFFLINE persistence; this
  /// queue is the in-memory, online path.
  final Map<String, List<_QueuedCloudMessage>> _queues =
      <String, List<_QueuedCloudMessage>>{};
  int _nextQueueId = 1;

  /// Staged attachments per session (server id → files). No workspace copy:
  /// the bytes are uploaded straight from the staged file path.
  final Map<String, List<({String name, String path, int size})>>
      _attachments =
      <String, List<({String name, String path, int size})>>{};

  /// REST/WS failures with no projection row yet (mode PATCH, send, stream
  /// errors). Keyed by server session id.
  final Map<String, (String code, String message)> _errors =
      <String, (String, String)>{};

  final Map<String, Future<void>> _modePatches = <String, Future<void>>{};
  Future<void>? _lastHardStop;
  bool _disposed = false;

  /// Ticks returned when there is no session at all (pre-boot), so the
  /// surface stays total without opening a subscription.
  final ValueNotifier<int> _orphanTicks = ValueNotifier<int>(0);

  // -------------------------------------------------------------------------
  // Session resolution
  // -------------------------------------------------------------------------

  /// Resolves a local or server session id to the server id. Task 9's store
  /// maps local ids; until then (and for already-server ids) the id passes
  /// through. Null falls back to the active session.
  String? _serverId(String? localOrServerId) {
    final id = localOrServerId ?? AppState.I.activeSessionId;
    if (id == null || id.isEmpty) return null;
    return _store?.serverIdFor(id) ?? id;
  }

  /// The projection + projector for one server session, subscribing on first
  /// use. Idempotent.
  _SessionCloudState _stateFor(String serverId) {
    final existing = _sessions[serverId];
    if (existing != null) return existing;

    final projection = TranscriptProjection();
    final state = _SessionCloudState(
      serverId,
      projection,
      EventTranscriptProjector(projection),
    );
    _sessions[serverId] = state;
    projection.addListener(() => _onProjectionChanged(serverId, state));

    // Task 9 carry (T7 review round 1): when the store seeds cached history
    // BEFORE subscribing, it must align the projector's cursor with the
    // cache's high-water mark. NOTE (review round 1, Minor 1):
    // `EventTranscriptProjector._lastSeq` is private with no reset/seed API,
    // so Task 9 cannot honor this carry without ADDING one (e.g.
    // `seedCursor(String? seq)`) to event_projection.dart.
    state.subscription = _ws.subscribe(serverId).listen(
          (CloudSessionEvent event) {
            if (_disposed) return;
            // Capture BEFORE folding: the projector clears activeRunId on
            // terminal events, and run_failed carries no runId — the
            // pre-fold active run is what identifies it (I-2).
            final activeBefore = state.projection.activeRunId;
            state.projector.apply(event);
            switch (event.type) {
              case 'run_started':
                final runId = event.payload['runId'];
                if (runId is String && runId != state.terminalSettledRunId) {
                  state.terminalSettledRunId = null;
                }
                state.queuedBehindActiveRun = false;
                _clearError(serverId);
                _notify();
                break;
              case 'run_completed':
              case 'run_failed':
                _onTerminalEvent(
                  serverId,
                  state,
                  event.type,
                  event.payload,
                  activeBefore,
                );
                break;
            }
          },
          onError: (Object error) => _onStreamError(serverId, error),
        );

    return state;
  }

  /// A terminal event settles busy ONLY when it belongs to the run the
  /// facade currently tracks (I-2).
  ///
  /// Same-session FIFO: the server accepts a second send while run-1 runs,
  /// so `runState.runId` is already run-2 when run-1's terminal arrives.
  /// Clearing on every terminal would make run-2 briefly uncancellable (the
  /// UI shows send instead of stop) until its own `run_started`. `run_failed`
  /// carries no runId, so the projection's pre-fold active run identifies it.
  void _onTerminalEvent(
    String serverId,
    _SessionCloudState state,
    String type,
    Map<String, dynamic> payload,
    String? activeBefore,
  ) {
    final payloadRunId = payload['runId'];
    final terminalRunId =
        payloadRunId is String ? payloadRunId : activeBefore;
    final currentRunId = state.runState.runId;
    final matches = terminalRunId == null ||
        currentRunId == null ||
        terminalRunId == currentRunId;
    if (!matches) {
      // A terminal for an older run in the same session's FIFO: leave the
      // current run's state (and cancellability) untouched.
      _notify();
      return;
    }
    if (terminalRunId != null) state.terminalSettledRunId = terminalRunId;
    state.queuedBehindActiveRun = false;
    state.runState = _copyRunState(
      state.runState,
      busy: false,
      stopRequested: false,
      clearRunId: true,
    );
    if (type == 'run_failed') {
      final code = payload['code'];
      final message = payload['message'];
      if (code is String) {
        _recordError(serverId, code, message is String ? message : '');
      }
    } else {
      _clearError(serverId);
    }
    _notify();
    unawaited(_drainQueue(serverId));
  }

  void _onProjectionChanged(String serverId, _SessionCloudState state) {
    if (_disposed) return;
    final projection = state.projection;
    if (projection.busy) {
      final active = projection.activeRunId;
      // Do not re-arm a run the server already declared terminal (a 409
      // settle or a terminal whose event we already folded). A NEW
      // run_started clears terminalSettledRunId in the stream listener.
      if (active == null || active != state.terminalSettledRunId) {
        state.runState = _copyRunState(
          state.runState,
          runId: active ?? state.runState.runId,
          busy: true,
        );
      }
    }
    // Terminal clearing is runId-matched in [_onTerminalEvent]; this
    // listener must never clear busy on its own (I-2).
    _notify();
  }

  void _onStreamError(String serverId, Object error) {
    if (_disposed) return;
    if (error is CloudWsError) {
      _recordError(serverId, error.code, error.message);
      _notify();
    }
  }

  void _recordError(String serverId, String code, String message) {
    _errors[serverId] = (code, message);
    final state = _sessions[serverId];
    if (state != null) {
      state.runState = _copyRunState(
        state.runState,
        lastErrorCode: code,
        lastErrorMessage: message,
      );
    }
  }

  void _clearError(String serverId) {
    _errors.remove(serverId);
    final state = _sessions[serverId];
    if (state != null && state.runState.lastErrorCode != null) {
      state.runState = _copyRunState(state.runState, clearError: true);
    }
  }

  void _notify() {
    if (_disposed) return;
    for (final entry in _busyNotifiers.entries) {
      entry.value.value = busyFor(entry.key);
    }
    notifyListeners();
  }

  static CloudRunState _copyRunState(
    CloudRunState s, {
    String? runId,
    bool? busy,
    bool? stopRequested,
    String? statusLine,
    int? retryAttempt,
    int? retryNextBackoffMs,
    String? lastErrorCode,
    String? lastErrorMessage,
    bool clearError = false,
    bool clearRunId = false,
  }) =>
      CloudRunState(
        runId: clearRunId ? null : (runId ?? s.runId),
        busy: busy ?? s.busy,
        stopRequested: stopRequested ?? s.stopRequested,
        statusLine: statusLine ?? s.statusLine,
        retryAttempt: retryAttempt ?? s.retryAttempt,
        retryNextBackoffMs: retryNextBackoffMs ?? s.retryNextBackoffMs,
        lastErrorCode: clearError ? null : (lastErrorCode ?? s.lastErrorCode),
        lastErrorMessage:
            clearError ? null : (lastErrorMessage ?? s.lastErrorMessage),
      );

  // -------------------------------------------------------------------------
  // AgentSurface — mode
  // -------------------------------------------------------------------------

  @override
  AgentMode get mode {
    final id = _serverId(null);
    if (id == null) return AgentMode.auto;
    return _modes[id] ?? _persistedModeFor(null, id);
  }

  /// The mode a session already has before any optimistic pick: an explicit
  /// `_modes` entry wins, else the persisted `ChatSession.mode`, else auto.
  /// Control is skipped — retired server-side (spec D5).
  AgentMode _persistedModeFor(String? localId, String serverId) {
    final session = AppState.I.sessionById(serverId) ??
        (localId == null ? null : AppState.I.sessionById(localId)) ??
        AppState.I.activeSession;
    final persisted = session?.mode;
    for (final candidate in AgentMode.values) {
      if (candidate == AgentMode.control) continue;
      if (candidate.name == persisted) return candidate;
    }
    return AgentMode.auto;
  }

  @override
  void setMode(AgentMode m, {String? sessionId}) {
    final localId = sessionId ?? AppState.I.activeSessionId;
    final id = _serverId(localId);
    if (id == null) return;
    // I-3: the effective pre-pick mode is the revert target. Capturing the
    // persisted mode here (not defaulting to auto) is what stops a failed
    // PATCH from shadowing a non-auto session mode.
    final previousExplicit = _modes[id];
    final previousEffective =
        previousExplicit ?? _persistedModeFor(localId, id);
    _modes[id] = m;
    _notify();
    final op = _patchMode(id, previousExplicit, previousEffective, m);
    _modePatches[id] = op;
    unawaited(op);
  }

  Future<void> _patchMode(
    String serverId,
    AgentMode? previousExplicit,
    AgentMode previousEffective,
    AgentMode next,
  ) async {
    try {
      await _rest.patchSession(serverId, mode: next.name);
      _clearError(serverId);
      _notify();
    } on CloudApiException catch (e) {
      _revertMode(serverId, previousExplicit, previousEffective);
      _recordError(serverId, e.code, e.message);
      _notify();
    } catch (e) {
      _revertMode(serverId, previousExplicit, previousEffective);
      _recordError(serverId, 'internal', '$e');
      _notify();
    }
  }

  void _revertMode(
    String serverId,
    AgentMode? previousExplicit,
    AgentMode previousEffective,
  ) {
    if (previousExplicit != null) {
      _modes[serverId] = previousExplicit;
    } else {
      // No explicit pick existed: remove the optimistic entry so the
      // persisted mode shows through again (rather than pinning auto).
      _modes.remove(serverId);
    }
    // Assert the effective value is what it was before the pick.
    assert((_modes[serverId] ?? previousEffective) == previousEffective);
  }

  // -------------------------------------------------------------------------
  // AgentSurface — run lifecycle
  // -------------------------------------------------------------------------

  @override
  bool busyFor(String sessionId) {
    final id = _serverId(sessionId);
    if (id == null) return false;
    final state = _sessions[id];
    if (state == null) return false;
    // A run the projection has seen is unambiguously busy — unless the
    // server already declared that exact run terminal (a 409 settle whose
    // terminal event was missed).
    if (state.projection.busy) {
      final active = state.projection.activeRunId;
      if (active != null && active == state.terminalSettledRunId) return false;
      return true;
    }
    // Accepted-but-not-started: a second send on a session with a run in
    // flight is server-queued (FIFO). It must read busy — and stay
    // cancellable — across the older run's terminal, before its own
    // run_started arrives (I-2).
    return state.runState.busy && state.queuedBehindActiveRun;
  }

  @override
  ValueListenable<bool> busyListenable(String sessionId) =>
      _busyNotifiers.putIfAbsent(
        sessionId,
        () => ValueNotifier<bool>(busyFor(sessionId)),
      );

  @override
  String? statusFor(String sessionId) {
    final id = _serverId(sessionId);
    return id == null ? null : _sessions[id]?.projection.statusLine;
  }

  @override
  ValueListenable<int> liveBubbleTicksFor(String sessionId) {
    final id = _serverId(sessionId);
    if (id == null) return _orphanTicks;
    return _stateFor(id).projection.liveBubbleTicks;
  }

  @override
  Future<void> runTask(
    String originalPrompt, {
    String? sessionId,
    bool freshTurn = true,
    ChatSession? expandRefsFor,
    List<({String name, String path, int size})>? attachments,
    Map<String, dynamic>? scheduledTask,
  }) async {
    // freshTurn/expandRefsFor/scheduledTask are local-loop concepts; the
    // cloud run is admitted server-side. They stay in the signature for
    // AgentSurface parity only.
    final id = _serverId(sessionId);
    if (id == null) {
      _recordError('', 'no_session', 'No chat session is selected.');
      _notify();
      return;
    }

    if (_store?.offline ?? false) {
      // Checked BEFORE `_stateFor` so an enqueue-only send does not open a
      // subscription (review round 1, Minor 3).
      await _store!.enqueue(id, originalPrompt);
      return;
    }

    final state = _stateFor(id);

    final staged = List<({String name, String path, int size})>.from(
      attachments ?? _attachments[id] ?? const [],
    );
    // Whether this send queues behind a live run (server FIFO). Captured
    // before the await: busyFor can change while the POST is in flight.
    final queuedBehindActiveRun = busyFor(id);

    try {
      final attachmentIds = <String>[];
      for (final attachment in staged) {
        final upload = await _rest.createAttachment(
          id,
          name: attachment.name,
          size: attachment.size,
        );
        final bytes = await File(attachment.path).readAsBytes();
        await _rest.uploadAttachmentBytes(upload, bytes);
        attachmentIds.add(upload.attachmentId);
      }

      final response = await _rest.sendMessage(
        id,
        originalPrompt,
        attachmentIds: attachmentIds,
        clientMsgId: _newClientMsgId(),
      );

      // Optimistic user row. privateSyncId = the server's userMessageId is
      // the Task 9 dedupe key when history is paged back in.
      state.projection.messages.add(Message(
        role: 'user',
        kind: MsgKind.text,
        content: originalPrompt,
        privateSyncId: response.userMessageId,
      ));
      state.projection.notifyListeners();

      state.runState = CloudRunState(runId: response.runId, busy: true);
      state.queuedBehindActiveRun = queuedBehindActiveRun;
      _attachments.remove(id);
      _errors.remove(id);
      _notify();
    } on CloudApiException catch (e) {
      _recordError(id, e.code, e.message);
      _notify();
    } catch (e) {
      _recordError(id, 'internal', '$e');
      _notify();
    }
  }

  @override
  bool stopRequested({required String sessionId}) {
    final id = _serverId(sessionId);
    if (id == null) return false;
    final state = _sessions[id];
    if (state == null ||
        state.runState.runId == null ||
        !state.runState.busy) {
      return false;
    }
    unawaited(_cancelRun(state));
    return true;
  }

  @override
  void hardStopAll() {
    final ops = <Future<void>>[];
    for (final state in _sessions.values.toList(growable: false)) {
      if (state.runState.runId != null && state.runState.busy) {
        ops.add(_cancelRun(state));
      }
    }
    _lastHardStop =
        ops.isEmpty ? Future<void>.value() : Future.wait(ops);
  }

  Future<void> _cancelRun(_SessionCloudState state) async {
    final runId = state.runState.runId;
    if (runId == null || !state.runState.busy) return;
    state.runState = _copyRunState(state.runState, stopRequested: true);
    _notify();
    try {
      await _rest.cancelRun(runId);
    } on CloudApiException catch (e) {
      if (e.status == 409 && e.code == 'run_not_cancellable') {
        // Review Focus cancel-race: the run terminalized before the cancel
        // landed. The server's answer is the truth — settle locally instead
        // of leaving a stop request stuck on a dead run. A missed terminal
        // event cannot keep the session shimmering, and
        // `terminalSettledRunId` stops a later projection change from
        // re-arming it (I-2).
        state.terminalSettledRunId = runId;
        state.queuedBehindActiveRun = false;
        state.runState = _copyRunState(
          state.runState,
          busy: false,
          stopRequested: false,
          clearRunId: true,
        );
        _notify();
        unawaited(_drainQueue(state.serverId));
      } else {
        _recordError(state.serverId, e.code, e.message);
        _notify();
      }
    } catch (e) {
      _recordError(state.serverId, 'internal', '$e');
      _notify();
    }
  }

  /// A fresh 32-hex idempotency key for `sendMessage.clientMsgId` (Task 4).
  static String _newClientMsgId() {
    final random = Random.secure();
    return List<String>.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  // -------------------------------------------------------------------------
  // AgentSurface — approvals (P3)
  // -------------------------------------------------------------------------

  @override
  ApprovalRequest? get pendingApproval => null; // P3: approval_* events

  @override
  List<({String sessionId, String title, ApprovalRequest request})>
      get pendingApprovalsElsewhere =>
          const []; // P3: approval_* events

  @override
  bool approveRequest(ApprovalRequest req, bool ok, {String? note}) =>
      false; // P3: no local approval machinery until the events land

  @override
  bool approveAlwaysRequest(ApprovalRequest req) =>
      false; // P3: no local approval machinery until the events land

  // -------------------------------------------------------------------------
  // AgentSurface — plan mode / attachments
  // -------------------------------------------------------------------------

  @override
  bool get planMode => AppState.I.activeSession?.planMode ?? false;

  @override
  set planMode(bool v) {
    final session = AppState.I.activeSession;
    if (session == null) return;
    session.planMode = v;
    _notify();
  }

  @override
  List<({String name, String path, int size})> get pendingAttachments {
    final id = _serverId(null);
    return id == null
        ? const []
        : List.unmodifiable(_attachments[id] ?? const []);
  }

  @override
  int get stagingAttachmentCount => 0;

  @override
  Future<String?> attachFile(
    String sourcePath,
    String fileName, {
    String? sessionId,
  }) async {
    final id = _serverId(sessionId);
    if (id == null) return 'Select a chat before attaching files.';
    int size;
    try {
      size = await File(sourcePath).length();
    } catch (_) {
      return 'file not found: $fileName';
    }
    if (size > 25 * 1024 * 1024) {
      return 'File is larger than the 25 MB cloud attachment limit.';
    }
    _attachments
        .putIfAbsent(
            id, () => <({String name, String path, int size})>[])
        .add((name: fileName, path: sourcePath, size: size));
    _notify();
    return null;
  }

  @override
  void removeAttachment(String path) {
    final id = _serverId(null);
    if (id == null) return;
    _attachments[id]?.removeWhere((a) => a.path == path);
    _notify();
  }

  @override
  void clearAttachment() {
    final id = _serverId(null);
    if (id == null) return;
    _attachments[id]?.clear();
    _notify();
  }

  // -------------------------------------------------------------------------
  // AgentSurface — jobs / context (P2 / P3)
  // -------------------------------------------------------------------------

  @override
  List<({int id, String name, String state, int elapsedSec, int outChars})>
      jobsFor(String sessionId) =>
          const []; // P2: job_* events

  @override
  void killJobFor(String sessionId, int jobId) {
    // P2: job_* events. There is no cloud job handle to kill until the
    // server emits them; the jobs popover stays empty via [jobsFor].
  }

  @override
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''}) =>
      0; // P3: usage events. chat_screen's % ring divides by
         // contextWindowForSession(), which defaults to 1M — no div-by-zero.

  // -------------------------------------------------------------------------
  // AgentSurface — composer queue
  //
  // The cloud has no client-side steering op yet. Rows queued while a run is
  // in flight are held here and dispatched as the next run when the current
  // one terminalizes. OFFLINE persistence belongs to Task 9's outbox; this is
  // the in-memory online path (queue-dock parity, review round 1 I-1).
  // -------------------------------------------------------------------------

  @override
  List<String> get queuedMessages =>
      queuedMessagesFor(_serverId(null) ?? '');

  @override
  List<String> queuedMessagesFor(String sessionId) {
    final queue = _queueFor(sessionId);
    if (queue == null || queue.isEmpty) return const [];
    return List.unmodifiable(queue.map((entry) => entry.text));
  }

  @override
  List<int> queuedMessageIdsFor(String sessionId) {
    final queue = _queueFor(sessionId);
    if (queue == null || queue.isEmpty) return const [];
    return List.unmodifiable(queue.map((entry) => entry.id));
  }

  @override
  void enqueueMessage(String text, {String? sessionId}) {
    if (text.trim().isEmpty) return;
    final id = _serverId(sessionId);
    if (id == null) return;
    _queues
        .putIfAbsent(id, () => <_QueuedCloudMessage>[])
        .add(_QueuedCloudMessage(_nextQueueId++, text));
    _notify();
    if (!busyFor(id)) unawaited(_drainQueue(id));
  }

  @override
  void editQueuedMessageById(int id, String newText) {
    if (newText.trim().isEmpty) return;
    final queue = _queueFor(null);
    if (queue == null) return;
    for (final entry in queue) {
      if (entry.id == id) {
        entry.text = newText;
        _notify();
        return;
      }
    }
  }

  @override
  void removeQueuedMessage(int index) {
    final queue = _queueFor(null);
    if (queue == null || index < 0 || index >= queue.length) return;
    queue.removeAt(index);
    _notify();
  }

  @override
  void removeQueuedMessageById(int id) {
    final queue = _queueFor(null);
    if (queue == null) return;
    final before = queue.length;
    queue.removeWhere((entry) => entry.id == id);
    if (queue.length != before) _notify();
  }

  @override
  void steerQueuedMessage(int index) {
    final queue = _queueFor(null);
    if (queue == null || index < 0 || index >= queue.length) return;
    final entry = queue.removeAt(index);
    queue.insert(0, entry);
    _notify();
  }

  @override
  void quickSendQueuedMessage(int id, {String? sessionId}) {
    final resolved = _serverId(sessionId);
    if (resolved == null) return;
    final queue = _queueFor(resolved);
    if (queue == null) return;
    var index = -1;
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id == id) {
        index = i;
        break;
      }
    }
    if (index < 0) return;
    final entry = queue.removeAt(index);
    queue.insert(0, entry);
    _notify();
    // Stop promotes the queue head (AgentService parity). The drain runs on
    // the terminal event, so the row starts as soon as the run settles.
    stopRequested(sessionId: resolved);
  }

  @override
  List<QueuedMessageSnapshot> takeQueuedMessages(String sessionId) {
    final queue = _queueFor(sessionId);
    if (queue == null || queue.isEmpty) return const [];
    final taken = <QueuedMessageSnapshot>[
      for (final entry in queue)
        (
          id: entry.id,
          text: entry.text,
          userReferences: true,
          nextDispatch: false,
          attachments: const <({String name, String path, int size})>[],
        ),
    ];
    queue.clear();
    _notify();
    return taken;
  }

  @override
  int restoreQueuedMessages(
    String sessionId,
    List<QueuedMessageSnapshot> items,
  ) {
    if (items.isEmpty) return 0;
    final id = _serverId(sessionId);
    if (id == null) return 0;
    final queue = _queues.putIfAbsent(id, () => <_QueuedCloudMessage>[]);
    final existing = <int>{for (final entry in queue) entry.id};
    var restored = 0;
    for (final item in items.reversed) {
      if (existing.contains(item.id)) continue;
      queue.insert(0, _QueuedCloudMessage(item.id, item.text));
      if (item.id >= _nextQueueId) _nextQueueId = item.id + 1;
      restored++;
    }
    if (restored > 0) _notify();
    return restored;
  }

  /// The live queue for [sessionId] (null when the session is unresolvable).
  List<_QueuedCloudMessage>? _queueFor(String? sessionId) {
    final id = _serverId(sessionId);
    return id == null ? null : _queues[id];
  }

  /// Sends the queue head as the next run once the session is idle.
  Future<void> _drainQueue(String serverId) async {
    if (_disposed) return;
    final queue = _queues[serverId];
    if (queue == null || queue.isEmpty) return;
    if (busyFor(serverId)) return;
    if (_store?.offline ?? false) return;
    final head = queue.removeAt(0);
    _notify();
    await runTask(head.text, sessionId: serverId);
    final state = _sessions[serverId];
    final failed = state != null &&
        !state.runState.busy &&
        state.runState.lastErrorCode != null;
    if (failed && !_disposed) {
      // Never drop a user's queued message on a send failure; the error is
      // surfaced through run state.
      queue.insert(0, head);
      _notify();
    }
  }

  // -------------------------------------------------------------------------
  // AgentSurface — context counters (P3)
  // -------------------------------------------------------------------------

  @override
  int get sessionSystemTokens => 0; // P3: usage events

  @override
  int get sessionToolTokens => 0; // P3: usage events

  @override
  int get sessionMessageTokens => 0; // P3: usage events

  @override
  int get sessionCacheReadTokens => 0; // P3: usage events

  // -------------------------------------------------------------------------
  // AgentSurface — subagents (P3)
  // -------------------------------------------------------------------------

  @override
  List<SubagentInfo> subagentsOf(String sessionId) =>
      const <SubagentInfo>[]; // P3: subagent_* events

  // -------------------------------------------------------------------------
  // AgentSurface — browser header (Task 16)
  // -------------------------------------------------------------------------

  @override
  bool get browserBusy => false; // Task 16: browser_* channel

  @override
  bool get browserReady => false; // Task 16: browser_* channel

  // -------------------------------------------------------------------------
  // AgentSurface — sidebar title (P4)
  // -------------------------------------------------------------------------

  @override
  Future<void> regenerateSessionTitle(ChatSession s) async {
    // P4/Task 10: no cloud title-GENERATION endpoint exists. PATCH
    // /sessions/:id accepts a title, but generating one is an agent/worker
    // concern (the local `_generateTitleFor` runs a provider call we do not
    // own on the thin client). Inert by design; Task 10 hides or disables
    // the action and the owning server task wires the path. Documented
    // rather than silently omitted (review round 1, I-1).
  }

  // -------------------------------------------------------------------------
  // Test seams
  // -------------------------------------------------------------------------

  /// The live projection for [sessionId] (null before first use).
  @visibleForTesting
  TranscriptProjection? projectionForTest(String sessionId) =>
      _sessions[_serverId(sessionId) ?? sessionId]?.projection;

  /// The run state for [sessionId], including errors recorded before any
  /// projection existed (mode PATCH, send failures).
  CloudRunState runStateFor(String sessionId) {
    final id = _serverId(sessionId) ?? sessionId;
    final state = _sessions[id];
    if (state != null) return state.runState;
    final error = _errors[id];
    return CloudRunState(
      lastErrorCode: error?.$1,
      lastErrorMessage: error?.$2,
    );
  }

  @visibleForTesting
  AgentMode modeForTest(String sessionId) {
    final id = _serverId(sessionId) ?? sessionId;
    return _modes[id] ?? _persistedModeFor(sessionId, id);
  }

  @visibleForTesting
  List<({String name, String path, int size})> pendingAttachmentsForTest(
          String sessionId) =>
      List.unmodifiable(
          _attachments[_serverId(sessionId) ?? sessionId] ?? const []);

  /// Awaits every cancel posted by the last [hardStopAll].
  @visibleForTesting
  Future<void> get hardStopSettledForTest =>
      _lastHardStop ?? Future<void>.value();

  /// Awaits the in-flight mode PATCH for [sessionId].
  @visibleForTesting
  Future<void> modePatchSettledForTest(String sessionId) async {
    final op = _modePatches[_serverId(sessionId) ?? sessionId];
    if (op != null) await op;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final state in _sessions.values) {
      unawaited(state.subscription?.cancel());
      state.projection.dispose();
    }
    _sessions.clear();
    for (final notifier in _busyNotifiers.values) {
      notifier.dispose();
    }
    _busyNotifiers.clear();
    _queues.clear();
    _orphanTicks.dispose();
    super.dispose();
  }
}

class _SessionCloudState {
  _SessionCloudState(this.serverId, this.projection, this.projector);

  final String serverId;
  final TranscriptProjection projection;
  final EventTranscriptProjector projector;
  StreamSubscription<CloudSessionEvent>? subscription;
  CloudRunState runState = const CloudRunState();

  /// The runId the server already declared terminal (a terminal event we
  /// folded, or a 409 `run_not_cancellable`). While the projection still
  /// shows that run busy, projection changes must not re-arm it (I-2). A
  /// `run_started` for a different run clears it.
  String? terminalSettledRunId;

  /// True when the tracked run was accepted while an OLDER run was still
  /// active (server FIFO). It keeps [CloudAgentFacade.busyFor] true across
  /// the older run's terminal, until this run's own `run_started` (I-2).
  bool queuedBehindActiveRun = false;
}

/// One row of the facade's in-memory composer queue.
class _QueuedCloudMessage {
  _QueuedCloudMessage(this.id, this.text);

  final int id;
  String text;
}
