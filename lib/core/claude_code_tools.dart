/// Claude Code tool-name and tool-input aliasing (master plan Phase 2 item 2).
///
/// Ovid's agent tools have their own names and argument shapes (`fs_edit
/// {command, path, old_str, new_str}`, `run_shell {command}`, ...). Claude Code
/// plugins — hooks, agent `tools:` lists, skill `allowed-tools` — speak Claude
/// Code's vocabulary (`Edit {file_path, old_string, new_string}`, `Bash`,
/// `Glob`, `Agent`/`Task`, ...). This file is the single translation table,
/// used in both directions:
///
///  * native → Claude Code: the tool name a matcher / stdin sees, and the
///    `tool_input` keys a hook script reads ([ccToolName], [ccToolInput]);
///  * Claude Code → native: a hook's `updatedInput` rewrite
///    ([nativeToolInput]) and a subagent `tools:` entry ([nativeToolsFor]).
///
/// Pure functions only — no service state — so it is trivially testable.
library;

class ClaudeCodeTools {
  ClaudeCodeTools._();

  /// Native tools each Claude Code tool name grants. Ovid has no dedicated
  /// MultiEdit / NotebookEdit / LS tools: their capability lives in `fs_edit`,
  /// `file_write` and `fs_glob`, so a `tools: MultiEdit` grant maps there.
  static const Map<String, Set<String>> _ccToNative = {
    'Bash': {'run_shell', 'job_start', 'job_output', 'job_list', 'job_kill'},
    'PowerShell': {'run_shell'},
    'Read': {'file_read', 'read_image', 'read_attachment'},
    'Write': {'file_write'},
    'Edit': {'fs_edit'},
    'MultiEdit': {'fs_edit'},
    'NotebookEdit': {'fs_edit', 'file_write'},
    'NotebookRead': {'file_read'},
    'Glob': {'fs_glob'},
    'LS': {'fs_glob'},
    'Grep': {'fs_grep'},
    'WebFetch': {'fetch_url'},
    'WebSearch': {'web_search'},
    'Agent': {'dispatch_agent'},
    'Task': {'dispatch_agent'},
    'Workflow': {'workflow'},
    'TodoWrite': {'todo_write'},
    'Skill': {'skill'},
    'AskUserQuestion': {'ask_user_question'},
    'ExitPlanMode': {'exit_plan_mode'},
    'SendMessage': {'send_message'},
    'TaskStop': {'interrupt_agent'},
    'TaskOutput': {'job_output'},
  };

  /// True when [name] is a Claude Code built-in tool name Ovid understands.
  static bool isCcToolName(String name) => _ccToNative.containsKey(name);

  /// Native tool names granted by Claude Code tool [ccName] (empty when the
  /// name is not a Claude Code built-in).
  static Set<String> nativeToolsFor(String ccName) =>
      _ccToNative[ccName] ?? const {};

  /// The Claude Code name for native tool [native] called with [input], or
  /// null when the tool has no Claude Code equivalent (MCP tools keep their
  /// `mcp__server__tool` name, which already IS the Claude Code name).
  /// `fs_edit` resolves per operation: `view` → Read, `create` → Write,
  /// everything else → Edit (Claude Code's own create-vs-edit split).
  static String? ccToolName(String native, [Map<String, dynamic>? input]) {
    switch (native) {
      case 'run_shell':
      case 'job_start':
        return 'Bash';
      case 'file_read':
      case 'read_image':
        return 'Read';
      case 'file_write':
        return 'Write';
      case 'fs_edit':
        return switch (input?['command']) {
          'view' => 'Read',
          'create' => 'Write',
          _ => 'Edit',
        };
      case 'fs_glob':
        return 'Glob';
      case 'fs_grep':
        return 'Grep';
      case 'fetch_url':
        return 'WebFetch';
      case 'web_search':
        return 'WebSearch';
      case 'dispatch_agent':
        return 'Agent';
      case 'workflow':
        return 'Workflow';
      case 'todo_write':
        return 'TodoWrite';
      case 'skill':
        return 'Skill';
      case 'ask_user_question':
        return 'AskUserQuestion';
      case 'exit_plan_mode':
        return 'ExitPlanMode';
      case 'send_message':
        return 'SendMessage';
      case 'interrupt_agent':
        return 'TaskStop';
    }
    return null;
  }

