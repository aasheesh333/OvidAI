import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_service.dart';
import 'hook_service.dart';
import 'state.dart';

/// Why a `session_start` lifecycle event is being dispatched.
enum SessionStartReason { created, implicit, restored, subagent }

/// Test seam: supplies the current process-local boot identity. Defaults to
/// [AppState.bootToken] — the sole production owner of boot activation.
typedef BootTokenProvider = Object? Function();

/// Test seam: waits for runtime activation of [token] to settle. Defaults to
/// [AppState.bootActivationSettled].
typedef ActivationWaiter = Future<void> Function(Object? token);

/// Test seam: refreshes the session-visible skill catalog before firing.
typedef SessionSkillRefresher = Future<void> Function(ChatSession session);

/// Test seam: fires one canonical hook. Defaults to [HookService.fire].
typedef HookDispatcher =
    Future<String> Function(
      String event,
      String sessionId, {
      Map<String, dynamic> payload,
      String? model,
    });

/// Exactly-once `session_start` dispatcher (design §5.6).
///
/// A session start is idempotent per `(boot token, session id)` regardless of
/// the supplied [SessionStartReason]; the first reason wins and duplicate
/// concurrent callers share the original in-flight future. Reservations are
/// never removed after a failure, so a fail-open hook or skill-refresh error
/// cannot cause a second firing inside the same boot.
///
/// Ordering per session:
///   1. await runtime activation readiness for the captured boot token
///   2. await the session-aware skill refresh (Task 4)
///   3. fire `session_start` directly (no listener pre-check) with the
///      `reason`/`parentSessionId`/`isSubagent` payload and the session model
///
/// Failures are swallowed: session creation and use must remain possible even
/// when a hook or refresh misbehaves.
class SessionLifecycleService {
  SessionLifecycleService._();

  static final SessionLifecycleService I = SessionLifecycleService._();

  /// Reserved starts, keyed by `bootGeneration:sessionId`.
  final Map<String, Future<void>> _starts = {};

  /// In-flight starts (drain seam).
  final Set<Future<void>> _inFlight = {};

  Object? _bootToken;
  int _bootGeneration = 0;

  /// Test seams.
  @visibleForTesting
  BootTokenProvider? bootTokenProviderForTest;
  @visibleForTesting
  ActivationWaiter? activationWaiterForTest;
  @visibleForTesting
  SessionSkillRefresher? skillRefresherForTest;
  @visibleForTesting
  HookDispatcher? hookDispatcherForTest;

  BootTokenProvider get _bootTokenProvider =>
      bootTokenProviderForTest ?? () => AppState.I.bootToken;

  ActivationWaiter get _activationWaiter =>
      activationWaiterForTest ??
      (token) => AppState.I.bootActivationSettled;

  SessionSkillRefresher get _skillRefresher =>
      skillRefresherForTest ??
      (session) => AgentService.I.refreshSkills(sessionId: session.id);

  HookDispatcher get _hookDispatcher =>
      hookDispatcherForTest ??
      (
        event,
        sessionId, {
        Map<String, dynamic> payload = const {},
        String? model,
      }) => HookService.I.fire(
        event,
        sessionId,
        payload: payload,
        model: model,
      );

  /// The current boot generation (advances only when the boot token changes).
  @visibleForTesting
  int get bootGenerationForTest => _bootGeneration;

  /// Advance the generation when the captured [token] differs from the last
  /// one seen. Resume/repeated startup reuse the same token and therefore the
  /// same generation.
  int _generationFor(Object? token) {
    if (!identical(_bootToken, token)) {
      _bootToken = token;
      _bootGeneration++;
      // Evict reservations from prior boots so the map cannot grow unbounded
      // across resumes/restarts (M1).
      _starts.removeWhere((key, _) => !key.startsWith('$_bootGeneration:'));
    }
    return _bootGeneration;
  }

  /// Fire `session_start` for [session] exactly once per boot.
  Future<void> sessionStarted(
    ChatSession session, {
    required SessionStartReason reason,
  }) {
    final token = _bootTokenProvider();
    final key = '${_generationFor(token)}:${session.id}';
    final existing = _starts[key];
    if (existing != null) return existing;
    final future = _runStart(session, reason, token);
    _starts[key] = future;
    _inFlight.add(future);
    future.whenComplete(() => _inFlight.remove(future));
    return future;
  }

  Future<void> _runStart(
    ChatSession session,
    SessionStartReason reason,
    Object? token,
  ) async {
    try {
      await _activationWaiter(token);
      await _skillRefresher(session);
      await _hookDispatcher(
        'session_start',
        session.id,
        payload: {
          'reason': reason.name,
          'parentSessionId': session.parentId,
          'isSubagent': session.parentId != null,
        },
        model: session.model,
      );
    } catch (_) {
      // Fail-open: a broken refresh/hook must never block session usability,
      // and the reservation above still guarantees exactly-once dispatch.
    }
  }

  /// Wait for every currently-tracked start to settle (test seam).
  @visibleForTesting
  Future<void> drainForTest() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_inFlight));
    }
  }

  /// Clear reservations and seams (test seam). A new boot token also advances
  /// the generation naturally; this fully resets for isolated tests.
  @visibleForTesting
  void resetForTest() {
    _starts.clear();
    _inFlight.clear();
    _bootToken = null;
    _bootGeneration = 0;
    bootTokenProviderForTest = null;
    activationWaiterForTest = null;
    skillRefresherForTest = null;
    hookDispatcherForTest = null;
  }
}
