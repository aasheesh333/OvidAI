import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/state.dart';

/// H1: the custom MCP server list and the global "always allow/deny"
/// decisions move out of SharedPreferences into secure storage with a
/// one-time, verified, idempotent migration.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const legacyMcpKey = 'ovid_custom_mcp_servers_v1';
  const secureMcpKey = 'ovid_custom_mcp_servers_v2';
  const legacyGrantsKey = 'ovid_permission_grants_v1';
  const secureGrantsKey = 'ovid_permission_grants_v2';

  final mcpRow = jsonEncode({
    'name': 'legacy-tools',
    'author': 'you',
    'command': 'npx',
    'args': ['-y', 'legacy-tools'],
    'transport': 'stdio',
  });
  final hostGrant = PermissionGrant.host(
    'api.example.com',
    global: true,
    at: DateTime.utc(2026, 1, 2),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
  });

  tearDown(AppState.resetTestInstance);

  group('custom MCP servers', () {
    test('legacy rows migrate into secure storage and load', () async {
      SharedPreferences.setMockInitialValues({
        legacyMcpKey: [mcpRow],
      });
      final app = AppState.createForTest();
      app.mcpServers.clear();

      await app.reloadCustomMcpServersForTest();

      expect(app.mcpServers.map((s) => s.name), contains('legacy-tools'));
      expect(await AppState.persistedCustomMcpRowsForTest(), [mcpRow]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyMcpKey), isFalse);
    });

    test('migration is idempotent; secure storage stays authoritative', () async {
      // A crash after the verified copy but before the preferences delete
      // leaves both. The secure list (here: the user removed the row since)
      // wins and the stale preferences copy is discarded.
      SharedPreferences.setMockInitialValues({
        legacyMcpKey: [mcpRow],
      });
      FlutterSecureStorage.setMockInitialValues({secureMcpKey: '[]'});
      final app = AppState.createForTest();
      app.mcpServers.clear();

      await app.reloadCustomMcpServersForTest();
      await app.reloadCustomMcpServersForTest();

      expect(app.mcpServers.where((s) => s.name == 'legacy-tools'), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyMcpKey), isFalse);
      expect(await AppState.persistedCustomMcpRowsForTest(), isEmpty);
    });

    test('a corrupt secure copy re-migrates from the legacy rows', () async {
      SharedPreferences.setMockInitialValues({
        legacyMcpKey: [mcpRow],
      });
      FlutterSecureStorage.setMockInitialValues({secureMcpKey: '[trunc'});
      final app = AppState.createForTest();
      app.mcpServers.clear();

      await app.reloadCustomMcpServersForTest();

      expect(app.mcpServers.map((s) => s.name), contains('legacy-tools'));
      expect(await AppState.persistedCustomMcpRowsForTest(), [mcpRow]);
    });

    test('new servers persist only to secure storage', () async {
      final app = AppState.createForTest();
      expect(
        app.addCustomMcpServer(name: 'fresh', command: 'node', args: ['s.js']),
        isNull,
      );
      await pumpEventQueue();

      final rows = await AppState.persistedCustomMcpRowsForTest();
      expect(rows!.single, contains('"fresh"'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyMcpKey), isFalse);
    });
  });

  group('global permission decisions', () {
    test('legacy decisions migrate, verify and leave preferences', () async {
      final legacy = jsonEncode([hostGrant.toJson()]);
      SharedPreferences.setMockInitialValues({legacyGrantsKey: legacy});
      final app = AppState.createForTest();

      await app.reloadShellPreferencesForTest();

      expect(
        app.globalPermissionGrants.map((g) => g.value),
        ['api.example.com'],
      );
      expect(
        await const FlutterSecureStorage().read(key: secureGrantsKey),
        legacy,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyGrantsKey), isFalse);

      // Second run: nothing left to migrate, same decisions.
      await app.reloadShellPreferencesForTest();
      expect(app.globalPermissionGrants, hasLength(1));
    });

    test('a forged preferences grant cannot override secure storage', () async {
      final forged = jsonEncode([
        PermissionGrant.host('evil.example', global: true).toJson(),
      ]);
      SharedPreferences.setMockInitialValues({legacyGrantsKey: forged});
      FlutterSecureStorage.setMockInitialValues({
        secureGrantsKey: jsonEncode([hostGrant.toJson()]),
      });
      final app = AppState.createForTest();

      await app.reloadShellPreferencesForTest();

      expect(
        app.globalPermissionGrants.map((g) => g.value),
        ['api.example.com'],
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyGrantsKey), isFalse);
    });

    test('new decisions are written to secure storage only', () async {
      final app = AppState.createForTest();
      await app.addGlobalPermissionGrant(hostGrant);

      final raw = await const FlutterSecureStorage().read(key: secureGrantsKey);
      expect(raw, contains('api.example.com'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(legacyGrantsKey), isFalse);
    });
  });
}
