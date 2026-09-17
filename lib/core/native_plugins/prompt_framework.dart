import 'package:ovid_ai/core/native_plugin.dart';

/// Marker interface for prompt-backed native plugin capabilities (NP5).
///
/// Capabilities declare prompt templates + JSON schemas; model execution
/// lives in `AgentService.runPromptTool` (a sub-model call with no tools
/// and no transcript writes, mirroring title generation). This file stays
/// LLM-free so `native_plugin.dart` never gains an import cycle.
abstract class NativePromptCapability implements NativePluginCapability {
  /// System prompt framing the sub-task (stable, cacheable).
  String get taskSystemPrompt;

  /// Build the user message for [toolName] from validated [args].
  /// Must embed a token-bounded slice of user input (see `boundInput`).
  String buildPrompt(String toolName, Map<String, dynamic> args);

  /// Token bound for embedded user content (overridable per capability).
  int get maxInputChars => 12000;

  /// Default callTool: prompt tools execute ONLY through the agent's
  /// runPromptTool path (needs a live model + session).
  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async =>
      'Plugin "$pluginName" runs its tools through the agent — call '
      'plugin__<slug>__$toolName in chat, not directly.';
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
