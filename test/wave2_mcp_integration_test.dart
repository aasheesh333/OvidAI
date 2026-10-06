// Wave 2 MCP caller integration — these tests pin the AppState ↔ McpService
// boundary that mcp_service's own fixtures cannot reach:
//
//   * `catalog_remove_mcp` (agent tool) must durably drop OAuth sidecars.
//   * marketplace `removeMarketplace` prune must drop OAuth sidecars.
//   * plugin `uninstallPlugin` must drop OAuth sidecars for owned rows.
//   * `toggleMcpServer`→disconnect (DISABLE, not remove) must *retain* them.
//   * `_addImportedMcpRow` must await the OAuth-config write and roll the
//     row back on failure — tested through the import entry points.
//
// Uses the existing `oauthSecureStorageDisabledForTest` seam so no real
// secure storage is touched, and `mcpOAuthWriteOverrideForTest` on AppState
// so we can inject a failing write without a live platform channel.
// No network — all tests run offline.

import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<McpServer> _seedCustomMcp(
  AppState app, {
  required String name,
  bool withOAuth = true,
}) async {
  // Import a custom MCP row through the same marketplace path user-facing
  // imports use so the fence/rollback bookkeeping runs end-to-end.
  final doc = <String, dynamic>{
    'mcpServers': [
      {
        'name': name,
        'command': 'npx',
        'args': ['-y', 'test'],
        if (withOAuth)
          'oauth': {
            'authorization_url': 'https://auth.example.com/authorize',
            'token_url': 'https://auth.example.com/token',
            'client_id': 'fixture-client',
          },
      },
    ],
  };
  final msg = app.mergeMarketplaceCatalogForTest(doc, 'wave2', 'repo');
  expect(msg, contains('Imported'));
  // Settle the OAuth-config write so the token we seed below cannot land
  // before the config in a way that would mask durable deletion.
  await app.awaitPendingMcpOAuthImports();
  final row = app.mcpServers.firstWhere((e) => e.name == name);
  // Seed an in-memory token (storage-disabled seam) so we can assert the
  // teardown dropped it.
  await McpService.I.storeMcpOAuthToken(
    row.canonicalId,
    const McpOAuthToken(accessToken: 'seed', refreshToken: 'r'),
  );
  expect(McpService.I.mcpOAuthConfigFor(row.canonicalId), isNotNull);
  expect(await McpService.I.mcpOAuthTokenFor(row.canonicalId), isNotNull);
  return row;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    // Keep OAuth sidecars in-memory only. The in-memory maps are the
    // durability oracle for these tests (writes are a no-op; removal still
    // has to drop the entries).
    McpService.oauthSecureStorageDisabledForTest = true;
  });

  tearDown(() async {
    AppState.mcpOAuthWriteOverrideForTest = null;
    McpService.oauthSecureStorageDisabledForTest = false;
    AppState.resetTestInstance();
  });

  test(
    'catalog_remove_mcp durably deletes OAuth config + token sidecars',
    () async {
      final app = AppState.I;
      final row = await _seedCustomMcp(app, name: 'wave2-tool-remove');
      final canonicalId = row.canonicalId;

      // Drive the exact agent-tool path. The handler awaits
      // AppState.removeMcpServer which in turn awaits
      // McpService.removeMcpOAuth — so by the time this returns, both
      // sidecars must be gone.
      final result = await AgentService.I.dispatchForTest(
        'catalog_remove_mcp',
        {'name': 'wave2-tool-remove'},
      );
      expect(result, contains('removed'));

      expect(app.mcpServers.any((e) => e.canonicalId == canonicalId), isFalse);
      expect(McpService.I.mcpOAuthConfigFor(canonicalId), isNull);
      expect(await McpService.I.mcpOAuthTokenFor(canonicalId), isNull);
    },
  );

  test('marketplace prune deletes OAuth sidecars for merged MCP rows',
      () async {
    final app = AppState.I;
    // Pre-register the marketplace so removeMarketplace runs its full prune.
    app.marketplaces.add('wave2/repo');
    final row = await _seedCustomMcp(app, name: 'wave2-prune-remote');
    final canonicalId = row.canonicalId;

    await app.removeMarketplace('wave2/repo');

    expect(app.mcpServers.any((e) => e.canonicalId == canonicalId), isFalse);
    expect(McpService.I.mcpOAuthConfigFor(canonicalId), isNull);
    expect(await McpService.I.mcpOAuthTokenFor(canonicalId), isNull);
  });

  test('plugin uninstall deletes OAuth sidecars for owned MCP rows',
      () async {
    final app = AppState.I;
    // A legacy, plugin-sourced MCP row that participates in uninstall's
    // owned-server teardown path (`plugin:<name>` source match).
    final plugin = PluginItem(
      name: 'wave2-owner',
      author: 'you',
      description: 'owns one MCP server',
      version: '1.0.0',
      category: 'Tool',
      installed: true,
      enabled: true,
    );
    app.plugins.add(plugin);

    final server = McpServer(
      name: 'wave2-owned-mcp',
      author: 'wave2-owner',
      description: 'owned',
      category: 'Custom',
      command: 'npx',
      args: const ['-y', 'owned'],
      source: 'plugin:wave2-owner',
      custom: true,
      transport: 'stdio',
    );
    app.mcpServers.add(server);
    await McpService.I.setMcpOAuthConfig(
      server.canonicalId,
      const McpOAuthConfig(
        authorizationUrl: 'https://auth.example.com/authorize',
        tokenUrl: 'https://auth.example.com/token',
        clientId: 'fixture-client',
      ),
    );
    await McpService.I.storeMcpOAuthToken(
      server.canonicalId,
      const McpOAuthToken(accessToken: 'seed', refreshToken: 'r'),
    );

    await app.uninstallPlugin(plugin);

    expect(app.mcpServers.any((e) => e.name == 'wave2-owned-mcp'), isFalse);
    expect(McpService.I.mcpOAuthConfigFor(server.canonicalId), isNull);
    expect(await McpService.I.mcpOAuthTokenFor(server.canonicalId), isNull);
  });

  test('disable (toggleMcpServer off) retains OAuth config + token',
      () async {
    final app = AppState.I;
    final row = await _seedCustomMcp(app, name: 'wave2-disable-retains');
    // Simulate the row being connected so toggle flips it off (disconnect).
    row.connected = true;
    app.toggleMcpServer(row);
    // `toggleMcpServer` schedules disconnect via unawaited; drain
    // microtasks + any pending disconnect work so the assertion is stable.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(row.connected, isFalse);
    // Durability: OAuth sidecars survive a disable. Only remove drops them.
    expect(McpService.I.mcpOAuthConfigFor(row.canonicalId), isNotNull);
    expect(await McpService.I.mcpOAuthTokenFor(row.canonicalId), isNotNull);
  });

  test('failed OAuth-config write rolls the imported MCP row back', () async {
    final app = AppState.I;
    // Inject a failing write for every candidate id — the handler must
    // detect it and remove the row we optimistically added.
    AppState.mcpOAuthWriteOverrideForTest = (_, _) async {
      throw StateError('simulated secure-store failure');
    };

    final msg = app.mergeMarketplaceCatalogForTest({
      'mcpServers': [
        {
          'name': 'wave2-rollback',
          'command': 'npx',
          'args': ['-y', 'rb'],
          'oauth': {
            'authorization_url': 'https://auth.example.com/authorize',
            'token_url': 'https://auth.example.com/token',
            'client_id': 'fixture-client',
          },
        },
      ],
    }, 'wave2', 'repo');
    // The merge path optimistically reports success — the rollback is
    // visible after draining the queued write.
    expect(msg, contains('Imported'));
    expect(app.mcpServers.any((e) => e.name == 'wave2-rollback'), isTrue);

    await app.awaitPendingMcpOAuthImports();

    // After the failed write, the row is gone and no OAuth sidecar lingers.
    expect(app.mcpServers.any((e) => e.name == 'wave2-rollback'), isFalse);
    // The injected override threw before touching McpService at all, so
    // no sidecar was ever registered.
    final canonicalId = 'wave2-rollback';
    expect(McpService.I.mcpOAuthConfigFor(canonicalId), isNull);
    expect(await McpService.I.mcpOAuthTokenFor(canonicalId), isNull);
  });

  test('remove racing in-flight OAuth import drains before dropping sidecars',
      () async {
    final app = AppState.I;
    // Hold the write open until we trigger the race, then release.
    final gate = Completer<void>();
    final entered = Completer<void>();
    AppState.mcpOAuthWriteOverrideForTest = (key, cfg) async {
      if (!entered.isCompleted) entered.complete();
      await gate.future;
      // Delegate to the real sidecar so the removal still has state to drop.
      await McpService.I.setMcpOAuthConfig(key, cfg);
    };

    app.mergeMarketplaceCatalogForTest({
      'mcpServers': [
        {
          'name': 'wave2-race',
          'command': 'npx',
          'args': const ['-y', 'race'],
          'oauth': {
            'authorization_url': 'https://auth.example.com/authorize',
            'client_id': 'fixture-client',
          },
        },
      ],
    }, 'wave2', 'repo');
    final row = app.mcpServers.firstWhere((e) => e.name == 'wave2-race');
    await entered.future;
    // Kick off removal while the write is still parked. It must await the
    // in-flight write (even on success) before dropping the sidecars.
    final removing = app.removeMcpServer(row);
    // Release the write first — the config lands.
    gate.complete();
    await removing;

    expect(app.mcpServers.any((e) => e.name == 'wave2-race'), isFalse);
    expect(McpService.I.mcpOAuthConfigFor(row.canonicalId), isNull);
    expect(await McpService.I.mcpOAuthTokenFor(row.canonicalId), isNull);
  });
}
