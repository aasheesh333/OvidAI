/// Human labels for cloud tool calls (Wave 1b, CH-004 / CH-037).
///
/// The server streams `tool_started{name, args}`; the chat shows a compact
/// row ("Edit · lib/main.dart"), the status line shows what the agent is
/// doing right now ("Editing lib/main.dart…"), and a subagent card shows its
/// child's current action ("Navigating to stripe.com…"). One table feeds all
/// three so they never disagree. Arg names mirror the BUILT server tools
/// (cloud/packages/agent-core/src/tools, cloud/packages/browser).
library;

/// Title for the collapsed tool row, the one-line argument summary next to
/// it, and the present-progressive activity phrase (no trailing ellipsis).
typedef CloudToolLabel = ({String title, String summary, String activity});

String? _arg(Map<String, dynamic> args, List<String> keys) {
  for (final k in keys) {
    final v = args[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return null;
}

String _oneLine(String s, [int max = 120]) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max - 1)}…';
}

/// `https://www.stripe.com/pricing` → `stripe.com`; non-URLs pass through.
String hostOf(String url) {
  final uri = Uri.tryParse(url.contains('://') ? url : 'https://$url');
  final host = uri?.host ?? '';
  if (host.isEmpty) return _oneLine(url, 60);
  return host.startsWith('www.') ? host.substring(4) : host;
}

String _humanName(String name) {
  final words = name.replaceAll(RegExp(r'^(mcp__|mcp_|plugin__)'), '')
      .split(RegExp(r'[_\-]+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return name;
  final first = words.first;
  return [first[0].toUpperCase() + first.substring(1), ...words.skip(1)]
      .join(' ');
}

/// The label for one call of [name] with [args].
CloudToolLabel cloudToolLabel(String name, Map<String, dynamic> args) {
  final path = _arg(args, const ['path', 'file_path', 'file', 'target']);
  final url = _arg(args, const ['url', 'href']);
  final query = _arg(args, const ['query', 'q', 'pattern']);
  final command = _arg(args, const ['command', 'cmd', 'code', 'script']);

  if (name == 'dispatch_agent') {
    final type = _arg(args, const ['agentType', 'subagent_type']) ??
        'Subagent';
    final prompt = _arg(args, const ['prompt', 'objective']) ?? '';
    return (
      title: type,
      summary: _oneLine(prompt),
      activity: 'Delegating to $type',
    );
  }
  if (name.startsWith('browser_')) {
    final action = name.substring('browser_'.length);
    if (url != null) {
      final host = hostOf(url);
      return (
        title: 'Browser',
        summary: host,
        activity: 'Navigating to $host',
      );
    }
    final target = _arg(args, const ['selector', 'text', 'ref', 'key']);
    final verb = switch (action) {
      'click' || 'tap_at' || 'double_click' => 'Clicking',
      'type' || 'fill' || 'press_key' => 'Typing',
      'scroll' || 'swipe' => 'Scrolling',
      'screenshot' || 'snapshot' => 'Looking at the page',
      'read' || 'outline' || 'find' => 'Reading the page',
      'back' => 'Going back',
      'forward' => 'Going forward',
      'reload' => 'Reloading the page',
      _ => _humanName(action),
    };
    return (
      title: 'Browser',
      summary: target == null ? _humanName(action) : _oneLine(target, 60),
      activity: target == null || verb.startsWith('Looking') ||
              verb.startsWith('Reading') || verb.startsWith('Go') ||
              verb.startsWith('Reload')
          ? verb
          : '$verb ${_oneLine(target, 40)}',
    );
  }
  switch (name) {
    case 'web_search':
      return (
        title: 'Web search',
        summary: _oneLine(query ?? ''),
        activity: query == null
            ? 'Searching the web'
            : 'Searching the web for "${_oneLine(query, 40)}"',
      );
    case 'fetch_url':
      final host = url == null ? '' : hostOf(url);
      return (
        title: 'Fetch',
        summary: url == null ? '' : _oneLine(url),
        activity: host.isEmpty ? 'Reading a web page' : 'Reading $host',
      );
    case 'file_write':
      return (
        title: 'Write',
        summary: path ?? '',
        activity: path == null ? 'Writing a file' : 'Writing $path',
      );
    case 'fs_edit' when args['command'] == 'view':
      return (
        title: 'Read',
        summary: path ?? '',
        activity: path == null ? 'Reading a file' : 'Reading $path',
      );
    case 'fs_edit':
    case 'multi_edit':
    case 'file_edit':
      return (
        title: 'Edit',
        summary: path ?? '',
        activity: path == null ? 'Editing a file' : 'Editing $path',
      );
    case 'fs_read':
    case 'file_read':
    case 'fs_view':
      return (
        title: 'Read',
        summary: path ?? '',
        activity: path == null ? 'Reading a file' : 'Reading $path',
      );
    case 'fs_grep':
    case 'fs_glob':
      return (
        title: name == 'fs_grep' ? 'Search files' : 'Find files',
        summary: _oneLine(query ?? path ?? ''),
        activity: 'Searching the workspace',
      );
    case 'run_shell':
    case 'job_start':
      return (
        title: 'Shell',
        summary: _oneLine(command ?? ''),
        activity: command == null
            ? 'Running a command'
            : 'Running ${_oneLine(command, 40)}',
      );
    case 'run_code':
      return (
        title: 'Run code',
        summary: _oneLine(command ?? ''),
        activity: 'Running code',
      );
    case 'todo_write':
      return (title: 'Todos', summary: '', activity: 'Updating the plan');
    case 'create_goal':
    case 'update_goal':
      return (
        title: 'Goal',
        summary: _oneLine(_arg(args, const ['objective', 'status']) ?? ''),
        activity: 'Updating the goal',
      );
    case 'memory_save':
      return (title: 'Memory', summary: '', activity: 'Saving to memory');
    case 'memory_search':
    case 'memory_read':
    case 'session_search':
      return (
        title: 'Recall',
        summary: _oneLine(query ?? ''),
        activity: 'Searching memory',
      );
    case 'git_clone':
    case 'git_pull':
    case 'git_push':
    case 'git_status':
    case 'git_diff':
    case 'git_log':
    case 'repo_sync':
    case 'repo_tree':
      return (
        title: 'Git',
        summary: _humanName(name.replaceFirst('git_', '')),
        activity: 'Working with the repository',
      );
    case 'exit_plan_mode':
      return (title: 'Plan', summary: '', activity: 'Presenting the plan');
    case 'skill':
      final skill = _arg(args, const ['name', 'skill']) ?? '';
      return (
        title: 'Skill',
        summary: skill,
        activity: skill.isEmpty ? 'Using a skill' : 'Using $skill',
      );
  }
  final human = _humanName(name);
  final detail = path ?? url ?? query ?? command ?? '';
  return (
    title: human,
    summary: _oneLine(detail),
    activity: 'Using $human',
  );
}
