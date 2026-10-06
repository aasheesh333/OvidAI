import 'dart:async';

import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

/// Agent-injected executor for the real, model-backed prompt-tool call.
///
/// `AgentService` installs this once at boot so a prompt capability can run
/// its actual sub-model execution — and honour a [UtilityCancellation] token —
/// without this file importing the agent (keeping it LLM-free and free of an
/// import cycle with `native_plugin.dart`).
typedef PromptToolExecutor = Future<String> Function(
  NativePromptCapability capability,
  String toolName,
  Map<String, dynamic> args, {
  UtilityCancellation? cancellation,
});

/// Marker interface for prompt-backed native plugin capabilities (NP5).
///
/// Capabilities declare prompt templates + JSON schemas; model execution
/// lives in `AgentService.runPromptTool` (a sub-model call with no tools
/// and no transcript writes, mirroring title generation). This file stays
/// LLM-free so `native_plugin.dart` never gains an import cycle.
abstract class NativePromptCapability implements NativePluginCapability {
  /// The installed agent-side executor, or null when none is wired.
  ///
  /// Null in pure-framework tests and before boot: [callTool] then keeps its
  /// historical refusal, so existing callers see byte-for-byte old behavior.
  static PromptToolExecutor? executor;

  /// System prompt framing the sub-task (stable, cacheable).
  String get taskSystemPrompt;

  /// Build the user message for [toolName] from validated [args].
  /// Must embed a token-bounded slice of user input (see `boundInput`).
  String buildPrompt(String toolName, Map<String, dynamic> args);

  /// Token bound for embedded user content (overridable per capability).
  int get maxInputChars => 12000;

  /// Default callTool: prompt tools execute through the agent's
  /// runPromptTool path (needs a live model + session).
  ///
  /// When an [executor] is installed, [cancellation] is threaded into the
  /// actual model execution so a Stop aborts it promptly. With no executor
  /// (or a null token) behavior is unchanged.
  @override
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  }) async {
    final run = executor;
    if (run == null) {
      return 'Plugin "$pluginName" runs its tools through the agent — call '
          'plugin__<slug>__$toolName in chat, not directly.';
    }
    return runPromptWithCancellation(
      () => run(this, toolName, args, cancellation: cancellation),
      cancellation: cancellation,
    );
  }
}

/// Runs [body] — the actual agent-side execution for a prompt tool — under
/// [cancellation].
///
/// * [cancellation] null → exactly `await body()`; behavior is unchanged.
/// * already cancelled → fails immediately without running [body].
/// * fires while in flight → the returned future fails with a
///   [FormatException] as soon as the token is cancelled, without waiting for
///   [body] to settle.
Future<String> runPromptWithCancellation(
  Future<String> Function() body, {
  UtilityCancellation? cancellation,
}) async {
  if (cancellation == null) return body();
  if (cancellation.isCancelled) {
    throw const FormatException('Prompt tool operation cancelled.');
  }
  final result = Completer<String>();
  unawaited(
    cancellation.whenCancelled.then((_) {
      if (!result.isCompleted) {
        result.completeError(
          const FormatException('Prompt tool operation cancelled.'),
        );
      }
    }),
  );
  unawaited(
    Future<String>.sync(body).then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    ),
  );
  return result.future;
}

/// Shared head-truncation with exact omission notice.
///
/// Returns [text] unchanged when it fits in [max] chars; otherwise keeps
/// the first [max] chars and appends an exact `[…N characters omitted…]`
/// notice where N is the number of dropped characters.
String boundInput(String text, [int max = 12000]) {
  if (text.length <= max) return text;
  final omitted = text.length - max;
  final head = text.substring(0, max);
  return '$head\n\n[…$omitted characters omitted…]';
}
