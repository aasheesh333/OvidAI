// v2-07: slim + premium plugins surface contract.
//
// Pins the v2 redesign of the plugins surface WITHOUT behavior change:
//   1. the installed/available card renders exactly ONE status pill
//      (no 7-tag stacks) + name + one supporting line;
//   2. BOTH the plugin detail and the MCP detail route through the shared
//      [IntegrationDetailScaffold] — header → Overview → Config → Status
//      (ONE health line) → Logs (shared ProgressLogView);
//   3. the card enable toggle still routes through the enable/disable
//      lifecycle + service probe (contract preserved);
//   4. the single add sheet still opens from the AppBar "+";
//   5. the screen survives 360×640 @ 2× text in light and dark.
//
// Bounded pumps/runAsync only — no pumpAndSettle against ambient async.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/integration_detail.dart';
import 'package:ovid_ai/ui/plugin_install_progress.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    app.plugins.clear();
    app.mcpServers.clear();
    app.marketplaces.clear();
  });

  tearDown(() {
    PluginRuntimeCallRecorderForTest.record = null;
    AppState.resetTestInstance();
    Aether.dark = true;
  });

  PluginItem plugin(
    String name, {
    bool installed = false,
    bool enabled = false,
    String category = 'Tool',
  }) => PluginItem(
    name: name,
    author: 'fixture',
    description: 'fixture $name description',
    version: '1.0.0',
    category: category,
    installed: installed,
    enabled: enabled,
  );

  McpServer server(String name) => McpServer(
    name: name,
    author: 'fixture',
    description: 'fixture $name description',
    category: 'Custom',
    command: '',
    transport: 'http',
    url: 'https://example.test/mcp',
    custom: true,
  );

  group('slim cards', () {
    testWidgets('installed card renders exactly one status pill', (
      tester,
    ) async {
      final p = plugin('V2 Tool', installed: true, enabled: true);
      app.plugins.add(p);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: p)),
        ),
      );
      await tester.pump();

      final card = find.byType(PluginCard);
      expect(
        find.descendant(of: card, matching: find.byType(PluginStatusPill)),
        findsOneWidget,
        reason: 'the v2 card carries exactly ONE status pill',
      );
      // No 7-tag stacks: category/format/hook Tags are gone from the card.
      expect(
        find.descendant(of: card, matching: find.byType(Tag)),
        findsNothing,
      );
      // Pill + name + ONE supporting line — the description stays on the
      // detail page.
      expect(find.text('Installed · enabled'), findsOneWidget);
      expect(find.text('V2 Tool'), findsOneWidget);
      expect(find.text('fixture · v1.0.0'), findsOneWidget);
      expect(find.text('fixture V2 Tool description'), findsNothing);
      // Lifecycle controls preserved on the installed card.
      expect(find.byKey(const ValueKey('plugin-switch-V2 Tool')), findsOneWidget);
      expect(find.byKey(const ValueKey('plugin-delete-V2 Tool')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('available card renders one pill and no lifecycle switch', (
      tester,
    ) async {
      final p = plugin('V2 Catalog');
      app.plugins.add(p);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: p)),
        ),
      );
      await tester.pump();

      final card = find.byType(PluginCard);
      expect(
        find.descendant(of: card, matching: find.byType(PluginStatusPill)),
        findsOneWidget,
      );
      expect(find.text('Available'), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('slim card still shows the durable reason on its one line', (
      tester,
    ) async {
      final p = plugin('V2 Legacy', installed: true)
        ..migrationRequired = true
        ..runtimeReason = 'Re-approve this legacy plugin before it can run';
      app.plugins.add(p);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: p)),
        ),
      );
      await tester.pump();

      final card = find.byType(PluginCard);
      expect(
        find.descendant(of: card, matching: find.byType(PluginStatusPill)),
        findsOneWidget,
      );
      // Durable status outranks availability on the one supporting line.
      expect(
        find.textContaining('Migration required'),
        findsWidgets,
      );
      expect(
        find.textContaining('Re-approve this legacy plugin'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('shared integration detail', () {
    testWidgets('plugin detail renders the shared sections', (tester) async {
      final p = plugin('V2 Detail', installed: true, enabled: true);
      app.plugins.add(p);

      // Tall surface: the detail ListView builds children lazily, and the
      // section contract asserts the whole flow (Overview → … → Changelog).
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: PluginDetailScreen(plugin: p)),
      );
      await _frames(tester);

      expect(find.byType(IntegrationDetailScaffold), findsOneWidget);
      // header (icon, name, enable switch, ⋯ actions) → Overview → Config →
      // Status (ONE health line) → Logs → trailing.
      expect(find.byKey(const ValueKey('plugin-detail-switch-V2 Detail')), findsOneWidget);
      expect(find.byKey(const ValueKey('plugin-detail-delete-V2 Detail')), findsOneWidget);
      expect(find.text('OVERVIEW'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      // A legacy row has no durable record: the neutral no-record copy is
      // the ONE health line — rendered exactly once.
      expect(find.text('Not started'), findsOneWidget);
      expect(find.text('LOGS'), findsOneWidget);
      expect(find.byType(ProgressLogView), findsOneWidget);
      expect(find.text('PERMISSIONS'), findsOneWidget);
      expect(find.text('CHANGELOG'), findsOneWidget);
      // Lifecycle actions preserved.
      expect(find.widgetWithText(FilledButton, 'Disable'), findsOneWidget);
      expect(find.text('Uninstall'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('MCP detail renders the shared sections', (tester) async {
      final s = server('V2 MCP');
      app.mcpServers.add(s);

      // Tall surface: the detail ListView builds children lazily, and the
      // section contract asserts the whole flow (Overview → … → Runtime).
      await tester.binding.setSurfaceSize(const Size(900, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: McpDetailScreen(server: s)),
      );
      await _frames(tester);

      expect(find.byType(IntegrationDetailScaffold), findsOneWidget);
      expect(
        find.byKey(ValueKey('mcp-detail-switch-${s.canonicalId}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('mcp-detail-delete-${s.canonicalId}')),
        findsOneWidget,
      );
      expect(find.text('OVERVIEW'), findsOneWidget);
      expect(find.text('CONFIG (STANDARD MCP.JSON)'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      // Durable-only neutral copy, exactly once (never a binary
      // connected/not-connected).
      expect(find.text('Not started'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('LOGS'), findsOneWidget);
      expect(find.byType(ProgressLogView), findsOneWidget);
      expect(find.text('RUNTIME'), findsOneWidget);
      // Connect lifecycle preserved.
      expect(find.widgetWithText(FilledButton, 'Connect server'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('behavior contracts', () {
    testWidgets('card enable toggle routes through lifecycle + service probe', (
      tester,
    ) async {
      final calls = <String>[];
      PluginRuntimeCallRecorderForTest.record = calls.add;
      final p = plugin('V2 Toggle', installed: true, enabled: true);
      app.plugins.add(p);

      Future<void> pumpCard() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: Scaffold(body: PluginCard(plugin: p)),
          ),
        );
        await tester.pump();
      }

      await pumpCard();

      final toggle = find.byKey(const ValueKey('plugin-switch-V2 Toggle'));
      await tester.tap(toggle);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _frames(tester);
      expect(calls, contains('disable'));
      expect(p.enabled, isFalse);

      // The screen rebuilds cards from AppState notifications; mirror that
      // so the re-rendered switch reads the flipped flag.
      await pumpCard();
      await tester.tap(toggle);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await _frames(tester);
      expect(calls, contains('enable'));
      expect(p.enabled, isTrue);
      // The enable path probes the service registry and records the
      // outcome — a fixture row contributes no tools, so the probe fails
      // honestly instead of claiming success.
      expect(
        app.serviceStatus['plugin:V2 Toggle']?.health,
        ServiceHealth.failed,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('add sheet opens from the AppBar +', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const PluginsScreen()),
      );
      await _frames(tester);

      await tester.tap(find.byTooltip('Add plugin or marketplace'));
      await _frames(tester);
      expect(find.text('Fetch from GitHub'), findsOneWidget);
      expect(
        find.text('owner/repo or https://github.com/owner/repo'),
        findsOneWidget,
      );
      expect(find.text('Add marketplace'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });

  group('360×640 @2x', () {
    for (final dark in [true, false]) {
      testWidgets('plugins screen survives small viewport ${dark ? 'dark' : 'light'}', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        Aether.dark = dark;
        final installed = plugin('V2 Installed Tool', installed: true, enabled: true);
        app.plugins.addAll([installed, plugin('V2 Available Tool')]);
        app.mcpServers.add(server('V2 MCP Server'));
        app.marketplaces.add('fixture/marketplace');

        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const PluginsScreen(),
          ),
        );
        await _frames(tester);

        // MCP card (top of the sliver) is immediately visible.
        expect(find.byType(McpCard), findsOneWidget);
        // The installed plugin card builds lazily — scroll it into view.
        await tester.scrollUntilVisible(
          find.text('V2 Installed Tool'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await _frames(tester, 4);
        final card = find.byType(PluginCard);
        expect(card, findsWidgets);
        expect(
          find.descendant(of: card.first, matching: find.byType(PluginStatusPill)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
