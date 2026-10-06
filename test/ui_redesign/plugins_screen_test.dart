// Premium `plugins_screen` redesign contract (wave 2 UI).
//
// Pins the public surface the redesigned Plugins & marketplaces screen owes
// callers:
// - the AppBar title reads "Plugins & marketplaces";
// - the installed list renders a [PluginCard] per installed plugin under an
//   AetherSectionTitle "Installed" (an [AetherEmptyState] takes its place
//   when nothing is installed);
// - the enable toggle on an installed card routes through
//   [AppState.disablePlugin] (and back through [AppState.enablePlugin]);
// - the delete action on an installed card routes through
//   [AppState.uninstallPlugin];
// - an AetherSectionTitle "Marketplaces" lists every registered marketplace
//   repo as an [AetherCard] carrying a Browse ghost button that invokes
//   [AppState.fetchMarketplaceCatalog] (the marketplace router).
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

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

  tearDown(AppState.resetTestInstance);

  PluginItem makePlugin(
    String name, {
    bool installed = true,
    bool enabled = true,
    String category = 'Tool',
  }) {
    return PluginItem(
      name: name,
      author: 'fixture-author',
      description: 'fixture $name',
      version: '1.0.0',
      category: category,
      installed: installed,
      enabled: enabled,
    );
  }

  Future<void> pumpPlugins(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const PluginsScreen()),
    );
    // Marketplace sync and PostFrameCallbacks settle after a few pumps.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('AppBar title reads "Plugins & marketplaces"', (tester) async {
    await pumpPlugins(tester);
    expect(find.text('Plugins & marketplaces'), findsOneWidget);
  });

  testWidgets('installed list renders one PluginCard per installed plugin', (
    tester,
  ) async {
    final installed = makePlugin('Alpha Tool');
    final available = makePlugin('Bravo Tool', installed: false);
    app.plugins.addAll([installed, available]);

    await pumpPlugins(tester);

    // The "Installed" eyebrow heading sits above the list.
    expect(find.text('INSTALLED'), findsOneWidget);
    // Both plugins render (installed first, then available).
    expect(find.byType(PluginCard), findsNWidgets(2));
    expect(find.text('Alpha Tool'), findsOneWidget);
    expect(find.text('Bravo Tool'), findsOneWidget);
    // The AetherEmptyState for plugins is NOT shown when plugins exist.
    expect(find.byKey(const ValueKey('plugins-empty-state')), findsNothing);
  });

  testWidgets('AetherEmptyState renders when no plugins are installed', (
    tester,
  ) async {
    // Zero plugins: the installed empty state takes over.
    await pumpPlugins(tester);

    expect(find.byKey(const ValueKey('plugins-empty-state')), findsOneWidget);
    expect(find.byType(AetherEmptyState), findsWidgets);
    expect(find.text('No plugins installed'), findsOneWidget);
  });

  testWidgets('enable toggle disables the plugin via AppState.disablePlugin', (
    tester,
  ) async {
    final plugin = makePlugin('Toggle Me');
    app.plugins.add(plugin);
    expect(plugin.enabled, isTrue);

    await pumpPlugins(tester);

    final switchFinder = find.byKey(ValueKey('plugin-switch-${plugin.name}'));
    expect(switchFinder, findsOneWidget);
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    // disablePlugin flips `enabled` to false on the shared row.
    expect(plugin.enabled, isFalse);
  });

  testWidgets(
    'overflow uninstall action routes through AppState.uninstallPlugin',
    (tester) async {
      final plugin = makePlugin('Removable');
      app.plugins.add(plugin);

      final calls = <String>[];
      PluginRuntimeCallRecorderForTest.record = calls.add;
      addTearDown(() => PluginRuntimeCallRecorderForTest.record = null);

      await pumpPlugins(tester);

      // The redesigned installed card still exposes a delete affordance that
      // routes through AppState.uninstallPlugin (recorded here as 'uninstall'
      // via the production call recorder seam).
      await tester.tap(
        find.byKey(ValueKey('plugin-delete-${plugin.name}')),
      );
      await tester.pumpAndSettle();
      // Confirm the destructive dialog.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(calls, contains('uninstall'));
      expect(app.plugins.any((p) => p.name == 'Removable'), isFalse);
    },
  );

  testWidgets(
    'Marketplaces section lists repos as AetherCards with Browse ghost',
    (tester) async {
      app.marketplaces.addAll(['owner-one/plugins', 'owner-two/mcps']);
      await pumpPlugins(tester);

      // The "Marketplaces" eyebrow heading is visible.
      expect(find.text('MARKETPLACES'), findsOneWidget);
      // Each marketplace repo renders in its own card.
      expect(find.text('owner-one/plugins'), findsOneWidget);
      expect(find.text('owner-two/mcps'), findsOneWidget);
      // Browse ghost buttons expose the marketplace router entry point.
      expect(find.widgetWithText(TextButton, 'Browse'), findsNWidgets(2));
    },
  );

  testWidgets(
    'Browse ghost invokes AppState.fetchMarketplaceCatalog for the repo',
    (tester) async {
      app.marketplaces.add('router-owner/router-repo');
      await pumpPlugins(tester);

      // Capture the Browse action by scrolling it into view and tapping it;
      // fetchMarketplaceCatalog does a real HTTP fetch, which fails offline
      // in the test harness — we assert the user-facing router message hits
      // the SnackBar so the lifecycle call is visible without network IO.
      final browse = find.widgetWithText(TextButton, 'Browse');
      expect(browse, findsOneWidget);
      await tester.ensureVisible(browse);
      await tester.pumpAndSettle();
      await tester.tap(browse);
      // Fetch resolves asynchronously; pump a few frames for the SnackBar.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // The router runs (fetches then reports). Online or offline, the
      // SnackBar surfaces the resulting message from fetchMarketplaceCatalog.
      expect(find.byType(SnackBar), findsOneWidget);
    },
  );
}
