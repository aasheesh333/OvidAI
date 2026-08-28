import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sandbox_service.dart';
import 'state.dart';

/// Real MCP client — spawns each server as a process inside the on-device
/// sandbox, speaks JSON-RPC 2.0 over stdin/stdout, discovers tools via
/// `tools/list`, and bridges `tools/call` for the agent.
///
/// Process model: one Process per connected server, started via
/// SandboxService.exec-style proot spawn so servers run in the Ubuntu jail.
/// Lifecycle is lazy — `connect()` spawns + handshakes, `disconnect()` kills.
class McpService {
  McpService._();
  static final McpService I = McpService._();

  final Map<String, _RunningServer> _running = {};

  /// Connected servers and the tools they advertise.
  Map<String, List<McpToolDef>> get connectedTools => {
        for (final e in _running.entries)
          e.key: e.value.tools,
      };

  bool isConnected(String serverName) => _running.containsKey(serverName);

  /// Spawn the server process and perform the MCP handshake
  /// (initialize → initialized → tools/list).
  ///
  /// Returns a human-readable status string for the UI.
  Future<String> connect(McpServer server) async {
    if (_running.containsKey(server.name)) {
      return '"${server.name}" is already connected';
    }

    final rs = _RunningServer(server: server);
    try {
      // Spawn inside the sandbox proot jail — servers are trusted code the
      // user explicitly connected, same trust level as DSH MCP defaults.
      final sandbox = SandboxService.I;
      if (!sandbox.isInstalled || sandbox.prootPath == null) {
        throw Exception(
          'sandbox not installed — open Studio once to install it',
        );
      }
      final proc = await Process.start(
        sandbox.prootPath!,
        _prootArgs(server),
      );
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

      // ── MCP handshake ──────────────────────────────────────────────
      final initResult = await _rpc(
        rs,
        'initialize',
        {
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'clientInfo': {'name': 'ovid-ai', 'version': '1.0.0'},
        },
      );
      if (initResult == null) {
        throw Exception('initialize handshake failed (no response)');
      }
      _sendNotification(rs, 'notifications/initialized', {});

      // ── Tool discovery ─────────────────────────────────────────────
      final toolsResult = await _rpc(rs, 'tools/list', {});
      if (toolsResult is Map<String, dynamic>) {
        final tools = (toolsResult['tools'] as List?)
                ?.whereType<Map>()
                .map((t) => McpToolDef.fromJson(t.cast<String, dynamic>()))
                .toList() ??
            <McpToolDef>[];
        rs.tools = tools;
      }

      _running[server.name] = rs;
      return '"${server.name}" connected · ${rs.tools.length} tools';
    } catch (e) {
      try {
        rs.process?.kill();
      } catch (_) {}
      return 'connect failed: $e';
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
  Future<String> callTool(
    String serverName,
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final rs = _running[serverName];
    if (rs == null) return 'MCP server "$serverName" is not connected';
    final result = await _rpc(rs, 'tools/call', {
      'name': toolName,
      'arguments': args,
    });
    if (result is Map<String, dynamic>) {
      final content = result['content'] as List?;
      if (content != null) {
        final text = content
            .whereType<Map>()
            .map((c) => c['text'])
            .whereType<String>()
            .join('\n');
        return text;
      }
      return jsonEncode(result);
    }
    return '$result';
  }

  /// Tear everything down (app exit / settings reset).
  Future<void> disconnectAll() async {
    for (final name in _running.keys.toList()) {
      await disconnect(name);
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  List<String> _prootArgs(McpServer server) {
    // Spawn inside the sandbox proot jail — servers are trusted code the
    // user explicitly connected, same trust level as DSH MCP defaults.
    final sandbox = SandboxService.I;
    if (!sandbox.isInstalled) {
      throw Exception(
        'sandbox not installed — install it from Studio first',
      );
    }
    return [
      '-r', sandbox.rootfs!.path,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '/sdcard',
      server.command,
      ...server.args,
    ];
  }

  int _nextId = 1;

  void _sendNotification(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) {
    final proc = rs.process;
    if (proc == null) return;
    proc.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    }));
  }

  /// Send a JSON-RPC request and await the matching response (id-correlated).
  /// 15s deadline; null on timeout/parse failure.
  Future<dynamic> _rpc(
    _RunningServer rs,
    String method,
    Map<String, dynamic> params,
  ) async {
    final proc = rs.process;
    if (proc == null) return null;
    final id = _nextId++;

    // Line-split stdout; responses are single-line JSON.
    final lines = rs.stdoutLines;
    final completer = Completer<dynamic>();
    late final StreamSubscription sub;
    sub = lines.stream.listen((line) {
      if (completer.isCompleted) return;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['id'] == id) {
          completer.complete(j['result'] ?? j['error']);
          sub.cancel();
        }
      } catch (_) {
        // Not JSON or not ours — ignore.
      }
    });

    proc.stdin.writeln(jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));

    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }
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
  List<McpToolDef> tools = [];
  final stdoutLines = _LineStream();
  final stderrLines = <String>[];

  _RunningServer({required this.server});
}

/// Broadcast stream of decoded stdout lines (multiple _rpc listeners can
/// subscribe concurrently; each request filters by id).
class _LineStream {
  final _controller = StreamController<String>.broadcast();
  Stream<String> get stream => _controller.stream;
  void add(String line) => _controller.add(line);
}
