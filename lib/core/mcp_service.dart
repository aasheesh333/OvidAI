import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sandbox_service.dart';
import 'state.dart';

/// Real MCP client — spawns each server as a process inside the on-device
/// sandbox, speaks JSON-RPC 2.0 over stdin/stdout, discovers tools via
/// `tools/list`, and bridges `tools/call` for the agent.
///
/// Process model: one Process per connected server, started via
/// SandboxService.spawn — servers run inside the native sandbox env.
/// Lifecycle is lazy — `connect()` spawns + handshakes, `disconnect()` kills.
///
/// Reliability contract (matches the reference MCP client behavior):
///   • a JSON-RPC error response surfaces as a thrown/returned error, never
///     as a successful result;
///   • a timeout surfaces as an explicit error string, never the text "null";
///   • a server that dies drops out of the connected map immediately, so
///     nothing stays "connected" with a dead pipe;
///   • `notifications/tools/list_changed` triggers a silent re-discovery;
///   • tool results are capped so a chatty server can't flood the context.
class McpService {
  McpService._();
  static final McpService I = McpService._();

  final Map<String, _RunningServer> _running = {};

  /// Connected servers and the tools they advertise.
  Map<String, List<McpToolDef>> get connectedTools => {
    for (final e in _running.entries) e.key: e.value.tools,
  };

  bool isConnected(String serverName) => _running.containsKey(serverName);

  /// Inline cap for a tool result handed to the model. Oversized output is
  /// trimmed head+tail with an exact omission notice (spill-style).
  @visibleForTesting
  static const maxToolResultCharsForTest = _maxToolResultChars;
  static const _maxToolResultChars = 6000;

  @visibleForTesting
  static String trimResultForTest(String text) => _trimResult(text);

  static String _trimResult(String text) {
    if (text.length <= _maxToolResultChars) return text;
    final head = text.substring(0, _maxToolResultChars ~/ 2);
    final tail = text.substring(text.length - _maxToolResultChars ~/ 2);
    final omitted = text.length - _maxToolResultChars;
    return '$head\n\n[…$omitted characters omitted — ask again with a '
        'narrower query to see the middle…]\n\n$tail';
  }

