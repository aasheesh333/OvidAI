import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';

/// A startup task that owns a canonical plugin/MCP id — the marker the
/// coordinator uses to attribute terminal transitions to durable status.
class _OwnedTask implements StartupTask, StartupOwnedTask {
  _OwnedTask({
    required this.id,
    required this.ownerId,
    required this.runner,
    this.kind = StartupItemKind.plugin,
    this.timeout = const Duration(seconds: 5),
    this.onDisable,
  });

  @override
  final String id;
  @override
  final String ownerId;
  @override
  final StartupItemKind kind;
  @override
  final Duration timeout;
  final Future<StartupItemStatus> Function() runner;
  @override
  final StartupDisable? onDisable;

  @override
  String get label => 'Owned $id';

  @override
  Future<StartupItemStatus> run() => runner();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory runtimeRoot;
  late AppState app;

  String contentPath(String id, [String version = '1.0.0']) =>
      '${runtimeRoot.path}/plugin-runtime/$id/$version/content';

  NormalizedPluginManifest runtimeManifest(
    String id, {
    String name = 'Health Plugin',
    List<PluginHook> hooks = const [],
    List<PluginMcpServer> mcpServers = const [],
    List<PluginCommand> commands = const [],
    List<PluginSkill> skills = const [],
    List<PluginAgent> agents = const [],
  }) => NormalizedPluginManifest(
    id: id,
    name: name,
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: contentPath(id),
    commands: commands,
    skills: skills,
    agents: agents,
    hooks: hooks,
    mcpServers: mcpServers,
    requestedCapabilities: const {PluginCapability.workspaceRead},
  );

  PluginItem runtimeRow(NormalizedPluginManifest m) => PluginItem(
    name: m.name,
    author: m.id.split('/').first,
    description: '',
    version: m.version,
    category: 'Tool',
    installed: true,
    enabled: true,
    runtimeId: m.id,
    activation: PluginActivation.globalActive,
  );

  Future<void> seedRuntime(NormalizedPluginManifest m) async {
    Directory(m.rootPath).createSync(recursive: true);
    final entry = PluginInstallEntry(
      activation: PluginActivationRecord(
        pluginId: m.id,
        state: PluginActivation.globalActive,
        installedBootEpoch: 0,
      ),
      manifest: m,
      contentDir: m.rootPath,
      version: m.version,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kPluginActivationPrefKey,
      jsonEncode({m.id: jsonEncode(entry.toJson())}),
    );
    await PluginPermissionStore().save(
      PluginPermissionGrant(
        pluginId: m.id,
        manifestDigest: pluginManifestDigest(m),
        capabilities: m.requestedCapabilities,
        environmentReadNames: {
          ...m.environmentReadNames,
          for (final server in m.mcpServers) ...server.envNames,
        },
        approvedAt: DateTime.utc(2026, 9, 10),
      ),
    );
  }

  McpServer ownedServer(
    String pluginId,
    String name, {
    String transport = 'http',
    List<String> requiredEnvNames = const [],
    List<String> requiredHeaderNames = const [],
  }) => McpServer(
    name: name,
    ownerPluginId: pluginId,
    author: 'test',
    description: '',
    category: 'Plugin',
    command: '',
    transport: transport,
    url: transport == 'http' ? 'https://mcp.example/rpc' : null,
    custom: true,
    requiredEnvNames: requiredEnvNames,
    requiredHeaderNames: requiredHeaderNames,
  );

