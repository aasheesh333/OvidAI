import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// Part 1 (NP3) sandbox-backed capability: Shell History.
///
/// Sandbox access goes directly through [SandboxService.I.exec] behind the
/// injectable [SandboxRunner] typedef — one hop, honest errors, hermetic
/// unit tests via fake runners. Later NP3 tasks append Git Workbench and
/// PDF Tools to this file.
typedef SandboxRunner =
    Future<String> Function(
      List<String> args, {
      String? cwd,
      Duration? timeout,
    });

Future<String> defaultSandboxRunner(
  List<String> args, {
  String? cwd,
  Duration? timeout,
}) =>
    SandboxService.I.exec(
      args,
      cwd: cwd,
    ).timeout(timeout ?? const Duration(seconds: 60));

/// Registers every sandbox-backed capability (Shell History, Git Workbench).
void registerSandboxUtilities() {
  NativePluginRegistry.I.register(ShellHistoryCapability());
  NativePluginRegistry.I.register(GitWorkbenchCapability());
}

/// Tolerant integer parsing for LLM-supplied numeric args: accepts [num]
/// directly or a numeric [String] (e.g. `"10"`); anything else is a
/// user-input error ([FormatException], matching the NP2 convention).
int _parseIntArg(dynamic raw, String key, int fallback) {
  if (raw == null) return fallback;
  if (raw is num) return raw.toInt();
  final parsed = int.tryParse(raw.toString().trim());
  if (parsed == null) {
    throw FormatException('Invalid $key "$raw": expected an integer.');
  }
  return parsed;
}

/// Inline cap for a tool result handed to the model. Oversized output is
/// trimmed head+tail with the exact MCP omission notice.
String _trimOutput(String text) {
  const cap = 6000;
  if (text.length <= cap) return text;
  final head = text.substring(0, cap ~/ 2);
  final tail = text.substring(text.length - cap ~/ 2);
  final omitted = text.length - cap;
  return '$head\n\n[…$omitted characters omitted — ask again with a '
      'narrower query to see the middle…]\n\n$tail';
}

// ---------------------------------------------------------------------------
// Shell History
// ---------------------------------------------------------------------------

class ShellHistoryCapability implements NativePluginCapability {
  ShellHistoryCapability({
    SandboxRunner? runner,
    bool Function()? isSandboxInstalled,
  })  : _runner = runner ?? defaultSandboxRunner,
        _isSandboxInstalled =
            isSandboxInstalled ?? (() => SandboxService.I.isInstalled);

  final SandboxRunner _runner;
  final bool Function() _isSandboxInstalled;

  static const _notInstalledMessage =
      'Sandbox is not installed — open Studio once to install it, then retry.';
  static const _absentMessage = 'No shell history file found in the sandbox '
      'yet — run some commands in Studio terminal first.';

  @override
  String get pluginName => 'Shell History';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'search',
          description:
              'Search sandbox shell history (case-insensitive), newest first.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string'},
              'limit': {'type': 'integer'},
            },
            'required': ['query'],
          },
        ),
        NativePluginTool(
          name: 'recent',
          description: 'Show recent sandbox shell history, newest first.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'limit': {'type': 'integer'},
            },
            'required': [],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (!_isSandboxInstalled()) return _notInstalledMessage;
    switch (toolName) {
      case 'search':
        final query = args['query']?.toString() ?? '';
        if (query.trim().isEmpty) {
          throw ArgumentError('Missing required argument: query');
        }
        return _trimOutput(
          await _search(
            query,
            _parseIntArg(args['limit'], 'limit', 50).clamp(1, 500),
          ),
        );
      case 'recent':
        return _trimOutput(
          await _recent(
            _parseIntArg(args['limit'], 'limit', 20).clamp(1, 500),
          ),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  /// Resolves the history file: `$HISTFILE` when set and non-empty
  /// (probed via `echo $HISTFILE`), else `~/.bash_history`.
  Future<String> _historyFile() async {
    final probe =
        (await _runner(['bash', '-c', r'echo $HISTFILE'])).trim();
    return probe.isNotEmpty ? probe : '~/.bash_history';
  }

  /// Reads the newest 5000 lines of [file], oldest-first (tail order).
  /// Empty output means the file is absent or has no content yet.
  Future<List<String>> _readLines(String file) async {
    // Quote the path (history paths may contain spaces); pre-expand a
    // leading `~` to `$HOME` since tilde does not expand inside quotes.
    final arg = file.startsWith('~/') ? '\$HOME/${file.substring(2)}' : file;
    final out = await _runner(['bash', '-c', 'tail -n 5000 "$arg"']);
    if (out.trim().isEmpty) return const [];
    final lines = out.split('\n');
    // Real `tail` output ends with a newline, which `split` turns into a
    // trailing empty entry — drop those so `recent` never returns a
    // phantom blank line as the newest entry.
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines;
  }

  Future<String> _search(String query, int limit) async {
    final lines = await _readLines(await _historyFile());
    if (lines.isEmpty) return _absentMessage;
    final needle = query.toLowerCase();
    final matches = <String>[];
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].toLowerCase().contains(needle)) {
        matches.add(lines[i]);
        if (matches.length >= limit) break;
      }
    }
    if (matches.isEmpty) {
      return 'No matches for "$query" in recent shell history.';
    }
    return matches.join('\n');
  }

  Future<String> _recent(int limit) async {
    final lines = await _readLines(await _historyFile());
    if (lines.isEmpty) return _absentMessage;
    final out = <String>[];
    for (var i = lines.length - 1; i >= 0 && out.length < limit; i--) {
      out.add(lines[i]);
    }
    return out.join('\n');
  }
}

// ---------------------------------------------------------------------------
// Git Workbench
// ---------------------------------------------------------------------------

