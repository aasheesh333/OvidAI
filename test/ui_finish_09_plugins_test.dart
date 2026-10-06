import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugin_install_progress.dart';
import 'package:ovid_ai/ui/plugin_permission_sheet.dart';
import 'package:ovid_ai/ui/plugin_settings_panel.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  bool fail = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (fail) return false;
    return super.setValue(valueType, key, value);
  }
}

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _id = 'finish-review/long-scopes';
const _scope = 'WORKSPACE_DOCUMENT_REVIEW_SERVICE_ACCESS_TOKEN';
final _manifest = NormalizedPluginManifest(
  id: _id,
  name: 'Workspace document review and collaboration',
  version: '1.2.3',
  format: PluginFormat.claudeCode,
  rootPath: '/fixture',
  environmentReadNames: const {_scope},
  commands: const [
    PluginCommand(
      pluginId: _id,
      name: 'review',
      path: 'commands/workspace/document-review-and-collaboration.md',
    ),
  ],
  dependencies: const PluginDependencies(packages: [
    PluginDependency(
      name: '@workspace/document-review-and-collaboration',
      versionSpec: '^1.2.3',
    ),
  ]),
);

void main() {
  late AppState app;
  late _Preferences preferences;
  final captureKey = GlobalKey();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    preferences = _Preferences();
    SharedPreferencesStorePlatform.instance = preferences;
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

  Future<void> mount(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(360, 640),
    double scale = 2,
    double keyboard = 0,
    bool dark = true,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Aether.dark = dark;
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: home,
    ));
    await _frames(tester);
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    // Text entry schedules caret scrolling for the next frame. Let that
    // complete before asking to reveal another control, as a user would.
    await _frames(tester);
    await tester.ensureVisible(target);
    await _frames(tester);
    expect(target.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  for (final viewport in [
    (size: const Size(360, 640), scale: 2.0, keyboard: 260.0),
    (size: const Size(320, 640), scale: 1.0, keyboard: 0.0),
    (size: const Size(1024, 768), scale: 1.0, keyboard: 0.0),
  ]) {
    for (final dark in [true, false]) {
      testWidgets('permission scopes scroll and cancel leaves no grant '
          '${viewport.size} ${viewport.scale} dark=$dark', (tester) async {
        bool? result;
        await mount(
          tester,
          Builder(builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showPluginPermissionSheet(context, manifest: _manifest);
              },
              child: const Text('Open'),
            ),
          )),
          size: viewport.size,
          scale: viewport.scale,
          keyboard: viewport.keyboard,
          dark: dark,
        );
        await tester.tap(find.text('Open'));
        await _frames(tester);
        expect(tester.takeException(), isNull);
        await reveal(tester, find.textContaining('variables: $_scope'));
        await reveal(tester, find.textContaining('@workspace/'));
        await reveal(tester, find.text('Cancel'));
        await tester.tap(find.text('Cancel'));
        await _frames(tester);
        expect(result, isFalse);
        expect(await PluginPermissionStore().loadAny(_id), isNull);
      });
    }
  }

  testWidgets('permission save failure stays readable and retry persists exact scopes', (tester) async {
    bool? result;
    await mount(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () async {
          result = await showPluginPermissionSheet(context, manifest: _manifest);
        },
        child: const Text('Open'),
      ),
    )), keyboard: 260);
    await tester.tap(find.text('Open'));
    await _frames(tester);
    preferences.fail = true;
    await reveal(tester, find.text('Accept'));
    await tester.tap(find.text('Accept'));
    await _frames(tester);
    await reveal(tester, find.textContaining('Could not save the grant'));
    expect(result, isNull);
    expect(await PluginPermissionStore().loadAny(_id), isNull);
    preferences.fail = false;
    await reveal(tester, find.text('Accept'));
    await tester.tap(find.text('Accept'));
    await _frames(tester);
    expect(result, isTrue);
    final grant = await PluginPermissionStore().loadAny(_id);
    expect(grant!.pluginId, _id);
    expect(grant.environmentReadNames, {_scope});
    expect(grant.capabilities, contains(PluginCapability.environmentRead));
    expect(grant.capabilities, contains(PluginCapability.workspaceRead));
  });

  testWidgets('long install title and errors scroll above keyboard; close keeps install alive', (tester) async {
    final progress = PluginInstallProgress()
      ..setPhase('Fetching workspace/document-review-and-collaboration source', .42)
      ..line('Resolving the requested dependency versions');
    addTearDown(progress.dispose);
    await mount(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => PluginInstallProgressSheet(
            progress: progress,
            title: 'Installing workspace/document-review-and-collaboration',
          ),
        ),
        child: const Text('Open'),
      ),
    )), keyboard: 260);
    await tester.tap(find.text('Open'));
    await _frames(tester);
    expect(tester.takeException(), isNull);
    await reveal(tester, find.text('Close — install continues'));
    await tester.tap(find.text('Close — install continues'));
    await _frames(tester);
    expect(progress.done, isFalse);
    progress.finish(ok: false, summary: 'Dependency installation failed. Check the configured repository credentials and retry the installation.');
    await tester.tap(find.text('Open'));
    await _frames(tester);
    await reveal(tester, find.text(progress.summary));
    expect(tester.widget<Text>(find.text(progress.phase)).maxLines, isNull);
    await reveal(tester, find.text('Close'));
    await tester.tap(find.text('Close'));
    await _frames(tester);
    expect(find.byType(PluginInstallProgressSheet), findsNothing);
  });

  testWidgets('settings long helper is readable and canonical secure save callback survives keyboard', (tester) async {
    var saves = 0;
    const hint = 'Use a token scoped to the document review workspace. '
        'Keep the complete credential, including the service prefix. '
        'You can replace this value after rotating the token in your service settings.';
    await mount(tester, Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: PluginSettingsPanel(
        pluginName: _id,
        fields: const [NativePluginConfigField(
          key: 'token', label: 'Document review service access token', secret: true, hint: hint,
        )],
        onSaved: () => saves++,
      ),
    )), keyboard: 260);
    final field = find.byKey(const ValueKey('plugin-settings-field-token'));
    await reveal(tester, field);
    await tester.enterText(field, 'fixture-secret');
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(tester.widget<Text>(find.text(hint)).maxLines, isNull);
    final save = find.byKey(const ValueKey('plugin-settings-save'));
    await reveal(tester, save);
    await tester.tap(save);
    await _frames(tester);
    expect(saves, 1);
    const key = 'native_plugin_finish_review_long_scopes__token';
    expect(await const FlutterSecureStorage().read(key: key), 'fixture-secret');
    expect((await SharedPreferences.getInstance()).getString(key), isNull);
    await reveal(tester, find.byKey(const ValueKey('plugin-settings-saved')));
    await reveal(tester, field);
    await tester.enterText(field, 'changed-secret');
    await _frames(tester);
    expect(find.byKey(const ValueKey('plugin-settings-saved')), findsNothing);
  });

  testWidgets('catalog distinguishes available rows and keeps lifecycle controls reachable', (tester) async {
    final plugin = PluginItem(
      name: 'Document review and collaboration', author: 'fixture',
      description: 'A long description of workspace document review. ' * 4,
      version: '1.2.3', category: 'Tool', installed: true, enabled: true,
    );
    app.plugins.addAll([plugin, PluginItem(
      name: 'Available review tool', author: 'fixture', description: 'Catalog entry',
      version: '1', category: 'Tool',
    )]);
    await mount(tester, const PluginsScreen());
    expect(tester.takeException(), isNull);
    final toggle = find.byKey(ValueKey('plugin-switch-${plugin.name}'));
    await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
    await reveal(tester, toggle);
    await tester.tap(toggle);
    await _frames(tester);
    expect(plugin.enabled, isFalse);
    await tester.scrollUntilVisible(find.text('AVAILABLE'), 250, scrollable: find.byType(Scrollable).first);
    expect(find.text('AVAILABLE'), findsOneWidget);
    // A lazy sliver may have disposed the search field while reading cards.
    // Do not use .first: it throws before scrollUntilVisible can rebuild it.
    final search = find.byType(TextField);
    await tester.scrollUntilVisible(search, -250,
        scrollable: find.byType(Scrollable).first);
    await reveal(tester, search);
    await tester.enterText(search, 'no-such-plugin');
    await _frames(tester);
    await tester.scrollUntilVisible(find.text('No matching plugins'), 150,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('No matching plugins'), findsOneWidget);
    expect(find.text('No plugins installed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final viewport in [
    (size: const Size(360, 640), scale: 2.0),
    (size: const Size(320, 640), scale: 1.0),
    (size: const Size(1024, 768), scale: 1.0),
  ]) {
    testWidgets('marketplace identity and delete confirmation fit ${viewport.size}', (tester) async {
      // Add after initial synchronization to keep the fixture free of network IO.
      await mount(tester, const PluginsScreen(), size: viewport.size, scale: viewport.scale);
      const repo = 'workspace-document-review/collaboration-marketplace';
      app.marketplaces.add(repo);
      app.refresh();
      await _frames(tester);
      final remove = find.byKey(const ValueKey('marketplace-remove-$repo'));
      await tester.scrollUntilVisible(remove, 250,
          scrollable: find.byType(Scrollable).first);
      await reveal(tester, find.text(repo));
      expect(tester.widget<Text>(find.text(repo)).maxLines, isNull);
      await reveal(tester, remove);
      await tester.tap(remove);
      await _frames(tester);
      await reveal(tester, find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(app.marketplaces, contains(repo));
      await reveal(tester, remove);
      await tester.tap(remove);
      await _frames(tester);
      await reveal(tester, find.text('Delete'));
      await tester.tap(find.text('Delete'));
      await _frames(tester);
      expect(app.marketplaces, isNot(contains(repo)));
    });

    testWidgets('MCP long identity and status fit ${viewport.size}', (tester) async {
      final server = McpServer(
        name: 'Workspace document review and collaboration server',
        author: 'fixture', description: 'Review workspace documents',
        category: 'Custom', command: '', transport: 'http',
        url: 'https://example.test/mcp', custom: true,
      );
      app.mcpServers.add(server);
      await mount(tester, const PluginsScreen(), size: viewport.size, scale: viewport.scale);
      final card = find.byKey(ValueKey('mcp-card-${server.canonicalId}'));
      await tester.scrollUntilVisible(card, 180,
          scrollable: find.byType(Scrollable).first);
      await reveal(tester, find.text(server.name));
      expect(tester.widget<Text>(find.text(server.name)).maxLines, isNull);
      final remove = find.byKey(ValueKey('mcp-delete-${server.canonicalId}'));
      await reveal(tester, remove);
      await tester.tap(remove);
      await _frames(tester);
      await reveal(tester, find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(app.mcpServers, contains(server));
    });
  }

  testWidgets('invalid source stays in add sheet and shows inline feedback', (tester) async {
    await mount(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => showPluginAddSheet(context),
        child: const Text('Open'),
      ),
    )), keyboard: 260);
    await tester.tap(find.text('Open'));
    await _frames(tester);
    final field = find.byType(TextField);
    await reveal(tester, field);
    await tester.enterText(field, 'incomplete');
    await reveal(tester, find.text('Fetch from GitHub'));
    await tester.tap(find.text('Fetch from GitHub'));
    await _frames(tester);
    expect(find.text('Add plugin or marketplace'), findsOneWidget);
    expect(tester.widget<TextField>(field).decoration!.errorText, isNotNull);
    expect(app.plugins, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail rebuilds enabled state after lifecycle action', (tester) async {
    final plugin = PluginItem(
      name: 'Review lifecycle', author: 'fixture', description: 'Review documents',
      version: '1', category: 'Tool', installed: true, enabled: true,
    );
    app.plugins.add(plugin);
    await mount(tester, PluginDetailScreen(plugin: plugin));
    final disable = find.widgetWithText(FilledButton, 'Disable');
    await tester.scrollUntilVisible(disable, 180);
    await reveal(tester, disable);
    await tester.tap(disable);
    await _frames(tester);
    expect(plugin.enabled, isFalse);
    expect(find.widgetWithText(FilledButton, 'Enable'), findsOneWidget);
    final toggle = find.byKey(ValueKey('plugin-detail-switch-${plugin.name}'));
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MCP config validation and save remain reachable above keyboard', (tester) async {
    final server = McpServer(
      name: 'Workspace review', author: 'fixture', description: 'Review documents',
      category: 'Custom', command: '', transport: 'http',
      url: 'https://example.test/mcp', custom: true,
    );
    app.mcpServers.add(server);
    await mount(tester, McpDetailScreen(server: server), keyboard: 260);
    await tester.tap(find.byTooltip('Edit config'));
    await _frames(tester);
    final field = find.byType(TextField);
    await reveal(tester, field);
    await tester.enterText(field, '{invalid');
    await _frames(tester);
    await reveal(tester, find.textContaining('Invalid mcp.json'));
    await reveal(tester, find.text('Save config'));
    await tester.tap(find.text('Save config'));
    await _frames(tester);
    expect(server.url, 'https://example.test/mcp');
    await reveal(tester, field);
    await tester.enterText(field, jsonEncode({
      'mcpServers': {
        server.name: {
          'transport': 'http', 'url': 'https://example.test/review',
          'env': {'REVIEW_TOKEN': 'fixture-token'},
        },
      },
    }));
    await reveal(tester, find.text('Save config'));
    await tester.tap(find.text('Save config'));
    await _frames(tester);
    expect(find.text('Edit mcp.json'), findsNothing);
    expect(server.url, 'https://example.test/review');
    expect(await app.getMcpEnv(server.canonicalId), {'REVIEW_TOKEN': 'fixture-token'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('progress replacement listens to the current install only', (tester) async {
    final first = PluginInstallProgress();
    final second = PluginInstallProgress();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    late StateSetter update;
    var current = first;
    await mount(tester, Scaffold(body: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return PluginInstallProgressSheet(progress: current, title: 'Install progress');
    })));
    update(() => current = second);
    await _frames(tester);
    second.finish(ok: true, summary: 'Current installation completed');
    await _frames(tester);
    await reveal(tester, find.text('Current installation completed'));
    expect(find.text('Done'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin sheet screenshot (opt-in)', (tester) async {
    if (!const bool.fromEnvironment('UI_REVIEW_CAPTURE')) return;
    await mount(tester, Builder(builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => showPluginPermissionSheet(context, manifest: _manifest),
        child: const Text('Open'),
      ),
    )), scale: 1);
    await tester.tap(find.text('Open'));
    await _frames(tester);
    expect(tester.takeException(), isNull);
    final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-09.png').writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
}
