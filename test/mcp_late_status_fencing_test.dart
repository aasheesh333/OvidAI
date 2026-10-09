import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Late transport callbacks (stdio exit, HTTP failure, reconnect success)
/// must only publish status for the account / AppState / row / plugin owner
/// that started the connection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = McpService.I;
  const pluginId = 'acme/late-fence-probe';

  http.Response ok(http.Request request) {
    final body = jsonDecode(request.body) as Map;
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': body['id'],
        'result': body['method'] == 'tools/list'
            ? {
                'tools': [
                  {'name': 'echo'},
                ],
              }
            : {},
      }),
      200,
    );
  }

  McpServer pluginServer() => McpServer(
    name: 'remote',
    author: 'test',
    description: '',
    category: 'Custom',
    command: '',
    transport: 'http',
    url: 'https://late.test/mcp',
    ownerPluginId: pluginId,
  );

  void registerPlugin() {
    PluginContributionRegistry.I.register(
      NormalizedPluginManifest(
        id: pluginId,
        name: 'late-fence-probe',
        version: '1.0.0',
        format: PluginFormat.claudeCode,
        rootPath: '/plugins/late',
      ),
      activation: PluginActivation.sessionActive,
      immediateSessionId: 's1',
    );
  }

  final cleanup = <String>[];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    svc.httpClientForTest = MockClient((r) async => ok(r));
  });
  tearDown(() async {
    for (final id in cleanup) {
      await svc.disconnect(id);
    }
    cleanup.clear();
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    svc.httpClientForTest = null;
    McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 500);
    McpService.reconnectMaxAttemptsForTest = 10;
    AppState.resetTestInstance();
  });

  test('late stdio exit after an account transition publishes nothing to '
      'the new account', () async {
    final server = McpServer(
      name: 'late-stdio',
      author: 'test',
      description: '',
      category: 'Custom',
      command: 'python3',
    );
    cleanup.add(server.canonicalId);
    AppState.I.mcpServers.add(server);
    final process = await Process.start('python3', [
      '-c',
      'import time; time.sleep(30)',
    ]);
    addTearDown(() => process.kill());
    server.connected = true;
    await svc.attachStdioForTest(server, process);

    final transition = AppState.I.transitionSessionAccount('firebase:B');
    // Background hydration needs path_provider; only the synchronous token
    // swap matters here. Swallow the transition's eventual error the
    // moment it starts — attaching the handler later lets the failure
    // surface as an unhandled async error and fail the test.
    unawaited(transition.catchError((Object _) {}));
    AppState.I.serviceStatus.remove('mcp:${server.canonicalId}');

    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(
      AppState.I.serviceStatusForTest('mcp:${server.canonicalId}'),
      isNull,
      reason: 'account A server must not publish into account B',
    );
    expect(server.connected, isTrue, reason: 'old row must not be mutated');
    expect(svc.hasPendingReconnectForTest(server.canonicalId), isFalse);
  });

  test('late HTTP failure after an account transition publishes nothing',
      () async {
    registerPlugin();
    final server = pluginServer();
    cleanup.add(server.canonicalId);
    AppState.I.mcpServers.add(server);
    await svc.connect(server);
    expect(server.connected, isTrue);

    final transition = AppState.I.transitionSessionAccount('firebase:B');
    // Same as the stdio test above: swallow the hydration failure eagerly.
    unawaited(transition.catchError((Object _) {}));
    AppState.I.serviceStatus.remove('mcp:${server.canonicalId}');
    svc.httpClientForTest = MockClient(
      (_) async => throw const SocketException('down'),
    );
    await svc.callTool(server.canonicalId, 'echo', {});
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(AppState.I.serviceStatusForTest('mcp:${server.canonicalId}'),
        isNull);
    expect(server.connected, isTrue);
    expect(svc.hasPendingReconnectForTest(server.canonicalId), isFalse);
  });

  test('plugin removed during an in-flight reconnect: late success does not '
      'resurrect the row', () async {
    McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 5);
    registerPlugin();
    final server = pluginServer();
    cleanup.add(server.canonicalId);
    AppState.I.mcpServers.add(server);
    await svc.connect(server);
    expect(server.connected, isTrue);

    final entered = Completer<void>();
    final release = Completer<void>();
    var down = true;
    svc.httpClientForTest = MockClient((request) async {
      if (down) throw const SocketException('down');
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'initialize' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      return ok(request);
    });
    await svc.callTool(server.canonicalId, 'echo', {});
    expect(server.connected, isFalse);
    down = false;
    await entered.future.timeout(const Duration(seconds: 2));

    // Owner goes away while the reconnect handshake is in flight.
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    AppState.I.mcpServers.remove(server);
    AppState.I.serviceStatus.remove('mcp:${server.canonicalId}');
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(AppState.I.mcpServers, isNot(contains(server)));
    expect(server.connected, isFalse);
    expect(AppState.I.serviceStatusForTest('mcp:${server.canonicalId}'),
        isNull);
    expect(svc.isConnected(server.canonicalId), isFalse);
  });

  test('same-account late HTTP failure still publishes failed status',
      () async {
    McpService.reconnectInitialDelayForTest = const Duration(seconds: 5);
    registerPlugin();
    final server = pluginServer();
    cleanup.add(server.canonicalId);
    AppState.I.mcpServers.add(server);
    await svc.connect(server);
    expect(server.connected, isTrue);

    svc.httpClientForTest = MockClient(
      (_) async => throw const SocketException('down'),
    );
    await svc.callTool(server.canonicalId, 'echo', {});

    expect(server.connected, isFalse);
    expect(
      AppState.I.serviceStatusForTest('mcp:${server.canonicalId}')?.health,
      ServiceHealth.failed,
    );
    expect(svc.hasPendingReconnectForTest(server.canonicalId), isTrue);
  });
}
