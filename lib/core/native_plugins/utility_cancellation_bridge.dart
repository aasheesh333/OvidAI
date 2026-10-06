import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'utility_limits.dart';

/// Bridges the app's per-run Stop signal into [UtilityCancellation] tokens so
/// concrete utility calls (which already accept a `cancellation` token) can be
/// aborted the moment the user presses Stop.
///
/// The app's run-cancellation signal is the per-run boolean
/// `AgentRun.cancelRequested`, set by `AgentService._cancelBucket` on every
/// stop path (Stop button, global stop, session drop). Concrete utility
/// capabilities under `native_plugins/` already accept
/// `UtilityCancellation? cancellation` and forward it to
/// [runBoundedUtility]/[boundedUtilityRequest], but the shared
/// `NativePluginCapability.callTool` interface does not expose that parameter,
/// so the agent controller cannot hand a token to an in-flight call.
///
/// This bridge is the additive half of the fix. It tracks in-flight tokens per
/// run key and exposes [signalStop] for the controller's existing Stop path.
/// Until the shared signature is extended it can be used directly with any
/// concrete capability (see [run]), which makes it drop-in today.
///
/// ## Controller integration (exact minimal signature extension)
///
/// 1. Extend the shared interface in `lib/core/native_plugin.dart`. Every
///    concrete utility capability already declares this exact parameter and
///    forwards it, so no concrete implementation changes are needed:
///
///    ```dart
///    abstract class NativePluginCapability {
///      // ...
///      Future<String> callTool(
///        String toolName,
///        Map<String, dynamic> args, {
///        UtilityCancellation? cancellation,
///      });
///    }
///    ```
///
/// 2. In `AgentService._dispatchInner`, at the native-plugin branch
///    (`case String() when name.startsWith('plugin__')`), open a token for the
///    running session, pass it through, and always close it. The session id is
///    the same run key the Stop path already uses for
///    `SandboxService.I.killRunProcesses(runKey)`:
///
///    ```dart
///    final runKey = _runSession?.id ?? '';
///    final token = UtilityCancellationBridge.I.open(runKey);
///    try {
///      return await capability.callTool(
///        toolName,
///        cleanArgs,
///        cancellation: token,
///      );
///    } finally {
///      UtilityCancellationBridge.I.close(runKey, token);
///    }
///    ```
///
/// 3. In `AgentService._cancelBucket(AgentRun r)`, after `runKey` is computed
///    (the `SandboxService.I.killRunProcesses(runKey)` site), signal the
///    bridge:
///
///    ```dart
///    UtilityCancellationBridge.I.signalStop(runKey);
///    ```
///
/// No other controller change is required. A token opened for a run is only
/// cancelled by that run's Stop; tokens whose call has already completed are
/// closed and are never touched by a later Stop.
class UtilityCancellationBridge {
  UtilityCancellationBridge._();

  /// Process-wide bridge, mirroring `SandboxService.I`/`NativePluginRegistry.I`.
  static final UtilityCancellationBridge I = UtilityCancellationBridge._();

  final Map<String, Set<UtilityCancellation>> _inFlight = {};

  /// Opens a fresh token bound to [runKey] and records it as in-flight.
  ///
  /// Callers must [close] the token in a `finally` once the utility call
  /// settles, so a Stop arriving after completion cannot reach it.
  UtilityCancellation open(String runKey) {
    final token = UtilityCancellation();
    _inFlight.putIfAbsent(runKey, () => <UtilityCancellation>{}).add(token);
    return token;
  }

  /// Removes [token] from [runKey]'s in-flight set. Idempotent; a later
  /// [signalStop] for [runKey] will not cancel a closed token.
  void close(String runKey, UtilityCancellation token) {
    final tokens = _inFlight[runKey];
    if (tokens == null) return;
    tokens.remove(token);
    if (tokens.isEmpty) _inFlight.remove(runKey);
  }

  /// Opens a token for [runKey], runs [body] with it, and always closes it.
  ///
  /// Drop-in for concrete capabilities today, e.g.:
  ///
  /// ```dart
  /// final out = await UtilityCancellationBridge.I.run(
  ///   runKey,
  ///   (token) => CronDesignerCapability().callTool(
  ///     'next_runs',
  ///     args,
  ///     cancellation: token,
  ///   ),
  /// );
  /// ```
  Future<T> run<T>(
    String runKey,
    Future<T> Function(UtilityCancellation cancellation) body,
  ) async {
    final token = open(runKey);
    try {
      return await body(token);
    } finally {
      close(runKey, token);
    }
  }

  /// The app's Stop/run-cancellation signal for [runKey]. Cancels every
  /// in-flight token for that run; already-closed (completed) tokens are not
  /// in the set and are unaffected. Idempotent.
  void signalStop(String runKey) {
    final tokens = _inFlight.remove(runKey);
    if (tokens == null) return;
    for (final token in tokens) {
      token.cancel();
    }
  }

  /// Number of in-flight tokens currently registered for [runKey].
  @visibleForTesting
  int inFlightCountForTest(String runKey) => _inFlight[runKey]?.length ?? 0;

  /// Clears all registered tokens (test isolation only).
  @visibleForTesting
  void resetForTest() => _inFlight.clear();
}