  /// Spawn the server process and perform the MCP handshake
  /// (initialize → initialized → tools/list).
  ///
  /// Returns a human-readable status string for the UI.
  Future<String> connect(McpServer server) async {
    final existing = _running[server.name];
    if (existing != null) {
      // Someone else's connect may still be handshaking — don't spawn a
      // second process for the same server (double-spawn race).
      if (!existing.handshakeDone) return '"${server.name}" is connecting…';
      return '"${server.name}" is already connected';
    }
    // Reserve the slot BEFORE spawning so a rapid second connect sees it.
    final rs = _RunningServer(server: server);
    _running[server.name] = rs;
    try {
      // Spawn inside the native sandbox — servers are trusted code the
      // user explicitly connected, same trust level as DSH MCP defaults.
      final sandbox = SandboxService.I;
      if (!sandbox.isInstalled || sandbox.prefixPath == null) {
        throw Exception(
          'MCP servers need the sandbox. Open Studio once to initialize it '
          '(fast native setup), then retry. If the sandbox is already '
          'initialized, this is a bug — report it.',
        );
      }
      // Lazy runtime ensure: if the eager Node.js/Python install during
      // sandbox setup was skipped (offline) or failed, install on demand
      // now — the server command needs npx / uvx to exist.
      final cmd = server.command;
      final kind = (cmd == 'npx' || cmd == 'node')
          ? 'node'
          : (cmd == 'uvx' || cmd == 'uv' || cmd == 'python' || cmd == 'python3')
          ? 'python'
          : null;
      if (kind != null) {
        final ok = await sandbox.ensureRuntime(kind);
        if (!ok) {
          throw Exception(
            'runtime "$cmd" unavailable — install ${kind == 'node' ? 'nodejs+npm' : 'python+uv'} '
            'failed (offline?). Reconnect once you have internet.',
          );
        }
      }
      // Per-server env vars (API keys etc.) from secure storage.
      final env = await AppState.I.getMcpEnv(server.name);
      // Native exec — the server command runs through the sandbox env
      // (PATH/LD_LIBRARY_PATH/LD_PRELOAD set by SandboxService.spawn).
      final proc = await sandbox.spawn([
        server.command,
        ...server.args,
      ], env: env.isEmpty ? null : env);
      rs.process = proc;

      // Route stdout lines into the broadcast stream; drain stderr so it
      // never blocks the pipes (keep a tail for diagnostics).
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(rs.stdoutLines.add);
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(rs.stderrLines.add);

      // Server-death watcher: the moment the process exits, drop it from
      // the connected map. Without this, a crashed server stayed
      // "connected" until the next write to its dead stdin threw.
      unawaited(
        proc.exitCode.then((code) {
          if (identical(_running[server.name], rs)) {
            _running.remove(server.name);
            _lastDeath = (
              server: server.name,
              code: code,
              at: DateTime.now(),
            );
          }
        }),
      );

      // Server-initiated messages (no id) arrive on the same stream:
      // notifications/tools/list_changed → re-discover silently.
      // The notification listener lives exactly as long as the server does
      // (the stream is per-_RunningServer), so it needs no manual cancel.
      // ignore: unused_local_variable
      final notificationSub = rs.stdoutLines.stream.listen((line) {
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          if (j.containsKey('id')) return; // a response, not a notification
          final method = j['method'] as String?;
          if (method == 'notifications/tools/list_changed') {
            unawaited(_rediscoverTools(server.name));
          }
        } catch (_) {}
      });

      // ── MCP handshake ──────────────────────────────────────────────
      final initResult = await _rpc(rs, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
      });
      if (initResult.isError) {
        throw Exception('initialize failed: ${initResult.error}');
      }
      _sendNotification(rs, 'notifications/initialized', {});