  /// Every Claude Code name a matcher may use for [native]. The subagent
  /// spawner is `Agent` in current Claude Code and `Task` in older plugins;
  /// both must match.
  static List<String> ccMatcherNames(
    String native, [
    Map<String, dynamic>? input,
  ]) {
    final primary = ccToolName(native, input);
    if (primary == null) return const [];
    if (primary == 'Agent') return const ['Agent', 'Task'];
    return [primary];
  }

  /// [input] reshaped for a Claude Code hook: the native keys are kept (so an
  /// Ovid-aware hook still works) and the Claude Code keys are ADDED
  /// (`file_path`, `old_string`, `new_string`, `content`, `glob`, `query`,
  /// `description`, ...). Never mutates [input].
  static Map<String, dynamic> ccToolInput(
    String native,
    Map<String, dynamic> input,
  ) {
    final out = <String, dynamic>{...input};
    void alias(String from, String to) {
      if (input.containsKey(from) && !input.containsKey(to)) {
        out[to] = input[from];
      }
    }

    switch (native) {
      case 'file_read':
      case 'read_image':
      case 'file_write':
        alias('path', 'file_path');
      case 'fs_edit':
        alias('path', 'file_path');
        switch (input['command']) {
          case 'create':
            alias('file_text', 'content');
          case 'str_replace':
            alias('old_str', 'old_string');
            alias('new_str', 'new_string');
            out.putIfAbsent('replace_all', () => false);
          case 'insert':
            alias('new_str', 'new_string');
        }
      case 'fs_grep':
        alias('include', 'glob');
      case 'web_search':
        final queries = input['queries'];
        if (queries is List &&
            queries.isNotEmpty &&
            !input.containsKey('query')) {
          out['query'] = queries.first;
        }
      case 'dispatch_agent':
        alias('label', 'description');
        out.putIfAbsent('subagent_type', () => 'general-purpose');
      case 'fetch_url':
        out.putIfAbsent('prompt', () => '');
    }
    return out;
  }

  /// Translate a Claude Code shaped [updated] input (a hook's `updatedInput`)
  /// back into native arguments for [native], given the [original] native
  /// args. Native keys in [updated] are honoured as-is; Claude Code keys are
  /// renamed; Claude-Code-only bookkeeping keys are dropped so they never
  /// reach a native tool. The result is meant to be MERGED over [original].
  static Map<String, dynamic> nativeToolInput(
    String native,
    Map<String, dynamic> original,
    Map<String, dynamic> updated,
  ) {
    final out = <String, dynamic>{};
    final consumed = <String>{};
    void take(String cc, String nativeKey) {
      if (!updated.containsKey(cc)) return;
      consumed.add(cc);
      // An explicit native key in the same rewrite wins.
      if (updated.containsKey(nativeKey) && cc != nativeKey) return;
      out[nativeKey] = updated[cc];
    }

    switch (native) {
      case 'file_read':
      case 'read_image':
      case 'file_write':
        take('file_path', 'path');
      case 'fs_edit':
        take('file_path', 'path');
        final op = updated['command'] ?? original['command'];
        if (op == 'create') {
          take('content', 'file_text');
        } else {
          take('old_string', 'old_str');
          take('new_string', 'new_str');
        }
        consumed.add('replace_all');
      case 'fs_grep':
        take('glob', 'include');
      case 'web_search':
        if (updated['query'] is String && !updated.containsKey('queries')) {
          out['queries'] = [updated['query']];
        }
        consumed.add('query');
      case 'dispatch_agent':
        take('description', 'label');
      case 'fetch_url':
        consumed.add('prompt');
    }
    for (final e in updated.entries) {
      if (consumed.contains(e.key)) continue;
      out[e.key] = e.value;
    }
    return out;
  }
}
