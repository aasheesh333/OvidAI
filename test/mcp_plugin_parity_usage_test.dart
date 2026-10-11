// PR-4b — MCP/plugin parity + usage tracking (F-092…F-103).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/native_mcp.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/plugin_user_config.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/tool_usage_store.dart';
import 'package:ovid_ai/ui/mcp_server_add_form.dart';
import 'package:ovid_ai/ui/plugin_install_progress.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

class _TwoToolHandler implements NativeMcpHandler {
  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async =>
      {
        'protocolVersion': '2025-06-18',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'two', 'version': '1'},
      };

  @override
  Future<List<McpToolDef>> listTools() async => [
    McpToolDef(
      name: 'search_docs',
      description: 'Search the docs',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'What to find'},
        },
        'required': ['query'],
      },
    ),
    McpToolDef(name: 'fail_tool', description: 'Always fails'),
  ];

  @override
  Future<McpRpcResult> callTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    if (toolName == 'fail_tool') return McpRpcResult.error('boom');
    return McpRpcResult.ok({
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    });
  }

  @override
  Future<void> dispose() async {}
}

McpServer _native(String name) => McpServer(
  name: name,
  author: 'test',
  description: 'fixture',
  category: 'Custom',
  command: '',
  transport: 'native',
  custom: true,
);

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: home));
  await tester.pump();
}

