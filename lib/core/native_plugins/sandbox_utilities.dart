import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// Part 1 (NP3) sandbox-backed capability: Shell History.
///
/// Sandbox access goes directly through [SandboxService.I.exec] behind the
/// injectable [SandboxRunner] typedef — one hop, honest errors, hermetic
/// unit tests via fake runners. Also home to the Git Workbench and
/// PDF Tools capabilities (NP3 Tasks 2–3).
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

/// Registers every sandbox-backed capability
/// (Shell History, Git Workbench, PDF Tools).
void registerSandboxUtilities() {
  NativePluginRegistry.I.register(ShellHistoryCapability());
  NativePluginRegistry.I.register(GitWorkbenchCapability());
  NativePluginRegistry.I.register(PdfToolsCapability());
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
        final message = (args['message']?.toString() ?? '').trim();
        if (message.isEmpty) {
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

// ---------------------------------------------------------------------------
// PDF Tools
// ---------------------------------------------------------------------------

/// PDF backend resolved per invocation: `pypdf` (python3) preferred,
// `qpdf` as fallback.
enum _PdfBackend { pypdf, qpdf }

class PdfToolsCapability implements NativePluginCapability {
  PdfToolsCapability({
    SandboxRunner? runner,
    bool Function()? isSandboxInstalled,
  })  : _runner = runner ?? defaultSandboxRunner,
        _isSandboxInstalled =
            isSandboxInstalled ?? (() => SandboxService.I.isInstalled);

  final SandboxRunner _runner;
  final bool Function() _isSandboxInstalled;

  static const _notInstalledMessage =
      'Sandbox is not installed — open Studio once to install it, then retry.';
  static const _noBackendMessage =
      'No PDF backend in the sandbox (needs python3+pypdf or qpdf) — install one, then retry.';
  static const _noExtractBackendMessage =
      'No PDF backend for extract_text in the sandbox (needs python3+pypdf or pdftotext) — install one, then retry.';

  /// Merges `sys.argv[1:-1]` (inputs) into `sys.argv[-1]` (output).
  static const _mergeScript =
      'import sys\n'
      'from pypdf import PdfMerger\n'
      'merger = PdfMerger()\n'
      'for path in sys.argv[1:-1]:\n'
      '    merger.append(path)\n'
      'merger.write(sys.argv[-1])\n'
      'merger.close()\n';

  /// Extracts one 1-based inclusive range into a new file.
  /// Args: input, start, end, output.
  static const _splitScript =
      'import sys\n'
      'from pypdf import PdfReader, PdfWriter\n'
      'src = sys.argv[1]\n'
      'start = int(sys.argv[2])\n'
      'end = int(sys.argv[3])\n'
      'dst = sys.argv[4]\n'
      'reader = PdfReader(src)\n'
      'writer = PdfWriter()\n'
      'for n in range(start - 1, end):\n'
      '    writer.add_page(reader.pages[n])\n'
      "with open(dst, 'wb') as f:\n"
      '    writer.write(f)\n';

  /// Re-writes the PDF with compressed content streams (best effort).
  /// Args: input, output.
  static const _compressScript =
      'import sys\n'
      'from pypdf import PdfReader, PdfWriter\n'
      'reader = PdfReader(sys.argv[1])\n'
      'writer = PdfWriter()\n'
      'for page in reader.pages:\n'
      '    writer.add_page(page)\n'
      'for page in writer.pages:\n'
      '    try:\n'
      '        page.compress_content_streams()\n'
      '    except Exception:\n'
      '        pass\n'
      "with open(sys.argv[2], 'wb') as f:\n"
      '    writer.write(f)\n';

  /// Prints page text plus a `{pages, chars}` stats line.
  /// Args: input, spec (`all` or a validated `N`/`N-M` comma list).
  static const _extractScript =
      'import sys\n'
      'from pypdf import PdfReader\n'
      'reader = PdfReader(sys.argv[1])\n'
      "spec = sys.argv[2] if len(sys.argv) > 2 else 'all'\n"
      'total = len(reader.pages)\n'
      'wanted = list(range(total)) if spec == \'all\' else []\n'
      "if spec != 'all':\n"
      "    for part in spec.split(','):\n"
      '        part = part.strip()\n'
      "        if '-' in part:\n"
      "            a, b = part.split('-', 1)\n"
      '            s, e = int(a), int(b)\n'
      '        else:\n'
      '            s = int(part)\n'
      '            e = s\n'
      '        for n in range(s - 1, e):\n'
      '            wanted.append(n)\n'
      'texts = []\n'
      'for n in wanted:\n'
      '    try:\n'
      "        texts.append(reader.pages[n].extract_text() or '')\n"
      '    except Exception as err:\n'
      "        texts.append('[page %d unreadable: %s]' % (n + 1, err))\n"
      "body = '\\n'.join(texts)\n"
      'print(body)\n'
      "print('{pages: %d, chars: %d}' % (len(wanted), len(body)))\n";

  /// Prints page count plus producer/title when readable. Args: input.
  static const _infoScript =
      'import sys\n'
      'from pypdf import PdfReader\n'
      'reader = PdfReader(sys.argv[1])\n'
      'meta = reader.metadata\n'
      "print('pages: %d' % len(reader.pages))\n"
      "print('producer: %s' % (meta.producer if meta and meta.producer else 'unknown'))\n"
      "print('title: %s' % (meta.title if meta and meta.title else 'unknown'))\n";

  @override
  String get pluginName => 'PDF Tools';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'merge',
          description: 'Merge two or more sandbox PDFs into one output PDF.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'inputs': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'output': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['inputs', 'output'],
          },
        ),
        NativePluginTool(
          name: 'split',
          description:
              'Split sandbox PDF pages into one output PDF per range.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
              'ranges': {'type': 'string'},
              'out_prefix': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['input', 'ranges'],
          },
        ),
        NativePluginTool(
          name: 'compress',
          description:
              'Re-write a sandbox PDF (best-effort size reduction) and report byte sizes.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
              'output': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['input', 'output'],
          },
        ),
        NativePluginTool(
          name: 'extract_text',
          description: 'Extract text from a sandbox PDF, optionally paged.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
              'pages': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['input'],
          },
        ),
        NativePluginTool(
          name: 'info',
          description:
              'Show page count, byte size, and producer/title of a sandbox PDF.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'input': {'type': 'string'},
              'timeout_seconds': {'type': 'integer'},
            },
            'required': ['input'],
          },
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async {
    if (!_isSandboxInstalled()) return _notInstalledMessage;
    switch (toolName) {
      case 'merge':
        {
          final backend = await _probeBackend();
          if (backend == null) return _noBackendMessage;
          final raw = args['inputs'];
          final inputs = raw is List
              ? [
                  for (final e in raw)
                    e.toString().trim(),
                ].where((s) => s.isNotEmpty).toList()
              : const <String>[];
          if (inputs.length < 2) {
            throw ArgumentError(
              'merge needs two or more input PDFs in "inputs".',
            );
          }
          final output = args['output']?.toString().trim() ?? '';
          if (output.isEmpty) {
            throw ArgumentError('Missing required argument: output');
          }
          final timeout = Duration(seconds: _timeoutSecs(args, 300));
          final String opOut;
          if (backend == _PdfBackend.pypdf) {
            opOut = await _runner(
              ['python3', '-c', _mergeScript, ...inputs, output],
              timeout: timeout,
            );
          } else {
            opOut = await _runner(
              ['qpdf', '--empty', '--pages', ...inputs, '--', output],
              timeout: timeout,
            );
          }
          if (_isExecFailure(opOut)) return _trimOutput(opOut);
          final summary =
              'Merged ${inputs.length} file(s) into $output via ${backend.name}.';
          return _trimOutput(
            opOut.trim().isEmpty ? summary : '$summary\n$opOut',
          );
        }
      case 'split':
        {
          final backend = await _probeBackend();
          if (backend == null) return _noBackendMessage;
          final input = args['input']?.toString().trim() ?? '';
          if (input.isEmpty) {
            throw ArgumentError('Missing required argument: input');
          }
          final ranges = _parsePageRanges(args['ranges']?.toString() ?? '');
          final prefixRaw = args['out_prefix']?.toString().trim() ?? '';
          final prefix =
              prefixRaw.isEmpty ? _defaultPrefix(input) : prefixRaw;
          final timeout = Duration(seconds: _timeoutSecs(args, 60));
          final outs = <String>[];
          final opOuts = <String>[];
          for (var i = 0; i < ranges.length; i++) {
            final (int start, int end) = ranges[i];
            final out = '$prefix-${i + 1}.pdf';
            final String opOut;
            if (backend == _PdfBackend.pypdf) {
              opOut = await _runner(
                ['python3', '-c', _splitScript, input, '$start', '$end', out],
                timeout: timeout,
              );
            } else {
              final range = start == end ? '$start' : '$start-$end';
              opOut = await _runner(
                ['qpdf', input, '--pages', input, range, '--', out],
                timeout: timeout,
              );
            }
            if (_isExecFailure(opOut)) return _trimOutput(opOut);
            if (opOut.trim().isNotEmpty) opOuts.add(opOut);
            outs.add(out);
          }
          final summary =
              'Wrote ${outs.length} file(s) via ${backend.name}: ${outs.join(', ')}.';
          final combined = opOuts.join('\n');
          return _trimOutput(
            combined.isEmpty ? summary : '$summary\n$combined',
          );
        }
      case 'compress':
        {
          final backend = await _probeBackend();
          if (backend == null) return _noBackendMessage;
          final input = args['input']?.toString().trim() ?? '';
          if (input.isEmpty) {
            throw ArgumentError('Missing required argument: input');
          }
          final output = args['output']?.toString().trim() ?? '';
          if (output.isEmpty) {
            throw ArgumentError('Missing required argument: output');
          }
          final timeout = Duration(seconds: _timeoutSecs(args, 300));
          final String opOut;
          if (backend == _PdfBackend.pypdf) {
            opOut = await _runner(
              ['python3', '-c', _compressScript, input, output],
              timeout: timeout,
            );
          } else {
            opOut = await _runner(
              [
                'qpdf',
                '--linearize',
                '--object-streams=generate',
                input,
                output,
              ],
              timeout: timeout,
            );
          }
          if (_isExecFailure(opOut)) return _trimOutput(opOut);
          final inBytes = await _fileSize(input);
          final outBytes = await _fileSize(output);
          final String detail;
          if (inBytes != null && outBytes != null) {
            detail = outBytes < inBytes
                ? 'saved ${inBytes - outBytes} bytes '
                    '(${(100 * (inBytes - outBytes) / inBytes).toStringAsFixed(1)}%).'
                : 'no size reduction.';
          } else {
            detail = 'size check unavailable.';
          }
          final summary =
              'Compressed $input → $output: ${inBytes ?? '?'} → ${outBytes ?? '?'} '
              'bytes ($detail) via ${backend.name}.';
          return _trimOutput(
            opOut.trim().isEmpty ? summary : '$summary\n$opOut',
          );
        }
      case 'extract_text':
        {
          final backend = await _probeBackend();
          if (backend == null) return _noBackendMessage;
          final input = args['input']?.toString().trim() ?? '';
          if (input.isEmpty) {
            throw ArgumentError('Missing required argument: input');
          }
          final pagesRaw = args['pages']?.toString().trim() ?? '';
          final timeout = Duration(seconds: _timeoutSecs(args, 60));
          if (backend == _PdfBackend.pypdf) {
            final spec = pagesRaw.isEmpty ? 'all' : pagesRaw;
            // Validates the syntax eagerly (FormatException on malformed).
            if (pagesRaw.isNotEmpty) _parsePageRanges(pagesRaw);
            final out = await _runner(
              ['python3', '-c', _extractScript, input, spec],
              timeout: timeout,
            );
            return _trimOutput(out);
          }
          final ranges =
              pagesRaw.isEmpty ? null : _parsePageRanges(pagesRaw);
          if (!await _hasPdftotext()) return _noExtractBackendMessage;
          if (ranges == null) {
            final out = await _runner(
              ['pdftotext', '-layout', input, '-'],
              timeout: timeout,
            );
            if (_isExecFailure(out)) return _trimOutput(out);
            final pages = out.isEmpty ? 0 : '\f'.allMatches(out).length + 1;
            return _trimOutput('$out\n{pages: $pages, chars: ${out.length}}');
          }
          final bodies = <String>[];
          var totalPages = 0;
          for (final (int start, int end) in ranges) {
            final out = await _runner(
              [
                'pdftotext',
                '-layout',
                '-f',
                '$start',
                '-l',
                '$end',
                input,
                '-',
              ],
              timeout: timeout,
            );
            if (_isExecFailure(out)) return _trimOutput(out);
            bodies.add(out);
            totalPages += end - start + 1;
          }
          final body = bodies.join('\n');
          return _trimOutput(
            '$body\n{pages: $totalPages, chars: ${body.length}}',
          );
        }
      case 'info':
        {
          final backend = await _probeBackend();
          if (backend == null) return _noBackendMessage;
          final input = args['input']?.toString().trim() ?? '';
          if (input.isEmpty) {
            throw ArgumentError('Missing required argument: input');
          }
          final timeout = Duration(seconds: _timeoutSecs(args, 60));
          final size = await _fileSize(input);
          final sizeLine =
              size == null ? 'size: unknown' : 'size: $size bytes';
          if (backend == _PdfBackend.pypdf) {
            final out = await _runner(
              ['python3', '-c', _infoScript, input],
              timeout: timeout,
            );
            if (_isExecFailure(out)) return _trimOutput(out);
            return _trimOutput('$input\n$sizeLine\n${out.trim()}');
          }
          final pagesOut = await _runner(
            ['qpdf', '--show-npages', input],
            timeout: timeout,
          );
          var metaLine = 'producer: unknown\ntitle: unknown';
          try {
            final dump = await _runner(
              [
                'bash',
                '-c',
                'qpdf --show-all-data ${_shQuote(input)} 2>/dev/null | '
                    'grep -a -m 10 -E "/(Title|Producer|Author|Creator)"',
              ],
              timeout: timeout,
            );
            final producer =
                RegExp(r'/Producer\s*\(([^)]*)\)').firstMatch(dump)?.group(1);
            final title =
                RegExp(r'/Title\s*\(([^)]*)\)').firstMatch(dump)?.group(1);
            metaLine =
                'producer: ${producer ?? 'unknown'}\ntitle: ${title ?? 'unknown'}';
          } catch (_) {
            // Best effort only — page count and size still stand.
          }
          return _trimOutput(
            '$input\n$sizeLine\npages: ${pagesOut.trim()}\n$metaLine',
          );
        }
      default:
        throw ArgumentError('Unknown tool: $toolName');
    }
  }

  /// Backend probe per invocation, preference order: pypdf first, then qpdf.
  /// A probe counts as ok only when the runner returns non-empty output with
  /// no exec `exit code` failure marker (real exec surfaces failures inline
  /// instead of throwing; fakes may throw — both mean "backend missing").
  Future<_PdfBackend?> _probeBackend() async {
    try {
      final py = await _runner([
        'bash',
        '-c',
        'command -v python3 && python3 -c "import pypdf"',
      ]);
      if (_probeOk(py)) return _PdfBackend.pypdf;
    } catch (_) {
      // Missing python3/pypdf — fall through to the qpdf probe.
    }
    try {
      final q = await _runner(['bash', '-c', 'command -v qpdf']);
      if (_probeOk(q)) return _PdfBackend.qpdf;
    } catch (_) {
      // Neither backend exists.
    }
    return null;
  }

  bool _probeOk(String out) =>
      out.trim().isNotEmpty && !out.contains('exit code');

  /// True when [out] carries the exec failure marker (`(exit code N)`).
  /// Real exec surfaces non-zero exits inline instead of throwing.
  bool _isExecFailure(String out) => out.contains('exit code');

  /// `pdftotext` (poppler) probe for the qpdf extract_text path. The qpdf
  /// probe never checked it, so a qpdf-only sandbox without poppler used to
  /// run `pdftotext`, then fabricate `{pages, chars}` stats from the
  /// exit-127 error text. Missing now returns an honest message instead.
  Future<bool> _hasPdftotext() async {
    try {
      final out = await _runner(['bash', '-c', 'command -v pdftotext']);
      return _probeOk(out);
    } catch (_) {
      return false;
    }
  }

  /// Parses a comma list of `N` / `N-M` 1-based page ranges. Endpoints use
  /// the tolerant int parsing convention; anything malformed (including
  /// `N < 1` and `M < N`) is a [FormatException].
  List<(int, int)> _parsePageRanges(String raw) {
    final out = <(int, int)>[];
    for (final chunk in raw.split(',')) {
      final part = chunk.trim();
      if (part.isEmpty) {
        throw FormatException(
          'Invalid page ranges "$raw": empty entry (expected "N" or "N-M").',
        );
      }
      if (part.contains('-')) {
        final ends = part.split('-');
        if (ends.length != 2) {
          throw FormatException(
            'Invalid page ranges "$raw": "$part" (expected "N" or "N-M").',
          );
        }
        final start = _parseIntArg(ends[0].trim(), 'range start', 0);
        final end = _parseIntArg(ends[1].trim(), 'range end', 0);
        if (start < 1 || end < 1) {
          throw FormatException(
            'Invalid page ranges "$raw": pages are 1-based.',
          );
        }
        if (end < start) {
          throw FormatException(
            'Invalid page ranges "$raw": end before start in "$part".',
          );
        }
        out.add((start, end));
      } else {
        final page = _parseIntArg(part, 'page', 0);
        if (page < 1) {
          throw FormatException(
            'Invalid page ranges "$raw": pages are 1-based.',
          );
        }
        out.add((page, page));
      }
    }
    if (out.isEmpty) {
      throw FormatException(
        'Invalid page ranges "$raw": no ranges given.',
      );
    }
    return out;
  }

  /// Default split prefix: the input path minus its extension
  /// (`doc.pdf` → `doc`), preserving any directory.
  String _defaultPrefix(String input) {
    final dot = input.lastIndexOf('.');
    final slash = input.lastIndexOf('/');
    if (dot > slash) return input.substring(0, dot);
    return input;
  }

  /// Honest byte size via `stat -c%s`, falling back to `wc -c` when stat
  /// fails; null when neither works (caller says so instead of guessing).
  Future<int?> _fileSize(String path) async {
    try {
      final out = await _runner(['stat', '-c%s', path]);
      final size = int.tryParse(out.trim());
      if (size != null) return size;
    } catch (_) {
      // Fall through to wc.
    }
    try {
      final out = await _runner(['bash', '-c', 'wc -c < ${_shQuote(path)}']);
      final size = int.tryParse(out.trim().split(RegExp(r'\s+')).first);
      if (size != null) return size;
    } catch (_) {
      // Unknown size — reported honestly by the caller.
    }
    return null;
  }

  /// Single-quote a path for `bash -c` (`'` → `'\''`).
  String _shQuote(String path) => "'${path.replaceAll("'", "'\\''")}'";

  int _timeoutSecs(Map<String, dynamic> args, int fallback) =>
      _parseIntArg(args['timeout_seconds'], 'timeout_seconds', fallback)
          .clamp(5, 600);
}
