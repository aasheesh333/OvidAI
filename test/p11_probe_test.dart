import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/plugin_adapters.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory p11Staging;
  late Directory p11Runtime;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    p11Staging = Directory.systemTemp.createTempSync('p11-staging-');
    p11Runtime = Directory.systemTemp.createTempSync('p11-runtime-');
    PluginRuntimeManager.stagingRootOverrideForTest = p11Staging;
    PluginRuntimeManager.runtimeRootOverrideForTest = p11Runtime;
    inspectResultsForTest.clear();
  });

  tearDown(() async {
    AgentService.setRunSessionForTest('');
    PluginRuntimeManager.stagingRootOverrideForTest = null;
    PluginRuntimeManager.runtimeRootOverrideForTest = null;
    PluginRuntimeManager.depsForTest = null;
    PluginRuntimeManager.failRenameForTest = false;
    PluginRuntimeManager.githubBaseOverrideForTest = null;
    PluginRuntimeManager.npmRegistryBaseOverrideForTest = null;
    PluginInspectRecorderForTest.record = null;
    PluginRuntimeCallRecorderForTest.record = null;
    pluginPickDirectoryForTest = null;
    pluginPickZipFileForTest = null;
    inspectResultsForTest.clear();
    for (final id in PluginContributionRegistry.I.registeredPluginIds
        .toList()) {
      if (id.startsWith('p11org/') || id.startsWith('mcp/')) {
        PluginContributionRegistry.I.unregisterPlugin(id);
      }
    }
    AppState.resetTestInstance();
    try {
      p11Staging.deleteSync(recursive: true);
    } catch (_) {}
    try {
      p11Runtime.deleteSync(recursive: true);
    } catch (_) {}
    SharedPreferences.setMockInitialValues({});
  });

  Directory p11PluginDir({String name = 'Diag Kit'}) {
    final dir = Directory.systemTemp.createTempSync('p11-plugin-src-');
    Directory('${dir.path}/.claude-plugin').createSync(recursive: true);
    File('${dir.path}/.claude-plugin/plugin.json').writeAsStringSync(
      jsonEncode({'name': name, 'author': 'p11org', 'version': '1.0.0'}),
    );
    Directory('${dir.path}/commands').createSync(recursive: true);
    File('${dir.path}/commands/review.md').writeAsStringSync(
      '---\ndescription: P11 command\n---\nP11 BODY',
    );
    return dir;
  }

  testWidgets(
    'PLUGIN11: permission cancel on the inspection flow leaves no state',
    (tester) async {
      AgentService.I.debugPauseScheduleTimerForTest(true);
      addTearDown(() {
        AgentService.I.debugPauseScheduleTimerForTest(false);
        AppState.resetTestInstance();
      });
      final app = AppState.createForTest();

      final src = p11PluginDir(name: 'Cancel Kit');
      final row = PluginItem(
        name: 'P11 Cancel Kit',
        author: 'p11org',
        description: 'P11 fixture',
        version: '1.0.0',
        category: 'Tool',
      );
      app.plugins.add(row);
      pluginPickDirectoryForTest = () async => src.path;

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: PluginDetailScreen(plugin: row),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local folder'));
      var sheetFound = false;
      for (var i = 0; i < 50 && !sheetFound; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
        sheetFound = find.text('Grant plugin access').evaluate().isNotEmpty;
        debugPrint('iter $i sheet=$sheetFound');
      }
      expect(sheetFound, isTrue, reason: 'inspection sheet never opened');

      expect(find.text('Grant plugin access'), findsOneWidget);
      expect(find.textContaining('p11org/cancel-kit'), findsOneWidget);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(row.installed, isFalse);
      expect(row.runtimeId, isNull);
      expect(row.activation, PluginActivation.disabled);
      expect(
        PluginContributionRegistry.I.isRegistered('p11org/cancel-kit'),
        isFalse,
      );
      final grant = await AppState.pluginPermissions.effectiveGrant(
        pluginId: 'p11org/cancel-kit',
        manifest: await const PluginAdapterRegistry().inspect(src),
      );
      expect(grant, isNull, reason: 'cancel must persist no grant');
      final stagingParent = Directory('${p11Staging.path}/plugin-staging');
      expect(
        stagingParent.existsSync() ? stagingParent.listSync() : [],
        isEmpty,
        reason: 'cancelled install must discard its staging',
      );
    },
  );
}