Future<void> _frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    ToolUsageStore.I.resetForTest();
    ToolUsageStore.saveDelayForTest = Duration.zero;
    McpService.I.clearNativeHandlers();
  });

  tearDown(() async {
    await McpService.I.disconnectAll();
    McpService.I.clearNativeHandlers();
    mcpAddConnectOverrideForTest = null;
    pluginUserConfigReaderForTest = null;
    ToolUsageStore.I.resetForTest();
    HookService.I.resetForTest();
    AppState.resetTestInstance();
  });

  group('Add MCP server sheet (F-092)', () {
    Future<List<String>> openMcpTab(WidgetTester tester) async {
      final connected = <String>[];
      mcpAddConnectOverrideForTest = (_, s) async => connected.add(s.name);
      await _pump(
        tester,
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showPluginAddSheet(ctx, initialTab: PluginAddTab.mcp),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _frames(tester);
      expect(find.byType(McpServerAddForm), findsOneWidget);
      return connected;
    }

    Future<void> submit(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const ValueKey('mcp-add-submit')));
      await tester.tap(find.byKey(const ValueKey('mcp-add-submit')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _frames(tester);
    }

    testWidgets('Command mode adds a stdio server with env, then connects', (
      tester,
    ) async {
      final connected = await openMcpTab(tester);
      await tester.enterText(find.byKey(const ValueKey('mcp-add-name')), 'mem');
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-command')),
        'npx -y "@modelcontextprotocol/server-memory"',
      );
      await tester.tap(find.byKey(const ValueKey('mcp-add-env-add-row')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-env-key-0')),
        'API_KEY',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-env-value-0')),
        'secret-1',
      );
      await submit(tester);
      final s = AppState.I.mcpServers.singleWhere((s) => s.name == 'mem');
      expect(s.transport, 'stdio');
      expect(s.command, 'npx');
      expect(s.args, ['-y', '@modelcontextprotocol/server-memory']);
      expect(s.custom, isTrue);
      expect(await AppState.I.getMcpEnv('mem'), {'API_KEY': 'secret-1'});
      expect(connected, ['mem']);
      expect(find.byType(McpServerAddForm), findsNothing);
    });

    testWidgets('Remote mode adds an http server with headers, then connects', (
      tester,
    ) async {
      final connected = await openMcpTab(tester);
      await tester.tap(find.text('Remote'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('mcp-add-name')), 'docs');
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-url')),
        'https://mcp.example.com/mcp',
      );
      await tester.tap(find.byKey(const ValueKey('mcp-add-header-add-row')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-header-key-0')),
        'Authorization',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-header-value-0')),
        'Bearer t',
      );
      await submit(tester);
      final s = AppState.I.mcpServers.singleWhere((s) => s.name == 'docs');
      expect(s.transport, 'http');
      expect(s.url, 'https://mcp.example.com/mcp');
      expect(s.headers, {'Authorization': 'Bearer t'});
      expect(await AppState.I.getMcpHeaders('docs'), {
        'Authorization': 'Bearer t',
      });
      expect(connected, ['docs']);
    });

    testWidgets('Paste JSON previews ignoredKeys and adds every entry', (
      tester,
    ) async {
      final connected = await openMcpTab(tester);
      await tester.tap(find.text('Paste JSON'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-json')),
        jsonEncode({
          'mcpServers': {
            'alpha': {
              'command': 'uvx',
              'args': ['alpha-mcp'],
              'env': {'TOKEN': 'abc'},
              'disabled': false,
            },
            'beta': {'type': 'http', 'url': 'https://beta.example.com/mcp'},
          },
        }),
      );
      await tester.tap(find.byKey(const ValueKey('mcp-add-json-preview')));
      await tester.pump();
      expect(find.byKey(const ValueKey('mcp-add-preview-alpha')), findsOneWidget);
      expect(find.byKey(const ValueKey('mcp-add-preview-beta')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('mcp-add-ignored-alpha')),
        findsOneWidget,
      );
      expect(find.textContaining('Ignored keys: disabled'), findsOneWidget);
      await submit(tester);
      final alpha = AppState.I.mcpServers.singleWhere((s) => s.name == 'alpha');
      final beta = AppState.I.mcpServers.singleWhere((s) => s.name == 'beta');
      expect(alpha.command, 'uvx');
      expect(beta.transport, 'http');
      expect(await AppState.I.getMcpEnv('alpha'), {'TOKEN': 'abc'});
      expect(connected, ['alpha', 'beta']);
    });

    testWidgets('a duplicate name is refused inline and nothing connects', (
      tester,
    ) async {
      AppState.I.mcpServers.add(_native('taken'));
      final connected = await openMcpTab(tester);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-add-name')),
        'taken',
      );
      await tester.enterText(find.byKey(const ValueKey('mcp-add-command')), 'x');
      await submit(tester);
      expect(find.textContaining('already exists'), findsOneWidget);
      expect(connected, isEmpty);
    });

    test('command lines split with quotes and escapes', () {
      expect(splitCommandLine(r'npx -y "@a/b c" ' "'d e'" r' f\ g'), [
        'npx',
        '-y',
        '@a/b c',
        'd e',
        'f g',
      ]);
    });
  });

  group('MCP detail tools + usage (F-093)', () {
    testWidgets('a connected server with two tools renders "Tools (2)"', (
      tester,
    ) async {
      McpService.I.registerNativeHandler('two', (_) => _TwoToolHandler());
      final s = _native('two');
      AppState.I.mcpServers.add(s);
      await tester.runAsync(() async {
        final outcome = await McpService.I.connectOutcome(
          s,
          handshakeBudget: const Duration(seconds: 5),
        );
        expect(outcome.kind, McpConnectOutcomeKind.ready);
        await McpService.I.callTool('two', 'search_docs', {'query': 'x'});
        await McpService.I.callTool('two', 'fail_tool', {});
      });
      s.connected = true;
      await _pump(tester, McpDetailScreen(server: s));
      await tester.scrollUntilVisible(
        find.text('Tools (2)'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Tools (2)'), findsOneWidget);
      expect(find.text('search_docs'), findsOneWidget);
      expect(find.text('fail_tool'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mcp-usage-two')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('2'), findsWidgets); // Calls
      expect(find.textContaining('1 (50%)'), findsOneWidget); // Failures
      // Last failed call surfaces the server's error.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mcp-last-error-two')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('boom'), findsWidgets);
    });

    testWidgets('a disconnected server says to connect to list tools', (
      tester,
    ) async {
      final s = _native('idle');
      AppState.I.mcpServers.add(s);
      await _pump(tester, McpDetailScreen(server: s));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('mcp-tools-disconnected-idle')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('Connect the server'), findsOneWidget);
    });

    test('schema preview lists properties with type, required marker', () {
      final text = mcpSchemaPreview({
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'What'},
          'limit': {'type': 'integer'},
        },
        'required': ['query'],
      });
      expect(text, contains('query*: string — What'));
      expect(text, contains('limit: integer'));
      expect(mcpSchemaPreview(null), 'No parameters');
    });
  });

  group('ToolUsageStore rollups (usage tracking)', () {
    test('count, errors, p50/p95, last used and last error', () {
      final store = ToolUsageStore.I;
      final now = DateTime(2026, 10, 11, 12);
      ToolUsageStore.clockForTest = () => now;
      for (var i = 1; i <= 20; i++) {
        store.record(
          kind: ToolUsageKind.mcp,
          tool: 't',
          mcpServerId: 'srv',
          ok: i != 7,
          elapsed: Duration(milliseconds: i * 10),
          error: i == 7 ? 'bad input' : null,
        );
      }
      final u = store.summary(mcpServerId: 'srv');
      expect(u.calls, 20);
      expect(u.errors, 1);
      expect(u.p50Ms, 100);
      expect(u.p95Ms, 190);
      expect(u.avgMs, 105);
      expect(u.lastUsed, now);
      expect(u.lastError, 'bad input');
      expect(store.summary(mcpServerId: 'other').isEmpty, isTrue);
    });

    test('rollups are per day, filtered by window, and persisted', () async {
      final store = ToolUsageStore.I;
      var now = DateTime(2026, 10, 1, 9);
      ToolUsageStore.clockForTest = () => now;
      store.record(
        kind: ToolUsageKind.pluginTool,
        tool: 'review',
        pluginId: 'acme/kit',
        ok: true,
        elapsed: const Duration(milliseconds: 5),
      );
      now = DateTime(2026, 10, 11, 9);
      store.record(
        kind: ToolUsageKind.mcp,
        tool: 'q',
        pluginId: 'acme/kit',
        mcpServerId: 'acme/kit/srv',
        ok: false,
        elapsed: const Duration(milliseconds: 15),
      );
      expect(store.summary(pluginId: 'acme/kit').calls, 2);
      expect(store.summary(pluginId: 'acme/kit', days: 1).calls, 1);
      expect(
        store.toolSummaries(pluginId: 'acme/kit').keys,
        containsAll(['review', 'q']),
      );
      await store.flush();
      final saved = (await SharedPreferences.getInstance()).getString(
        ToolUsageStore.prefsKey,
      );
      expect(saved, isNotNull);
      store.resetForTest();
      ToolUsageStore.clockForTest = () => now;
      expect(store.summary(pluginId: 'acme/kit').calls, 0);
      await store.load();
      expect(store.summary(pluginId: 'acme/kit').calls, 2);
    });

    test('rollups older than the retention window are dropped', () {
      final store = ToolUsageStore.I;
      var now = DateTime(2026, 8, 1);
      ToolUsageStore.clockForTest = () => now;
      store.record(
        kind: ToolUsageKind.mcp,
        tool: 'old',
        mcpServerId: 's',
        ok: true,
        elapsed: Duration.zero,
      );
      now = DateTime(2026, 10, 11);
      store.record(
        kind: ToolUsageKind.mcp,
        tool: 'new',
        mcpServerId: 's',
        ok: true,
        elapsed: Duration.zero,
      );
      expect(store.toolSummaries(mcpServerId: 's').keys, ['new']);
    });

    test('McpService.callTool records each call under the server', () async {
      McpService.I.registerNativeHandler('two', (_) => _TwoToolHandler());
      final s = _native('two');
      AppState.I.mcpServers.add(s);
      await McpService.I.connectOutcome(
        s,
        handshakeBudget: const Duration(seconds: 5),
      );
      await McpService.I.callTool('two', 'search_docs', {'query': 'x'});
      await McpService.I.callTool('two', 'fail_tool', {});
      final tools = ToolUsageStore.I.toolSummaries(mcpServerId: 'two');
      expect(tools['search_docs']!.calls, 1);
      expect(tools['search_docs']!.errors, 0);
      expect(tools['fail_tool']!.errors, 1);
    });
  });

  group('per-plugin hook counters (F-094) + plugin settings env (F-095)', () {
    void register(String id, String payload) {
      PluginContributionRegistry.I.register(
        NormalizedPluginManifest(
          id: id,
          name: id.split('/').last,
          version: '1.0.0',
          format: PluginFormat.claudeCode,
          rootPath: '/plugin',
          hooks: [
            PluginHook(
              pluginId: id,
              event: 'pre_tool',
              ordinal: 0,
              type: 'command',
              payload: payload,
              timeoutS: 5,
            ),
          ],
        ),
        activation: PluginActivation.globalActive,
      );
    }

    tearDown(() {
      for (final id in ['acme/good', 'acme/bad', 'acme/opts']) {
        PluginContributionRegistry.I.unregisterPlugin(id);
      }
    });

    test('two plugins, one failing hook — only that plugin counts it', () async {
      register('acme/good', 'good-hook');
      register('acme/bad', 'bad-hook');
      HookService.I.executorForTest = (cmd, env) async {
        if (cmd.contains('bad-hook')) throw StateError('bad exploded');
        return '';
      };
      await HookService.I.fire('pre_tool', 's1', payload: {'tool': 'file_read'});
      final good = HookService.I.statsFor('acme/good')!;
      final bad = HookService.I.statsFor('acme/bad')!;
      expect(good.fired, 1);
      expect(good.failed, 0);
      expect(bad.fired, 1);
      expect(bad.failed, 1);
      expect(bad.lastError, contains('bad exploded'));
      // The boot-global totals still include both.
      expect(HookService.I.fired, 2);
      expect(HookService.I.failed, 1);
    });

    testWidgets('plugin diagnostics show only that plugin\'s hook failures', (
      tester,
    ) async {
      register('acme/good', 'good-hook');
      register('acme/bad', 'bad-hook');
      HookService.I.executorForTest = (cmd, env) async {
        if (cmd.contains('bad-hook')) throw StateError('bad exploded');
        return '';
      };
      await tester.runAsync(
        () => HookService.I.fire(
          'pre_tool',
          's1',
          payload: {'tool': 'file_read'},
        ),
      );
      PluginItem row(String id) => PluginItem(
        name: id,
        author: 'acme',
        description: 'fixture',
        version: '1.0.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        runtimeId: id,
      );
      Future<String> statsText(String id) async {
        await _pump(tester, PluginDetailScreen(plugin: row(id)));
        final f = find.byKey(ValueKey('plugin-hook-stats-$id'));
        await tester.scrollUntilVisible(
          f,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        return tester
            .widgetList<Text>(find.descendant(of: f, matching: find.byType(Text)))
            .map((t) => t.data ?? '')
            .join(' | ');
      }

      final bad = await statsText('acme/bad');
      expect(bad, contains('failed 1'));
      expect(bad, contains('bad exploded'));
      final good = await statsText('acme/good');
      expect(good, contains('fired 1, failed 0'));
      expect(good, isNot(contains('bad exploded')));
    });

    test('saved settings reach hooks as CLAUDE_PLUGIN_OPTION_<KEY>', () async {
      register('acme/opts', r'run --key "${user_config.api_key}"');
      pluginUserConfigReaderForTest = (id) async =>
          id == 'acme/opts' ? {'api_key': 'k-123'} : {};
      String? seenCmd;
      Map<String, String>? seenEnv;
      HookService.I.executorForTest = (cmd, env) async {
        seenCmd = cmd;
        seenEnv = env;
        return '';
      };
      await HookService.I.fire('pre_tool', 's1', payload: {'tool': 'file_read'});
      expect(seenEnv?['CLAUDE_PLUGIN_OPTION_API_KEY'], 'k-123');
      // The value is never spliced into the shell string.
      expect(seenCmd, contains(r'${CLAUDE_PLUGIN_OPTION_API_KEY}'));
      expect(seenCmd, isNot(contains('k-123')));
    });

    test('saved settings reach the plugin MCP env and args', () async {
      register('acme/opts', 'noop');
      pluginUserConfigReaderForTest = (id) async =>
          id == 'acme/opts' ? {'api_key': 'k-123', 'region': 'eu'} : {};
      final server = McpServer(
        name: 'srv',
        ownerPluginId: 'acme/opts',
        author: 'acme',
        description: '',
        category: 'Plugin',
        command: 'node',
        args: [r'--region=${user_config.region}'],
        custom: true,
      );
      AppState.I.mcpServers.add(server);
      List<String>? argv;
      Map<String, String>? spawnEnv;
      McpService.spawnProcessForTest = (a, {env, hostWorkDir}) async {
        argv = a;
        spawnEnv = env;
        throw const ProcessException('fake', [], 'stop after spawn');
      };
      McpService.missingRuntimeOverrideForTest = (_) async => null;
      addTearDown(() {
        McpService.spawnProcessForTest = null;
        McpService.missingRuntimeOverrideForTest = null;
      });
      await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(spawnEnv?['CLAUDE_PLUGIN_OPTION_API_KEY'], 'k-123');
      expect(spawnEnv?['CLAUDE_PLUGIN_OPTION_REGION'], 'eu');
      expect(argv, ['node', '--region=eu']);
      // The persisted row keeps the template.
      expect(server.args, [r'--region=${user_config.region}']);
    });

    test('option env names and substitution', () {
      expect(pluginOptionEnvName('api-key'), 'CLAUDE_PLUGIN_OPTION_API_KEY');
      expect(
        substituteUserConfig(r'a ${user_config.x} ${user_config.y}', {'x': '1'}),
        r'a 1 ${user_config.y}',
      );
    });
  });

  group('PluginsScreen filtering + sync (F-097, F-098)', () {
    testWidgets('search "zzz" renders no McpCard; Agent chip hides MCP', (
      tester,
    ) async {
      final app = AppState.I;
      app.mcpServers
        ..clear()
        ..add(_native('slack'));
      await _pump(tester, const PluginsScreen());
      await _frames(tester);
      expect(find.byType(McpCard), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'zzz');
      await _frames(tester);
      expect(find.byType(McpCard), findsNothing);
      expect(find.byKey(const ValueKey('mcp-section-no-match')), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'sla');
      await _frames(tester);
      expect(find.byType(McpCard), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Agent'));
      await _frames(tester);
      expect(find.byType(McpCard), findsNothing);
      expect(find.text('CONNECTED TOOLS · MCP SERVERS'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'MCP'));
      await _frames(tester);
      expect(find.byType(McpCard), findsOneWidget);
    });

    testWidgets('a failed marketplace sync shows the banner with Retry', (
      tester,
    ) async {
      final app = AppState.I;
      app.marketplaces
        ..clear()
        ..add('acme/missing');
      AppState.marketplaceBaseOverrideForTest = 'http://127.0.0.1:9';
      addTearDown(() => AppState.marketplaceBaseOverrideForTest = null);
      await _pump(tester, const PluginsScreen());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await _frames(tester);
      expect(find.byKey(const ValueKey('marketplace-sync-banner')), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
      expect(app.marketplaceSyncErrors['acme/missing'], isNotNull);
    });
  });

  group('marketplace + source input (F-099, F-100)', () {
    test('GitHub inputs parse into owner/repo/ref/subPath', () {
      GithubPluginSource src(String s) => parseGithubSourceInput(s).source!;
      expect(src('github.com/o/r').owner, 'o');
      expect(src('github.com/o/r').repo, 'r');
      expect(src('https://github.com/o/r.git').repo, 'r');
      final tree = src('https://github.com/o/r/tree/main/plugins/foo');
      expect(tree.ref, 'main');
      expect(tree.subPath, 'plugins/foo');
      expect(src('git@github.com:o/r.git').repo, 'r');
      expect(src('o/r@v1.2').ref, 'v1.2');
      expect(src('o/r#dev').ref, 'dev');
      expect(parseGithubSourceInput('o/r/extra').source, isNull);
      expect(parseGithubSourceInput('o/r/extra').error, contains('/extra'));
      expect(
        parseGithubSourceInput('https://gitlab.com/o/r').error,
        contains('Only GitHub'),
      );
      expect(parseGithubSourceInput('').source, isNull);
    });

    test('addMarketplace reports invalid vs duplicate', () {
      final app = AppState.I;
      app.marketplaces.clear();
      final ok = app.addMarketplaceChecked('https://github.com/acme/market.git');
      expect(ok.repo, 'acme/market');
      expect(
        app.addMarketplaceChecked('acme/market').error,
        MarketplaceAddError.duplicate,
      );
      expect(
        app.addMarketplaceChecked('not a repo').error,
        MarketplaceAddError.invalid,
      );
      expect(
        app.addMarketplaceChecked('acme/market/extra').error,
        MarketplaceAddError.invalid,
      );
    });

    testWidgets('the sheet shows the duplicate-specific message', (
      tester,
    ) async {
      AppState.I.marketplaces
        ..clear()
        ..add('acme/market');
      await _pump(
        tester,
        Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => showPluginAddSheet(ctx),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _frames(tester);
      await tester.enterText(find.byType(TextField).first, 'acme/market');
      await tester.tap(find.text('Add marketplace'));
      await _frames(tester);
      expect(find.text('That marketplace is already added.'), findsOneWidget);
    });
  });

  group('install failures and outcomes (F-101, F-102, F-103)', () {
    test('raw exceptions map to readable copy', () {
      expect(
        describeInstallFailure(const SocketException('Failed host lookup')),
        contains('offline'),
      );
      expect(
        describeInstallFailure('PluginSourceException: HTTP 403 rate limit'),
        contains('rate limit'),
      );
      expect(
        describeInstallFailure('GitHub tree unreachable for o/r (tried main)'),
        contains("Couldn't find that repository"),
      );
      expect(
        describeInstallFailure(const FormatException('bad')),
        isNot(contains('FormatException')),
      );
    });

    test('outcomes come from the result record, incl. probe failures', () {
      final ok = describeInstallOutcome(
        const PluginInstallResult(
          status: PluginInstallStatus.ok,
          record: PluginActivationRecord(
            pluginId: 'a/b',
            state: PluginActivation.sessionActive,
          ),
        ),
      );
      expect(ok.outcome, InstallOutcome.success);
      expect(ok.summary, contains('Active in this chat'));
      expect(ok.summary, isNot(contains('restart')));
      final degraded = describeInstallOutcome(
        const PluginInstallResult(
          status: PluginInstallStatus.degraded,
          degradedNames: ['sharp'],
          probeFailures: ['commands/x.md'],
        ),
      );
      expect(degraded.outcome, InstallOutcome.degraded);
      expect(degraded.summary, contains('sharp'));
      expect(degraded.summary, contains('commands/x.md'));
      final failed = describeInstallOutcome(
        const PluginInstallResult.failed(
          error: 'source resolution failed: SocketException: refused',
        ),
      );
      expect(failed.outcome, InstallOutcome.failed);
      expect(failed.summary, isNot(contains('SocketException')));
      expect(failed.details, contains('SocketException'));
      expect(
        describeInstallOutcome(null).outcome,
        InstallOutcome.cancelled,
      );
    });

    testWidgets('degraded renders amber "Installed with warnings"', (
      tester,
    ) async {
      final p = PluginInstallProgress()
        ..finish(outcome: InstallOutcome.degraded, summary: 'warn');
      addTearDown(p.dispose);
      await _pump(
        tester,
        Scaffold(body: PluginInstallProgressSheet(progress: p, title: 'x')),
      );
      expect(p.phase, 'Installed with warnings');
      expect(find.byKey(const ValueKey('install-result-degraded')), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsWidgets);
    });

    testWidgets('cancelled renders neutral, with no error icon', (tester) async {
      final p = PluginInstallProgress()
        ..finish(outcome: InstallOutcome.cancelled, summary: 'nothing changed');
      addTearDown(p.dispose);
      await _pump(
        tester,
        Scaffold(body: PluginInstallProgressSheet(progress: p, title: 'x')),
      );
      expect(find.byKey(const ValueKey('install-result-cancelled')), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(find.byIcon(Icons.info_outline), findsWidgets);
    });

    test('install is never reported as started before approval', () async {
      var approved = false;
      final result = await startPluginInstallForTest(
        AppState.I,
        null,
        source: const LocalFolderPluginSource('/nonexistent/plugin/dir'),
        onApproved: () => approved = true,
      );
      expect(result?.status, PluginInstallStatus.failed);
      expect(approved, isFalse);
    });
  });
}
