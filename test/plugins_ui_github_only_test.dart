// Task 2 (Plugins/MCP UI Contraction, spec §5.2): single "+" sheet.
// Source-level contract (one AppBar Icons.add → showPluginAddSheet with
// GitHub fetch + marketplace add; no standalone marketplace/extension
// buttons, no _AddMcpTile/_addMcpDialog/_importMcpConfig; empty MCP list
// hints at "+") + widget-level behavior (sheet routes both actions).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

String _pluginsScreenSource() =>
    File('lib/ui/plugins_screen.dart').readAsStringSync();

/// The `showPluginAddSheet` function body: from its declaration to the
/// `_githubSourceFromInput` helper that follows it.
String _addSheetBody(String src) {
  final start = src.indexOf('Future<void> showPluginAddSheet');
  assert(start >= 0, 'showPluginAddSheet not found');
  final end = src.indexOf(
    'GithubPluginSource? _githubSourceFromInput',
    start,
  );
  assert(end > start, 'add-sheet body end marker not found');
  return src.substring(start, end);
}

void main() {
  group('Single add sheet for plugins and marketplaces', () {
    test('sheet keeps the GitHub route', () {
      final src = _pluginsScreenSource();
      final sheet = _addSheetBody(src);
      expect(sheet, contains('_githubSourceFromInput'));
      expect(sheet, contains('_runSourceInstall'));
      expect(sheet, contains('Fetch from GitHub'));
      expect(sheet, contains('owner/repo'));
      expect(sheet, contains('Add plugin or marketplace'));
      // File-picker seams stay gone.
      expect(src, isNot(contains('pluginPickDirectoryForTest')));
      expect(src, isNot(contains('pluginPickZipFileForTest')));
      expect(src, isNot(contains('FilePicker')));
    });

    test('sheet has no non-GitHub routes', () {
      final sheet = _addSheetBody(_pluginsScreenSource());
      expect(sheet, isNot(contains('Local folder')));
      expect(sheet, isNot(contains('ZIP archive')));
      expect(sheet, isNot(contains('Install from npm')));
      expect(sheet, isNot(contains('Inspect pasted config')));
      expect(sheet, isNot(contains('Add MCP server')));
      expect(sheet, isNot(contains('PASTE MCP CONFIG')));
      expect(sheet, isNot(contains('DIRECT MCP SERVER')));
      expect(sheet, isNot(contains('LocalFolderPluginSource')));
      expect(sheet, isNot(contains('ZipPluginSource')));
      expect(sheet, isNot(contains('NpmPluginSource')));
      expect(sheet, isNot(contains('PastedConfigPluginSource')));
      expect(sheet, isNot(contains('DirectMcpPluginSource')));
    });

    test('sheet routes marketplace add too', () {
      final src = _pluginsScreenSource();
      final sheet = _addSheetBody(src);
      expect(sheet, contains('addMarketplace'));
      expect(sheet, contains('fetchMarketplaceCatalog'));
      expect(sheet, contains('Add marketplace'));
    });

    test('exactly one + entry, no standalone entries', () {
      final src = _pluginsScreenSource();
      // One AppBar "+" with the combined tooltip.
      expect(src, contains("tooltip: 'Add plugin or marketplace'"));
      expect(src, contains('showPluginAddSheet'));
      // Standalone marketplace dialog route is gone (folded into sheet).
      expect(src, isNot(contains('_addMarketplaceDialog')));
      expect(src, isNot(contains("tooltip: 'Add marketplace'")));
      // Standalone GitHub-chooser extension button is gone (folded).
      expect(src, isNot(contains('showPluginSourceChooser')));
      expect(src, isNot(contains("tooltip: 'Install plugin from GitHub'")));
      // MCP manual/import entries are gone from the UI.
      expect(src, isNot(contains('_AddMcpTile')));
      expect(src, isNot(contains('_addMcpDialog')));
      expect(src, isNot(contains('_importMcpConfig')));
      expect(src, isNot(contains('Add custom MCP server')));
      expect(src, isNot(contains('Import MCP config')));
    });

    test('empty MCP list hints at +', () {
      expect(
        _pluginsScreenSource(),
        contains('Use + to add from GitHub'),
      );
    });

    test('detail Install fallback opens the sheet', () {
      final src = _pluginsScreenSource();
      expect(src, contains('showPluginAddSheet(context)'));
      // No detail fallback still routes to the old chooser.
      expect(src, isNot(contains('showPluginSourceChooser(context)')));
    });

    testWidgets('add sheet shows the GitHub + marketplace actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showPluginAddSheet(ctx),
                child: const Text('open add sheet'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open add sheet'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Fetch from GitHub'), findsOneWidget);
      expect(
        find.text('owner/repo or https://github.com/owner/repo'),
        findsOneWidget,
      );
      expect(find.text('Add marketplace'), findsOneWidget);
      expect(find.text('Local folder'), findsNothing);
      expect(find.text('ZIP archive'), findsNothing);
      expect(find.text('Add custom MCP server'), findsNothing);
      expect(find.text('Import MCP config'), findsNothing);
    });

    testWidgets('AppBar has refresh + exactly one +', (tester) async {
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      app.plugins.clear();
      app.mcpServers.clear();
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const PluginsScreen()),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byTooltip('Add plugin or marketplace'),
        findsOneWidget,
      );
      expect(find.byTooltip('Add marketplace'), findsNothing);
      expect(find.byTooltip('Install plugin from GitHub'), findsNothing);
      expect(find.byTooltip('Refresh marketplaces'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
      // Empty MCP list shows the "+" hint.
      expect(find.text('Use + to add from GitHub'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
