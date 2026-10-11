// PR-4a — MCP/plugin correctness and destructive safety (F-078…F-091).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

McpServer _server({
  String name = 'hdr_mcp',
  List<String>? requiredEnvNames,
  List<String>? requiredHeaderNames,
  String transport = 'stdio',
  String command = 'echo',
  String? url,
  bool custom = true,
  String? envHint,
}) => McpServer(
  name: name,
  author: 'test',
  description: 'fixture',
  category: 'Custom',
  command: command,
  custom: custom,
  transport: transport,
  url: url,
  envHint: envHint,
  requiredEnvNames: requiredEnvNames,
  requiredHeaderNames: requiredHeaderNames,
);

Future<void> _pump(WidgetTester tester, Widget home) async {
  await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: home));
  await tester.pump();
}

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
    mcpSupportGateForTest = null;
    McpService.missingRuntimeOverrideForTest = null;
    AppState.resetTestInstance();
  });

  group('MCP credentials (F-079, F-080, F-081)', () {
    test('missing credentials are split into env and header names', () async {
      final s = _server(
        requiredEnvNames: ['API_KEY'],
        requiredHeaderNames: ['Authorization'],
      );
      final split = await McpService.I.missingCredentialsSplitFor(s);
      expect(split.env, ['API_KEY']);
      expect(split.headers, ['Authorization']);
      expect(await McpService.I.missingCredentialsFor(s), [
        'API_KEY',
        'Authorization',
      ]);
    });

    test('header credentials land in the headers store and clear the gate',
        () async {
      final app = AppState.I;
      final s = _server(requiredHeaderNames: ['Authorization']);
      await app.saveMcpCredentials(s, headers: {'Authorization': 'Bearer x'});
      expect(
        (await app.getMcpHeaders(s.canonicalId))['Authorization'],
        'Bearer x',
      );
      expect(await app.getMcpEnv(s.canonicalId), isEmpty);
      expect(s.headers['Authorization'], 'Bearer x');
      expect(await McpService.I.missingCredentialsFor(s), isEmpty);
    });

    test('saving missing env keys merges with what is already stored',
        () async {
      final app = AppState.I;
      final s = _server(requiredEnvNames: ['A', 'B']);
      await app.setMcpEnv(s.canonicalId, {'A': '1'});
      await app.saveMcpCredentials(s, env: {'B': '2'});
      expect(await app.getMcpEnv(s.canonicalId), {'A': '1', 'B': '2'});
    });

    testWidgets('the credential sheet saves header fields as headers', (
      tester,
    ) async {
      mcpSupportGateForTest = (_) => null;
      McpService.missingRuntimeOverrideForTest = (_) async => null;
      final app = AppState.I;
      final s = _server(
        requiredEnvNames: ['API_KEY'],
        requiredHeaderNames: ['Authorization'],
      );
      app.mcpServers.add(s);
      await app.setMcpEnv(s.canonicalId, {'OTHER': 'keep'});
      await _pump(tester, McpDetailScreen(server: s));
      await tester.tap(find.widgetWithText(FilledButton, 'Connect server'));
      await tester.pumpAndSettle();
      expect(find.text('Authorization (HTTP header)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('mcp-cred-env-API_KEY')),
        'k1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-cred-header-Authorization')),
        'Bearer t',
      );
      await tester.tap(find.text('Save & connect'));
      await tester.pumpAndSettle();
      expect(await app.getMcpEnv(s.canonicalId), {
        'OTHER': 'keep',
        'API_KEY': 'k1',
      });
      expect(await app.getMcpHeaders(s.canonicalId), {
        'Authorization': 'Bearer t',
      });
      expect(await McpService.I.missingCredentialsFor(s), isEmpty);
    });
  });

  group('mcp.json editor (F-083, F-084)', () {
    Future<Map<String, dynamic>> openEditor(
      WidgetTester tester,
      McpServer s,
    ) async {
      await _pump(tester, McpDetailScreen(server: s));
      await tester.tap(find.byTooltip('Edit config'));
      await tester.pumpAndSettle();
      final text = tester
          .widget<TextField>(find.byType(TextField))
          .controller!
          .text;
      return jsonDecode(text) as Map<String, dynamic>;
    }

    Future<void> save(WidgetTester tester, Map<String, dynamic> cfg) async {
      await tester.enterText(find.byType(TextField), jsonEncode(cfg));
      await tester.tap(find.text('Save config'));
      await tester.pumpAndSettle();
    }

    testWidgets('editing a custom HTTP server keeps its auth header', (
      tester,
    ) async {
      final app = AppState.I;
      final s = _server(
        name: 'remote',
        transport: 'http',
        command: '',
        url: 'https://example.test/mcp',
      )..headers = {'Authorization': 'Bearer secret'};
      app.mcpServers.add(s);
      await app.setMcpHeaders(s.canonicalId, {'Authorization': 'Bearer secret'});
      final cfg = await openEditor(tester, s);
      final entry = (cfg['mcpServers'] as Map).values.single as Map;
      expect(entry['headers'], {'Authorization': '••••••••'});
      expect(jsonEncode(cfg).contains('Bearer secret'), isFalse);
      entry['url'] = 'https://example.test/v2';
      await save(tester, cfg);
      expect(s.url, 'https://example.test/v2');
      expect(s.headers, {'Authorization': 'Bearer secret'});
      expect(await app.getMcpHeaders(s.canonicalId), {
        'Authorization': 'Bearer secret',
      });
    });

    testWidgets('removing a header in the editor deletes it', (tester) async {
      final app = AppState.I;
      final s = _server(
        name: 'remote2',
        transport: 'http',
        command: '',
        url: 'https://example.test/mcp',
      )..headers = {'Authorization': 'Bearer old'};
      app.mcpServers.add(s);
      await app.setMcpHeaders(s.canonicalId, {'Authorization': 'Bearer old'});
      final cfg = await openEditor(tester, s);
      ((cfg['mcpServers'] as Map).values.single as Map).remove('headers');
      await save(tester, cfg);
      expect(s.headers, isEmpty);
      expect(await app.getMcpHeaders(s.canonicalId), isEmpty);
    });

    testWidgets('timeouts round-trip through the editor', (tester) async {
      final s = _server(name: 'timeouts', command: 'node')
        ..startupTimeoutS = 90
        ..toolTimeoutS = 300;
      AppState.I.mcpServers.add(s);
      final cfg = await openEditor(tester, s);
      final entry = (cfg['mcpServers'] as Map).values.single as Map;
      expect(entry['startupTimeoutS'], 90);
      expect(entry['toolTimeoutS'], 300);
      entry['args'] = ['--x'];
      await save(tester, cfg);
      expect(s.args, ['--x']);
      expect(s.startupTimeoutS, 90);
      expect(s.toolTimeoutS, 300);
      final again = await openEditor(tester, s);
      ((again['mcpServers'] as Map).values.single as Map)['toolTimeoutS'] =
          120;
      await save(tester, again);
      expect(s.toolTimeoutS, 120);
    });

    testWidgets('an unsupported transport is rejected and nothing changes', (
      tester,
    ) async {
      final s = _server(name: 'badtransport', command: 'node');
      AppState.I.mcpServers.add(s);
      final cfg = await openEditor(tester, s);
      ((cfg['mcpServers'] as Map).values.single as Map)['transport'] =
          'websocket';
      await save(tester, cfg);
      expect(find.textContaining('Unsupported transport'), findsOneWidget);
      expect(s.transport, 'stdio');
    });

    testWidgets('plugin-owned and built-in servers are read-only', (
      tester,
    ) async {
      final owned = McpServer(
        name: 'owned',
        author: 'p',
        description: '',
        category: 'Custom',
        command: 'node',
        custom: true,
        ownerPluginId: 'acme/kit',
      );
      await _pump(tester, McpDetailScreen(server: owned));
      expect(find.byTooltip('Edit config'), findsNothing);
      expect(find.textContaining('Managed by plugin acme/kit'), findsOneWidget);
      final seed = _server(name: 'seed', custom: false);
      await _pump(tester, McpDetailScreen(server: seed));
      expect(find.byTooltip('Edit config'), findsNothing);
      expect(find.textContaining('Built-in server'), findsOneWidget);
    });
  });

  group('connect feedback (F-091)', () {
    testWidgets('the detail screen repaints the real outcome in place', (
      tester,
    ) async {
      final app = AppState.I;
      final s = _server(name: 'live', command: 'node');
      app.mcpServers.add(s);
      await _pump(tester, McpDetailScreen(server: s));
      expect(find.text('Not started'), findsOneWidget);
      await tester.runAsync(
        () => app.recordStartupStatus(
          StartupItemStatus(
            id: s.canonicalId,
            kind: StartupItemKind.mcp,
            label: 'Connect live',
            state: StartupItemState.ready,
            reason: 'connected',
          ),
          ownerId: s.canonicalId,
        ),
      );
      app.refresh();
      await tester.pump();
      expect(find.text('Ready · connected'), findsOneWidget);
    });

    testWidgets('busy while connecting: no double toggle', (tester) async {
      final app = AppState.I;
      final s = _server(name: 'busy', command: 'node');
      app.mcpServers.add(s);
      app.updateServiceStatus(
        'mcp:${s.canonicalId}',
        ServiceHealth.connecting,
        detail: 'connecting…',
      );
      await _pump(tester, McpDetailScreen(server: s));
      expect(find.text('Connecting…'), findsOneWidget);
      final sw = tester.widget<Switch>(
        find.byKey(ValueKey('mcp-detail-switch-${s.canonicalId}')),
      );
      expect(sw.onChanged, isNull);
    });

    test('outcome copy is mapped, not raw', () {
      final s = _server(name: 'X');
      expect(mcpConnectOutcomeMessage(s, true, 'ok'), startsWith('X: Connected'));
      expect(
        mcpConnectOutcomeMessage(s, false, 'MCP handshake timed out'),
        'X: Timed out while connecting',
      );
      expect(
        mcpConnectOutcomeMessage(s, false, 'HTTP 401 Unauthorized'),
        'X: Needs sign-in',
      );
      expect(
        mcpConnectOutcomeMessage(
          s,
          false,
          '"X" degraded: needs configuration (TOKEN)',
        ),
        contains('Needs setup'),
      );
    });

    test('toggleMcpServer completes with the real outcome', () async {
      final app = AppState.I;
      // An unsupported transport fails fast without any process/network.
      final s = _server(name: 'bad', transport: 'websocket');
      app.mcpServers.add(s);
      final outcome = await app.toggleMcpServer(s);
      expect(outcome.ok, isFalse);
      expect(outcome.detail, contains('Unsupported transport'));
      expect(s.connected, isFalse);
    });
  });
}