class GitWorkbenchCapability implements NativePluginCapability {
  GitWorkbenchCapability({
    SandboxRunner? runner,
    bool Function()? isSandboxInstalled,
  })  : _runner = runner ?? defaultSandboxRunner,
        _isSandboxInstalled =
            isSandboxInstalled ?? (() => SandboxService.I.isInstalled);

  final SandboxRunner _runner;
  final bool Function() _isSandboxInstalled;

  static const _notInstalledMessage =
      'Sandbox is not installed — open Studio once to install it, then retry.';

  @override
  String get pluginName => 'Git Workbench';

  @override
  List<NativePluginConfigField> get configFields => const [
        NativePluginConfigField(
          key: 'default_path',
          label: 'Default working directory',
          secret: false,
        ),
      ];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'status',
          description: 'Show working-tree status (short format with branch).',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': [],
          },
        ),
        NativePluginTool(
          name: 'log',
          description: 'Show recent commits, one line each.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'limit': {'type': 'integer'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': [],
          },
        ),
        NativePluginTool(
          name: 'branch',
          description:
              'List local and remote branches, marking the current one.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': [],
          },
        ),
        NativePluginTool(
          name: 'clone',
          description: 'Clone a git repository into the sandbox.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'url': {'type': 'string'},
              'path': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['url'],
          },
        ),
        NativePluginTool(
          name: 'commit',
          description: 'Stage all changes and commit with a message.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'message': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['message'],
          },
        ),
        NativePluginTool(
          name: 'push',
          description: 'Push commits to a remote.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'remote': {'type': 'string'},
              'branch': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': [],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) =>
      NativePluginConfigStore.I.save(
        pluginName: pluginName,
        fields: configFields,
        values: values,
      );

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (!_isSandboxInstalled()) return _notInstalledMessage;
    switch (toolName) {
      case 'status':
        final dir = await _resolveDir(args);
        return _trimOutput(
          await _runner(
            _withDir(dir, ['status', '--short', '--branch']),
            cwd: dir,
            timeout: Duration(seconds: _timeoutSecs(args, 60)),
          ),
        );
      case 'log':
        final dir = await _resolveDir(args);
        final limit = _parseIntArg(args['limit'], 'limit', 20).clamp(1, 200);
        return _trimOutput(
          await _runner(
            _withDir(dir, ['log', '--oneline', '-n', '$limit']),
            cwd: dir,
            timeout: Duration(seconds: _timeoutSecs(args, 60)),
          ),
        );
      case 'branch':
        final dir = await _resolveDir(args);
        final out = await _runner(
          _withDir(dir, ['branch', '-a']),
          cwd: dir,
          timeout: Duration(seconds: _timeoutSecs(args, 60)),
        );
        final current = _parseCurrentBranch(out);
        if (current == null) return _trimOutput(out);
        return _trimOutput('${out.trimRight()}\ncurrent: $current');
      case 'clone':
        final url = args['url']?.toString().trim() ?? '';
        if (url.isEmpty) {
          throw ArgumentError('Missing required argument: url');
        }
        final dest = args['path']?.toString().trim();
        return _trimOutput(
          await _runner(
            ['git', 'clone', url, if (dest != null && dest.isNotEmpty) dest],
            cwd: await _storedDefault(),
            timeout: Duration(seconds: _timeoutSecs(args, 300)),
          ),
        );
      case 'commit':
        final message = args['message']?.toString() ?? '';
        if (message.trim().isEmpty) {
          throw ArgumentError('Missing required argument: message');
        }
        final dir = await _resolveDir(args);
        final timeout = Duration(seconds: _timeoutSecs(args, 60));
        final addOut = await _runner(
          _withDir(dir, ['add', '-A']),
          cwd: dir,
          timeout: timeout,
        );
        final commitOut = await _runner(
          _withDir(dir, ['commit', '-m', message]),
          cwd: dir,
          timeout: timeout,
        );
        final combined = [addOut, commitOut]
            .where((s) => s.trim().isNotEmpty)
            .join('\n');
        return _trimOutput(combined);
      case 'push':
        final dir = await _resolveDir(args);
        final remote = args['remote']?.toString().trim();
        final remoteName =
            (remote == null || remote.isEmpty) ? 'origin' : remote;
        final branch = args['branch']?.toString().trim();
        return _trimOutput(
          await _runner(
            [
              ..._withDir(dir, ['push', remoteName]),
              if (branch != null && branch.isNotEmpty) branch,
            ],
            cwd: dir,
            timeout: Duration(seconds: _timeoutSecs(args, 300)),
          ),
        );
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  /// Working dir: explicit `path` arg wins, else the stored `default_path`
  /// pref, else null (exec defaults to the sandbox home).
  Future<String?> _resolveDir(Map<String, dynamic> args) async {
    final explicit = args['path']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    return _storedDefault();
  }

  Future<String?> _storedDefault() async {
    final stored = await NativePluginConfigStore.I.read(
      pluginName: pluginName,
      key: 'default_path',
    );
    final trimmed = stored?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Prefixes `git -C <dir>` when a working dir is resolved.
  List<String> _withDir(String? dir, List<String> rest) =>
      dir == null ? ['git', ...rest] : ['git', '-C', dir, ...rest];

  int _timeoutSecs(Map<String, dynamic> args, int fallback) =>
      _parseIntArg(args['timeout_seconds'], 'timeout_seconds', fallback)
          .clamp(5, 600);

  /// Parses the `* <name>` line of `git branch` output.
  String? _parseCurrentBranch(String output) {
    for (final line in output.split('\n')) {
      if (line.startsWith('* ')) {
        final rest = line.substring(2).trim();
        if (rest.isEmpty) return null;
        return rest.split(RegExp(r'\s+')).first;
      }
    }
    return null;
  }
}
