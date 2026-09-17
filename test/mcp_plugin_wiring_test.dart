import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Catalog plugin rows that name a real MCP server must wire to it:
/// Install connects the server, and the probe reports the proxy tool —
/// never a fake success followed by a Failed status on back navigation.
void main() {
  McpServer server(String name) => McpServer(
    name: name,
    author: 'test',
    description: 'test server',
    category: 'Custom',
    command: 'echo',
    custom: true,
  );

  PluginItem row(String name) => PluginItem(
    name: name,
    author: 'mcp-community',
    description: 'test',
    version: '1.0.0',
    category: 'MCP',
  );

  tearDown(() {
    AppState.I.mcpServers.clear();
  });

  test('plugin display names normalize to server keys', () {
    expect(
      AgentService.mcpServerKeyForPluginForTest('Puppeteer MCP'),
      'puppeteer',
    );
    expect(
      AgentService.mcpServerKeyForPluginForTest('Postgres Tools'),
      'postgres',
    );
    expect(
      AgentService.mcpServerKeyForPluginForTest('Playwright MCP'),
      'playwright',
    );
    expect(
      AgentService.mcpServerKeyForPluginForTest('MCP Server Hub'),
      'mcp_server_hub',
    );
  });

  test('mapped row with a matching server routes to server connect', () {
    AppState.I.mcpServers.add(server('Puppeteer'));
    final route = pluginInstallRouteForTest(row('Puppeteer MCP'));
    expect(route.kind, PluginInstallKind.mcpServer);
    expect(route.server?.name, 'Puppeteer');
  });

  test('mapped row without a matching server stays honestly unsupported',
      () {
    final route = pluginInstallRouteForTest(row('Puppeteer MCP'));
    expect(route.kind, PluginInstallKind.unsupported);
  });

  test('exact server names still match, suffix or not', () {
    AppState.I.mcpServers.add(server('X MCP'));
    expect(
      pluginInstallRouteForTest(row('X MCP')).kind,
      PluginInstallKind.mcpServer,
    );
    AppState.I.mcpServers.removeWhere((s) => s.name == 'X MCP');
    AppState.I.mcpServers.add(server('Puppeteer'));
    expect(
      pluginInstallRouteForTest(row('Puppeteer MCP')).kind,
      PluginInstallKind.mcpServer,
    );
  });

  test('installed mapped row probes the proxy tool, not failure', () {
    AppState.I.mcpServers.add(server('Postgres'));
    final p = row('Postgres Tools')
      ..installed = true
      ..enabled = true;
    expect(
      AgentService.I.pluginToolNames(p),
      contains('mcp (proxy)'),
    );
  });

  test('backing-less inbuilt row never routes to direct install', () {
    // 'MCP Server Hub' ships with the app but has no executable backing:
    // Install must not flip flags that later probe red.
    final mcpHub = PluginItem(
      name: 'MCP Server Hub',
      author: 'modelcontextprotocol',
      description: 'test',
      version: '1.0.0',
      category: 'MCP',
    );
    expect(
      pluginInstallRouteForTest(mcpHub).kind,
      PluginInstallKind.unsupported,
    );
    final gitBench = PluginItem(
      name: 'Git Workbench',
      author: 'ovidai',
      description: 'test',
      version: '1.0.0',
      category: 'Tool',
    );
    // NP3 Task 4: boot wiring registers the sandbox-backed Git Workbench
    // capability, so it routes through the NP1 native-capability install
    // truth instead of unsupported.
    registerAllNativePlugins();
    addTearDown(NativePluginRegistry.I.clearForTest);
    expect(
      pluginInstallRouteForTest(gitBench).kind,
      PluginInstallKind.nativeCapability,
    );
  });

  test('real seeds keep direct install', () {
    for (final name in [
      'Web Search',
      'Image Studio',
      'File Reader',
      'Web Fetch & Reader',
      'Code Runner',
      'RAG Memory',
      'DeepThink Reasoning',
      'Sandbox Runtime',
    ]) {
      final p = PluginItem(
        name: name,
        author: 'ovidai',
        description: 'test',
        version: '1.0.0',
        category: 'Tool',
      );
      expect(
        pluginInstallRouteForTest(p).kind,
        PluginInstallKind.builtinDirect,
        reason: '$name must stay directly installable',
      );
    }
  });

  test('hydrate heals fake installed flags on backing-less seeds', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    var app = AppState.createForTest();
    await app.initialize();
    final fake = app.plugins.firstWhere((p) => p.name == 'MCP Server Hub');
    fake.installed = true;
    fake.enabled = true;
    await app.persistPluginState();
    AppState.resetTestInstance();

    app = AppState.createForTest();
    await app.initialize();
    addTearDown(() => AppState.resetTestInstance());
    final reloaded = app.plugins.firstWhere(
      (p) => p.name == 'MCP Server Hub',
    );
    expect(reloaded.installed, isFalse);
    expect(reloaded.enabled, isFalse);
  });
}