  MockClient healthyMcp({List<Map<String, String>> tools = const []}) =>
      MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': body['method'] == 'tools/list'
                ? {'tools': tools}
                : <String, dynamic>{},
          }),
          200,
        );
      });

  PluginRuntimeStatus status(
    String id,
    StartupItemState state, {
    String? reason,
    List<String> logs = const [],
    DateTime? updatedAt,
  }) => PluginRuntimeStatus(
    pluginId: id,
    state: state,
    reason: reason,
    logs: logs,
    updatedAt: updatedAt,
  );

  Future<Map<String, dynamic>> outerStatusMap() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      kPluginRuntimeStatusPrefKey,
    );
    if (raw == null) return {};
    return (jsonDecode(raw) as Map).cast<String, dynamic>();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    runtimeRoot = Directory.systemTemp.createTempSync('ovid-status-');
    PluginRuntimeManager.runtimeRootOverrideForTest = runtimeRoot;
    PluginRuntimeManager.failCanonicalRowsWriteForTest = false;
    app = AppState.createForTest();
    HookService.I.enabled = true;
    HookService.I.executorForTest = null;
  });

  tearDown(() async {
    for (final id in PluginContributionRegistry.I.registeredPluginIds
        .toList()) {
      PluginContributionRegistry.I.unregisterPlugin(id);
    }
    HookService.I.executorForTest = null;
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    McpService.I.httpClientForTest = null;
    await McpService.I.disconnectAll();
    AppState.resetTestInstance();
    if (runtimeRoot.existsSync()) runtimeRoot.deleteSync(recursive: true);
  });

  group('durable status store', () {
    test('canonical round-trip keeps same display name / different IDs', () async {
      final store = PluginRuntimeStatusStore();
      await store.record(
        status('acme/shared', StartupItemState.ready, reason: 'ok'),
      );
      await store.record(
        status('other/shared', StartupItemState.failed, reason: 'bad'),
      );

      final outer = await outerStatusMap();
      expect(outer.keys.toList(), ['acme/shared', 'other/shared']);

      final fresh = PluginRuntimeStatusStore();
      await fresh.hydrate();
      expect(fresh.statusFor('acme/shared')!.state, StartupItemState.ready);
      expect(fresh.statusFor('acme/shared')!.reason, 'ok');
      expect(fresh.statusFor('other/shared')!.state, StartupItemState.failed);
      expect(fresh.statusFor('other/shared')!.reason, 'bad');
    });

    test('unchanged status does not rewrite preferences', () async {
      final store = PluginRuntimeStatusStore();
      await store.record(
        status(
          'acme/stable',
          StartupItemState.ready,
          reason: 'same',
          logs: const ['a', 'b'],
        ),
      );
      final first = await outerStatusMap();
      final count = store.persistCountForTest;

      await store.record(
        status(
          'acme/stable',
          StartupItemState.ready,
          reason: 'same',
          logs: const ['a', 'b'],
        ),
      );

      expect(await outerStatusMap(), first);
      expect(store.persistCountForTest, count);
    });

    test('corrupt and noncanonical inner records are isolated', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPluginRuntimeStatusPrefKey,
        jsonEncode({
          'acme/good': jsonEncode(
            status('acme/good', StartupItemState.ready, reason: 'ok').toJson(),
          ),
          'acme/bad': '{not json',
          'legacy:1:2': jsonEncode(
            status('acme/good', StartupItemState.ready).toJson(),
          ),
          '': jsonEncode(
            status('acme/good', StartupItemState.ready).toJson(),
          ),
        }),
      );

      final store = PluginRuntimeStatusStore();
      await store.hydrate();
      expect(store.statusFor('acme/good'), isNotNull);
      expect(store.statusFor('acme/bad'), isNull);

      await store.record(status('acme/new', StartupItemState.failed, reason: 'n'));
      final outer = await outerStatusMap();
      expect(outer.containsKey('acme/bad'), isFalse);
      expect(outer.containsKey('legacy:1:2'), isFalse);
      expect(outer.containsKey(''), isFalse);
    });

    test('reasons and logs are scrubbed before persistence', () async {
      const token = 'sk-live-SUPERSECRET1234567890';
      const password = 'hunter2-password-value';
      const bearer = 'Bearer abcdef0123456789';
      final store = PluginRuntimeStatusStore();
      await store.record(
        status(
          'acme/secrets',
          StartupItemState.failed,
          reason: 'api_key=$token authorization: $bearer password=$password',
          logs: [
            'token: $token',
            'Authorization: $bearer',
            'password=$password',
            '{"env":{"MCP_TOKEN":"$token"},"headers":{"Authorization":"$bearer"}}',
          ],
        ),
      );

      final raw = (await SharedPreferences.getInstance()).getString(
        kPluginRuntimeStatusPrefKey,
      )!;
      expect(raw, isNot(contains(token)));
      expect(raw, isNot(contains(password)));
      expect(raw, isNot(contains('abcdef0123456789')));
      expect(raw, contains('[REDACTED]'));
      expect(store.statusFor('acme/secrets')!.reason, isNot(contains(token)));
    });

    test('logs cap at the newest 100 lines and 32 KiB UTF-8', () async {
      final store = PluginRuntimeStatusStore();
      await store.record(
        status(
          'acme/cap',
          StartupItemState.ready,
          logs: [for (var i = 0; i < 150; i++) 'line-$i'],
        ),
      );
      final rec = store.statusFor('acme/cap')!;
      expect(rec.logs.length, 100);
      expect(rec.logs.first, 'line-50');
      expect(rec.logs.last, 'line-149');

      final big = PluginRuntimeStatusStore();
      await big.record(
        status(
          'acme/big',
          StartupItemState.ready,
          logs: [for (var i = 0; i < 100; i++) 'x' * 1000],
        ),
      );
      final rec2 = big.statusFor('acme/big')!;
      final bytes = rec2.logs.fold<int>(
        0,
        (sum, line) => sum + utf8.encode(line).length,
      );
      expect(bytes, lessThanOrEqualTo(kPluginRuntimeStatusMaxLogBytes));
      expect(rec2.logs.length, lessThan(100));
    });

    test('a stale write cannot recreate a removed record', () async {
      final store = PluginRuntimeStatusStore();
      await store.record(status('acme/gone', StartupItemState.ready));
      await store.remove('acme/gone');
      expect(store.statusFor('acme/gone'), isNull);

      await store.record(status('acme/gone', StartupItemState.ready));
      expect(store.statusFor('acme/gone'), isNull);

      await store.record(
        status('acme/gone', StartupItemState.ready),
        revive: true,
      );
      expect(store.statusFor('acme/gone'), isNotNull);
    });
  });

  group('AppState persistence wiring', () {
    test('status, reason, and logs survive AppState recreation', () async {
      await app.runtimeStatusStore.record(
        status(
          'acme/survive',
          StartupItemState.failed,
          reason: 'boom',
          logs: const ['line1', 'line2'],
        ),
      );

      AppState.resetTestInstance();
      final app2 = AppState.createForTest();
      await app2.hydrateRuntimeStatuses();
      final restored = app2.statusFor('acme/survive')!;
      expect(restored.state, StartupItemState.failed);
      expect(restored.reason, 'boom');
      expect(restored.logs, ['line1', 'line2']);
    });

    test('uninstall removes only the target status record', () async {
      await app.runtimeStatusStore.record(
        status('acme/keep', StartupItemState.ready),
      );
      await app.runtimeStatusStore.record(
        status('acme/drop', StartupItemState.ready),
      );
      final row = PluginItem(
        name: 'Drop',
        author: 't',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: 'acme/drop',
      );

      await app.uninstallPlugin(row);

      expect(app.statusFor('acme/drop'), isNull);
      expect(app.statusFor('acme/keep'), isNotNull);
    });

    test('marketplace removal drops status for a removed runtime row', () async {
      await app.runtimeStatusStore.record(
        status('acme/mkt', StartupItemState.ready),
      );
      final row = PluginItem(
        name: 'Mkt',
        author: 't',
        description: '',
        version: '1',
        category: 'Tool',
        runtimeId: 'acme/mkt',
        marketplace: 'owner/repo',
      );
      app.plugins.add(row);

      await app.removeMarketplace('owner/repo');

      expect(app.statusFor('acme/mkt'), isNull);
    });

    test('factory reset clears the key and blocks late completions', () async {
      await app.runtimeStatusStore.record(
        status('acme/reset', StartupItemState.ready),
      );
      expect(await outerStatusMap(), isNotEmpty);

      await app.deleteAllData();

      expect(
        (await SharedPreferences.getInstance()).getString(
          kPluginRuntimeStatusPrefKey,
        ),
        isNull,
      );
      expect(app.statusFor('acme/reset'), isNull);

      await app.runtimeStatusStore.record(
        status('acme/reset', StartupItemState.ready),
      );
      expect(app.statusFor('acme/reset'), isNull);
    });
  });

  group('normalized plugin health', () {
    test('hook-only plugin is Ready once its hooks are registered', () async {
      final manifest = runtimeManifest(
        'acme/hooks',
        name: 'Hooks Only',
        hooks: [
          PluginHook(
            pluginId: 'acme/hooks',
            event: 'session_start',
            payload: 'echo hi',
          ),
        ],
      );
      await seedRuntime(manifest);
      final row = runtimeRow(manifest);

      expect(
        (await app.pluginHealthFor(row)).state,
        isNot(StartupItemState.ready),
      );

      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      final health = await app.pluginHealthFor(row);
      expect(health.state, StartupItemState.ready);
      expect(HookService.I.hasRegisteredHooks('acme/hooks'), isTrue);
    });

    test('legacy hook map is not normalized health and migration blocks', () async {
      final migrated = PluginItem(
        name: 'Legacy Hooks',
        author: 't',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        migrationRequired: true,
        runtimeId: 'acme/legacy',
        hooks: const {'on_turn_start': 'echo hi'},
      );
      expect(
        (await app.pluginHealthFor(migrated)).state,
        StartupItemState.migrationRequired,
      );

      final unregistered = PluginItem(
        name: 'Ghost Hooks',
        author: 't',
        description: '',
        version: '1',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: 'acme/ghost-hooks',
        hooks: const {'on_turn_start': 'echo hi'},
      );
      expect(
        (await app.pluginHealthFor(unregistered)).state,
        isNot(StartupItemState.ready),
      );
    });

    test('MCP-only plugin is Ready only after handshake, even with zero tools', () async {
      final manifest = runtimeManifest(
        'acme/mcp',
        name: 'MCP Only',
        mcpServers: [
          PluginMcpServer(
            pluginId: 'acme/mcp',
            name: 'server',
            transport: 'http',
            url: 'https://mcp.example/rpc',
          ),
        ],
      );
      await seedRuntime(manifest);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      final row = runtimeRow(manifest);
      final server = ownedServer('acme/mcp', 'server');
      app.mcpServers.add(server);

      expect(
        (await app.pluginHealthFor(row)).state,
        isNot(StartupItemState.ready),
      );

      McpService.I.httpClientForTest = healthyMcp();
      final outcome = await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(outcome.kind, McpConnectOutcomeKind.ready);
      server.connected = true;

      expect((await app.pluginHealthFor(row)).state, StartupItemState.ready);
    });

    test('missing credentials report Needs setup without dialing', () async {
      final manifest = runtimeManifest(
        'acme/needs',
        name: 'Needs Creds',
        mcpServers: [
          PluginMcpServer(
            pluginId: 'acme/needs',
            name: 'server',
            transport: 'http',
            url: 'https://mcp.example/rpc',
            envNames: const ['API_TOKEN'],
            headerNames: const ['Authorization'],
          ),
        ],
      );
      await seedRuntime(manifest);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      final row = runtimeRow(manifest);
      app.mcpServers.add(
        ownedServer(
          'acme/needs',
          'server',
          requiredEnvNames: const ['API_TOKEN'],
          requiredHeaderNames: const ['Authorization'],
        ),
      );
      var requests = 0;
      McpService.I.httpClientForTest = MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      });

      final health = await app.pluginHealthFor(row);

      expect(health.state, StartupItemState.needsSetup);
      expect(health.reason, contains('API_TOKEN'));
      expect(requests, 0, reason: 'credential probe must not dial');
    });

    test('unsupported transport reports Unsupported', () async {
      final manifest = runtimeManifest(
        'acme/sse',
        name: 'SSE Only',
        mcpServers: [
          PluginMcpServer(
            pluginId: 'acme/sse',
            name: 'server',
            transport: 'sse',
          ),
        ],
      );
      await seedRuntime(manifest);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      final row = runtimeRow(manifest);
      app.mcpServers.add(
        ownedServer('acme/sse', 'server', transport: 'sse'),
      );

      final health = await app.pluginHealthFor(row);

      expect(health.state, StartupItemState.unsupported);
    });

    test('mixed hook + MCP is Ready only after every required probe', () async {
      final manifest = runtimeManifest(
        'acme/mixed',
        name: 'Mixed',
        hooks: [
          PluginHook(
            pluginId: 'acme/mixed',
            event: 'session_start',
            payload: 'echo hi',
          ),
        ],
        mcpServers: [
          PluginMcpServer(
            pluginId: 'acme/mixed',
            name: 'server',
            transport: 'http',
            url: 'https://mcp.example/rpc',
          ),
        ],
      );
      await seedRuntime(manifest);
      PluginContributionRegistry.I.register(
        manifest,
        activation: PluginActivation.globalActive,
      );
      final row = runtimeRow(manifest);
      final server = ownedServer('acme/mixed', 'server');
      app.mcpServers.add(server);

      expect(
        (await app.pluginHealthFor(row)).state,
        isNot(StartupItemState.ready),
      );

      McpService.I.httpClientForTest = healthyMcp();
      await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 5),
      );
      server.connected = true;

      expect((await app.pluginHealthFor(row)).state, StartupItemState.ready);
    });
  });

  group('coordinator status sink', () {
    test('exception, timeout, retry, and disable transitions persist', () async {
      final recorded = <String, PluginRuntimeStatus>{};
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 30),
        statusSink: (status, ownerId) {
          if (ownerId == null) return;
          recorded[ownerId] = PluginRuntimeStatus(
            pluginId: ownerId,
            state: status.state,
            reason: status.reason,
            updatedAt: status.updatedAt,
          );
        },
      );

      await coordinator.start([
        _OwnedTask(
          id: 'exception',
          ownerId: 'acme/exception',
          runner: () async => throw StateError('boom'),
        ),
      ]);
      expect(recorded['acme/exception']!.state, StartupItemState.failed);

      await coordinator.start([
        _OwnedTask(
          id: 'timeout',
          ownerId: 'acme/timeout',
          timeout: const Duration(milliseconds: 20),
          runner: () async {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            return StartupItemStatus.ready(
              'timeout',
              StartupItemKind.plugin,
              'T',
            );
          },
        ),
      ]);
      expect(recorded['acme/timeout']!.state, StartupItemState.degraded);

      var attempts = 0;
      await coordinator.start([
        _OwnedTask(
          id: 'retry',
          ownerId: 'acme/retry',
          runner: () async {
            attempts++;
            if (attempts == 1) throw StateError('first');
            return StartupItemStatus.ready(
              'retry',
              StartupItemKind.plugin,
              'R',
            );
          },
        ),
      ]);
      expect(recorded['acme/retry']!.state, StartupItemState.failed);
      await coordinator.retry('retry');
      expect(recorded['acme/retry']!.state, StartupItemState.ready);

      await coordinator.start([
        _OwnedTask(
          id: 'disable',
          ownerId: 'acme/disable',
          kind: StartupItemKind.mcp,
          runner: () async => StartupItemStatus.failed(
            'disable',
            StartupItemKind.mcp,
            'D',
            reason: 'no',
          ),
          onDisable: () async {},
        ),
      ]);
      await coordinator.disable('disable');
      expect(recorded['acme/disable']!.state, StartupItemState.disabled);
    });

    test('deadline persists degraded and a stale completion cannot overwrite', () async {
      final recorded = <String, StartupItemStatus>{};
      final coordinator = StartupCoordinator.forTest(
        deadline: const Duration(milliseconds: 40),
        statusSink: (status, ownerId) {
          if (ownerId != null) recorded[ownerId] = status;
        },
      );
      final release = Completer<void>();
      final task = _OwnedTask(
        id: 'slow',
        ownerId: 'acme/slow',
        runner: () async {
          await release.future;
          return StartupItemStatus.ready('slow', StartupItemKind.plugin, 'Slow');
        },
      );

      await coordinator.start([task]);
      expect(recorded['acme/slow']!.state, StartupItemState.degraded);

      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(recorded['acme/slow']!.state, StartupItemState.degraded);
      expect(
        coordinator.snapshot.items.single.state,
        StartupItemState.degraded,
      );
    });
  });
}