      // ── Tool discovery ─────────────────────────────────────────────
      final toolsResult = await _rpc(rs, 'tools/list', {});
      if (toolsResult.isError) {
        throw Exception('tools/list failed: ${toolsResult.error}');
      }
      final payload = toolsResult.value;
      if (payload is Map<String, dynamic>) {
        rs.tools =
            (payload['tools'] as List?)
                ?.whereType<Map>()
                .map((t) => McpToolDef.fromJson(t.cast<String, dynamic>()))
                .toList() ??
            <McpToolDef>[];
      }
      rs.handshakeDone = true;
      return '"${server.name}" connected · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[server.name], rs)) _running.remove(server.name);
      try {
        rs.process?.kill();
      } catch (_) {}
      return 'connect failed: $e';
    }
  }

  /// Re-run tools/list after a server says its catalog changed.
  Future<void> _rediscoverTools(String serverName) async {
    final rs = _running[serverName];
    if (rs == null) return;
    final res = await _rpc(rs, 'tools/list', {});
    if (res.isError) return;
    final payload = res.value;
    if (payload is Map<String, dynamic>) {
      rs.tools =
          (payload['tools'] as List?)
              ?.whereType<Map>()
              .map((t) => McpToolDef.fromJson(t.cast<String, dynamic>()))
              .toList() ??
          rs.tools;
    }
  }

  /// Kill a server process. Safe to call when not connected.
  Future<void> disconnect(String serverName) async {
    final rs = _running.remove(serverName);
    if (rs == null) return;
    try {
      rs.process?.kill();
    } catch (_) {}
  }

  /// Call a tool on a connected server. Returns the text result.
  ///
  /// Server errors (JSON-RPC error, `isError: true`, timeout, dead process)
  /// come back as an explicit `MCP error: …` string so the model knows the
  /// call failed — they used to masquerade as results (or as the text
  /// "null").
  Future<String> callTool(
    String serverName,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final rs = _running[serverName];
    if (rs == null) {
      return 'MCP error: server "$serverName" is not connected'
          '${_lastDeathOf(serverName)}';
    }
    final res = await _rpc(rs, 'tools/call', {
      'name': toolName,
      'arguments': args,
    });
    if (res.isTimeout) {
      return 'MCP error: "$toolName" on "$serverName" timed out after '
          '$_rpcTimeoutSeconds s (server may be busy or dead).';
    }
    if (res.isError) {
      return 'MCP error: ${res.error}';
    }
    final payload = res.value;
    if (payload is Map<String, dynamic>) {
      final flagged = payload['isError'] as bool? ?? false;
      final content = payload['content'] as List?;
      if (content != null) {
        final parts = <String>[];
        for (final c in content) {
          if (c is! Map) continue;
          final type = c['type'];
          if (type == 'text') {
            final t = c['text'];
            if (t is String && t.trim().isNotEmpty) parts.add(t);
          } else if (type == 'resource') {
            final r = c['resource'];
            if (r is Map && r['text'] is String) {
              parts.add('[resource] ${r['text']}');
            }
          } else if (type == 'image') {
            // Images can't reach a text-only model context; note them so
            // the model knows something was produced.
            parts.add('[image content returned — not displayable here]');
          }
        }
        final text = parts.join('\n');
        if (flagged) return 'MCP error: ${_trimResult(text)}';
        return _trimResult(text);
      }
      return _trimResult(jsonEncode(payload));
    }
    if (payload == null) return 'MCP error: empty response';
    return _trimResult('$payload');
  }

  /// Tear everything down (app exit / settings reset).
  Future<void> disconnectAll() async {
    for (final name in _running.keys.toList()) {
      await disconnect(name);
    }
  }

  /// Last known death of a server (diagnostics for "not connected").
  ({String server, int code, DateTime at})? _lastDeath;
  String _lastDeathOf(String serverName) {
    final d = _lastDeath;
    if (d == null || d.server != serverName) return '';
    final hh = d.at.hour.toString().padLeft(2, '0');
    final mm = d.at.minute.toString().padLeft(2, '0');
    return ' (its process exited with code ${d.code} at $hh:$mm)';
  }

  /// Test seam: drive ONE `callTool` round-trip against canned server
  /// replies, exercising the real line-parse + result/error/timeout paths
  /// with no process, no sandbox, and a millisecond deadline.
  @visibleForTesting
  static Future<String> callToolForTest({
    required List<String> replies,
    String method = 'tools/call',
  }) async {
    final harness = _McpTestHarness(replies);
    final svc = McpService._();
    final rs = _RunningServer(
      server: McpServer(
        name: 'test-server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        args: const [],
      ),
    );
    rs.process = harness.process;
    svc._running['test-server'] = rs;
    // Deliver the canned replies the moment the request is written.
    unawaited(
      harness.requestWritten.then((_) {
        for (final line in replies) {
          rs.stdoutLines.add(line);
        }
      }),
    );
    try {
      return await svc.callTool('test-server', 'tool', {});
    } finally {
      await harness.dispose();
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  int _nextId = 1;

  /// RPC deadline. Tests shorten it so timeout paths run in milliseconds
  /// instead of the production 30 s.
  @visibleForTesting
  static int rpcTimeoutSecondsForTest = 30;
  static int get _rpcTimeoutSeconds => rpcTimeoutSecondsForTest;

  void _sendNotification(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) {
    final proc = rs.process;
    if (proc == null) return;
    proc.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
    );
  }

  /// Send a JSON-RPC request and await the matching response (id-correlated).
  ///
  /// A JSON-RPC **error** object is unwrapped into [McpRpcResult.error] —
  /// callers can never mistake it for a result. Timeouts are flagged via
  /// [McpRpcResult.isTimeout] instead of returning null.
  Future<McpRpcResult> _rpc(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) async {
    final proc = rs.process;
    if (proc == null) {
      return McpRpcResult._error('server process not running');
    }
    final id = _nextId++;

    // Line-split stdout; responses are single-line JSON.
    final lines = rs.stdoutLines;
    final completer = Completer<McpRpcResult>();
    late final StreamSubscription sub;
    sub = lines.stream.listen((line) {
      if (completer.isCompleted) return;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['id'] == id) {
          if (j.containsKey('error')) {
            final err = j['error'];
            completer.complete(
              McpRpcResult._error(
                err is Map
                    ? '${err['message'] ?? err['code'] ?? 'error'}'
                    : '$err',
              ),
            );
          } else {
            completer.complete(McpRpcResult._ok(j['result']));
          }
          sub.cancel();
        }
      } catch (_) {
        // Not JSON or not ours — ignore.
      }
    });

    proc.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );

    try {
      return await completer.future.timeout(
        Duration(seconds: _rpcTimeoutSeconds),
        onTimeout: () => McpRpcResult._timeout(),
      );
    } finally {
      await sub.cancel();
    }
  }
}

