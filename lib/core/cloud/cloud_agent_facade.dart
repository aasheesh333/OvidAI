/// `CloudAgentFacade` — the cloud client over Ovid Cloud
/// (P8 Task 8).
///
/// Composes the landed client pieces behind the [AgentSurface] seam:
///
///  * `CloudRestClient` (Task 5) — send/cancel/patch/attachment endpoints;
///  * `WsMultiplexer` (Task 6) — one socket, per-session subscriptions;
///  * `EventTranscriptProjector` / `TranscriptProjection` (Task 7) — the
///    event→transcript fold.
///
/// The facade is the ONLY [AgentSurface] implementation since Task 19:
/// `chat_screen.dart` binds to it directly (Task 20 removed the dual-path
/// gate). It owns no local execution machinery — no tool loop, no jobs.
/// Approvals are SERVER decisions (P3 Task 12's gate + redis bridge): the
/// facade surfaces the live `approval_requested` prompt and answers it with
/// the `approval_response` WS op; sections whose server events have not
/// landed yet (P2 jobs, usage counters) are explicitly inert with a marker
/// rather than silently faked.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../connection_service.dart';
import '../diag.dart';
import '../state.dart';
import 'agent_surface.dart';
import 'cloud_rest.dart';
import 'cloud_session_store.dart';
import 'cloud_ws.dart';
import 'event_projection.dart';
import 'models.dart';

