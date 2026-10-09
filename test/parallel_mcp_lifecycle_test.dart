import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = McpService.I;
  late McpServer server;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    server = McpServer(
      name: 'parallel-mcp',
      author: 'test',
      description: '',
      category: 'Custom',
      command: '',
      transport: 'http',
      url: 'https://mcp.test',
    );
    AppState.I.mcpServers.add(server);
    svc.httpClientForTest = MockClient((request) async {
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
    });
  });
  tearDown(() async {
    await svc.disconnect(server.canonicalId);
    svc.httpClientForTest = null;
    McpService.beforeReserveHookForTest = null;
    McpService.missingRuntimeOverrideForTest = null;
    McpService.spawnProcessForTest = null;
    McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 500);
    McpService.reconnectMaxAttemptsForTest = 10;
    AppState.resetTestInstance();
  });

  test(
    'simultaneous callers share the credential/runtime reservation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var probes = 0;
      McpService.missingRuntimeOverrideForTest = (_) async {
        probes++;
        if (!entered.isCompleted) entered.complete();
        await release.future;
        return null;
      };
      final first = svc.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 2),
      );
      await entered.future;
      final second = svc.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 2),
      );
      release.complete();
      final results = await Future.wait([first, second]);
      expect(results.every((r) => r.isReady), isTrue);
      expect(probes, 1);
    },
  );

  test(
    'disconnect during preflight cancels promptly and prevents a late dial',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      McpService.missingRuntimeOverrideForTest = (_) async {
        entered.complete();
        await release.future;
        return null;
      };
      final pending = svc.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 2),
      );
      await entered.future;
      await svc.disconnect(server.canonicalId);
      final result = await pending.timeout(
        const Duration(milliseconds: 150),
        onTimeout: () => const McpConnectOutcome(McpConnectOutcomeKind.ready),
      );
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        result.isReady,
        isFalse,
        reason: 'cancellation must release waiting callers',
      );
      expect(svc.isConnected(server.canonicalId), isFalse);
    },
  );

  test('a joining caller timeout does not abort the shared owner', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    McpService.missingRuntimeOverrideForTest = (_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return null;
    };
    final owner = svc.connectOutcome(
      server,
      handshakeBudget: const Duration(seconds: 2),
    );
    await entered.future;
    final joiner = await svc.connectOutcome(
      server,
      handshakeBudget: const Duration(milliseconds: 30),
    );
    release.complete();
    expect(joiner.reason, contains('timed out'));
    expect((await owner).isReady, isTrue);
  });

  test('ordinary connect kills a process returned after disconnect', () async {
    server.transport = 'stdio';
    server.command = 'python3';
    final entered = Completer<void>();
    final release = Completer<void>();
    final spawned = Completer<Process>();
    McpService.spawnProcessForTest = (argv, {env, hostWorkDir}) async {
      entered.complete();
      await release.future;
      final process = await Process.start('python3', [
        '-c',
        'import time; time.sleep(30)',
      ]);
      spawned.complete(process);
      return process;
    };
    final pending = svc.connect(server);
    await entered.future;
    await svc.disconnect(server.canonicalId);
    release.complete();
    final process = await spawned.future;
    addTearDown(() => process.kill());
    final exited = await process.exitCode.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () => 999,
    );
    expect(exited, isNot(999));
    expect(await pending, contains('aborted'));
  });

  test('failed HTTP reconnect retries up to the cap', () async {
    McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 5);
    McpService.reconnectMaxAttemptsForTest = 3;
    await svc.connect(server);
    expect(server.connected, isTrue);
    var retries = 0;
    final capped = Completer<void>();
    svc.httpClientForTest = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      if (body['method'] == 'initialize') {
        retries++;
        if (retries == 3) capped.complete();
      }
      throw const SocketException('fixture unavailable');
    });
    await svc.callTool(server.canonicalId, 'echo', {});
    await capped.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
    expect(retries, 3);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(retries, 3);
    expect(server.connected, isFalse);
    expect(
      AppState.I.serviceStatusForTest('mcp:${server.canonicalId}')?.health,
      ServiceHealth.failed,
    );
  });

  test(
    'successful HTTP reconnect restores the row and working status',
    () async {
      McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 5);
      await svc.connect(server);
      var available = false;
      svc.httpClientForTest = MockClient((request) async {
        if (!available) throw const SocketException('down');
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
      });

      await svc.callTool(server.canonicalId, 'echo', {});
      expect(server.connected, isFalse);
      available = true;
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(svc.isConnected(server.canonicalId), isTrue);
      expect(server.connected, isTrue);
      expect(
        AppState.I.serviceStatusForTest('mcp:${server.canonicalId}')?.health,
        ServiceHealth.working,
      );
    },
  );

  test(
    'an unexpected stdio exit clears the row and publishes failed status',
    () async {
      final process = await Process.start('python3', [
        '-c',
        'import time; time.sleep(30)',
      ]);
      addTearDown(() => process.kill());
      server.transport = 'stdio';
      server.command = 'python3';
      server.connected = true;
      await svc.attachStdioForTest(server, process);

      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(server.connected, isFalse);
      expect(
        AppState.I.serviceStatusForTest('mcp:${server.canonicalId}')?.health,
        ServiceHealth.failed,
      );
    },
  );

  test(
    'disconnect invalidates a reconnect already waiting in preflight',
    () async {
      McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 5);
      await svc.connect(server);
      final entered = Completer<void>();
      final release = Completer<void>();
      McpService.missingRuntimeOverrideForTest = (_) async {
        entered.complete();
        await release.future;
        return null;
      };
      svc.httpClientForTest = MockClient(
        (_) async => throw const SocketException('down'),
      );
      await svc.callTool(server.canonicalId, 'echo', {});
      await entered.future;
      await svc.disconnect(server.canonicalId);
      var lateDials = 0;
      svc.httpClientForTest = MockClient((_) async {
        lateDials++;
        throw const SocketException('late dial');
      });
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(lateDials, 0);
      expect(svc.hasPendingReconnectForTest(server.canonicalId), isFalse);
    },
  );

  test('automatic reconnect stops on an authentication refusal', () async {
    McpService.reconnectInitialDelayForTest = const Duration(milliseconds: 5);
    await svc.connect(server);
    svc.httpClientForTest = MockClient(
      (_) async => throw const SocketException('down'),
    );
    await svc.callTool(server.canonicalId, 'echo', {});
    var retries = 0;
    final refused = Completer<void>();
    svc.httpClientForTest = MockClient((_) async {
      retries++;
      if (!refused.isCompleted) refused.complete();
      return http.Response('', 401);
    });
    await refused.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(retries, 1);
    expect(svc.hasPendingReconnectForTest(server.canonicalId), isFalse);
  });

  test('expired preflight cannot overwrite a replacement connection', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    McpService.beforeReserveHookForTest = () async {
      entered.complete();
      await release.future;
    };
    final stale = svc.connectOutcome(
      server,
      handshakeBudget: const Duration(milliseconds: 30),
    );
    await entered.future;
    expect((await stale).isReady, isFalse);
    McpService.beforeReserveHookForTest = null;
    expect(
      (await svc.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 1),
      )).isReady,
      isTrue,
    );
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(svc.isConnected(server.canonicalId), isTrue);
    expect(svc.connectedTools[server.canonicalId]!.single.name, 'echo');
  });
}