/// One JSON-RPC round-trip outcome: a result, an error, or a timeout.
/// [error] is non-null iff isError; [value] is the raw result payload.
class McpRpcResult {
  final dynamic value;
  final String? error;
  final bool isTimeout;
  const McpRpcResult._ok(this.value)
    : error = null,
      isTimeout = false;
  const McpRpcResult._error(String e)
    : value = null,
      error = e,
      isTimeout = false;
  const McpRpcResult._timeout()
    : value = null,
      error = null,
      isTimeout = true;
  bool get isError => error != null;
}

/// Tool definition advertised by an MCP server (from tools/list).
class McpToolDef {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  McpToolDef({required this.name, this.description, this.inputSchema});

  factory McpToolDef.fromJson(Map<String, dynamic> j) => McpToolDef(
    name: j['name'] as String? ?? '',
    description: j['description'] as String?,
    inputSchema: j['inputSchema'] as Map<String, dynamic>?,
  );

  /// Convert to an OpenAI function-tool schema for the agent loop.
  Map<String, dynamic> toOpenAiTool(String serverKey) => {
    'type': 'function',
    'function': {
      'name': 'mcp__${serverKey}__$name',
      'description': description ?? 'MCP tool $name',
      'parameters': inputSchema ?? {'type': 'object', 'properties': {}},
    },
  };
}

class _RunningServer {
  final McpServer server;
  Process? process;
  bool handshakeDone = false;
  List<McpToolDef> tools = [];
  final stdoutLines = _LineStream();
  final stderrLines = <String>[];

  _RunningServer({required this.server});
}

/// In-process Process stand-in for tests: a single request "write" on
/// stdin completes [requestWritten]; canned lines are then fed back through
/// the server's stdout stream. No process, no sandbox, no timing flake.
class _McpTestHarness {
  final _written = Completer<void>();
  Future<void> get requestWritten => _written.future;
  late final FakeMcpProcess process;

  _McpTestHarness(List<String> replies) {
    process = FakeMcpProcess(_written);
  }

  Future<void> dispose() async {}
}

/// The Process interface _rpc actually touches: stdin.writeln + exitCode.
class FakeMcpProcess implements Process {
  final Completer<void> _written;
  FakeMcpProcess(this._written);

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => _FakeStdinSink(_written);

  @override
  Future<int> get exitCode => Future.value(0);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('FakeMcpProcess: ${invocation.memberName}');
  }
}

class _FakeStdinSink implements IOSink {
  final Completer<void> _written;
  var _lines = 0;
  _FakeStdinSink(this._written);

  @override
  void writeln([Object? object = '']) {
    _lines++;
    if (_lines >= 1 && !_written.isCompleted) _written.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('_FakeStdinSink: ${invocation.memberName}');
  }
}

/// Broadcast stream of decoded stdout lines (multiple _rpc listeners can
/// subscribe concurrently; each request filters by id).
class _LineStream {
  final _controller = StreamController<String>.broadcast();
  Stream<String> get stream => _controller.stream;
  void add(String line) => _controller.add(line);
}
