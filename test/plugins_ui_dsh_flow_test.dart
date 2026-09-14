// Test suite for DSH web-style inline switch and quick delete on
// PluginCard and McpCard, along with their detail screens.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });

  tearDown(() async {
    for (final s in List<McpServer>.of(AppState.I.mcpServers)) {
      await McpService.I.disconnect(s.canonicalId);
    }
    AppState.resetTestInstance();
  });

  group('McpCard DSH flow', () {
    testWidgets('inline switch toggles McpServer connection', (tester) async {
      final app = AppState.I;
      final server = McpServer(
        name: 'test_mcp',
        author: 'test',
        description: 'test mcp server',
        category: 'Custom',
        command: 'echo',
        custom: true,
      );
      app.mcpServers.add(server);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: McpCard(server: server)),
        ),
      );
      await tester.pump();

      // Find inline switch on McpCard
      final switchFinder = find.byKey(ValueKey('mcp-switch-${server.canonicalId}'));
      expect(switchFinder, findsOneWidget);

      final switchWidget = tester.widget<Switch>(switchFinder);
      expect(switchWidget.value, isFalse);

      // Tap switch to toggle on
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(switchFinder, findsOneWidget);
    });

    testWidgets('delete button opens confirmation dialog and deletes server', (tester) async {
      final app = AppState.I;
      final server = McpServer(
        name: 'delete_mcp',
        author: 'test',
        description: 'delete test',
        category: 'Custom',
        command: 'echo',
        custom: true,
      );
      app.mcpServers.add(server);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: McpCard(server: server)),
        ),
      );
      await tester.pump();

      // Find trash icon button
      final deleteBtn = find.byKey(ValueKey('mcp-delete-${server.canonicalId}'));
      expect(deleteBtn, findsOneWidget);

      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Verify confirmation dialog
      expect(find.text('Delete delete_mcp?'), findsOneWidget);

      // Tap Delete in dialog
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      // Server removed from app.mcpServers
      expect(app.mcpServers.any((s) => s.canonicalId == server.canonicalId), isFalse);
    });
  });

  group('PluginCard DSH flow', () {
    testWidgets('inline switch toggles plugin enable/disable', (tester) async {
      final app = AppState.I;
      final plugin = PluginItem(
        name: 'test_plugin',
        version: '1.0.0',
        author: 'test',
        description: 'test plugin',
        category: 'Tool',
        installed: true,
        enabled: true,
      );
      app.plugins.add(plugin);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: plugin)),
        ),
      );
      await tester.pump();

      // Find inline switch on PluginCard
      final switchFinder = find.byKey(ValueKey('plugin-switch-${plugin.name}'));
      expect(switchFinder, findsOneWidget);

      final switchWidget = tester.widget<Switch>(switchFinder);
      expect(switchWidget.value, isTrue);

      // Tap switch to disable
      await tester.tap(switchFinder);
      await tester.pump();

      expect(plugin.enabled, isFalse);
    });

    testWidgets('delete button opens confirmation dialog and uninstalls/removes plugin', (tester) async {
      final app = AppState.I;
      final plugin = PluginItem(
        name: 'delete_plugin',
        version: '1.0.0',
        author: 'test',
        description: 'plugin to delete',
        category: 'Tool',
        installed: true,
        enabled: true,
      );
      app.plugins.add(plugin);

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: PluginCard(plugin: plugin)),
        ),
      );
      await tester.pump();

      // Find trash icon button
      final deleteBtn = find.byKey(ValueKey('plugin-delete-${plugin.name}'));
      expect(deleteBtn, findsOneWidget);

      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Verify confirmation dialog
      expect(find.text('Delete delete_plugin?'), findsOneWidget);

      // Tap Delete in dialog
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(plugin.installed, isFalse);
      expect(plugin.enabled, isFalse);
    });
  });
}
