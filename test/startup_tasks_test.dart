import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/startup_tasks.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

McpServer _httpServer(
  String name, {
  String? owner,
  String url = 'https://mcp.example/rpc',
  int startupTimeoutS = 30,
  List<String> requiredEnvNames = const [],
  List<String> requiredHeaderNames = const [],
  String transport = 'http',
}) => McpServer(
  name: name,
  ownerPluginId: owner,
  author: 'test',
  description: '',
  category: 'Custom',
  command: '',
  transport: transport,
  url: url,
  custom: true,
  startupTimeoutS: startupTimeoutS,
  requiredEnvNames: requiredEnvNames,
  requiredHeaderNames: requiredHeaderNames,
);

McpConnectTask _mcpTask(
  String canonicalId, {
  required Future<McpConnectOutcome> Function(Duration budget) connect,
  bool Function()? isConnected,
  StartupDisable? onDisable,
  int startupTimeoutS = 30,
}) => McpConnectTask(
  canonicalId: canonicalId,
  label: 'Connect $canonicalId',
  budget: McpConnectTask.budgetFor(startupTimeoutS),
  connect: connect,
  isConnected: isConnected ?? () => true,
  onDisable: onDisable ?? () async {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(() async {
    McpService.I.httpClientForTest = null;
    await McpService.I.disconnectAll();
    AppState.resetTestInstance();
  });

  group('MCP startup tasks', () {
    test('two MCP tasks run strictly one-by-one without overlap', () async {
      final calls = <String>[];
      final aStarted = Completer<void>();
      final releaseA = Completer<void>();
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 30),
      );

      final a = _mcpTask(
        'owner/a',
        connect: (_) async {
          calls.add('a:start');
          aStarted.complete();
          await releaseA.future;
          calls.add('a:end');
          return const McpConnectOutcome(McpConnectOutcomeKind.ready);
        },
      );
      final b = _mcpTask(
        'owner/b',
        connect: (_) async {
          calls.add('b:start');
          calls.add('b:end');
          return const McpConnectOutcome(McpConnectOutcomeKind.ready);
        },
      );

      final run = coordinator.start([a, b]);
      await aStarted.future;
      expect(calls, ['a:start']);
      releaseA.complete();
      await run;

      expect(calls, ['a:start', 'a:end', 'b:start', 'b:end']);
    });

    test('a failed MCP A still runs MCP B', () async {
      final calls = <String>[];
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 30),
      );

      final a = _mcpTask(
        'owner/a',
        connect: (_) async {
          calls.add('a');
          throw StateError('A exploded');
        },
      );
      final b = _mcpTask(
        'owner/b',
        connect: (_) async {
          calls.add('b');
          return const McpConnectOutcome(McpConnectOutcomeKind.ready);
        },
      );

      await coordinator.start([a, b]);

      expect(calls, ['a', 'b']);
      expect(
        coordinator.snapshot.items
            .singleWhere((item) => item.id == 'mcp.connect:owner/a')
            .state,
        StartupItemState.failed,
      );
      expect(
        coordinator.snapshot.items
            .singleWhere((item) => item.id == 'mcp.connect:owner/b')
            .state,
        StartupItemState.ready,
      );
    });

    test('a failed plugin task does not stop a later MCP task', () async {
      final calls = <String>[];
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 30),
      );

      final plugin = PluginActivationTask(
        id: 'plugin.activate',
        label: 'Activate plugins',
        timeout: const Duration(seconds: 5),
        activate: () async => throw StateError('activation boom'),
      );
      final mcp = _mcpTask(
        'owner/a',
        connect: (_) async {
          calls.add('mcp');
          return const McpConnectOutcome(McpConnectOutcomeKind.ready);
        },
      );

      await coordinator.start([plugin, mcp]);

      expect(
        coordinator.snapshot.items
            .singleWhere((item) => item.id == 'plugin.activate')
            .state,
        StartupItemState.failed,
      );
      expect(calls, ['mcp']);
      expect(
        coordinator.snapshot.items
            .singleWhere((item) => item.id == 'mcp.connect:owner/a')
            .state,
        StartupItemState.ready,
      );
    });

    test('per-server MCP ids are canonical and distinct', () {
      final a = _mcpTask(
        'publisher/shared',
        connect: (_) async =>
            const McpConnectOutcome(McpConnectOutcomeKind.ready),
      );
      final b = _mcpTask(
        'other/shared',
        connect: (_) async =>
            const McpConnectOutcome(McpConnectOutcomeKind.ready),
      );

      expect(a.id, 'mcp.connect:publisher/shared');
      expect(b.id, 'mcp.connect:other/shared');
      expect(a.id, isNot(b.id));
    });

    test('startupTimeoutS 120 receives exactly one 30 second budget', () async {
      expect(McpConnectTask.budgetFor(120), const Duration(seconds: 30));
      expect(McpConnectTask.budgetFor(5), const Duration(seconds: 5));

      var calls = 0;
      Duration? seen;
      final task = _mcpTask(
        'slow',
        startupTimeoutS: 120,
        connect: (budget) async {
          calls++;
          seen = budget;
          return const McpConnectOutcome(McpConnectOutcomeKind.ready);
        },
      );

      expect(task.timeout, const Duration(seconds: 31));
      final status = await task.run();
      expect(status.state, StartupItemState.ready);
      expect(seen, const Duration(seconds: 30));
      expect(calls, 1, reason: 'one budget, not one per RPC');
    });

    test('a ready outcome without a live connection becomes failed', () async {
      final task = _mcpTask(
        'ghost',
        connect: (_) async =>
            const McpConnectOutcome(McpConnectOutcomeKind.ready),
        isConnected: () => false,
      );

      final status = await task.run();
      expect(status.state, StartupItemState.failed);
      expect(status.reason, contains('not connected'));
    });

    test(
      'unsupported outcome maps to the unsupported terminal state',
      () async {
        final task = _mcpTask(
          'sse',
          connect: (_) async => const McpConnectOutcome(
            McpConnectOutcomeKind.unsupported,
            'SSE is not supported',
          ),
        );

        final status = await task.run();
        expect(status.state, StartupItemState.unsupported);
        expect(status.reason, 'SSE is not supported');
      },
    );

    test('a throwing MCP body never escapes as an exception', () async {
      final task = _mcpTask(
        'throws',
        connect: (_) async => throw StateError('transport exploded'),
      );

      final status = await task.run();
      expect(status.state, StartupItemState.failed);
      expect(status.reason, contains('transport exploded'));
    });

    test(
      'initialize timeout prevents tools/list and never marks ready',
      () async {
        final methods = <String>[];
        McpService.I.httpClientForTest = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          methods.add(body['method'] as String);
          if (body['method'] == 'initialize') {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          return http.Response('{}', 200);
        });
        AppState.createForTest();
        final server = _httpServer('slow-init');

        final outcome = await McpService.I.connectOutcome(
          server,
          handshakeBudget: const Duration(milliseconds: 60),
        );

        expect(outcome.kind, McpConnectOutcomeKind.failed);
        expect(methods, ['initialize']);
        expect(McpService.I.isConnected(server.canonicalId), isFalse);
      },
    );

    test('tools/list timeout removes the slot and never marks ready', () async {
      final methods = <String>[];
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        methods.add(body['method'] as String);
        if (body['method'] == 'tools/list') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': body['method'] == 'tools/list'
                ? {
                    'tools': [
                      {'name': 'lookup'},
                    ],
                  }
                : {},
          }),
          200,
        );
      });
      AppState.createForTest();
      final server = _httpServer('slow-tools');

      final outcome = await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(milliseconds: 120),
      );

      expect(outcome.kind, McpConnectOutcomeKind.failed);
      expect(methods, contains('tools/list'));
      expect(McpService.I.isConnected(server.canonicalId), isFalse);
      expect(
        McpService.I.hasPendingReconnectForTest(server.canonicalId),
        isFalse,
      );
    });

    test('missing env or header maps to needsSetup without dialing', () async {
      var requests = 0;
      McpService.I.httpClientForTest = MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      });
      AppState.createForTest();
      final server = _httpServer(
        'needs-setup',
        requiredEnvNames: const ['API_TOKEN'],
        requiredHeaderNames: const ['Authorization'],
      );

      final outcome = await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 5),
      );

      expect(outcome.kind, McpConnectOutcomeKind.needsSetup);
      expect(outcome.reason, contains('API_TOKEN'));
      expect(outcome.reason, contains('Authorization'));
      expect(requests, 0, reason: 'credential gate must not dial');
    });

    test('sse and unknown transports are unsupported', () async {
      AppState.createForTest();
      final sse = _httpServer('legacy-sse', transport: 'sse');
      final weird = _httpServer('weird', transport: 'carrier-pigeon');

      final sseOutcome = await McpService.I.connectOutcome(
        sse,
        handshakeBudget: const Duration(seconds: 5),
      );
      final weirdOutcome = await McpService.I.connectOutcome(
        weird,
        handshakeBudget: const Duration(seconds: 5),
      );

      expect(sseOutcome.kind, McpConnectOutcomeKind.unsupported);
      expect(weirdOutcome.kind, McpConnectOutcomeKind.unsupported);
      expect(weirdOutcome.reason, contains('carrier-pigeon'));
    });

    test(
      'a successful handshake reports ready and isConnected honestly',
      () async {
        McpService.I.httpClientForTest = MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': body['method'] == 'tools/list'
                  ? {
                      'tools': [
                        {'name': 'lookup'},
                      ],
                    }
                  : {},
            }),
            200,
          );
        });
        AppState.createForTest();
        final server = _httpServer('healthy');

        final outcome = await McpService.I.connectOutcome(
          server,
          handshakeBudget: const Duration(seconds: 5),
        );

        expect(outcome.kind, McpConnectOutcomeKind.ready);
        expect(McpService.I.isConnected(server.canonicalId), isTrue);
        addTearDown(() => McpService.I.disconnect(server.canonicalId));
      },
    );
  });

  group('marketplace startup task', () {
    test(
      'aggregates the worst outcome and continues after a failure',
      () async {
        final visited = <String>[];
        final task = MarketplaceRefreshTask(
          id: 'marketplace.refresh',
          label: 'Refresh plugin marketplaces',
          timeout: const Duration(seconds: 20),
          repos: () => const ['a', 'b', 'c'],
          refresh: (repo) async {
            visited.add(repo);
            return switch (repo) {
              'a' => MarketplaceSyncOutcome.ready,
              'b' => MarketplaceSyncOutcome.failed,
              _ => MarketplaceSyncOutcome.degraded,
            };
          },
        );

        final status = await task.run();

        expect(visited, ['a', 'b', 'c']);
        expect(status.state, StartupItemState.failed);
      },
    );

    test('maps ready, degraded, and a throwing refresh', () async {
      Future<StartupItemState> runFor(MarketplaceSyncOutcome outcome) async {
        final task = MarketplaceRefreshTask(
          id: 'marketplace.refresh',
          label: 'Refresh plugin marketplaces',
          timeout: const Duration(seconds: 20),
          repos: () => const ['only'],
          refresh: (_) async => outcome,
        );
        return (await task.run()).state;
      }

      expect(
        await runFor(MarketplaceSyncOutcome.ready),
        StartupItemState.ready,
      );
      expect(
        await runFor(MarketplaceSyncOutcome.degraded),
        StartupItemState.degraded,
      );

      final throwing = MarketplaceRefreshTask(
        id: 'marketplace.refresh',
        label: 'Refresh plugin marketplaces',
        timeout: const Duration(seconds: 20),
        repos: () => const ['only'],
        refresh: (_) async => throw StateError('offline'),
      );
      expect((await throwing.run()).state, StartupItemState.failed);
    });

    test(
      'a cached catalog degrades instead of failing when fetch fails',
      () async {
        final app = AppState.createForTest();
        app.mergeMarketplaceCatalogForTest(
          {
            'plugins': [
              {'name': 'cached-plugin', 'source': 'owner/repo'},
            ],
          },
          'cached',
          'repo',
        );
        AppState.marketplaceBaseOverrideForTest = 'http://127.0.0.1:1';
        addTearDown(() => AppState.marketplaceBaseOverrideForTest = null);

        final outcome = await app.refreshMarketplaceForStartup('cached/repo');

        expect(outcome, MarketplaceSyncOutcome.degraded);
      },
    );
  });

  group('firebase startup task', () {
    test(
      'unavailable and unexpected failures are retryable degraded',
      () async {
        final unavailable = FirebaseStartupTask(
          id: 'firebase.initialize',
          label: 'Initialize optional services',
          timeout: const Duration(seconds: 10),
          initialize: () async => false,
        );
        final unexpected = FirebaseStartupTask(
          id: 'firebase.initialize',
          label: 'Initialize optional services',
          timeout: const Duration(seconds: 10),
          initialize: () async => throw StateError('no config'),
        );
        final ready = FirebaseStartupTask(
          id: 'firebase.initialize',
          label: 'Initialize optional services',
          timeout: const Duration(seconds: 10),
          initialize: () async => true,
        );

        expect((await unavailable.run()).state, StartupItemState.degraded);
        expect((await unexpected.run()).state, StartupItemState.degraded);
        expect((await ready.run()).state, StartupItemState.ready);
      },
    );
  });

  group('sandbox startup task', () {
    SandboxMaintenanceTask task({
      required bool installed,
      Future<void> Function()? startMaintenance,
      Future<bool> Function()? runtimesVerified,
      Future<bool> Function()? installCoreRuntimes,
      Future<void> Function()? enforceQuota,
    }) => SandboxMaintenanceTask(
      id: 'sandbox.selfHeal',
      label: 'Maintain local sandbox',
      timeout: const Duration(seconds: 30),
      isInstalled: () => installed,
      startMaintenance: startMaintenance ?? () async {},
      runtimesVerified: runtimesVerified ?? () async => true,
      installCoreRuntimes: installCoreRuntimes ?? () async => true,
      enforceQuota: enforceQuota ?? () async {},
    );

    test('not installed is skipped', () async {
      final status = await task(installed: false).run();
      expect(status.state, StartupItemState.skipped);
    });

    test('a permanent ABI failure is unsupported', () async {
      final status = await task(
        installed: true,
        startMaintenance: () async =>
            throw const SandboxUnsupportedException('unsupported ABI'),
      ).run();
      expect(status.state, StartupItemState.unsupported);
      expect(status.reason, 'unsupported ABI');
    });

    test('unverified runtimes after install is degraded', () async {
      final status = await task(
        installed: true,
        runtimesVerified: () async => false,
        installCoreRuntimes: () async => false,
      ).run();
      expect(status.state, StartupItemState.degraded);
    });

    test('a healthy sandbox is ready and runs quota after runtimes', () async {
      final calls = <String>[];
      final status = await task(
        installed: true,
        startMaintenance: () async => calls.add('maintain'),
        runtimesVerified: () async => true,
        enforceQuota: () async => calls.add('quota'),
      ).run();
      expect(status.state, StartupItemState.ready);
      expect(calls, ['maintain', 'quota']);
    });
  });

  group('readiness queue', () {
    test('orders local, plugin, skill before per-server MCP items', () async {
      SharedPreferences.setMockInitialValues({
        'ovid_mcp_connected_v1': ['Filesystem', 'Fetch'],
      });
      final app = AppState.createForTest();
      final ids = (await app.buildReadinessTasks())
          .map((task) => task.id)
          .toList();

      expect(ids.indexOf('local.hydrate'), 0);
      expect(ids.indexOf('localSafety.migrate'), 1);
      expect(
        ids.indexOf('plugin.activate'),
        lessThan(ids.indexOf('skill.mount')),
      );
      expect(
        ids.indexOf('skill.mount'),
        lessThan(ids.indexOf('session.restore')),
      );
      expect(
        ids.indexOf('session.restore'),
        lessThan(ids.indexOf('marketplace.refresh')),
      );
      expect(
        ids.indexOf('marketplace.refresh'),
        lessThan(ids.indexOf('github.initialize')),
      );
      final firstMcp = ids.indexWhere((id) => id.startsWith('mcp.connect:'));
      expect(firstMcp, greaterThan(ids.indexOf('skill.mount')));
      expect(ids, contains('mcp.connect:Filesystem'));
      expect(ids, contains('mcp.connect:Fetch'));
      expect(
        ids.indexOf('mcp.connect:Filesystem'),
        lessThan(ids.indexOf('mcp.connect:Fetch')),
      );
      expect(
        ids.indexOf('mcp.connect:Fetch'),
        lessThan(ids.indexOf('firebase.initialize')),
      );
      expect(
        ids.indexOf('firebase.initialize'),
        lessThan(ids.indexOf('sandbox.selfHeal')),
      );
    });

    test('disabling one MCP item clears only its own intent id', () async {
      SharedPreferences.setMockInitialValues({
        'ovid_mcp_connected_v1': ['Filesystem', 'Fetch'],
      });
      final app = AppState.createForTest();
      final task = (await app.buildReadinessTasks()).singleWhere(
        (candidate) => candidate.id == 'mcp.connect:Filesystem',
      );

      await task.onDisable!();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('ovid_mcp_connected_v1'), ['Fetch']);
    });

    test('startup reasons never leak secret values', () async {
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 5),
      );
      await coordinator.start([
        _mcpTask(
          'secret',
          connect: (_) async => throw StateError(
            'api_key=sk-visible-token Authorization: Bearer visible-token',
          ),
        ),
      ]);

      final reason = coordinator.snapshot.items
          .singleWhere((item) => item.id == 'mcp.connect:secret')
          .reason!;
      expect(reason, isNot(contains('sk-visible-token')));
      expect(reason, isNot(contains('visible-token')));
      expect(reason, contains('[REDACTED]'));
    });
  });

  group('plugin safety aggregate', () {
    test(
      'precedence is failed > unsupported > migration > degraded > ready',
      () {
        expect(
          aggregateStartupStates([
            StartupItemState.ready,
            StartupItemState.degraded,
          ]),
          StartupItemState.degraded,
        );
        expect(
          aggregateStartupStates([
            StartupItemState.migrationRequired,
            StartupItemState.degraded,
          ]),
          StartupItemState.migrationRequired,
        );
        expect(
          aggregateStartupStates([
            StartupItemState.unsupported,
            StartupItemState.migrationRequired,
          ]),
          StartupItemState.unsupported,
        );
        expect(
          aggregateStartupStates([
            StartupItemState.failed,
            StartupItemState.unsupported,
          ]),
          StartupItemState.failed,
        );
        expect(
          aggregateStartupStates([
            StartupItemState.unsupported,
            StartupItemState.failed,
          ]),
          StartupItemState.failed,
        );
        expect(
          aggregateStartupStates([StartupItemState.ready]),
          StartupItemState.ready,
        );
      },
    );
  });
}