/// Cloud facade over the REST + WS surface.
class CloudAgentFacade extends ChangeNotifier
    implements AgentSurface, CloudTranscriptSink {
  CloudAgentFacade({
    required CloudRestClient rest,
    required WsMultiplexer ws,
    required CloudSessionStore? store,
    Duration Function()? stallWindowFor,
  })  : _rest = rest, // ignore: prefer_initializing_formals
        _ws = ws, // ignore: prefer_initializing_formals
        _store = store, // ignore: prefer_initializing_formals
        _stallWindowFor = stallWindowFor { // ignore: prefer_initializing_formals
    final s = store;
    if (s != null) {
      // Task 9 wiring: the store seeds this facade's projections and the
      // facade flushes the store's outbox on the offline→online flip.
      s.transcriptSink = this;
      _connection = s.connection;
      _lastOffline = s.offline;
      _connection!.addListener(_onConnectivityChanged);
      _ws.addListener(_onConnectivityChanged);
    } else {
      _connection = null;
    }
  }

  final CloudRestClient _rest;
  final WsMultiplexer _ws;
  final CloudSessionStore? _store;

  /// Optional override of the stall window (the response-timeout watchdog
  /// below). Tests inject a short window so the watchdog can be exercised
  /// under fake time; production leaves it null and reads the user's
  /// Settings response timeout (see [_responseTimeoutStallWindow]).
  final Duration Function()? _stallWindowFor;

  /// The store's connectivity probe (null when no store is wired).
  late final ConnectionService? _connection;

  /// Previous combined offline state — the flush trigger is a TRUE→FALSE
  /// edge across BOTH inputs (connectivity probe + WS link state).
  bool _lastOffline = false;

  static CloudAgentFacade? _instance;

  /// The process-wide default. Nothing reads it until Task 10 flips
  /// `chat_screen.dart` onto the facade.
  static CloudAgentFacade get I => _instance ??= CloudAgentFacade(
        rest: CloudRestClient.I,
        ws: WsMultiplexer.I,
        store: CloudSessionStore.I,
      );

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(CloudAgentFacade facade) => _instance = facade;

  /// Clears the singleton — test wiring only.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// Drops every in-memory per-account cache on an account switch or a full
  /// data reset. This is the surviving owner of the reset guarantee the
  /// retired local service's `sessionAccountChanged` provided: projections,
  /// subscriptions, queued sends, staged attachments, optimistic modes and
  /// error surfaces must never leak into the next account.
  void resetAccountState() {
    if (_disposed) return;
    for (final state in _sessions.values) {
      unawaited(state.subscription?.cancel());
      state.projection.dispose();
    }
    _sessions.clear();
    for (final notifier in _busyNotifiers.values) {
      notifier.dispose();
    }
    _busyNotifiers.clear();
    for (final notifier in _tickNotifiers.values) {
      notifier.dispose();
    }
    _tickNotifiers.clear();
    _queues.clear();
    _draining.clear();
    _sending.clear();
    _attachments.clear();
    _attachmentReservations.clear();
    _modes.clear();
    _errors.clear();
    _errorResetsAt.clear();
    _modePatches.clear();
    _titlePatches.clear();
    _activeRunForTest.clear();
    _approvalRequests.clear();
    pendingApprovalForTest = null;
    _lastHardStop = null;
    for (final timer in _stallTimers.values) {
      timer.cancel();
    }
    _stallTimers.clear();
    _stallTicks.clear();
    _stalled.clear();
    notifyListeners();
  }

  /// Account-scoped reset that never constructs the facade just to clear it.
  static void resetAccountStateIfInstalled() =>
      _instance?.resetAccountState();

  /// Single-session teardown for `AppState.onSessionDeleted`: unsubscribes
  /// the socket stream, disposes the projection and drops every per-session
  /// surface (queue, staged attachments, recorded errors, optimistic mode,
  /// busy/tick notifiers) — the one-session slice of [resetAccountState].
  /// Other sessions' parallel state is untouched. Accepts a local or server
  /// id; a never-subscribed id is a no-op.
  void dropSession(String localOrServerId) {
    if (_disposed) return;
    final id = _serverId(localOrServerId) ?? localOrServerId;
    // The map entry can already be gone (the delete cleared it) — resolve
    // through the store first, then fall back to the raw id.
    final state = _sessions.remove(id);
    if (state != null) {
      unawaited(state.subscription?.cancel());
      state.projection.dispose();
    }
    // Frees the server-side subscription too (sends the unsubscribe op and
    // closes the multiplexer's stream; idempotent for a never-subscribed id).
    _ws.unsubscribe(id);
    _queues.remove(id);
    _draining.remove(id);
    _sending.remove(id);
    _attachments.remove(id);
    _attachmentReservations.remove(id);
    _modes.remove(id);
    _errors.remove(id);
    _errorResetsAt.remove(id);
    _modePatches.remove(id);
    _titlePatches.remove(id);
    _busyNotifiers.remove(id)?.dispose();
    _tickNotifiers.remove(id)?.dispose();
    _activeRunForTest.remove(id);
    _approvalRequests.remove(id);
    _stopStallWatchdog(id);
    _notify();
  }

  final Map<String, _SessionCloudState> _sessions =
      <String, _SessionCloudState>{};
  final Map<String, ValueNotifier<bool>> _busyNotifiers =
      <String, ValueNotifier<bool>>{};

  /// Stable live-bubble tick notifiers, created on first UI bind WITHOUT
  /// subscribing to the socket. A transcript binds before any run exists;
  /// [_stateFor] forwards the projection's ticks into this notifier once the
  /// session actually subscribes.
  final Map<String, ValueNotifier<int>> _tickNotifiers =
      <String, ValueNotifier<int>>{};

  ValueNotifier<int> _tickNotifierFor(String id) =>
      _tickNotifiers.putIfAbsent(id, () => ValueNotifier<int>(0));

  /// Test-only busy overrides, mirroring the retired local service's
  /// `setActiveRunForTest` seam. Empty in production.
  final Map<String, bool> _activeRunForTest = <String, bool>{};

  /// Test-only pending approval override — WINS over the live prompt while
  /// set (UI tests inject cards through it, mirroring the retired local
  /// service's settable `pendingApproval`). Null in production: the live
  /// prompt comes from the `approval_requested` fold.
  ApprovalRequest? pendingApprovalForTest;

  /// The live approval prompt per server session id (P3 Task 12): the
  /// UI-shaped [ApprovalRequest] the chat's approval dock renders, mirrored
  /// from each projection's [CloudApprovalPrompt] by
  /// [_syncApprovalRequest]. One entry per session — the gate blocks the
  /// run in the worker's bridge until it settles, so at most one prompt is
  /// ever pending per session.
  final Map<String, ApprovalRequest> _approvalRequests =
      <String, ApprovalRequest>{};

  /// Optimistic per-session mode (server id → mode) until the PATCH settles.
  /// Absent means "no explicit pick yet" — the persisted session mode is the
  /// effective value (see [mode]).
  final Map<String, AgentMode> _modes = <String, AgentMode>{};

  /// The facade's composer queue per server session. The cloud has no
  /// client-side steering channel yet: a queued row is held here and sent as
  /// the next run when the current one terminalizes (the retired local service's
  /// continuation semantics). Task 9's outbox owns OFFLINE persistence; this
  /// queue is the in-memory, online path.
  final Map<String, List<_QueuedCloudMessage>> _queues =
      <String, List<_QueuedCloudMessage>>{};
  int _nextQueueId = 1;

  /// Sessions whose queue drain has a POST in flight (the `_drainQueue`
  /// re-entrancy guard — Task 10).
  final Set<String> _draining = <String>{};

  /// Sessions whose DIRECT send is between its synchronous entry and the
  /// POST landing (the double-send guard — chat P1). Claimed before
  /// `runTask`'s first await, released when the POST settles either way;
  /// `busyFor` reports it so a second tap queues instead of dispatching a
  /// second run. Both the pre-create local id and the resolved server id
  /// are held across a first-send create (see `runTask`).
  final Set<String> _sending = <String>{};

  /// Staged attachments per session (server id → files). No workspace copy:
  /// the bytes are uploaded straight from the staged file path.
  final Map<String, List<({String name, String path, int size})>>
      _attachments =
      <String, List<({String name, String path, int size})>>{};

  /// Composer cap (the retired local service's `maxAttachments`; the UI's
  /// `_maxChatAttachments` is the same 20). Enforced here so a picker burst
  /// cannot stage past it.
  static const int _maxAttachments = 20;

  /// In-flight `attachFile` calls per session. The count check and the
  /// reservation happen before the first await, so concurrent picks cannot
  /// all pass the limit together (the retired service's
  /// `_attachmentCopies`).
  final Map<String, int> _attachmentReservations = <String, int>{};

  /// REST/WS failures with no projection row yet (mode PATCH, send, stream
  /// errors). Keyed by server session id.
  final Map<String, (String code, String message)> _errors =
      <String, (String, String)>{};

  // -------------------------------------------------------------------------
  // Response-timeout watchdog (the Settings "Response wait limit" —
  // `responseTimeoutSec`). A SURFACE, never a cancel: long silent stretches
  // are legitimate (a reasoning model thinking, a slow tool call), so the
  // watchdog only flips a user-visible "still waiting" state the composer
  // status line renders ("Still working…"). The cloud already enforces its
  // own idle ceilings server-side; this is purely what the user sees.
  //
  // Semantics: the timer arms on a session's run_started and, once armed,
  // ticks once per second. ANY event of any kind (delta, thinking, tool,
  // terminal, …) re-stamps the last-event time; the stalled flag flips only
  // when a full window elapses with no event at all, and any event clears
  // it again. The tick itself stops once the session is no longer busy, so
  // every settle path (terminal event, 409 cancel race, drop, reset)
  // silences it without each needing its own hook.
  // -------------------------------------------------------------------------

  /// Quiet-time measurement per server session id, in watchdog ticks since
  /// the last event (run_started resets it to 0; every event does the same).
  /// Tick-counted rather than wall-clocked so the seam stays deterministic
  /// under test time control.
  final Map<String, int> _stallTicks = <String, int>{};

  /// Sessions whose live run has been silent for the whole stall window.
  final Set<String> _stalled = <String>{};

  /// One periodic check timer per live run's session.
  final Map<String, Timer> _stallTimers = <String, Timer>{};

  /// How often the armed watchdog re-checks the last-event time.
  static const Duration _stallTickInterval = Duration(seconds: 1);

  /// The production stall window: the user's responseTimeoutSec clamped to
  /// [30s, 600s]. The setting itself allows up to 3600s, but a "still
  /// waiting" surface that first appears an hour in says nothing the busy
  /// dot does not already; the clamp bounds the SURFACE only — the server's
  /// own timeouts are untouched. A degenerate read (unset/non-positive)
  /// falls back to 60s.
  Duration _responseTimeoutStallWindow() {
    final configured = _stallWindowFor?.call();
    if (configured != null) return configured;
    final sec = AppState.I.responseTimeoutSec;
    return Duration(seconds: (sec > 0 ? sec : 60).clamp(30, 600));
  }

  /// Re-stamps [serverId]'s quiet-time — every event of any kind does this —
  /// and clears a stale stalled flag so the status line drops back to the
  /// normal label the moment traffic resumes.
  void _noteStallEvent(String serverId) {
    _stallTicks[serverId] = 0;
    if (_stalled.remove(serverId)) _notify();
  }

  /// Arms the watchdog for [serverId] (idempotent while armed).
  void _armStallWatchdog(String serverId) {
    _noteStallEvent(serverId);
    _stallTimers.putIfAbsent(
      serverId,
      () => Timer.periodic(_stallTickInterval, (_) => _checkStall(serverId)),
    );
  }

  /// One watchdog tick: a session that is no longer busy disarms and
  /// clears; a session quiet for the whole window surfaces as stalled.
  void _checkStall(String serverId) {
    if (_disposed) {
      _stopStallWatchdog(serverId);
      return;
    }
    if (!_busyForRun(serverId)) {
      _stopStallWatchdog(serverId);
      return;
    }
    final ticks = (_stallTicks[serverId] ?? 0) + 1;
    _stallTicks[serverId] = ticks;
    if (_stallTickInterval * ticks >= _responseTimeoutStallWindow() &&
        _stalled.add(serverId)) {
      _notify();
    }
  }

  /// Disarms the watchdog and clears the stalled state for [serverId].
  void _stopStallWatchdog(String serverId) {
    _stallTimers.remove(serverId)?.cancel();
    _stallTicks.remove(serverId);
    if (_stalled.remove(serverId)) _notify();
  }

  /// `x-ovid-resets-at` of the recorded error (402 `daily_limit_reached`
  /// carries the epoch-ms instant the allowance resets), keyed like
  /// [_errors]. Cleared with it.
  final Map<String, DateTime?> _errorResetsAt = <String, DateTime?>{};

  final Map<String, Future<void>> _modePatches = <String, Future<void>>{};

  /// In-flight title PATCHes, keyed like [_modePatches] (the rename seam
  /// tests await).
  final Map<String, Future<void>> _titlePatches = <String, Future<void>>{};
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

    // Task 9 reconciliation (T7 review carry): seed the cached transcript and
    // the exactly-once cursor BEFORE subscribing, and align the multiplexer's
    // replay cursor with the cache's high-water mark, so the server replays
    // only events the cache does not already cover.
    final store = _store;
    if (store != null) {
      final cached = store.cachedTranscriptFor(serverId);
      if (cached != null && cached.isNotEmpty) {
        final cursor = store.cachedCursorFor(serverId);
        projection.seedFromHistory(cached);
        state.projector.seedCursor(cursor);
        _ws.seedCursor(serverId, cursor);
      }
    }

    projection.addListener(() => _onProjectionChanged(serverId, state));
    final ticks = _tickNotifierFor(serverId);
    projection.liveBubbleTicks.addListener(
      () => ticks.value = projection.liveBubbleTicks.value,
    );

    state.subscription = _ws.subscribe(serverId).listen(
          (CloudSessionEvent event) {
            if (_disposed) return;
            // Response-timeout watchdog: every event of any kind re-stamps
            // this session's last-event time (run_started arms the periodic
            // check below; any event resets it; a terminal's settle path —
            // via the busy check in the tick itself — stops it).
            _noteStallEvent(serverId);
            // Capture BEFORE folding: the projector clears activeRunId on
            // terminal events, and run_failed carries no runId — the
            // pre-fold active run is what identifies it (I-2). run_cancelled
            // (the full processor's cancel terminal) does carry its runId.
            final activeBefore = state.projection.activeRunId;
            if (_isDuplicateTerminal(state, event, activeBefore)) {
              // Both spellings of one cancel: the settle already happened.
              // Dropped BEFORE the fold so the duplicate appends no second
              // turn-tail row, and before the terminal switch below so it
              // records no error and drains no queue.
              return;
            }
            state.projector.apply(event);
            switch (event.type) {
              case 'run_started':
                final runId = event.payload['runId'];
                if (runId is String && runId != state.terminalSettledRunId) {
                  state.terminalSettledRunId = null;
                }
                state.queuedBehindActiveRun = false;
                _clearError(serverId);
                // A live run exists from now on: start the silence clock.
                _armStallWatchdog(serverId);
                _notify();
                break;
              case 'run_completed':
              case 'run_failed':
              case 'run_cancelled':
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

  /// True when [event] is a terminal the session has ALREADY settled — the
  /// server may emit BOTH spellings of one cancel (the full processor's
  /// `run_cancelled{runId}` followed by the compat `run_failed{cancelled}`,
  /// which carries no runId). A duplicate is a full no-op: not folded (no
  /// second turn-tail row), not settled again, no error, no queue drain —
  /// the same [terminalSettledRunId] guard [busyFor] uses.
  ///
  /// NOT a duplicate, and deliberately not dropped:
  ///  * a terminal whose runId is not the settled run — a fresh run clears
  ///    `terminalSettledRunId` on its `run_started`, so a different id means
  ///    no settle happened for it (older-run terminals belong to the FIFO
  ///    guard in [_onTerminalEvent]);
  ///  * a `run_failed` with no runId while a run is TRACKED
  ///    (`runState.runId` set): a fresh run always has its id set by its own
  ///    send (the queued-cancel path) or a folded run_started, so this is
  ///    that run's genuine terminal, not the settled run's second spelling.
  ///    Corner: a queued row dispatched between the two spellings re-arms
  ///    `runState.runId` before the duplicate lands — the duplicate then
  ///    settles the new run and records a transient 'cancelled' error its
  ///    own `run_started` clears (self-healing, and indistinguishable at
  ///    this seam: run_failed carries no runId);
  ///  * the 409 `run_not_cancellable` settle of a run whose terminal event
  ///    was merely LATE: there the projection is still busy on the settled
  ///    run and MUST fold the event (the live bubble would otherwise
  ///    shimmer until the next run_started).
  bool _isDuplicateTerminal(
    _SessionCloudState state,
    CloudSessionEvent event,
    String? activeBefore,
  ) {
    switch (event.type) {
      case 'run_completed':
      case 'run_failed':
      case 'run_cancelled':
        break;
      default:
        return false;
    }
    final settled = state.terminalSettledRunId;
    if (settled == null) return false;
    // The 409-missed-terminal exception: that settle came from the cancel
    // race, not from a folded event — the projection is still in flight on
    // the settled run and the late terminal must fold.
    if (state.projection.busy &&
        state.projection.activeRunId == settled) {
      return false;
    }
    final payloadRunId = event.payload['runId'];
    final terminalRunId =
        payloadRunId is String ? payloadRunId : activeBefore;
    if (terminalRunId != null) return terminalRunId == settled;
    return state.runState.runId == null;
  }

  /// A terminal event settles busy ONLY when it belongs to the run the
  /// facade currently tracks (I-2). Duplicates never reach it — the
  /// subscriber drops them via [_isDuplicateTerminal] before the fold.
  ///
  /// Same-session FIFO: the server accepts a second send while run-1 runs,
  /// so `runState.runId` is already run-2 when run-1's terminal arrives.
  /// Clearing on every terminal would make run-2 briefly uncancellable (the
  /// UI shows send instead of stop) until its own `run_started`. `run_failed`
  /// carries no runId, so the projection's pre-fold active run identifies it;
  /// `run_cancelled` (the full processor's cancel terminal) carries its own.
  ///
  /// `run_cancelled` settles exactly like the other terminals — busy cleared,
  /// stopRequested cleared, error cleared, queue drained — but records NO
  /// error: a user-initiated cancel is not a surfaced failure, and the
  /// projection fold owns the turn-tail row the user sees.
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
    // The run settled: the response-timeout watchdog stands down and any
    // stalled state clears immediately (a tick-only clear would leave
    // "Still working…" up for up to a second after the terminal landed).
    _stopStallWatchdog(serverId);
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
      // run_completed and run_cancelled clear the error surface: a
      // user-initiated cancel is not a surfaced error (the projection fold
      // appends the 'Stopped by user.' turn tail the user sees).
      _clearError(serverId);
    }
    _notify();
    // Terminal cache write (Task 9 carry, Task 10): live deltas are not
    // persisted per-delta, so THIS is what makes a cold offline start show
    // the latest turn — the settled projection is written to the store's
    // offline READ CACHE.
    unawaited(_persistTerminal(serverId, state));
    unawaited(_drainQueue(serverId));
  }

  Future<void> _persistTerminal(String serverId, _SessionCloudState state) async {
    final store = _store;
    if (store == null || _disposed) return;
    try {
      await store.persistTranscript(
        serverId,
        state.projection.messages,
        store.cachedCursorFor(serverId),
      );
    } catch (_) {
      // A failed cache write never surfaces as a run error.
    }
  }

  void _onProjectionChanged(String serverId, _SessionCloudState state) {
    if (_disposed) return;
    final projection = state.projection;
    // The approval mirror rides every projection notify — the fold itself is
    // what changed it, and this is the single funnel for live folds, replay
    // folds, and the optimistic clearPendingApproval dismiss alike.
    _syncApprovalRequest(serverId, state);
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

  void _recordError(String serverId, String code, String message,
      {DateTime? resetsAt}) {
    _errors[serverId] = (code, message);
    _errorResetsAt[serverId] = resetsAt;
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
    _errorResetsAt.remove(serverId);
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
  /// Control was retired server-side (spec D5) and no longer exists in the
  /// enum.
  AgentMode _persistedModeFor(String? localId, String serverId) {
    final session = AppState.I.sessionById(serverId) ??
        (localId == null ? null : AppState.I.sessionById(localId)) ??
        AppState.I.activeSession;
    final persisted = session?.mode;
    for (final candidate in AgentMode.values) {
      if (candidate.name == persisted) return candidate;
    }
    return AgentMode.auto;
  }

  @override
  void setMode(AgentMode m, {String? sessionId}) {
    final localId = sessionId ?? AppState.I.activeSessionId;
    final id = _serverId(localId);
    if (id == null) return;
    // I-3: the effective pre-pick mode is the revert target. Capture it
    // BEFORE the optimistic session-row write below.
    final previousExplicit = _modes[id];
    final previousEffective =
        previousExplicit ?? _persistedModeFor(localId, id);
    // Mirror the retired local service: an explicit mode pick persists on the
    // session row and ends plan mode. An unknown id still PATCHes (the facade
    // is addressable by server id even when no local row exists).
    final session = AppState.I.sessionById(localId ?? '') ??
        AppState.I.sessionById(id);
    if (session != null) {
      if (session.planMode || session.planModePending != null) {
        session.planMode = false;
        session.planModePending = null;
      }
      session.mode = m.name;
      unawaited(AppState.I.persistSessions());
    }
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
      _recordError(serverId, e.code, e.message, resetsAt: e.resetsAt);
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
    // The session row was updated optimistically; restore it with the
    // effective pre-pick mode.
    final session = AppState.I.sessionById(serverId);
    if (session != null) {
      session.mode = previousEffective.name;
      unawaited(AppState.I.persistSessions());
    }
    // Assert the effective value is what it was before the pick.
    assert((_modes[serverId] ?? previousEffective) == previousEffective);
  }

  // -------------------------------------------------------------------------
  // Session title (rename sync)
  // -------------------------------------------------------------------------

  /// Pushes a rename to the server for [sessionId] (local or server id),
  /// when a facade is installed. The local row is already renamed
  /// optimistically by the caller (`AppState.renameSession`); this only
  /// PATCHes the title, so a later `refreshSessions` `_applyDto` echoes the
  /// rename instead of reverting the chat list to the stale server title.
  /// Purely local sessions (no server id yet) are skipped: nothing exists
  /// to sync, and the first send carries the local title anyway.
  static void renameSessionIfInstalled(String sessionId, String title) =>
      _instance?._renameSession(sessionId, title);

  void _renameSession(String sessionId, String title) {
    final serverId = _store?.knownServerIdFor(sessionId);
    if (serverId == null) return;
    final op = _patchTitle(serverId, title);
    _titlePatches[serverId] = op;
    unawaited(op);
  }

  /// The title twin of [_patchMode]: fire-and-forget. A failure keeps the
  /// optimistic local title (the rename already succeeded locally) and is
  /// only Diag-swallowed — a title is not a run, so it must never surface
  /// as a chat error. The next rename or refresh reconciles.
  Future<void> _patchTitle(String serverId, String title) async {
    try {
      await _rest.patchSession(serverId, title: title);
    } catch (e, s) {
      Diag.swallow('cloud.renameSession', e, s);
    }
  }

  // -------------------------------------------------------------------------
  // AgentSurface — run lifecycle
  // -------------------------------------------------------------------------

  @override
  bool busyFor(String sessionId) {
    final id = _serverId(sessionId);
    if (id == null) return false;
    // A send between its synchronous entry and the POST landing (the
    // double-send guard) reads busy: a second tap must queue, not dispatch
    // a second run and double-spend (chat P1).
    if (_sending.contains(id)) return true;
    return _busyForRun(id);
  }

  /// Run-tracking busy state only — the projection plus the
  /// accepted-but-not-started FIFO window — WITHOUT the in-flight-send
  /// guard. The send path itself holds that guard and must not read its
  /// own POST as a live run when it captures `queuedBehindActiveRun`.
  bool _busyForRun(String serverId) {
    if (_activeRunForTest[serverId] == true) return true;
    final state = _sessions[serverId];
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

  /// True when [sessionId]'s live run has been silent — no event of any
  /// kind — for the response-timeout window (the Settings "Response wait
  /// limit"). A surface only: the run keeps streaming server-side, and the
  /// composer status line renders "Still working…" while this is set.
  @override
  bool stalledFor(String sessionId) {
    final id = _serverId(sessionId);
    return id != null && _stalled.contains(id);
  }

  @override
  ValueListenable<int> liveBubbleTicksFor(String sessionId) {
    final id = _serverId(sessionId);
    if (id == null) return _orphanTicks;
    // Do NOT create/subscribe the session state here: a mounted transcript
    // binds this before any run, and subscribing would open a socket (and a
    // reconnect timer) for every rendered session.
    return _tickNotifierFor(id);
  }

  @override
  Future<void> runTask(
    String originalPrompt, {
    String? sessionId,
    bool freshTurn = true,
    ChatSession? expandRefsFor,
    List<({String name, String path, int size})>? attachments,
  }) async {
    // freshTurn/expandRefsFor are local-loop concepts; the cloud run is
    // admitted server-side. They stay in the signature for AgentSurface
    // parity only.
    String? id = _serverId(sessionId);
    if (id == null) {
      _recordError('', 'no_session', 'No chat session is selected.');
      _notify();
      return;
    }
    final store = _store;

    // The Settings "Max output tokens" pick (global — the setting lives on
    // AppState, not the session). 0/auto sends no key, so the provider's own
    // default applies; values above the wire cap degrade to the cap instead
    // of failing every send with a 400 the settings screen never warned
    // about.
    final maxOutputTokens = AppState.I.maxOutputTokens > 0
        ? min(AppState.I.maxOutputTokens,
            CloudRestClient.maxOutputTokensWireCap)
        : null;

    // Double-send guard (chat P1): `busyFor` flips only when the POST
    // response lands, so a second tap while the first send is between its
    // synchronous entry and that POST would dispatch a SECOND run — double
    // spend. The flag is claimed here, BEFORE the first await (the
    // `_drainQueue` re-entrancy guard, applied to the direct send that
    // never had it), and released when the POST settles either way. A
    // re-entrant call queues behind the in-flight send; its row leaves on
    // the first send's terminal, in order.
    if (!_sending.add(id)) {
      if (store != null && sessionId != null && sessionId.isNotEmpty) {
        // Resolve like the primary path so the row lands under the key
        // every later `_serverId` resolves to — an unmapped local id can
        // move to its server id while the first send is in the create.
        try {
          id = await store.ensureServerSession(sessionId);
        } on CloudApiException catch (e) {
          _recordError(sessionId, e.code, e.message, resetsAt: e.resetsAt);
          _notify();
          return;
        }
      }
      if (store?.offline ?? false) {
        await store!.enqueue(
          id,
          originalPrompt,
          maxOutputTokens: maxOutputTokens,
        );
        return;
      }
      _enqueueRow(id, originalPrompt, attachments ?? _attachments[id]);
      return;
    }
    final guardKeys = <String>{id};
    try {
      // Create-on-first-send (Task 9): an unmapped LOCAL session gets its
      // server session before the first POST — the store's shared in-flight
      // future keeps concurrent first sends to one create. Server ids the
      // store already knows pass through `ensureServerSession` untouched.
      if (store != null && sessionId != null && sessionId.isNotEmpty) {
        try {
          final resolved = await store.ensureServerSession(sessionId);
          if (resolved != id) {
            // The guard was keyed on the local id; the fresh server id is
            // what every later `_serverId` resolves to, so claim it too or
            // a second tap after the create would slip past the guard.
            _sending.add(resolved);
            guardKeys.add(resolved);
          }
          id = resolved;
        } on CloudApiException catch (e) {
          _recordError(sessionId, e.code, e.message, resetsAt: e.resetsAt);
          _notify();
          return;
        }
      }

      if (store?.offline ?? false) {
        // Checked BEFORE `_stateFor` so an enqueue-only send does not open a
        // subscription (review round 1, Minor 3).
        await store!.enqueue(
          id,
          originalPrompt,
          maxOutputTokens: maxOutputTokens,
        );
        return;
      }

      final state = _stateFor(id);

      final staged = List<({String name, String path, int size})>.from(
        attachments ?? _attachments[id] ?? const [],
      );
      // Whether this send queues behind a live run (server FIFO). Captured
      // before the await: busyFor can change while the POST is in flight.
      // `_busyForRun` — this send already holds the in-flight flag and must
      // not read its own POST as a live run.
      final queuedBehindActiveRun = _busyForRun(id);
      // The composer decides queue-vs-send on `busyFor`; flip it for the
      // in-flight window too.
      _notify();

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
          maxOutputTokens: maxOutputTokens,
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

        // Review carry (T8 round 1): a terminal event for THIS run can arrive
        // while the POST is in flight. Resurrecting busy after that would
        // leave the composer showing Stop for a dead run.
        if (state.terminalSettledRunId != response.runId) {
          state.runState = CloudRunState(runId: response.runId, busy: true);
          state.queuedBehindActiveRun = queuedBehindActiveRun;
        }
        // Clear only the snapshot this send carried. A file staged while the
        // POST was in flight belongs to the NEXT message and must survive
        // (the retired local service's `_acknowledgeAttachments` contract).
        final live = _attachments[id];
        if (live != null) {
          for (final sent in staged) {
            final index = live.indexWhere((a) =>
                a.name == sent.name &&
                a.path == sent.path &&
                a.size == sent.size);
            if (index >= 0) live.removeAt(index);
          }
          if (live.isEmpty) _attachments.remove(id);
        }
        // A freshly accepted send clears any stale recorded error (mode PATCH
        // failures, a previous 402) — Task 10's composer decides draft
        // acceptance on `runState.lastErrorCode == null`.
        _clearError(id);
        _notify();
      } on CloudApiException catch (e) {
        _recordError(id, e.code, e.message, resetsAt: e.resetsAt);
        _notify();
      } catch (e) {
        _recordError(id, 'internal', '$e');
        _notify();
      }
    } finally {
      // The POST settled (or the send aborted): the in-flight window is
      // over and the composer falls back to run-tracking busy state.
      _sending.removeAll(guardKeys);
      _notify();
    }
  }

  @override
  bool stopRequested({required String sessionId}) {
    final id = _serverId(sessionId);
    if (id == null) return false;
    // Test-seam busy state (see [setActiveRunForTest]) settles like a real
    // stop: there is no server run to cancel.
    if (_activeRunForTest.remove(id) == true) {
      _notify();
      return true;
    }
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
        // The server says the run is done: the watchdog stands down with it.
        _stopStallWatchdog(state.serverId);
        state.runState = _copyRunState(
          state.runState,
          busy: false,
          stopRequested: false,
          clearRunId: true,
        );
        _notify();
        unawaited(_drainQueue(state.serverId));
      } else {
        _recordError(state.serverId, e.code, e.message, resetsAt: e.resetsAt);
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
  // AgentSurface — approvals (P3 Task 12: the gate + redis bridge landed)
  // -------------------------------------------------------------------------

  /// The foreground session's live prompt, or null. The prompt itself is
  /// folded by the projection ([CloudApprovalPrompt]); this mirrors it into
  /// the UI-shaped [ApprovalRequest] the dock renders.
  @override
  ApprovalRequest? get pendingApproval {
    // The test seam shadows the live prompt (UI tests inject cards through
    // pendingApprovalForTest exactly like the retired local service's
    // settable).
    final seeded = pendingApprovalForTest;
    if (seeded != null) return seeded;
    final id = _serverId(null);
    return id == null ? null : _approvalRequests[id];
  }

  @override
  List<({String sessionId, String title, ApprovalRequest request})>
      get pendingApprovalsElsewhere {
    final active = _serverId(null);
    return [
      for (final entry in _approvalRequests.entries)
        if (entry.key != active)
          (
            sessionId: entry.key,
            // The row the other-sessions banner switches to; a session with
            // no local row (never rendered) falls back to the raw server id.
            title: AppState.I.sessionById(entry.key)?.title ?? entry.key,
            request: entry.value,
          ),
    ];
  }

  @override
  bool approveRequest(ApprovalRequest req, bool ok, {String? note}) =>
      // note: the cloud wire has no field for a refusal note — the
      // `approval_response` op is exactly {sessionId, approvalId, decision}
      // (shared ws.ts) — so it is accepted for surface parity and dropped.
      _respondApproval(req, ok ? 'allow' : 'deny');

  @override
  bool approveAlwaysRequest(ApprovalRequest req) =>
      _respondApproval(req, 'always');

  /// Mirrors the projection's prompt into [_approvalRequests]. approvalId-
  /// keyed: the SAME prompt keeps the SAME request object across unrelated
  /// projection notifies, so the dock's identity-tracked arm guard
  /// (`_ApprovalDock._track`) stays stable while the card is up.
  void _syncApprovalRequest(String serverId, _SessionCloudState state) {
    final prompt = state.projection.pendingApproval;
    final cached = _approvalRequests[serverId];
    if (prompt == null) {
      if (cached != null) _approvalRequests.remove(serverId);
      return;
    }
    if (cached != null && cached.approvalId == prompt.approvalId) return;
    _approvalRequests[serverId] = ApprovalRequest(
      tool: prompt.tool,
      summary: prompt.summary,
      detail: prompt.detail,
      allowAlways: prompt.allowAlways,
      approvalId: prompt.approvalId,
      // Best-effort mode tag: the server persists grants itself, so this is
      // row parity, not a decision input.
      modeName: AppState.I.sessionById(serverId)?.mode ?? '',
    );
  }

  /// Answers the bridge over the multiplexer's raw lane:
  /// `{"op":"approval_response","sessionId":…,"approvalId":…,"decision":
  /// "allow"|"deny"|"always"}` (the gateway validates session ownership and
  /// the decision enum, publishes to the approval responses channel, and
  /// acks with `approval_ack`). The DURABLE confirmation is the session's
  /// own `approval_resolved` event, whose fold clears the card. The prompt
  /// is dropped OPTIMISTICALLY here: the bridge is first-resolution-wins, a
  /// late second answer is a no-op server-side, and the card must not wait
  /// for the resolved event to dismiss. False when [req] is not — or is no
  /// longer — a pending cloud prompt (a test-seeded request with no
  /// approvalId, or a stale tap after the card was answered).
  bool _respondApproval(ApprovalRequest req, String decision) {
    final approvalId = req.approvalId;
    if (approvalId == null || approvalId.isEmpty) return false;
    String? serverId;
    for (final entry in _approvalRequests.entries) {
      if (identical(entry.value, req) ||
          entry.value.approvalId == approvalId) {
        serverId = entry.key;
        break;
      }
    }
    if (serverId == null) return false; // already answered or superseded
    _approvalRequests.remove(serverId);
    _sessions[serverId]?.projection.clearPendingApproval(approvalId);
    unawaited(_ws.sendRaw(<String, Object?>{
      'op': 'approval_response',
      'sessionId': serverId,
      'approvalId': approvalId,
      'decision': decision,
    }));
    _notify();
    return true;
  }

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
    if (id == null) return <({String name, String path, int size})>[];
    // Mutable by contract: the surviving composer/edit paths stage a message's
    // existing attachments by adding to this list (the retired local service
    // exposed the same mutable view).
    return _attachments.putIfAbsent(
        id, () => <({String name, String path, int size})>[]);
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
    final pending = _attachments.putIfAbsent(
        id, () => <({String name, String path, int size})>[]);
    if (pending.length + (_attachmentReservations[id] ?? 0) >=
        _maxAttachments) {
      return 'You can attach up to 20 files per message. Remove a file first.';
    }
    // Reserve the slot BEFORE the first await: the picker stages a burst of
    // files concurrently, and a count check after `File.length()` would let
    // every call pass.
    _attachmentReservations[id] = (_attachmentReservations[id] ?? 0) + 1;
    _notify();
    try {
      if (fileName.isEmpty ||
          fileName == '.' ||
          fileName == '..' ||
          fileName.contains('/') ||
          fileName.contains('\\') ||
          fileName.contains('\u0000')) {
        return 'invalid attachment filename';
      }
      int size;
      try {
        size = await File(sourcePath).length();
      } catch (_) {
        return 'file not found: $fileName';
      }
      if (size > 25 * 1024 * 1024) {
        return 'File is larger than the 25 MB cloud attachment limit.';
      }
      // Re-read the map after the await: a send that settled during the
      // picker call may have removed this session's staged snapshot.
      _attachments
          .putIfAbsent(
              id, () => <({String name, String path, int size})>[])
          .add((name: fileName, path: sourcePath, size: size));
      _notify();
      return null;
    } finally {
      final remaining = (_attachmentReservations[id] ?? 1) - 1;
      if (remaining <= 0) {
        _attachmentReservations.remove(id);
      } else {
        _attachmentReservations[id] = remaining;
      }
      _notify();
    }
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

  /// Test seam: stage an attachment without touching the filesystem. The
  /// retired local service exposed its mutable staging list; the facade keeps
  /// staging private, so UI tests use this instead.
  @visibleForTesting
  void stageAttachmentForTest(
    String sessionId, {
    required String name,
    required String path,
    required int size,
  }) {
    final id = _serverId(sessionId) ?? sessionId;
    _attachments
        .putIfAbsent(id, () => <({String name, String path, int size})>[])
        .add((name: name, path: path, size: size));
    _notify();
  }

  /// Test seam: clear every in-memory composer queue.
  @visibleForTesting
  void clearQueueForTest() {
    _queues.clear();
    _draining.clear();
    _sending.clear();
    _notify();
  }

  /// Test seam: mark [sessionId] busy without a live WS run.
  @visibleForTesting
  void setActiveRunForTest(String sessionId, String? runId) {
    final id = _serverId(sessionId) ?? sessionId;
    if (runId == null) {
      _activeRunForTest.remove(id);
    } else {
      _activeRunForTest[id] = true;
    }
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
    // Ownership transfer at enqueue time (chat P1): the staged files ride
    // WITH this row — "the queued message keeps its original attachments" —
    // and leave the composer's staging list. Anything staged later belongs
    // to the NEXT message: the drain hands the row its own list, so the
    // direct-send fallback never lends later files to an earlier row.
    final staged = _attachments.remove(id);
    _enqueueRow(id, text, staged);
    if (!busyFor(id)) unawaited(_drainQueue(id));
  }

  /// Adds one row to [serverId]'s queue with [staged] as the row's own
  /// attachments (empty when nothing was staged). The drain's `runTask`
  /// call passes the list explicitly, which also disables its
  /// `_attachments` fallback for the dispatch.
  void _enqueueRow(
    String serverId,
    String text,
    List<({String name, String path, int size})>? staged,
  ) {
    _queues
        .putIfAbsent(serverId, () => <_QueuedCloudMessage>[])
        .add(_QueuedCloudMessage(
          _nextQueueId++,
          text,
          attachments: List<({String name, String path, int size})>.from(
              staged ?? const []),
        ));
    _notify();
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
    // Stop promotes the queue head (local-queue parity). The drain runs on
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
          attachments: entry.attachments,
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
      // Undo restores the row WITH its attachments — "queued text and files
      // come back with their original ids" (queue dock copy).
      queue.insert(0, _QueuedCloudMessage(item.id, item.text,
          attachments: item.attachments));
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
  ///
  /// Re-entrancy guarded (T8 carry, owned by Task 10): a row enqueued while
  /// the head's POST is in flight would otherwise find `busyFor` still false
  /// (busy only flips on `run_started`) and dispatch the SECOND head
  /// concurrently — out of order. The in-flight flag serializes drains per
  /// session; a successful drain re-checks the queue so rows queued during
  /// the POST still leave in order.
  Future<void> _drainQueue(String serverId) async {
    if (_disposed) return;
    final queue = _queues[serverId];
    if (queue == null || queue.isEmpty) return;
    if (busyFor(serverId)) return;
    if (_store?.offline ?? false) return;
    if (!_draining.add(serverId)) return;
    var dispatched = false;
    try {
      final head = queue.removeAt(0);
      dispatched = true;
      _notify();
      // The row's own attachments ride with it (chat P1); passing the list
      // explicitly also disables runTask's `_attachments` fallback, so a
      // file staged AFTER this row was queued belongs to the next message.
      await runTask(
        head.text,
        sessionId: serverId,
        attachments: head.attachments,
      );
      final state = _sessions[serverId];
      final failed = state != null &&
          !state.runState.busy &&
          state.runState.lastErrorCode != null;
      if (failed && !_disposed) {
        // Never drop a user's queued message on a send failure; the error is
        // surfaced through run state.
        queue.insert(0, head);
        dispatched = false;
        _notify();
      }
    } finally {
      _draining.remove(serverId);
    }
    if (_disposed || !dispatched) return;
    // Rows queued while the POST was in flight dispatch now, in order.
    if (_queues[serverId]?.isNotEmpty == true && !busyFor(serverId)) {
      unawaited(_drainQueue(serverId));
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
  // Task 9 — store wiring: reconnect flush + transcript seeding
  // -------------------------------------------------------------------------

  /// Fires for both offline inputs (connectivity probe + WS link state). A
  /// TRUE→FALSE edge is the reconnect: upload any files that were staged
  /// while offline, then flush the prompt outbox FIFO.
  void _onConnectivityChanged() {
    if (_disposed) return;
    final store = _store;
    if (store == null) return;
    final nowOffline = store.offline;
    final wasOffline = _lastOffline;
    _lastOffline = nowOffline;
    if (wasOffline && !nowOffline) {
      unawaited(_flushAfterReconnect(store));
    }
  }

  /// Offline attachments semantics (Task 9 owns the T8 carry): the bytes
  /// stayed staged on disk while offline, because an attachment id can only
  /// be minted by the gateway. On reconnect they are uploaded first and the
  /// ids are attached to the queued entry; a failure leaves them staged for
  /// the next flip and the flush still runs (sending the text alone).
  Future<void> _flushAfterReconnect(CloudSessionStore store) async {
    if (_disposed) return;
    for (final entry in store.outboxEntries) {
      // P0 privacy: skip-and-retain another account's prompt. `outboxEntries`
      // is already account-filtered; this guard keeps the invariant even if
      // a future caller widens the getter — a foreign entry must never
      // trigger a session create or an upload under the wrong credentials.
      // Null never owns (fail-closed, like the store's own filter).
      if (entry.account != AppState.I.sessionAccountId) {
        continue;
      }
      final staged = _attachments[entry.sessionId];
      if (staged == null || staged.isEmpty) continue;
      try {
        final serverId = await store.ensureServerSession(entry.sessionId);
        final ids = <String>[];
        for (final attachment in staged) {
          final upload = await _rest.createAttachment(
            serverId,
            name: attachment.name,
            size: attachment.size,
          );
          final bytes = await File(attachment.path).readAsBytes();
          await _rest.uploadAttachmentBytes(upload, bytes);
          ids.add(upload.attachmentId);
        }
        await store.setAttachmentIds(entry.clientMsgId, ids);
        _attachments.remove(entry.sessionId);
      } catch (_) {
        // Keep them staged; the flush below is still safe.
      }
    }
    await store.flushOutbox();
    if (!_disposed) _notify();
  }

  @override
  void seedTranscript(
    String serverSessionId,
    List<Message> messages,
    String? cursor,
  ) {
    if (_disposed) return;
    final state = _stateFor(serverSessionId);
    state.projection.seedFromHistory(messages);
    state.projector.seedCursor(cursor);
    _ws.seedCursor(serverSessionId, cursor);
    _notify();
  }

  @override
  void prependTranscript(String serverSessionId, List<Message> messages) {
    if (_disposed || messages.isEmpty) return;
    final state = _stateFor(serverSessionId);
    final known = <String>{
      for (final message in state.projection.messages) message.privateSyncId,
    };
    final older = <Message>[
      for (final message in messages)
        if (known.add(message.privateSyncId)) message,
    ];
    if (older.isEmpty) return;
    state.projection.messages.insertAll(0, older);
    state.projection.notifyListeners();
    _notify();
  }

  @override
  void appendSentUserMessage(
    String serverSessionId,
    String userMessageId,
    String content,
  ) {
    if (_disposed) return;
    final state = _stateFor(serverSessionId);
    // A clientMsgId replay returns the ORIGINAL userMessageId: the row is
    // already present, so the outbox must not append a second one.
    if (state.projection.messages
        .any((m) => m.privateSyncId == userMessageId)) {
      return;
    }
    state.projection.messages.add(Message(
      role: 'user',
      kind: MsgKind.text,
      content: content,
      privateSyncId: userMessageId,
    ));
    state.projection.notifyListeners();
    _notify();
  }

  // -------------------------------------------------------------------------
  // Test seams
  // -------------------------------------------------------------------------

  /// The live projection for [sessionId] (null before first use).
  @visibleForTesting
  TranscriptProjection? projectionForTest(String sessionId) =>
      _sessions[_serverId(sessionId) ?? sessionId]?.projection;

  /// Forces the session state (cache seed + WS subscription) without a send.
  /// The production UI no longer triggers this from a plain transcript bind
  /// (see [liveBubbleTicksFor]); runs and cache loads still do.
  @visibleForTesting
  void subscribeForTest(String sessionId) {
    _stateFor(_serverId(sessionId) ?? sessionId);
  }

  // -------------------------------------------------------------------------
  // Task 10 — the chat rewire's read surface (cloud-only; the default build
  // renders ChatSession.messages straight from the server projection).
  // -------------------------------------------------------------------------

  /// The live transcript list chat_screen renders (oldest-first; null before
  /// the session was first used — the caller falls back to
  /// `ChatSession.messages`). Accepts a local or server session id.
  List<Message>? transcriptFor(String sessionId) =>
      _sessions[_serverId(sessionId) ?? sessionId]?.projection.messages;

  /// `x-ovid-resets-at` of the last recorded error for [sessionId], or null.
  /// The 402 countdown in the chat's error row derives from this.
  DateTime? errorResetsAtFor(String sessionId) =>
      _errorResetsAt[_serverId(sessionId) ?? sessionId];

  /// Dismisses the recorded error for [sessionId] (the chat error row's
  /// dismiss action). A later failure records a fresh one.
  void clearErrorFor(String sessionId) {
    _clearError(_serverId(sessionId) ?? sessionId);
    _notify();
  }

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

  /// Awaits the in-flight title PATCH for [sessionId] (rename sync).
  @visibleForTesting
  Future<void> titlePatchSettledForTest(String sessionId) async {
    final op = _titlePatches[_serverId(sessionId) ?? sessionId];
    if (op != null) await op;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connection?.removeListener(_onConnectivityChanged);
    _ws.removeListener(_onConnectivityChanged);
    for (final state in _sessions.values) {
      unawaited(state.subscription?.cancel());
      state.projection.dispose();
    }
    _sessions.clear();
    for (final notifier in _busyNotifiers.values) {
      notifier.dispose();
    }
    _busyNotifiers.clear();
    for (final notifier in _tickNotifiers.values) {
      notifier.dispose();
    }
    _tickNotifiers.clear();
    _queues.clear();
    for (final timer in _stallTimers.values) {
      timer.cancel();
    }
    _stallTimers.clear();
    _stallTicks.clear();
    _stalled.clear();
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
  _QueuedCloudMessage(
    this.id,
    this.text, {
    List<({String name, String path, int size})>? attachments,
  }) : attachments = List<({String name, String path, int size})>.from(
            attachments ?? const []);

  final int id;
  String text;

  /// The files staged when this row was queued — the row's OWN attachments
  /// (chat P1), snapshotted at enqueue time. The drain passes them to
  /// `runTask` explicitly, so anything staged later belongs to the next
  /// message, never to an earlier queued row.
  final List<({String name, String path, int size})> attachments;
}
