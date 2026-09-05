import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'sandbox_service.dart';
import 'state.dart';

/// Real MCP client — connects to each server over its configured
/// transport (stdio: spawn inside the sandbox and speak JSON-RPC over
/// stdin/stdout; http: POST JSON-RPC to a Streamable-HTTP endpoint, no
/// sandbox needed), discovers tools via `tools/list`, and bridges
/// `tools/call` for the agent.
///
/// Process model (stdio): one Process per connected server, started via
/// SandboxService.spawn — servers run inside the native sandbox env.
/// Lifecycle is lazy — `connect()` spawns/dials + handshakes, `disconnect()`
/// kills/drops.
///
/// Reliability contract (matches the reference MCP client behavior):
///   • a JSON-RPC error response surfaces as a thrown/returned error, never
///     as a successful result;
///   • a timeout surfaces as an explicit error string, never the text "null";
///   • a server that dies drops out of the connected map immediately, so
///     nothing stays "connected" with a dead pipe;
///   • `notifications/tools/list_changed` triggers a silent re-discovery
///     (stdio only — an HTTP server has no persistent notification channel
///     in the Streamable-HTTP request/response model Ovid uses);
///   • tool results are capped so a chatty server can't flood the context;
///   • PR41: an UNEXPECTED disconnect (stdio process death, or an HTTP call
///     failing with a connection-level error) schedules automatic
///     reconnection with exponential backoff — `ovid-mcp-client` parity
///     (500ms → 30s, giving up after 10 consecutive failures). A
///     user-initiated `disconnect()` never triggers this.
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

  /// Test seam: replace the HTTP client used by the 'http' transport.
  @visibleForTesting
  http.Client? httpClientForTest;

  /// Test seam: reconnect backoff timing, shortened so tests run in
  /// milliseconds instead of real seconds.
  @visibleForTesting
  static Duration reconnectInitialDelayForTest = const Duration(
    milliseconds: 500,
  );
  @visibleForTesting
  static Duration reconnectMaxDelayForTest = const Duration(seconds: 30);
  @visibleForTesting
  static int reconnectMaxAttemptsForTest = 10;

  /// Spawn/dial the server and perform the MCP handshake
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
    if (server.transport == 'http') {
      return _connectHttp(server, rs);
    }
    return _connectStdio(server, rs);
  }

  /// PR41: Streamable-HTTP transport — no process, no sandbox. Every
  /// JSON-RPC call is its own HTTP POST to [McpServer.url]; the handshake
  /// is the same three calls (initialize/initialized/tools/list) as stdio,
  /// just carried over HTTP instead of stdin/stdout.
  Future<String> _connectHttp(McpServer server, _RunningServer rs) async {
    try {
      final url = server.url;
      if (url == null || url.isEmpty) {
        throw Exception('no url configured for HTTP transport');
      }
      final initResult = await _rpcHttp(rs, 'initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
      });
      if (initResult.isError) {
        throw Exception('initialize failed: ${initResult.error}');
      }
      await _sendNotificationHttp(rs, 'notifications/initialized', {});
      final toolsResult = await _rpcHttp(rs, 'tools/list', {});
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
      _reconnectAttempts.remove(server.name);
      return '"${server.name}" connected (http) · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[server.name], rs)) _running.remove(server.name);
      return 'connect failed: $e';
    }
  }

  Future<String> _connectStdio(McpServer server, _RunningServer rs) async {
    try {
      // Spawn inside the native sandbox — servers are trusted code the
      // user explicitly connected, same trust level as MCP defaults.
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
      // PR41: a death the user didn't ask for (disconnect() sets
      // rs.userDisconnected first) schedules automatic reconnection with
      // backoff instead of just vanishing — ovid-mcp-client parity.
      unawaited(
        proc.exitCode.then((code) {
          if (identical(_running[server.name], rs)) {
            _running.remove(server.name);
            _lastDeath = (
              server: server.name,
              code: code,
              at: DateTime.now(),
            );
            if (!rs.userDisconnected) _scheduleReconnect(server);
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
      _reconnectAttempts.remove(server.name);
      return '"${server.name}" connected · ${rs.tools.length} tools';
    } catch (e) {
      if (identical(_running[server.name], rs)) _running.remove(server.name);
      try {
        rs.process?.kill();
      } catch (_) {}
      return 'connect failed: $e';
    }
  }

  /// PR41: reconnect backoff timers, one per server name so a repeated
  /// crash doesn't stack multiple pending retries.
  final Map<String, Timer> _reconnectTimers = {};

  /// Consecutive failed reconnect attempts per server name. Lives on the
  /// service (not on the per-connect `_RunningServer`, which is recreated
  /// fresh every `connect()` call) so backoff keeps doubling across
  /// repeated failures instead of resetting to attempt 1 each time. Reset
  /// to 0 on any successful handshake.
  final Map<String, int> _reconnectAttempts = {};

  /// Schedule an automatic reconnect for [server] after an UNEXPECTED
  /// disconnect (never called after a user-initiated `disconnect()`).
  /// Delay doubles from [reconnectInitialDelayForTest] up to
  /// [reconnectMaxDelayForTest]; gives up silently after
  /// [reconnectMaxAttemptsForTest] consecutive failures (the server stays
  /// listed but disconnected — the user can retry manually, same as
  /// today's behavior before this feature existed).
  void _scheduleReconnect(McpServer server) {
    _reconnectTimers.remove(server.name)?.cancel();
    final attempt = (_reconnectAttempts[server.name] ?? 0) + 1;
    if (attempt > reconnectMaxAttemptsForTest) return;
    final initialMs = reconnectInitialDelayForTest.inMilliseconds;
    final maxMs = reconnectMaxDelayForTest.inMilliseconds;
    final delayMs = (initialMs * (1 << (attempt - 1))).clamp(initialMs, maxMs);
    _reconnectAttempts[server.name] = attempt;
    _reconnectTimers[server.name] = Timer(
      Duration(milliseconds: delayMs),
      () {
        _reconnectTimers.remove(server.name);
        // The user may have manually reconnected (or removed the server)
        // while this timer was pending — never race a live connection.
        if (_running.containsKey(server.name)) return;
        if (!AppState.I.mcpServers.contains(server)) return;
        unawaited(connect(server));
      },
    );
  }

  /// Test seam: how many reconnect attempts have been recorded for
  /// [serverName] (0 if none).
  @visibleForTesting
  int reconnectAttemptsForTest(String serverName) =>
      _reconnectAttempts[serverName] ?? 0;

  /// Test seam: is a reconnect currently scheduled for [serverName]?
  @visibleForTesting
  bool hasPendingReconnectForTest(String serverName) =>
      _reconnectTimers.containsKey(serverName);

  /// Cancel any pending reconnect for [serverName] (used by [disconnect]
  /// and available to tests for teardown).
  void _cancelReconnect(String serverName) {
    _reconnectTimers.remove(serverName)?.cancel();
    _reconnectAttempts.remove(serverName);
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
    _cancelReconnect(serverName);
    if (rs == null) return;
    rs.userDisconnected = true;
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
    final res = rs.server.transport == 'http'
        ? await _rpcHttp(rs, 'tools/call', {
            'name': toolName,
            'arguments': args,
          })
        : await _rpc(rs, 'tools/call', {
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

  /// PR41: Streamable-HTTP JSON-RPC notification — a POST that carries no
  /// `id`. Best-effort: a server may legitimately respond 202/204 with no
  /// body, or ignore the initialized notification entirely (optional per
  /// the MCP spec).
  Future<void> _sendNotificationHttp(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) async {
    final url = rs.server.url;
    if (url == null) return;
    try {
      final client = httpClientForTest ?? http.Client();
      await client
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              ...rs.server.headers,
            },
            body: jsonEncode({
              'jsonrpc': '2.0',
              'method': method,
              'params': params,
            }),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      // Notifications are fire-and-forget by design.
    }
  }

  /// PR41: Streamable-HTTP JSON-RPC request/response — one POST per call,
  /// same [McpRpcResult] contract as the stdio [_rpc] so every downstream
  /// consumer (callTool's content parsing, timeout/error surfacing) is
  /// transport-agnostic. A connection-level failure (can't reach the
  /// server at all — DNS, refused, timeout) is treated exactly like a
  /// stdio process death: the server drops out of `_running` and an
  /// automatic reconnect is scheduled (unless the user disconnected).
  Future<McpRpcResult> _rpcHttp(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) async {
    final url = rs.server.url;
    if (url == null) {
      return McpRpcResult._error('no url configured');
    }
    final id = _nextId++;
    try {
      final client = httpClientForTest ?? http.Client();
      final res = await client
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json, text/event-stream',
              ...rs.server.headers,
            },
            body: jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'method': method,
              'params': params,
            }),
          )
          .timeout(Duration(seconds: _rpcTimeoutSeconds));
      // A single-object JSON response is the common case; a
      // "text/event-stream" response carries one or more `data: {...}`
      // lines — take the LAST one, which per the spec is the final
      // response for this request (earlier lines are notifications).
      final contentType = res.headers['content-type'] ?? '';
      Map<String, dynamic>? j;
      if (contentType.contains('text/event-stream')) {
        final dataLines = res.body
            .split('\n')
            .where((l) => l.startsWith('data:'))
            .map((l) => l.substring(5).trim())
            .where((l) => l.isNotEmpty)
            .toList();
        for (final line in dataLines.reversed) {
          try {
            final decoded = jsonDecode(line) as Map<String, dynamic>;
            if (decoded['id'] == id) {
              j = decoded;
              break;
            }
          } catch (_) {}
        }
      } else if (res.body.trim().isNotEmpty) {
        try {
          j = jsonDecode(res.body) as Map<String, dynamic>;
        } catch (_) {}
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        // The server responded (just not successfully) — it's still up,
        // so this is a per-call error, not a connection failure. A
        // non-2xx with a JSON-RPC error body still carries a useful
        // message; fall back to the raw status when it doesn't.
        final msg = j?['error'] is Map
            ? '${(j!['error'] as Map)['message'] ?? res.statusCode}'
            : 'HTTP ${res.statusCode}';
        return McpRpcResult._error(msg);
      }
      if (j == null) return McpRpcResult._error('empty or unparsable response');
      if (j.containsKey('error')) {
        final err = j['error'];
        return McpRpcResult._error(
          err is Map ? '${err['message'] ?? err['code'] ?? 'error'}' : '$err',
        );
      }
      return McpRpcResult._ok(j['result']);
    } on TimeoutException {
      return const McpRpcResult._timeout();
    } catch (e) {
      // Connection-level failure (refused, DNS, socket) — the server is
      // effectively down; drop it and schedule a reconnect exactly like
      // an unexpected stdio process death.
      _markHttpFailure(rs);
      return McpRpcResult._error('$e');
    }
  }

  /// An HTTP server has no process to watch for death, so a connection-
  /// level failure on any call is this transport's equivalent signal:
  /// drop it from `_running` and schedule automatic reconnection (unless
  /// the user explicitly disconnected it). Only fires for a server that
  /// was actually UP (`handshakeDone`) — a failure during the initial
  /// handshake is an ordinary failed `connect()`, not something to
  /// "recover" from; `_connectHttp`'s own catch handles that case.
  void _markHttpFailure(_RunningServer rs) {
    if (!rs.handshakeDone) return;
    final name = rs.server.name;
    if (!identical(_running[name], rs)) return; // already superseded
    _running.remove(name);
    _lastDeath = (server: name, code: -1, at: DateTime.now());
    if (!rs.userDisconnected) _scheduleReconnect(rs.server);
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

  /// PR41: set by [McpService.disconnect] BEFORE killing the process, so
  /// the death watcher can tell a user-initiated disconnect apart from an
  /// unexpected crash — only the latter schedules automatic reconnection.
  bool userDisconnected = false;

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
