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
  final Map<String, AgentMode> _modes = <String, AgentMode>{};

  /// Staged attachments per session (server id → files). No workspace copy:
  /// the bytes are uploaded straight from [({String name, String path, int size}).path].
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
    // BEFORE subscribing, the projector's monotonic `_lastSeq` must be
    // aligned with the cache's high-water mark — `seedFromHistory` does not
    // reset it. That reconciliation belongs to Task 9's store wiring.
    state.subscription = _ws.subscribe(serverId).listen(
          (CloudSessionEvent event) {
            if (_disposed) return;
            state.projector.apply(event);
            // Mirror the terminal error into run state (the projection keeps
            // its own lastError for transcript consumers). run_started /
            // run_completed clear a previous run's error; a projection's
            // lastError deliberately survives, so it cannot be used here.
            switch (event.type) {
              case 'run_failed':
                final code = event.payload['code'];
                final message = event.payload['message'];
                if (code is String) {
                  _recordError(
                      serverId, code, message is String ? message : '');
                  _notify();
                }
                break;
              case 'run_started':
              case 'run_completed':
                _clearError(serverId);
                _notify();
                break;
            }
          },
          onError: (Object error) => _onStreamError(serverId, error),
        );

    return state;
  }

  void _onProjectionChanged(String serverId, _SessionCloudState state) {
    if (_disposed) return;
    final projection = state.projection;
    if (projection.busy) {
      state.runState = _copyRunState(
        state.runState,
        runId: projection.activeRunId ?? state.runState.runId,
        busy: true,
      );
    } else if (state.runState.busy) {
      // Terminal event: the run is over. stopRequested must not survive it.
      state.runState = _copyRunState(
        state.runState,
        busy: false,
        stopRequested: false,
      );
    }
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
  }) =>
      CloudRunState(
        runId: runId ?? s.runId,
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
    if (id != null) {
      final explicit = _modes[id];
      if (explicit != null) return explicit;
      final persisted = AppState.I.activeSession?.mode;
      for (final candidate in AgentMode.values) {
        // Control is retired in the cloud (spec D5); a legacy local session
        // must not surface a mode the server does not accept.
        if (candidate == AgentMode.control) continue;
        if (candidate.name == persisted) return candidate;
      }
    }
    return AgentMode.auto;
  }

  @override
  void setMode(AgentMode m, {String? sessionId}) {
    final id = _serverId(sessionId);
    if (id == null) return;
    final previous = _modes[id] ?? AgentMode.auto;
    _modes[id] = m;
    _notify();
    final op = _patchMode(id, previous, m);
    _modePatches[id] = op;
    unawaited(op);
  }

  Future<void> _patchMode(
    String serverId,
    AgentMode previous,
    AgentMode next,
  ) async {
    try {
      await _rest.patchSession(serverId, mode: next.name);
      _clearError(serverId);
      _notify();
    } on CloudApiException catch (e) {
      _modes[serverId] = previous;
      _recordError(serverId, e.code, e.message);
      _notify();
    } catch (e) {
      _modes[serverId] = previous;
      _recordError(serverId, 'internal', '$e');
      _notify();
    }
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
    // The projection is the event truth; the facade's run state is the
    // cancel-race override (a 409 settles it even when the terminal event
    // was missed).
    return state.projection.busy && state.runState.busy;
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

    final state = _stateFor(id);

    if (_store?.offline ?? false) {
      await _store!.enqueue(id, originalPrompt);
      return;
    }

    final staged = List<({String name, String path, int size})>.from(
      attachments ?? _attachments[id] ?? const [],
    );

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
        // event cannot keep the session shimmering.
        state.runState = _copyRunState(
          state.runState,
          busy: false,
          stopRequested: false,
        );
        _notify();
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
  int measuredContextTokens(ChatSession s, {String systemPrompt = ''}) =>
      0; // P3: usage events. chat_screen's % ring divides by
         // contextWindowForSession(), which defaults to 1M — no div-by-zero.

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
  AgentMode modeForTest(String sessionId) =>
      _modes[_serverId(sessionId) ?? sessionId] ?? AgentMode.auto;

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
}
