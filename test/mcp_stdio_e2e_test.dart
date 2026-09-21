import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

/// REAL subprocess MCP E2E: drives Ovid's actual stdio transport —
/// spawn → initialize → notifications/initialized → tools/list →
/// tools/call → disconnect — against a real python3 MCP server process.
///
/// The Android sandbox doesn't exist on host CI, so the test injects
/// [McpService.spawnProcessForTest] to spawn directly on the host. Every
/// byte of JSON-RPC framing, the handshake, tool discovery, the tool-call
/// result/error mapping, and disconnect is Ovid's production code — only
/// the process spawn itself is substituted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Minimal MCP server: newline-delimited JSON-RPC over stdio, exactly
  // what Ovid's `_connectStdio` handshake expects.
  const serverScript = r'''
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    mid = msg.get("id")
    if mid is None:
        continue  # notification — no reply
    method = msg.get("method", "")
    params = msg.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "ovid-e2e", "version": "1.0.0"},
        }})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [
            {"name": "echo", "description": "Echoes text back",
             "inputSchema": {"type": "object",
                             "properties": {"text": {"type": "string"}}}},
            {"name": "boom", "description": "Always fails",
             "inputSchema": {"type": "object"}},
        ]}})
    elif method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name == "echo":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "content": [{"type": "text",
                             "text": "echo:" + str(args.get("text", ""))}],
                "isError": False}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {
                "code": -32603, "message": "boom failed intentionally"}})
''';

  test('stdio lifecycle against a real MCP server process', () async {
    final dir = await Directory.systemTemp.createTemp('ovid-mcp-e2e');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/mcp_server.py');
    await script.writeAsString(serverScript);

    McpService.spawnProcessForTest =
        (
          List<String> argv, {
          Map<String, String>? env,
          Directory? hostWorkDir,
        }) => Process.start(
          argv.first,
          argv.sublist(1),
          environment: {...Platform.environment, ...?env},
          workingDirectory: hostWorkDir?.path,
        );
    addTearDown(() => McpService.spawnProcessForTest = null);

    final server = McpServer(
      name: 'ovid-e2e-stdio',
      author: 'test',
      description: 'Real-subprocess MCP E2E server',
      category: 'Custom',
      transport: 'stdio',
      command: 'python3',
      args: [script.path],
    );
    addTearDown(() => McpService.I.disconnect('ovid-e2e-stdio'));

    // 1. connect: spawn + initialize + notifications/initialized + tools/list
    final status = await McpService.I.connect(server);
    expect(status, contains('connected'));
    expect(status, contains('2 tools'));
    expect(McpService.I.isConnected('ovid-e2e-stdio'), isTrue);

    // 2. protocol version + capabilities captured from the initialize result
    expect(McpService.I.protocolVersionForTest('ovid-e2e-stdio'), '2024-11-05');
    expect(
      McpService.I.capabilitiesForTest('ovid-e2e-stdio')['tools'],
      isNotNull,
    );

    // 3. a successful tool call round-trips arguments and text content
    final echo = await McpService.I.callTool('ovid-e2e-stdio', 'echo', {
      'text': 'hello-mcp',
    });
    expect(echo, contains('echo:hello-mcp'));

    // 4. a server-side tool error surfaces as an MCP error, not a throw
    final boom = await McpService.I.callTool('ovid-e2e-stdio', 'boom', {});
    expect(boom, contains('MCP error'));
    expect(boom, contains('boom failed intentionally'));

    // 5. disconnect kills the process and drops the session
    await McpService.I.disconnect('ovid-e2e-stdio');
    expect(McpService.I.isConnected('ovid-e2e-stdio'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
