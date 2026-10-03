import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final app = AppState.createForTest();
    app.plugins.clear();
    app.mcpServers.clear();
    app.marketplaces.clear();
  });
  tearDown(AppState.resetTestInstance);

  testWidgets('concurrent installs keep their own approval navigator', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final staging = Directory.systemTemp.createTempSync('ui-approval-context-');
    PluginRuntimeManager.stagingRootOverrideForTest = staging;
    addTearDown(() {
      PluginRuntimeManager.stagingRootOverrideForTest = null;
      inspectResultsForTest.clear();
      staging.deleteSync(recursive: true);
    });
    final contexts = <BuildContext>[];
    await tester.pumpWidget(
      Row(
        textDirection: TextDirection.ltr,
        children: [
          for (var i = 0; i < 2; i++)
            Expanded(
              child: MaterialApp(
                home: Builder(
                  builder: (context) {
                    contexts.add(context);
                    return const Scaffold();
                  },
                ),
              ),
            ),
        ],
      ),
    );
    final installs = <Future<PluginInstallResult?>>[];
    await tester.runAsync(() async {
      for (var i = 0; i < 2; i++) {
        installs.add(
          startPluginInstallForTest(
            AppState.I,
            null,
            approvalContext: contexts[i],
            source: PastedConfigPluginSource(
              label: 'approval-$i',
              rawConfig: jsonEncode({
                'mcpServers': {
                  'fixture-$i': {'command': 'node'},
                },
              }),
            ),
          ),
        );
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (inspectResultsForTest.length < 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final app = find.byType(MaterialApp).at(i);
      expect(
        find.descendant(of: app, matching: find.text('Grant plugin access')),
        findsOneWidget,
      );
      await tester.tap(find.descendant(of: app, matching: find.text('Cancel')));
    }
    await tester.pumpAndSettle();
    final results = await tester.runAsync(() => Future.wait(installs));
    expect(results, [null, null]);
    expect(AppState.I.plugins, isEmpty);
    expect(staging.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  PluginItem plugin(String name, {bool installed = false}) => PluginItem(
    name: name,
    author: 'fixture',
    description: 'fixture',
    version: '1',
    category: 'Tool',
    installed: installed,
  );
  McpServer server(String name, {bool custom = false, String? owner}) =>
      McpServer(
        name: name,
        author: 'fixture',
        description: 'fixture',
        category: 'Custom',
        command: 'node',
        custom: custom,
        ownerPluginId: owner,
      );

  testWidgets(
    'installed-first order responds to notifications, additions and removal',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState.I;
      final available = plugin('Available');
      final disabled = plugin('Installed disabled', installed: true);
      app.plugins.addAll([available, disabled]);
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const PluginsScreen()),
      );
      await tester.pumpAndSettle();
      List<String> order() => tester
          .widgetList<PluginCard>(find.byType(PluginCard))
          .map((w) => w.plugin.name)
          .toList();
      expect(order(), ['Installed disabled', 'Available']);
      expect(app.plugins, [available, disabled]);

      available.installed = true;
      app.refresh();
      await tester.pump();
      expect(order(), ['Available', 'Installed disabled']);
      final added = plugin('New install', installed: true);
      available.installed = false;
      app.plugins.add(added);
      app.refresh();
      await tester.pump();
      expect(order(), ['Installed disabled', 'New install', 'Available']);
      app.plugins.remove(disabled);
      app.refresh();
      await tester.pump();
      expect(order(), ['New install', 'Available']);

      await tester.enterText(find.byType(TextField), 'Available');
      await tester.pump();
      expect(order(), ['Available']);
    },
  );

  testWidgets(
    'configured MCP rows stay first while disconnected and reorder reactively',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppState.I;
      final catalog = server('Catalog');
      final custom = server('Configured', custom: true);
      final owned = server('Owned', owner: 'fixture/owner');
      app.mcpServers.addAll([catalog, custom, owned]);
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const PluginsScreen()),
      );
      await tester.pumpAndSettle();
      List<String> order() => tester
          .widgetList<McpCard>(find.byType(McpCard))
          .map((w) => w.server.name)
          .toList();
      expect(order(), ['Configured', 'Owned', 'Catalog']);
      custom.connected = true;
      app.refresh();
      await tester.pump();
      custom.connected = false;
      catalog.custom = true;
      app.refresh();
      await tester.pump();
      expect(order(), ['Catalog', 'Configured', 'Owned']);
      expect(app.mcpServers, [catalog, custom, owned]);
    },
  );

  for (final multiple in [false, true]) {
    testWidgets(
      'masked ${multiple ? 'multi' : 'single'} env survives no-op and args edit',
      (tester) async {
        final app = AppState.I;
        final s = McpServer(
          name: 'Credential fixture',
          author: 'fixture',
          description: 'fixture',
          category: 'Custom',
          command: 'node',
          custom: true,
          envHint: multiple ? ' FIRST, SECOND ' : 'FIRST',
        );
        final original = {
          'FIRST': 'fixture-one',
          if (multiple) 'SECOND': 'fixture-two',
          'UNLISTED': 'fixture-extra',
        };
        await app.setMcpEnv(s.canonicalId, original);
        app.mcpServers.add(s);
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: McpDetailScreen(server: s),
          ),
        );
        for (final editArgs in [false, true]) {
          await tester.tap(find.byTooltip('Edit config'));
          await tester.pumpAndSettle();
          final text = tester
              .widget<TextField>(find.byType(TextField))
              .controller!
              .text;
          for (final value in original.values) {
            expect(
              text.contains(value),
              isFalse,
              reason: 'editor must mask stored values',
            );
          }
          if (editArgs) {
            final config = jsonDecode(text) as Map<String, dynamic>;
            (config['mcpServers'] as Map).values.single['args'] = ['--changed'];
            await tester.enterText(find.byType(TextField), jsonEncode(config));
          }
          await tester.tap(find.text('Save config'));
          await tester.pumpAndSettle();
          final saved = await app.getMcpEnv(s.canonicalId);
          expect(saved.keys.toSet(), original.keys.toSet());
          for (final key in original.keys) {
            expect(
              saved[key] == original[key],
              isTrue,
              reason: 'stored value preserved for $key',
            );
          }
        }
        expect(s.args, ['--changed']);
      },
    );
  }

  testWidgets('env editor replaces and removes values without storing masks', (
    tester,
  ) async {
    final app = AppState.I;
    final s = McpServer(
      name: 'Credential edits',
      author: 'fixture',
      description: 'fixture',
      category: 'Custom',
      command: 'node',
      custom: true,
      envHint: 'KEEP,REPLACE,REMOVE,MISSING',
    );
    await app.setMcpEnv(s.canonicalId, {
      'KEEP': 'fixture-keep',
      'REPLACE': 'fixture-old',
      'REMOVE': 'fixture-remove',
    });
    app.mcpServers.add(s);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: McpDetailScreen(server: s),
      ),
    );
    await tester.tap(find.byTooltip('Edit config'));
    await tester.pumpAndSettle();
    final config =
        jsonDecode(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
            )
            as Map<String, dynamic>;
    final entry = (config['mcpServers'] as Map).values.single as Map;
    (entry['env'] as Map)
      ..['REPLACE'] = 'fixture-new'
      ..remove('REMOVE');
    await tester.enterText(find.byType(TextField), jsonEncode(config));
    await tester.tap(find.text('Save config'));
    await tester.pumpAndSettle();
    final saved = await app.getMcpEnv(s.canonicalId);
    expect(saved.keys.toSet(), {'KEEP', 'REPLACE'});
    expect(saved['KEEP'] == 'fixture-keep', isTrue);
    expect(saved['REPLACE'] == 'fixture-new', isTrue);
    expect(saved.values.any((v) => v == '••••••••'), isFalse);

    await tester.tap(find.byTooltip('Edit config'));
    await tester.pumpAndSettle();
    entry.remove('env');
    await tester.enterText(find.byType(TextField), jsonEncode(config));
    await tester.tap(find.text('Save config'));
    await tester.pumpAndSettle();
    expect(await app.getMcpEnv(s.canonicalId), isEmpty);
  });

  for (final transport in ['stdio', 'http']) {
    testWidgets('$transport config editor round-trips escaped values', (
      tester,
    ) async {
      final s = server('Mixed "Name"\\fixture', custom: true)
        ..command = 'node"\\runner'
        ..args = ['a"b', r'C:\folder\file', 'line\nbreak', 'tab\tvalue', '雪']
        ..cwd = 'folder"\\nested'
        ..transport = transport
        ..url = transport == 'http'
            ? 'https://example.test/"quoted"\\path'
            : null;
      AppState.I.mcpServers.add(s);
      final expectedArgs = List<String>.of(s.args);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: McpDetailScreen(server: s),
        ),
      );
      await tester.tap(find.byTooltip('Edit config'));
      await tester.pumpAndSettle();
      final text = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      final entry =
          ((jsonDecode(text) as Map)['mcpServers'] as Map).values.single as Map;
      expect(entry['command'], 'node"\\runner');
      expect(entry['args'], expectedArgs);
      expect(entry['cwd'], 'folder"\\nested');
      expect(entry['transport'], transport);
      await tester.tap(find.text('Save config'));
      await tester.pumpAndSettle();
      expect(find.text('Edit mcp.json'), findsNothing);
      expect(s.command, 'node"\\runner');
      expect(s.args, expectedArgs);
      expect(s.cwd, 'folder"\\nested');
      expect(s.transport, transport);
      expect(
        s.url,
        transport == 'http' ? 'https://example.test/"quoted"\\path' : null,
      );
    });
  }
}
