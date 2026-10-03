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

/// Test seam: fires one canonical hook. Production uses [HookService.fireDetailed]
/// to distinguish a successful start from a fail-open execution failure.
typedef HookDispatcher =
    Future<String> Function(
      String event,
      String sessionId, {
      Map<String, dynamic> payload,
      String? model,
    });

/// Successful-once `session_start` dispatcher per boot.
///
/// A session start is idempotent per `(boot token, session id)` regardless of
/// the supplied [SessionStartReason]; the first reason wins and duplicate
/// concurrent callers share the original in-flight future. Failed readiness or
/// execution releases the reservation; retries retain the original reason and
/// skip successful synchronous hooks from earlier attempts.
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
  final Map<String, SessionStartReason> _reasons = {};
  final Map<String, Set<String>> _completedHooks = {};

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
  static bool skipActivationWaitForTest = false;
  @visibleForTesting
  SessionSkillRefresher? skillRefresherForTest;
  @visibleForTesting
  HookDispatcher? hookDispatcherForTest;

  BootTokenProvider get _bootTokenProvider =>
      bootTokenProviderForTest ?? () => AppState.I.bootToken;

  ActivationWaiter get _activationWaiter =>
      activationWaiterForTest ?? (token) => AppState.I.bootActivationSettled;

  SessionSkillRefresher get _skillRefresher =>
      skillRefresherForTest ??
      (session) => AgentService.I.refreshSkills(sessionId: session.id);

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
      _reasons.clear();
      _completedHooks.clear();
    }
    return _bootGeneration;
  }

  /// Fire `session_start` successfully once per boot. Failed attempts retry on
  /// the next call; this service does not schedule a provisioning callback.
  Future<void> sessionStarted(
    ChatSession session, {
    required SessionStartReason reason,
  }) {
    final token = _bootTokenProvider();
    final key = '${_generationFor(token)}:${session.id}';
    final existing = _starts[key];
    if (existing != null) return existing;
    final firstReason = _reasons.putIfAbsent(key, () => reason);
    final completed = _completedHooks.putIfAbsent(key, () => {});
    late final Future<void> future;
    future = _runStart(session, firstReason, token, completed).then((success) {
      if (!success && identical(_starts[key], future)) _starts.remove(key);
    });
    _starts[key] = future;
    _inFlight.add(future);
    future.whenComplete(() => _inFlight.remove(future));
    return future;
  }

  Future<bool> _runStart(
    ChatSession session,
    SessionStartReason reason,
    Object? token,
    Set<String> completed,
  ) async {
    try {
      if (!skipActivationWaitForTest) await _activationWaiter(token);
      await _skillRefresher(session);
      final payload = <String, dynamic>{
        'reason': reason.name,
        'parentSessionId': session.parentId,
        'isSubagent': session.parentId != null,
      };
      final dispatcher = hookDispatcherForTest;
      if (dispatcher != null) {
        await dispatcher(
          'session_start',
          session.id,
          payload: payload,
          model: session.model,
        );
        return true;
      }
      final result = await HookService.I.fireDetailed(
        'session_start',
        session.id,
        payload: payload,
        model: session.model,
        completedStartHooks: completed,
      );
      return !result.retryableFailure;
    } catch (_) {
      return false;
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
    _reasons.clear();
    _completedHooks.clear();
    _inFlight.clear();
    _bootToken = null;
    _bootGeneration = 0;
    bootTokenProviderForTest = null;
    activationWaiterForTest = null;
    skipActivationWaitForTest = false;
    skillRefresherForTest = null;
    hookDispatcherForTest = null;
  }
}
