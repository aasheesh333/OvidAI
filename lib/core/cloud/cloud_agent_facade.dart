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
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection_service.dart';
import '../diag.dart';
import '../state.dart';
import 'agent_surface.dart';
import 'cloud_errors.dart';
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
    this.persistQueue = false,
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
      // Pending-row states ("Sending…", "Waiting for connection", "Not
      // sent") are derived from the outbox: any outbox change repaints.
      s.addListener(_notify);
    } else {
      _connection = null;
    }
    if (persistQueue) unawaited(_loadPersistedQueues());
  }

  /// When true the composer queue (rows typed while a run is busy) is
  /// persisted per account, so process death cannot lose it (CH-023).
  /// Test fixtures that do not care leave it off.
  final bool persistQueue;

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
        persistQueue: true,
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
    _queuesLoaded = false;
    if (persistQueue) unawaited(_loadPersistedQueues());
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
    _pendingRows.clear();
    _lastPrompts.clear();
    _released.clear();
    _recent.clear();
    pendingApprovalForTest = null;
    _lastHardStop = null;
    for (final timer in _stallTimers.values) {
      timer.cancel();
    }
    _stallTimers.clear();
    _stallTicks.clear();
    _stalled.clear();
    for (final timer in _approvalTimers.values) {
      timer.cancel();
    }
    _approvalTimers.clear();
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
    unawaited(_persistQueues());
    _pendingRows.remove(id);
    _lastPrompts.remove(id);
    _released.remove(id);
    _recent.remove(id);
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

  /// The gateway's per-file cap (`ATTACHMENT_MAX_BYTES`,
  /// cloud/apps/gateway/src/routes/attachments.ts) — 25,000,000 bytes.
  static const int maxAttachmentBytes = 25000000;

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

  /// True when [key] is (as far as this process knows) a SERVER session id
  /// — one a WS subscription may name. An unmapped local id (a brand-new
  /// chat before its first send landed) is not: subscribing it would only
  /// earn a server error.
  bool _isServerKey(String key) {
    final store = _store;
    if (store == null) return true;
    return store.knownServerIdFor(key) == key;
  }

  /// The projection + projector for one session, subscribing on first use
  /// when [key] is a server id ([subscribe] false defers the subscription —
  /// a pending first send of an unmapped chat renders before the server id
  /// exists). Idempotent; a released (unsubscribed) session re-subscribes.
  _SessionCloudState _stateFor(String serverId, {bool? subscribe}) {
    final existing = _sessions[serverId];
    if (existing != null) {
      _released.remove(serverId);
      if (existing.subscription == null &&
          (subscribe ?? _isServerKey(serverId))) {
        _subscribe(serverId, existing);
      }
      _touchRecent(serverId);
      return existing;
    }

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

    // Prompts still in the outbox (queued offline, waiting for a retry, or
    // refused and waiting for the user) render as pending user rows — also
    // after a cold start, so a composed prompt is never invisible (CH-009).
    _restorePendingRows(serverId, state);

    if (subscribe ?? _isServerKey(serverId)) _subscribe(serverId, state);
    _touchRecent(serverId);
    // Rows restored from the persisted composer queue (CH-023) leave once
    // the session is idle.
    if (_queues[serverId]?.isNotEmpty == true) {
      scheduleMicrotask(() => unawaited(_drainQueue(serverId)));
    }
    return state;
  }

  void _subscribe(String serverId, _SessionCloudState state) {
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
              case 'plan_mode_changed':
              // The agent left (or entered) plan mode server-side
              // (exit_plan_mode): the Plan chip must follow, or the next
              // send would put the session straight back into plan mode.
              case 'todo_updated':
              case 'goal_updated':
                _syncSessionState(serverId, state);
                _notify();
                break;
              case 'subagent_started':
                // The live activity card reads the child's own events.
                final child = event.payload['childSessionId'];
                if (child is String && child.isNotEmpty) {
                  _watchChild(child);
                }
                break;
              case 'system_note':
                // CH-016: a queued run the server merged into the active
                // one never gets its own terminal — settle it here or the
                // composer shows Stop forever.
                if (event.payload['code'] == 'run_merged') {
                  final merged = event.payload['mergedRunId'];
                  if (merged is String &&
                      merged == state.runState.runId &&
                      merged != state.projection.activeRunId) {
                    final into = event.payload['runId'];
                    state.runState = _copyRunState(
                      state.runState,
                      runId: into is String ? into : null,
                      clearRunId: into is! String,
                      busy: into is String,
                    );
                    state.queuedBehindActiveRun = false;
                    _notify();
                  }
                }
                break;
            }
          },
          onError: (Object error) => _onStreamError(serverId, error),
        );
  }

  /// The local row mapped to [serverId], if any.
  ChatSession? _localSessionFor(String serverId) {
    for (final s in AppState.I.sessions) {
      if (_store?.serverIdFor(s.id) == serverId) return s;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Subscription lifetime (CH-014): only the chats the user is looking at,
  // or that have work in flight, stay subscribed.
  // -------------------------------------------------------------------------

  /// Most-recently-used subscribed sessions, oldest first.
  final List<String> _recent = <String>[];

  /// Sessions the user navigated away from while they still had work in
  /// flight; they unsubscribe as soon as that work settles.
  final Set<String> _released = <String>{};

  /// The server's per-connection cap is 64; stay far below it.
  static const int maxLiveSubscriptions = 16;

  void _touchRecent(String key) {
    _recent.remove(key);
    _recent.add(key);
    _enforceSubscriptionCap();
  }

  /// True while [key] must keep its live subscription: it is on screen, a
  /// run is in flight or queued, an approval waits, or prompts wait in the
  /// outbox.
  bool _mustStaySubscribed(String key) {
    final active = _serverId(null);
    if (active == key) return true;
    if (_sending.contains(key) || _busyForRun(key)) return true;
    if (_approvalRequests.containsKey(key)) return true;
    if (_queues[key]?.isNotEmpty == true) return true;
    final store = _store;
    if (store != null && store.outboxFor(key).isNotEmpty) return true;
    return false;
  }

  /// The user left [localOrServerId]'s chat. Its WS subscription is
  /// dropped now — or, when work is still in flight, as soon as it settles.
  /// The projection stays in memory and the replay cursor is kept, so
  /// coming back re-subscribes cheaply from where it stopped.
  void releaseSession(String localOrServerId) {
    if (_disposed) return;
    final key = _serverId(localOrServerId) ?? localOrServerId;
    if (!_sessions.containsKey(key)) return;
    _released.add(key);
    _maybeUnsubscribe(key);
  }

  /// The user opened [localOrServerId]'s chat: (re)subscribe it if it has a
  /// live projection or is a known server session.
  void activateSession(String localOrServerId) {
    if (_disposed) return;
    final key = _serverId(localOrServerId) ?? localOrServerId;
    _released.remove(key);
    if (_sessions.containsKey(key) || (_store != null && _isServerKey(key))) {
      _stateFor(key);
    }
  }

  void _maybeUnsubscribe(String key) {
    final state = _sessions[key];
    if (state == null || state.subscription == null) {
      _released.remove(key);
      return;
    }
    if (_mustStaySubscribed(key)) return;
    _released.remove(key);
    _recent.remove(key);
    unawaited(state.subscription?.cancel());
    state.subscription = null;
    _ws.unsubscribe(key);
  }

  void _enforceSubscriptionCap() {
    var live = _sessions.values.where((s) => s.subscription != null).length;
    if (live <= maxLiveSubscriptions) return;
    for (final key in List<String>.of(_recent)) {
      if (live <= maxLiveSubscriptions) break;
      final state = _sessions[key];
      if (state == null || state.subscription == null) continue;
      if (_mustStaySubscribed(key)) continue;
      _recent.remove(key);
      unawaited(state.subscription?.cancel());
      state.subscription = null;
      _ws.unsubscribe(key);
      live--;
    }
  }

  /// Subscribed session ids, for tests.
  @visibleForTesting
  Set<String> get subscribedSessionsForTest => <String>{
        for (final e in _sessions.entries)
          if (e.value.subscription != null) e.key,
      };

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
    // CH-019: a RUN-level failure has exactly one surface — the inline
    // failure row the projection appends (plain copy, Details, Retry, Pick
    // model). The red banner is reserved for send-level errors, so it is
    // cleared here for every terminal, failures included. CH-020: the
    // queued-cancel spelling run_failed{code:'cancelled'} is a user stop.
    _clearError(serverId);
    _notify();
    // Terminal cache write (Task 9 carry, Task 10): live deltas are not
    // persisted per-delta, so THIS is what makes a cold offline start show
    // the latest turn — the settled projection is written to the store's
    // offline READ CACHE.
    unawaited(_persistTerminal(serverId, state));
    unawaited(_drainQueue(serverId));
    if (_released.contains(serverId)) {
      scheduleMicrotask(() => _maybeUnsubscribe(serverId));
    }
  }

  Future<void> _persistTerminal(String serverId, _SessionCloudState state) async {
    final store = _store;
    if (store == null || _disposed) return;
    try {
      // CH-015: the cache's cursor is the LIVE replay cursor at this
      // terminal — the seq up to which the cached rows are authoritative —
      // never the stale mark of the last REST page (which rewound the
      // replay and duplicated every turn tail since).
      final cursor = state.projector.cursor ?? await _ws.cursorFor(serverId);
      await store.persistTranscript(
        serverId,
        // Pending rows live in the outbox, never in the read cache; the
        // settled projection has no live bubble at a terminal.
        [
          for (final m in state.projection.messages)
            if (pendingClientMsgIdOf(m) == null && m.kind != MsgKind.streaming)
              m,
        ],
        cursor,
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
      // CH-017: a refused approval answer brings its card straight back.
      final sending = _approvalRequests[serverId];
      if (sending != null && sending.sending && sending.approvalId != null) {
        _restoreApproval(sending.approvalId!);
      }
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
    _persistQueuesIfChanged();
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Composer-queue persistence (CH-023)
  // -------------------------------------------------------------------------

  static const String queuePrefKey = 'ovid_cloud_composer_queue';
  bool _queuesLoaded = false;
  String? _lastQueueSnapshot;

  String _queueSnapshot() => jsonEncode(<String, Object>{
        for (final e in _queues.entries)
          if (e.value.isNotEmpty)
            e.key: [for (final row in e.value) row.toJson()],
      });

  void _persistQueuesIfChanged() {
    if (!persistQueue || !_queuesLoaded) return;
    final snapshot = _queueSnapshot();
    if (snapshot == _lastQueueSnapshot) return;
    _lastQueueSnapshot = snapshot;
    unawaited(_writeQueues(snapshot));
  }

  Future<void> _persistQueues() async {
    if (!persistQueue || !_queuesLoaded) return;
    final snapshot = _queueSnapshot();
    _lastQueueSnapshot = snapshot;
    await _writeQueues(snapshot);
  }

  Future<void> _writeQueues(String snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          AppState.I.accountScopedPrefKey(queuePrefKey), snapshot);
    } catch (e, s) {
      Diag.swallow('cloud.persistQueue', e, s);
    }
  }

  Future<void> _loadPersistedQueues() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(AppState.I.accountScopedPrefKey(queuePrefKey));
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            final rows = e.value;
            if (e.key is! String || rows is! List) continue;
            final queue = _queues.putIfAbsent(
                e.key as String, () => <_QueuedCloudMessage>[]);
            final known = {for (final r in queue) r.id};
            for (final r in rows) {
              if (r is! Map) continue;
              final row = _QueuedCloudMessage.fromJson(
                  Map<String, dynamic>.from(r));
              if (row.text.trim().isEmpty || !known.add(row.id)) continue;
              queue.add(row);
              if (row.id >= _nextQueueId) _nextQueueId = row.id + 1;
            }
          }
        }
      }
    } catch (e, s) {
      Diag.swallow('cloud.loadQueue', e, s);
    }
    _queuesLoaded = true;
    _lastQueueSnapshot = _queueSnapshot();
    if (_disposed) return;
    for (final key in _queues.keys.toList()) {
      if (_sessions.containsKey(key)) unawaited(_drainQueue(key));
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
    // Test seam: the raw local id may not have a server mapping yet, but a
    // test that marked it busy still expects the UI to see it.
    if (_activeRunForTest[sessionId] == true) return true;
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

  /// CH-037: what the run is doing right now — "Waking your workspace",
  /// the running tool's activity ("Searching the web for …"), the active
  /// subagent — or null while it thinks or writes.
  String? activityFor(String sessionId) {
    final id = _serverId(sessionId);
    return id == null ? null : _sessions[id]?.projection.activity;
  }

  /// CH-037: true while the answer text itself is streaming (the bubble's
  /// caret is the status then — no second indicator).
  bool writingFor(String sessionId) {
    final id = _serverId(sessionId);
    final rows = id == null ? null : _sessions[id]?.projection.messages;
    if (rows == null || rows.isEmpty) return false;
    final last = rows.last;
    return last.kind == MsgKind.streaming &&
        !last.thinking &&
        last.content.isNotEmpty;
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

  // -------------------------------------------------------------------------
  // Per-turn settings (Wave 1a — CT-001, CH-001, CH-007, CH-008)
  // -------------------------------------------------------------------------

  /// The wire model id for a session's header pick: an empty pick or the
  /// legacy "Select a provider" sentinel means server routing ("auto") —
  /// exactly what the header label shows as "Auto".
  static String cloudModelWireId(String? model) {
    final m = model?.trim() ?? '';
    if (m.isEmpty || m == 'Select a provider') return 'auto';
    return m;
  }

  /// The settings the user can SEE for [localId]/[key] right now: header
  /// model, access-mode chip, Plan chip and preset. They ride every send so
  /// the server routes and gates the run with exactly these values.
  CloudTurnOptions turnOptionsFor(
    String? localId,
    String key, {
    List<String> sessionRefs = const <String>[],
    List<String> projectRefs = const <String>[],
  }) {
    // A queue drain addresses the chat by its SERVER id while the row is
    // keyed by its local id — resolve through the id map too.
    final session =
        AppState.I.sessionById(localId ?? '') ??
        AppState.I.sessionById(key) ??
        _localSessionFor(key);
    final mode = _modes[key] ?? _persistedModeFor(session?.id ?? localId, key);
    final preset = session?.presetId;
    return CloudTurnOptions(
      model: cloudModelWireId(session?.model),
      mode: mode.name,
      planMode: session?.planMode ?? false,
      presetId: (preset == null || preset.isEmpty) ? null : preset,
      sessionRefs: sessionRefs,
      projectRefs: projectRefs,
    );
  }

  // -------------------------------------------------------------------------
  // Pending user rows (CH-011): the prompt shows in the transcript the
  // moment Send is pressed, keyed by its clientMsgId, and is swapped for the
  // confirmed row when the server accepts it.
  // -------------------------------------------------------------------------

  static const String _pendingPrefix = 'pending:';

  /// The transcript row id of a not-yet-confirmed prompt.
  static String pendingRowId(String clientMsgId) => '$_pendingPrefix$clientMsgId';

  /// The clientMsgId behind a pending row, or null for a confirmed row.
  static String? pendingClientMsgIdOf(Message m) =>
      m.privateSyncId.startsWith(_pendingPrefix)
          ? m.privateSyncId.substring(_pendingPrefix.length)
          : null;

  /// Pending rows per session key (survive a transcript re-seed).
  final Map<String, List<Message>> _pendingRows = <String, List<Message>>{};

  /// The delivery state of a pending row, for the bubble's status line.
  PendingSendState? pendingStateOf(Message m) {
    final id = pendingClientMsgIdOf(m);
    if (id == null) return null;
    final entry = _store?.outboxEntry(id);
    if (entry != null && entry.failed) return PendingSendState.failed;
    if (entry != null && (_store?.offline ?? false)) {
      return PendingSendState.waitingForNetwork;
    }
    if (entry != null && entry.attempts > 0) return PendingSendState.retrying;
    return PendingSendState.sending;
  }

  /// The refusal behind a failed pending row ("Not sent" copy), or null.
  OutboxEntry? pendingEntryOf(Message m) {
    final id = pendingClientMsgIdOf(m);
    return id == null ? null : _store?.outboxEntry(id);
  }

  void _addPendingRow(
    _SessionCloudState state,
    String key,
    String clientMsgId,
    String content,
    List<({String name, String path, int size})> files,
  ) {
    final rowId = pendingRowId(clientMsgId);
    if (state.projection.messages.any((m) => m.privateSyncId == rowId)) return;
    final row = Message(
      role: 'user',
      kind: MsgKind.text,
      content: content,
      privateSyncId: rowId,
      attachments: [
        for (final f in files) MessageAttachment(name: f.name, size: f.size),
      ],
    );
    _pendingRows.putIfAbsent(key, () => <Message>[]).add(row);
    state.projection.messages.add(row);
    state.projection.notifyListeners();
  }

  void _restorePendingRows(String key, _SessionCloudState state) {
    final known = <String>{
      for (final m in state.projection.messages) m.privateSyncId,
    };
    var changed = false;
    for (final row in _pendingRows[key] ?? const <Message>[]) {
      if (known.add(row.privateSyncId)) {
        state.projection.messages.add(row);
        changed = true;
      }
    }
    final store = _store;
    if (store != null) {
      for (final entry in store.outboxFor(key)) {
        final rowId = pendingRowId(entry.clientMsgId);
        if (!known.add(rowId)) continue;
        final row = Message(
          role: 'user',
          kind: MsgKind.text,
          content: entry.content,
          privateSyncId: rowId,
          time: entry.createdAt,
          attachments: [
            for (final f in entry.attachmentFiles)
              MessageAttachment(name: f.name, size: f.size),
          ],
        );
        _pendingRows.putIfAbsent(key, () => <Message>[]).add(row);
        state.projection.messages.add(row);
        changed = true;
      }
    }
    if (changed) state.projection.notifyListeners();
  }

  /// Swaps the pending row for [clientMsgId] for the confirmed server row
  /// (same position — CH-011), or drops it when the confirmed row is
  /// already present (a replay, or a history page that raced the 202).
  void _confirmPendingRow(
    String key,
    String clientMsgId,
    String userMessageId,
    String content,
  ) {
    final state = _sessions[key];
    final rowId = pendingRowId(clientMsgId);
    _pendingRows[key]?.removeWhere((m) => m.privateSyncId == rowId);
    if (_pendingRows[key]?.isEmpty == true) _pendingRows.remove(key);
    if (state == null) return;
    final messages = state.projection.messages;
    final index = messages.indexWhere((m) => m.privateSyncId == rowId);
    final already = messages.any((m) => m.privateSyncId == userMessageId);
    if (index >= 0) {
      final pending = messages[index];
      if (already) {
        messages.removeAt(index);
      } else {
        messages[index] = Message(
          role: 'user',
          kind: MsgKind.text,
          content: pending.content,
          privateSyncId: userMessageId,
          time: pending.time,
          attachments: pending.attachments,
        );
      }
    } else if (!already) {
      messages.add(Message(
        role: 'user',
        kind: MsgKind.text,
        content: content,
        privateSyncId: userMessageId,
      ));
    }
    state.projection.notifyListeners();
  }

  /// Drops a pending row (the user discarded the prompt).
  void _removePendingRow(String key, String clientMsgId) {
    final rowId = pendingRowId(clientMsgId);
    _pendingRows[key]?.removeWhere((m) => m.privateSyncId == rowId);
    final state = _sessions[key];
    if (state == null) return;
    final before = state.projection.messages.length;
    state.projection.messages.removeWhere((m) => m.privateSyncId == rowId);
    if (state.projection.messages.length != before) {
      state.projection.notifyListeners();
    }
  }

  /// Retry on a "Not sent" row: delivers again with the SAME clientMsgId,
  /// so a prompt the server did accept can never run twice (CH-010).
  Future<void> retryPendingSend(String clientMsgId) async {
    final store = _store;
    if (store == null) return;
    final entry = store.outboxEntry(clientMsgId);
    if (entry == null) return;
    final key = _serverId(entry.sessionId) ?? entry.sessionId;
    _clearError(key);
    _notify();
    await store.retryOutboxEntry(clientMsgId);
    final after = store.outboxEntry(clientMsgId);
    if (after != null && after.failed) {
      _recordError(
        _serverId(after.sessionId) ?? after.sessionId,
        after.failedCode!,
        after.failedMessage ?? '',
        resetsAt: store.outboxErrorResetsAt,
      );
    }
    _notify();
  }

  /// Discard on a queued or "Not sent" row: the only path that removes a
  /// composed prompt without delivering it.
  Future<void> discardPendingSend(String clientMsgId) async {
    final store = _store;
    final entry = store?.outboxEntry(clientMsgId);
    final key = entry == null
        ? null
        : (_serverId(entry.sessionId) ?? entry.sessionId);
    await store?.discardOutboxEntry(clientMsgId);
    if (key != null) {
      _removePendingRow(key, clientMsgId);
      _clearError(key);
    } else {
      for (final k in _pendingRows.keys.toList()) {
        _removePendingRow(k, clientMsgId);
      }
    }
    _notify();
  }

  /// The last prompt sent per session — the run-failure Retry re-sends it.
  final Map<String, ({String text, CloudTurnOptions turn})> _lastPrompts =
      <String, ({String text, CloudTurnOptions turn})>{};

  /// Re-sends the last prompt of [sessionId] after a RUN-level failure
  /// (run_lost, model_*, …). A failed run consumed its clientMsgId, so this
  /// is deliberately a new send.
  Future<void> retryLastPrompt(String sessionId) async {
    final key = _serverId(sessionId) ?? sessionId;
    final last = _lastPrompts[key];
    if (last == null) return;
    _clearError(key);
    _notify();
    await runTask(last.text,
        sessionId: sessionId, sessionRefs: last.turn.sessionRefs);
  }

  /// True when [sessionId] has a prompt Retry can re-send.
  bool canRetryLastPrompt(String sessionId) =>
      _lastPrompts.containsKey(_serverId(sessionId) ?? sessionId);

  // -------------------------------------------------------------------------
  // Wave 1b (CT-004 / CH-024): history edits — server truncate, regenerate,
  // branch. Every action is a real server operation; the local projection
  // only mirrors what the server already did.
  // -------------------------------------------------------------------------

  /// A locally minted row id (`Message`'s 24 random bytes as hex) — never a
  /// server message id.
  static final RegExp _localIdShape = RegExp(r'^[0-9a-f]{48}$');

  /// True when [m] is a row the server stores (a user prompt or a final
  /// answer, keyed by its server message id) — the only rows history edits
  /// can address. Tool rows, segments, artifact chips (`kind:` prefixed
  /// ids), pending prompts and locally minted rows are not.
  static bool isServerMessage(Message m) {
    final id = m.privateSyncId;
    return (m.role == 'user' || m.role == 'assistant') &&
        m.kind == MsgKind.text &&
        m.toolName == null &&
        id.isNotEmpty &&
        !id.contains(':') &&
        !_localIdShape.hasMatch(id);
  }

  /// The oldest server-stored row of a loaded transcript — the `before`
  /// cursor for the next older history page (rich rows carry other ids).
  String? oldestServerMessageId(String sessionId) {
    final rows = transcriptFor(sessionId);
    if (rows == null) return null;
    for (final m in rows) {
      if (isServerMessage(m)) return m.privateSyncId;
    }
    return null;
  }

  Message? _lastServerPrompt(String sessionId) {
    final rows = transcriptFor(sessionId);
    if (rows == null) return null;
    for (var i = rows.length - 1; i >= 0; i--) {
      final m = rows[i];
      if (m.role == 'user' && isServerMessage(m)) return m;
    }
    return null;
  }

  /// R4 release gate: idle checks alone do not serialize history changes
  /// with another device's send. No mutable flag or test-only bypass.
  bool canEditHistory(String sessionId) => false;

  static const historyActionsUnavailableText =
      'Your chat is kept unchanged. Changing earlier messages, retrying a '
      'finished task and branching are unavailable.';

  void _truncateLocal(String key, String fromMessageId, {bool keep = false}) {
    final state = _sessions[key];
    if (state == null) return;
    final rows = state.projection.messages;
    final idx = rows.indexWhere((m) => m.privateSyncId == fromMessageId);
    if (idx < 0) return;
    state.projection.truncateAt(keep ? idx + 1 : idx);
    unawaited(_persistTerminal(key, state));
  }

  /// Deletes [message] and everything after it, on the server and here.
  /// Throws [CloudApiException] (409 `session_busy` while a run is active).
  Future<void> deleteFrom(String sessionId, Message message) async {
    final key = _serverId(sessionId) ?? sessionId;
    if (!isServerMessage(message)) {
      throw CloudApiException(
          status: 400, code: 'bad_request', message: 'This row cannot be deleted.');
    }
    await _rest.deleteMessagesFrom(key, message.privateSyncId);
    _truncateLocal(key, message.privateSyncId);
    _notify();
  }

  /// Edit & resend: the prompt and everything after it go, then [newText]
  /// is sent as a fresh prompt through the normal send path.
  Future<void> editAndResend(
    String sessionId,
    Message prompt,
    String newText,
  ) async {
    await deleteFrom(sessionId, prompt);
    await runTask(newText, sessionId: sessionId);
  }

  /// Runs [target]'s prompt again: an answer is replaced (it and everything
  /// after it go); a prompt whose run failed is retried in place.
  Future<void> regenerate(String sessionId, Message target) async {
    final key = _serverId(sessionId) ?? sessionId;
    if (!isServerMessage(target)) {
      throw CloudApiException(
          status: 400, code: 'bad_request', message: 'This row cannot be run again.');
    }
    final maxOut = AppState.I.maxOutputTokens;
    final response = await _rest.regenerateMessage(
      key,
      target.privateSyncId,
      maxOutputTokens: maxOut > 0 ? maxOut : null,
    );
    _truncateLocal(key, response.promptMessageId, keep: true);
    final state = _stateFor(key, subscribe: true);
    // Accepted, not started yet: Stop is offered until run_started lands.
    _markAccepted(key, state, response.runId, true);
  }

  /// Retry after a RUN-level failure: re-runs the last server prompt in
  /// place (no duplicate user row); falls back to re-sending the remembered
  /// text when the prompt never reached the server.
  Future<void> retryFailedRun(String sessionId) async {
    final prompt = _lastServerPrompt(sessionId);
    if (prompt == null) {
      await retryLastPrompt(sessionId);
      return;
    }
    _clearError(_serverId(sessionId) ?? sessionId);
    await regenerate(sessionId, prompt);
  }

  /// Branch: a NEW server chat holding this chat's history up to and
  /// including [message]. Returns the new chat's id.
  Future<String> branchFrom(String sessionId, Message message) async {
    final key = _serverId(sessionId) ?? sessionId;
    if (!isServerMessage(message)) {
      throw CloudApiException(
          status: 400, code: 'bad_request', message: 'This row cannot start a branch.');
    }
    final dto = await _rest.branchSession(key, message.privateSyncId);
    final store = _store;
    return store == null ? dto.id : store.adoptServerSession(dto);
  }

  @override
  Future<void> runTask(
    String originalPrompt, {
    String? sessionId,
    bool freshTurn = true,
    ChatSession? expandRefsFor,
    List<({String name, String path, int size})>? attachments,
    String? clientMsgId,
    List<String> sessionRefs = const <String>[],
    List<String> projectRefs = const <String>[],
    VoidCallback? onQueued,
  }) async {
    // freshTurn/expandRefsFor are local-loop concepts; the cloud run is
    // admitted server-side. They stay in the signature for AgentSurface
    // parity only.
    final localId = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : AppState.I.activeSessionId;
    final key = localId == null ? null : _serverId(localId);
    if (localId == null || key == null) {
      _recordError('', 'no_session', 'Start a chat first.');
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

    // Double-send guard (chat P1): a second tap while the first send is
    // between its synchronous entry and the server's answer queues behind
    // it instead of dispatching a second run. Claimed before the first
    // await, released when the send settles either way.
    if (!_sending.add(key)) {
      _enqueueRow(
        key,
        originalPrompt,
        attachments ?? _attachments.remove(key),
        sessionRefs: sessionRefs,
        projectRefs: projectRefs,
      );
      onQueued?.call();
      return;
    }
    final guardKeys = <String>{key};
    try {
      // ONE idempotency key per user send (CH-010): minted here (or handed
      // in by a retry) and kept with the prompt until the server confirms.
      final msgId = (clientMsgId != null && clientMsgId.isNotEmpty)
          ? clientMsgId
          : CloudSessionStore.newClientMsgId();

      // Snapshot the staged files BEFORE any await or server-id assignment
      // (CH-033): in a brand-new chat they are keyed by the LOCAL id, and the
      // first send must carry them whatever id the chat ends up with. The
      // prompt owns them from here; files staged later belong to the next
      // message.
      final staged = List<({String name, String path, int size})>.from(
        attachments ?? _attachments[key] ?? const [],
      );
      final live = _attachments[key];
      if (attachments == null && live != null) {
        for (final sent in staged) {
          final index = live.indexWhere(
            (a) =>
                a.name == sent.name &&
                a.path == sent.path &&
                a.size == sent.size,
          );
          if (index >= 0) live.removeAt(index);
        }
        if (live.isEmpty) _attachments.remove(key);
      }

      final turn = turnOptionsFor(
        localId,
        key,
        sessionRefs: sessionRefs,
        projectRefs: projectRefs,
      );
      _lastPrompts[key] = (text: originalPrompt, turn: turn);

      // The prompt is on screen immediately (CH-011), in order, before any
      // network round trip — including the first send of a new chat.
      final state = _stateFor(key, subscribe: _isServerKey(key));
      _addPendingRow(state, key, msgId, originalPrompt, staged);
      _clearError(key);
      _notify();

      if (store == null) {
        onQueued?.call();
        await _sendDirect(key, state, originalPrompt, msgId, staged, turn,
            maxOutputTokens);
        return;
      }

      // Durable FIRST: the prompt (with its files, settings and key) is in
      // the account-scoped outbox before anything touches the network, so a
      // timeout, a 429, a 401 or process death can never lose it (CH-009).
      await store.enqueue(
        localId,
        originalPrompt,
        clientMsgId: msgId,
        maxOutputTokens: maxOutputTokens,
        turn: turn,
        attachmentFiles: [
          for (final f in staged)
            OutboxFile(name: f.name, path: f.path, size: f.size),
        ],
      );
      onQueued?.call();
      // Deliver now when online; offline it waits for the reconnect flush
      // (and the pending row says so).
      await store.flushOutbox();
      final resolved = _serverId(localId) ?? key;
      if (resolved != key) guardKeys.add(resolved);
      final entry = store.outboxEntry(msgId);
      if (entry != null && entry.failed) {
        _recordError(resolved, entry.failedCode!, entry.failedMessage ?? '',
            resetsAt: store.outboxErrorResetsAt);
      }
    } catch (e, s) {
      // Never an unhandled exception out of a send (CH-012).
      Diag.swallow('cloud.runTask', e, s);
      _recordError(key, cloudFailureCode(e), e is CloudApiException ? e.message : '');
    } finally {
      // The send settled (accepted, queued or refused): the in-flight window
      // is over and the composer falls back to run-tracking busy state.
      _sending.removeAll(guardKeys);
      _notify();
    }
  }

  /// Store-less send (unit-test compositions): upload, POST, swap the row.
  Future<void> _sendDirect(
    String id,
    _SessionCloudState state,
    String prompt,
    String clientMsgId,
    List<({String name, String path, int size})> staged,
    CloudTurnOptions turn,
    int? maxOutputTokens,
  ) async {
    // Whether this send queues behind a live run (server FIFO). Captured
    // before the await: busyFor can change while the POST is in flight.
    final queuedBehindActiveRun = _busyForRun(id);
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
        prompt,
        attachmentIds: attachmentIds,
        clientMsgId: clientMsgId,
        maxOutputTokens: maxOutputTokens,
        turn: turn,
      );
      _confirmPendingRow(id, clientMsgId, response.userMessageId, prompt);
      _markAccepted(id, state, response.runId, queuedBehindActiveRun);
    } catch (e) {
      // Without an outbox the row cannot wait: it leaves and the error row
      // explains (the text is still recoverable through Retry).
      _removePendingRow(id, clientMsgId);
      if (staged.isNotEmpty) {
        _attachments.putIfAbsent(id, () => []).insertAll(0, staged);
      }
      _recordError(id, cloudFailureCode(e),
          e is CloudApiException ? e.message : '',
          resetsAt: e is CloudApiException ? e.resetsAt : null);
      _notify();
    }
  }

  /// Arms run tracking for an accepted send.
  void _markAccepted(
    String id,
    _SessionCloudState state,
    String runId,
    bool queuedBehindActiveRun,
  ) {
    // Review carry (T8 round 1): a terminal event for THIS run can arrive
    // while the POST is in flight. Resurrecting busy after that would leave
    // the composer showing Stop for a dead run.
    if (state.terminalSettledRunId != runId) {
      state.runState = CloudRunState(runId: runId, busy: true);
      state.queuedBehindActiveRun = queuedBehindActiveRun;
    }
    // A freshly accepted send clears any stale recorded error.
    _clearError(id);
    _notify();
  }

  @override
  bool stopRequested({required String sessionId, bool dispatchQueued = false}) {
    final id = _serverId(sessionId);
    if (id == null) return false;
    // Test-seam busy state (see [setActiveRunForTest]) settles like a real
    // stop: there is no server run to cancel. It deliberately does NOT drain
    // the queue — the seam models "the stop resolved locally", so callers
    // can assert the steered queue order.
    if (_activeRunForTest.remove(id) == true) {
      _notify();
      return true;
    }
    final state = _sessions[id];
    if (state == null || state.runState.runId == null || !state.runState.busy) {
      return false;
    }
    unawaited(_cancelRun(state, dispatchQueued: dispatchQueued));
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
    _lastHardStop = ops.isEmpty ? Future<void>.value() : Future.wait(ops);
  }

  Future<void> _cancelRun(
    _SessionCloudState state, {
    bool dispatchQueued = false,
  }) async {
    final runId = state.runState.runId;
    if (runId == null || !state.runState.busy) return;
    // CH-044: one cancel per run. Further taps while "Stopping…" are no-ops.
    if (state.runState.stopRequested) return;
    state.runState = _copyRunState(state.runState, stopRequested: true);
    _notify();
    try {
      await _rest.cancelRun(runId);
      // W9 Stop semantics: the cancel was accepted, so the queued message
      // is dispatched NOW (the server FIFO runs it after the cancelled
      // turn). Without this the row waited for the terminal event.
      if (dispatchQueued) {
        unawaited(_drainQueue(state.serverId, force: true));
      }
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

  /// True while a Stop for [sessionId]'s run is in flight ("Stopping…").
  bool stoppingFor(String sessionId) {
    final id = _serverId(sessionId);
    final state = id == null ? null : _sessions[id];
    return state != null && state.runState.busy && state.runState.stopRequested;
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
      if (cached != null) {
        _approvalRequests.remove(serverId);
        final id = cached.approvalId;
        if (id != null) _approvalTimers.remove(id)?.cancel();
      }
      return;
    }
    if (cached != null && cached.approvalId == prompt.approvalId) return;
    _approvalRequests[serverId] = ApprovalRequest(
      tool: prompt.tool,
      summary: prompt.summary,
      detail: prompt.detail,
      allowAlways: prompt.allowAlways && prompt.kind == 'tool',
      approvalId: prompt.approvalId,
      // CH-017: the kind, the plan text and the auto-deny clock survive
      // into the card.
      kind: prompt.kind,
      expiresAt: prompt.expiresAt,
      planBody: prompt.kind == 'plan' ? planBodyOf(prompt.detail) : null,
      // Best-effort mode tag: the server persists grants itself, so this is
      // row parity, not a decision input.
      modeName: AppState.I.sessionById(serverId)?.mode ?? '',
    );
  }

  /// The plan text of an `exit_plan_mode` prompt's detail: the gate frames
  /// it as `lead-in + blank line + plan`, so everything after the first blank line
  /// (or the whole detail when there is no lead-in).
  @visibleForTesting
  static String planBodyOf(String detail) {
    final i = detail.indexOf('\n\n');
    if (i < 0) return detail.trim();
    final rest = detail.substring(i + 2).trim();
    return rest.isEmpty ? detail.trim() : rest;
  }

  /// How long a tapped decision waits for the server's `approval_ack` (or
  /// the durable `approval_resolved`) before the card comes back (CH-017).
  @visibleForTesting
  static Duration approvalConfirmTimeout = const Duration(seconds: 5);

  /// One confirmation clock per answered approvalId.
  final Map<String, Timer> _approvalTimers = <String, Timer>{};

  StreamSubscription<Map<String, dynamic>>? _rawSub;

  void _ensureRawListener() {
    _rawSub ??= _ws.rawServerFrames.listen((frame) {
      if (_disposed) return;
      if (frame['op'] == 'approval_ack') {
        final id = frame['approvalId'];
        if (id is String) _confirmApproval(id);
      }
    });
  }

  /// The server accepted the decision: the card goes away for good.
  void _confirmApproval(String approvalId) {
    _approvalTimers.remove(approvalId)?.cancel();
    String? serverId;
    for (final entry in _approvalRequests.entries) {
      if (entry.value.approvalId == approvalId) serverId = entry.key;
    }
    if (serverId == null) return;
    _approvalRequests.remove(serverId);
    _sessions[serverId]?.projection.clearPendingApproval(approvalId);
    _notify();
  }

  /// The decision was never confirmed (frame dropped, gateway refused):
  /// the card comes back so the user can answer again.
  void _restoreApproval(String approvalId) {
    _approvalTimers.remove(approvalId)?.cancel();
    for (final req in _approvalRequests.values) {
      if (req.approvalId == approvalId && req.sending) {
        req.sending = false;
        _notify();
      }
    }
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
    final pending = _approvalRequests[serverId]!;
    if (pending.sending) return false; // one answer in flight at a time
    // CH-017: the card stays up ("Sending…") until the server confirms the
    // decision — `approval_ack`, or the durable `approval_resolved` fold —
    // and comes back if neither arrives (a dropped frame, a gateway error).
    pending.sending = true;
    _ensureRawListener();
    _approvalTimers.remove(approvalId)?.cancel();
    _approvalTimers[approvalId] =
        Timer(approvalConfirmTimeout, () => _restoreApproval(approvalId));
    unawaited(_ws.sendRaw(<String, Object?>{
      'op': 'approval_response',
      'sessionId': serverId,
      'approvalId': approvalId,
      'decision': decision,
    }).catchError((Object _) => _restoreApproval(approvalId)));
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
      // CH-022: the gateway's exact limit (25,000,000 bytes, `size > 0`),
      // checked HERE so a file that cannot be sent never stages.
      if (size <= 0) {
        return '$fileName is empty, so there is nothing to send.';
      }
      if (size > maxAttachmentBytes) {
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

  /// Test seam: append a projected row (e.g. a running `dispatch_agent`
  /// card) without starting a WS subscription or a real run.
  @visibleForTesting
  void seedRowForTest(String sessionId, Message row) {
    final id = _serverId(sessionId) ?? sessionId;
    final state = _stateFor(id, subscribe: false);
    state.projection.messages.add(row);
    state.projection.notifyListeners();
  }

  // -------------------------------------------------------------------------
  // AgentSurface — jobs / context (P2 / P3)
  // -------------------------------------------------------------------------

  /// CH-028: the Jobs list is the session's subagents that are still
  /// working (the only background work the cloud agent runs for a chat).
  /// The id is the card's position, stable for the life of the run.
  @override
  List<({int id, String name, String state, int elapsedSec, int outChars})>
      jobsFor(String sessionId) {
    final rows = _subagentRows(sessionId);
    final now = DateTime.now();
    return [
      for (var i = 0; i < rows.length; i++)
        if (rows[i].toolState == 'running')
          (
            id: i,
            name: subagentActivityLine(rows[i]),
            state: 'running',
            elapsedSec: now.difference(rows[i].time).inSeconds,
            outChars: 0,
          ),
    ];
  }

  /// Stops a running subagent from the Jobs list: its child run is
  /// cancelled server-side (ownership is the child session's — the user's).
  @override
  void killJobFor(String sessionId, int jobId) {
    final rows = _subagentRows(sessionId);
    if (jobId < 0 || jobId >= rows.length) return;
    final child = rows[jobId].toolSessionId;
    final key = _serverId(sessionId);
    final runId = child == null || key == null
        ? null
        : _sessions[key]?.projection.childRunOf(child);
    if (runId == null) return;
    unawaited(_rest.cancelRun(runId).then((_) {}, onError: (Object e) {
      Diag.swallow('cloud.killSubagent', e);
    }));
  }

  /// The `dispatch_agent` rows (subagent activity cards) of a session.
  List<Message> _subagentRows(String sessionId) {
    final key = _serverId(sessionId);
    final state = key == null ? null : _sessions[key];
    if (state == null) return const <Message>[];
    return [
      for (final m in state.projection.messages)
        if (m.kind == MsgKind.tool &&
            m.toolName == 'dispatch_agent' &&
            m.toolSessionId != null)
          m,
    ];
  }

  /// The live activity line of a subagent card: "CodeSubagent: Editing
  /// lib/main.dart" while its child works, the bare name otherwise.
  String subagentActivityLine(Message card) {
    final name = card.toolTitle ?? 'Subagent';
    final child = card.toolSessionId;
    if (card.toolState != 'running' || child == null) return name;
    final activity = _sessions[child]?.projection.activity;
    return activity == null ? name : '$name: $activity';
  }

  /// CH-028: the context ring reads the latest run's measured size
  /// (`run_completed.usage.contextTokens`); 0 until a run reports usage.
  @override
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''}) {
    final key = _serverId(s.id);
    return (key == null ? null : _sessions[key])
            ?.projection
            .lastUsage
            ?.contextTokens ??
        0;
  }

  /// The child session's live transcript for a subagent card (subscribing
  /// on first use while the child runs).
  void _watchChild(String childSessionId) {
    if (_disposed) return;
    _stateFor(childSessionId, subscribe: true);
  }

  /// Opens (or re-opens) a subagent's own transcript: subscribes the child
  /// session and, the first time, pages its history so a finished child's
  /// work is readable after a reload.
  Future<void> openSubagentTranscript(String childSessionId) async {
    if (_disposed) return;
    final existing = _sessions[childSessionId];
    _stateFor(childSessionId, subscribe: true);
    final store = _store;
    if (store == null) return;
    if (existing != null && existing.projection.messages.isNotEmpty) return;
    try {
      await store.loadTranscript(childSessionId);
    } catch (e) {
      Diag.swallow('cloud.openSubagentTranscript', e);
    }
  }

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
  void enqueueMessage(
    String text, {
    String? sessionId,
    List<String> sessionRefs = const <String>[],
    List<String> projectRefs = const <String>[],
  }) {
    if (text.trim().isEmpty) return;
    final id = _serverId(sessionId);
    if (id == null) return;
    // Ownership transfer at enqueue time (chat P1): the staged files ride
    // WITH this row — "the queued message keeps its original attachments" —
    // and leave the composer's staging list. Anything staged later belongs
    // to the NEXT message: the drain hands the row its own list, so the
    // direct-send fallback never lends later files to an earlier row.
    final staged = _attachments.remove(id);
    _enqueueRow(
      id,
      text,
      staged,
      sessionRefs: sessionRefs,
      projectRefs: projectRefs,
    );
    if (!busyFor(id)) unawaited(_drainQueue(id));
  }

  /// Adds one row to [serverId]'s queue with [staged] as the row's own
  /// attachments (empty when nothing was staged). The drain's `runTask`
  /// call passes the list explicitly, which also disables its
  /// `_attachments` fallback for the dispatch.
  void _enqueueRow(
    String serverId,
    String text,
    List<({String name, String path, int size})>? staged, {
    List<String> sessionRefs = const <String>[],
    List<String> projectRefs = const <String>[],
  }) {
    _queues
        .putIfAbsent(serverId, () => <_QueuedCloudMessage>[])
        .add(
          _QueuedCloudMessage(
            _nextQueueId++,
            text,
            attachments: List<({String name, String path, int size})>.from(
              staged ?? const [],
            ),
            sessionRefs: sessionRefs,
            projectRefs: projectRefs,
          ),
        );
    _notify();
  }

  @override
  void editQueuedMessageById(
    int id,
    String newText, {
    List<String> sessionRefs = const <String>[],
    List<String> projectRefs = const <String>[],
  }) {
    if (newText.trim().isEmpty) return;
    final queue = _queueFor(null);
    if (queue == null) return;
    for (final entry in queue) {
      if (entry.id == id) {
        entry.text = newText;
        // Re-derive the row's explicit refs from the edited text so a
        // removed/added @-tag cannot go stale (W1b projectRefs included).
        entry.sessionRefs = List<String>.of(sessionRefs);
        entry.projectRefs = List<String>.of(projectRefs);
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
    // Stop promotes the queue head (local-queue parity). The cancel is
    // accepted before the row is dispatched, so "send now" really starts
    // the next run instead of waiting for the current turn's terminal.
    stopRequested(sessionId: resolved, dispatchQueued: true);
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
  Future<void> _drainQueue(String serverId, {bool force = false}) async {
    if (_disposed) return;
    final queue = _queues[serverId];
    if (queue == null || queue.isEmpty) return;
    // `force` is the Stop-button path: the cancel was accepted, so the
    // queue head may be POSTed now and the server queues it behind the
    // cancelled run (FIFO). Subagent runs are untouched.
    if (!force && busyFor(serverId)) return;
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
        sessionRefs: head.sessionRefs,
        projectRefs: head.projectRefs,
      );
      // With an outbox the row is now durable there (delivered, retrying, or
      // "Not sent" with Retry) — never re-queued, never lost. Without one,
      // a failed send goes back to the head of the queue.
      final state = _sessions[serverId];
      final failed =
          _store == null &&
          state != null &&
          !state.runState.busy &&
          state.runState.lastErrorCode != null;
      if (failed && !_disposed) {
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

  CloudRunUsage? get _activeUsage {
    final key = _serverId(null);
    return key == null ? null : _sessions[key]?.projection.lastUsage;
  }

  /// The server reports one context total, not a system/tools split: the
  /// meter shows it as messages (the honest bucket) and the split as 0.
  @override
  int get sessionSystemTokens => 0;

  @override
  int get sessionToolTokens => 0;

  @override
  int get sessionMessageTokens => _activeUsage?.contextTokens ?? 0;

  @override
  int get sessionCacheReadTokens => _activeUsage?.cacheReadTokens ?? 0;

  // -------------------------------------------------------------------------
  // AgentSurface — subagents (Wave 1b: from the subagent_* folds)
  // -------------------------------------------------------------------------

  @override
  List<SubagentInfo> subagentsOf(String sessionId) {
    final key = _serverId(sessionId) ?? sessionId;
    final rows = _subagentRows(sessionId);
    String? handleOf(Message row) {
      final raw = row.toolInput;
      if (raw == null || raw.isEmpty) return null;
      try {
        final j = jsonDecode(raw);
        final h = j is Map ? j['handle'] : null;
        return h is String && h.isNotEmpty ? h : null;
      } catch (_) {
        return null;
      }
    }

    return [
      for (var i = rows.length - 1; i >= 0; i--)
        SubagentInfo(
          id: 'sub-${i + 1}',
          label: rows[i].toolTitle ?? 'Subagent',
          sessionId: rows[i].toolSessionId!,
          parentSessionId: key,
          parentMode: mode,
          prompt: rows[i].toolSummary ?? '',
          agentType: rows[i].toolTitle ?? 'general-purpose',
          handle: handleOf(rows[i]),
        )
          ..finished = rows[i].toolState != 'running'
          ..interrupted = rows[i].toolState == 'stopped',
    ];
  }

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

  /// Offline attachments semantics: queued prompts carry their own staged
  /// files (`OutboxEntry.attachmentFiles`) and the flush uploads them to the
  /// resolved server session before sending — nothing rides along with an
  /// unrelated later message any more (CH-035).
  Future<void> _flushAfterReconnect(CloudSessionStore store) async {
    if (_disposed) return;
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
    final state = _stateFor(serverSessionId, subscribe: true);
    state.projection.seedFromHistory(messages);
    state.projector.seedCursor(cursor);
    _ws.seedCursor(serverSessionId, cursor);
    // A history page that lands after Send must not wipe the prompt the
    // user just sent (CH-011): pending rows survive the re-seed.
    _restorePendingRows(serverSessionId, state);
    _notify();
  }

  @override
  void seedRichTranscript(
    String serverSessionId, {
    required List<Message> rows,
    required List<CloudSessionEvent> events,
    required String? watermark,
    required String? activeRunId,
  }) {
    if (_disposed) return;
    final state = _stateFor(serverSessionId, subscribe: true);
    EventTranscriptProjector.rebuild(
      state.projection,
      state.projector,
      rows: rows,
      events: events,
      watermark: watermark,
      activeRunId: activeRunId,
    );
    // CH-003: the live stream resumes strictly after the snapshot — never
    // the whole event log on top of it — and anything this socket already
    // delivered past the watermark replays into the rebuilt fold.
    _ws.rebaseCursor(serverSessionId, state.projector.cursor);
    if (activeRunId != null) {
      // CH-002: a chat reopened mid-run shows Stop at once (a queued run
      // too — it has not started, but it is the session's in-flight work).
      if (state.terminalSettledRunId != activeRunId) {
        state.runState = _copyRunState(
          state.runState,
          runId: activeRunId,
          busy: true,
        );
        // A queued run (no run_started yet) still reads busy.
        if (!state.projection.busy) state.queuedBehindActiveRun = true;
      }
    }
    _syncSessionState(serverSessionId, state);
    // A history page that lands after Send must not wipe the prompt the
    // user just sent (CH-011): pending rows survive the re-seed.
    _restorePendingRows(serverSessionId, state);
    _notify();
  }

  /// Mirrors the projection's folded session state (todos, goal, plan mode)
  /// into the local [ChatSession] the docks render from (CH-004).
  void _syncSessionState(String serverId, _SessionCloudState state) {
    final p = state.projection;
    final session =
        AppState.I.sessionById(serverId) ?? _localSessionFor(serverId);
    if (session == null) return;
    var changed = false;
    final todos = p.todos;
    if (todos != null && !_sameTodos(session.todos, todos)) {
      session.todos
        ..clear()
        ..addAll(todos);
      changed = true;
    }
    if (p.goalFolded && !mapEquals(session.goal, p.goal)) {
      session.goal = p.goal == null ? null : Map<String, dynamic>.of(p.goal!);
      changed = true;
    }
    final plan = p.planMode;
    if (plan != null && session.planMode != plan) {
      session.planMode = plan;
      session.planModePending = null;
      changed = true;
    }
    if (changed) {
      unawaited(AppState.I.persistSessions());
      AppState.I.refresh();
    }
  }

  static bool _sameTodos(
      List<Map<String, String>> a, List<Map<String, String>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!mapEquals(a[i], b[i])) return false;
    }
    return true;
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
  void outboxDelivered(
    String serverSessionId,
    OutboxEntry entry,
    SendMessageResponse response,
  ) {
    if (_disposed) return;
    final queuedBehindActiveRun = _busyForRun(serverSessionId);
    final state = _stateFor(serverSessionId, subscribe: true);
    // A clientMsgId replay returns the ORIGINAL userMessageId: dedupe keeps
    // it to one row.
    _confirmPendingRow(serverSessionId, entry.clientMsgId,
        response.userMessageId, entry.content);
    _markAccepted(serverSessionId, state, response.runId, queuedBehindActiveRun);
  }

  /// Every per-session surface keyed by a chat's LOCAL id moves to its new
  /// server id the moment the server assigns it (CH-033): staged files,
  /// queued rows, the optimistic mode, recorded errors, pending rows and the
  /// projection itself — then the projection subscribes under the server id.
  @override
  void sessionMapped(String localSessionId, String serverSessionId) {
    if (_disposed || localSessionId == serverSessionId) return;
    void move<V>(Map<String, V> map, V Function(V into, V from)? merge) {
      final from = map.remove(localSessionId);
      if (from == null) return;
      final into = map[serverSessionId];
      map[serverSessionId] =
          into == null || merge == null ? from : merge(into, from);
    }

    move<List<({String name, String path, int size})>>(
        _attachments, (a, b) => [...a, ...b]);
    move<List<_QueuedCloudMessage>>(_queues, (a, b) => [...a, ...b]);
    move<AgentMode>(_modes, null);
    move<(String, String)>(_errors, null);
    move<DateTime?>(_errorResetsAt, null);
    move<List<Message>>(_pendingRows, (a, b) => [...a, ...b]);
    move<({String text, CloudTurnOptions turn})>(_lastPrompts, null);
    final reservations = _attachmentReservations.remove(localSessionId);
    if (reservations != null) {
      _attachmentReservations[serverSessionId] =
          (_attachmentReservations[serverSessionId] ?? 0) + reservations;
    }
    if (_sending.remove(localSessionId)) _sending.add(serverSessionId);
    final ticks = _tickNotifiers.remove(localSessionId);
    if (ticks != null) {
      _tickNotifiers.putIfAbsent(serverSessionId, () => ticks);
    }
    final state = _sessions.remove(localSessionId);
    if (state != null && !_sessions.containsKey(serverSessionId)) {
      final moved = _SessionCloudState(
          serverSessionId, state.projection, state.projector)
        ..runState = state.runState
        ..terminalSettledRunId = state.terminalSettledRunId
        ..queuedBehindActiveRun = state.queuedBehindActiveRun;
      unawaited(state.subscription?.cancel());
      _sessions[serverSessionId] = moved;
      moved.projection.addListener(
          () => _onProjectionChanged(serverSessionId, moved));
      final t = _tickNotifierFor(serverSessionId);
      moved.projection.liveBubbleTicks.addListener(
        () => t.value = moved.projection.liveBubbleTicks.value,
      );
      _subscribe(serverSessionId, moved);
      _recent.remove(localSessionId);
      _touchRecent(serverSessionId);
    }
    _notify();
  }

  // -------------------------------------------------------------------------
  // Memory preferences (SE-005 / owner rule R1)
  // -------------------------------------------------------------------------

  /// Pushes the Settings memory switches to the server, which enforces them
  /// on every run (memory tools, cross-chat search). Fire-and-forget: a
  /// failure is retried on the next boot or toggle.
  Future<void> syncPreferences() async {
    try {
      final app = AppState.I;
      await _rest.patchPreferences(
        memoryEnabled: app.memoryEnabled,
        shareSessionMemory: app.effectiveShareSessionMemory,
      );
    } catch (e, s) {
      Diag.swallow('cloud.syncPreferences', e, s);
    }
  }

  /// [syncPreferences] when a facade is installed (Settings toggles).
  static void syncPreferencesIfInstalled() =>
      unawaited(_instance?.syncPreferences());

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
    _stateFor(_serverId(sessionId) ?? sessionId, subscribe: true);
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
    _store?.removeListener(_notify);
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
    for (final timer in _approvalTimers.values) {
      timer.cancel();
    }
    _approvalTimers.clear();
    unawaited(_rawSub?.cancel());
    _rawSub = null;
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
    this.sessionRefs = const <String>[],
    this.projectRefs = const <String>[],
  }) : attachments = List<({String name, String path, int size})>.from(
         attachments ?? const [],
       );

  factory _QueuedCloudMessage.fromJson(Map<String, dynamic> j) =>
      _QueuedCloudMessage(
        (j['id'] as num?)?.toInt() ?? 0,
        j['text'] as String? ?? '',
        attachments: [
          for (final a in (j['attachments'] as List? ?? const <dynamic>[]))
            if (a is Map)
              (
                name: a['name'] as String? ?? 'file',
                path: a['path'] as String? ?? '',
                size: (a['size'] as num?)?.toInt() ?? 0,
              ),
        ],
        sessionRefs: [
          for (final r in (j['sessionRefs'] as List? ?? const <dynamic>[]))
            if (r is String) r,
        ],
        projectRefs: [
          for (final r in (j['projectRefs'] as List? ?? const <dynamic>[]))
            if (r is String) r,
        ],
      );

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'text': text,
    if (attachments.isNotEmpty)
      'attachments': [
        for (final a in attachments)
          {'name': a.name, 'path': a.path, 'size': a.size},
      ],
    if (sessionRefs.isNotEmpty) 'sessionRefs': sessionRefs,
    if (projectRefs.isNotEmpty) 'projectRefs': projectRefs,
  };

  final int id;
  String text;

  /// Sessions the user @-tagged in this row (R1) — they ride its send.
  List<String> sessionRefs;

  /// Projects the user @-tagged in this row (R1) — they ride its send.
  List<String> projectRefs;

  /// The files staged when this row was queued — the row's OWN attachments
  /// (chat P1), snapshotted at enqueue time. The drain passes them to
  /// `runTask` explicitly, so anything staged later belongs to the next
  /// message, never to an earlier queued row.
  final List<({String name, String path, int size})> attachments;
}

/// Delivery state of a pending (not yet confirmed) user row.
enum PendingSendState {
  /// The POST is in flight.
  sending,

  /// A transient failure happened; the app retries by itself with backoff.
  retrying,

  /// Offline: it sends automatically when Ovid is reachable again.
  waitingForNetwork,

  /// The server refused it; the user can retry or discard.
  failed,
}
