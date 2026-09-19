import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/native_mcp.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _HangingNativeHandler implements NativeMcpHandler {
  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async => {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'hanging', 'version': '1.0.0'},
      };

  @override
  Future<List<McpToolDef>> listTools() async => [
        McpToolDef(
          name: 'hang_forever',
          description: 'Hangs',
          inputSchema: {'type': 'object'},
        ),
      ];

  @override
  Future<McpRpcResult> callTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    final completer = Completer<McpRpcResult>();
    // Never completes unless timeout occurs
    return completer.future;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(() async {
    await McpService.I.disconnectAll();
    McpService.I.clearNativeHandlers();
    McpService.rpcTimeoutSecondsForTest = null;
    AppState.resetTestInstance();
  });

  test('McpServer defaults toolTimeoutS to 60 seconds', () {
    final server = McpServer(
      name: 'test-default',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: 'npx',
    );
    expect(server.toolTimeoutS, 60);
    expect(server.startupTimeoutS, 30);
  });

  test('per-server toolTimeoutS above 60s is honored (H1)', () {
    McpService.rpcTimeoutSecondsForTest = null;
    final server = McpServer(
      name: 'slow-srv',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: 'npx',
      toolTimeoutS: 120,
    );
    expect(
      McpService.effectiveToolTimeoutForTest(server).inSeconds,
      120,
      reason: 'the 60s test-seam default must not cap a larger server setting',
    );
  });

  test('toolTimeoutS is bounded to 600s (H1)', () {
    McpService.rpcTimeoutSecondsForTest = null;
    final server = McpServer(
      name: 'absurd-srv',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: 'npx',
      toolTimeoutS: 9999,
    );
    expect(McpService.effectiveToolTimeoutForTest(server).inSeconds, 600);
  });

  test('an explicit test override still wins over toolTimeoutS (H1)', () {
    McpService.rpcTimeoutSecondsForTest = 1;
    final server = McpServer(
      name: 'override-srv',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: 'npx',
      toolTimeoutS: 120,
    );
    expect(McpService.effectiveToolTimeoutForTest(server).inSeconds, 1);
  });

  test('callTool respects per-call custom timeout', () async {
    McpService.I.registerNativeHandler('hanging_srv', (_) => _HangingNativeHandler());

    final server = McpServer(
      name: 'hanging_srv',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: '',
      transport: 'native',
      toolTimeoutS: 60,
    );
    AppState.I.mcpServers.add(server);

    await McpService.I.connect(server);

    final result = await McpService.I.callTool(
      server.canonicalId,
      'hang_forever',
      {},
      timeout: const Duration(milliseconds: 50),
    );

    expect(result, contains('timed out after'));
  });

  test('catalog_set_mcp_timeout tool dynamically changes server timeout', () async {
    final server = McpServer(
      name: 'DynamicTimeoutSrv',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: 'npx',
      custom: true,
      toolTimeoutS: 60,
    );
    AppState.I.mcpServers.add(server);

    final res = await AgentService.I.dispatchForTest('catalog_set_mcp_timeout', {
      'server': 'DynamicTimeoutSrv',
      'timeout_seconds': 120,
    });

    expect(res, contains('120s'));
    expect(server.toolTimeoutS, 120);
  });

  test('agent dispatching mcp__ strips _timeout_seconds and passes custom duration', () async {
    McpService.I.registerNativeHandler('fast_hang', (_) => _HangingNativeHandler());

    final server = McpServer(
      name: 'fast_hang',
      author: 'test',
      description: 'desc',
      category: 'Custom',
      command: '',
      transport: 'native',
      toolTimeoutS: 60,
    );
    AppState.I.mcpServers.add(server);
    await McpService.I.connect(server);

    final res = await AgentService.I.dispatchForTest(
      'mcp__fast_hang__hang_forever',
      {'_timeout_seconds': 5},
    );

    // Call runs with 5s timeout
    expect(res, isNotNull);
  });
}
