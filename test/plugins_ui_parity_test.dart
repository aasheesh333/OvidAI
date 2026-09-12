// Task 4 (Plugins/MCP UI Contraction): cross-task parity gate.
//
// Pins the three contracted behaviors together in one suite instead of
// re-proving each task in isolation:
//   1. GitHub-only install (no local/ZIP/npm/paste/direct-MCP routes);
//   2. single "+" sheet (one entry routing both GitHub fetch and
//      marketplace add);
//   3. durable MCP status with reasons (toggle outcomes persist under the
//      canonical id; UI renders durable-only; absence reads "Not started").
//
// Runtime behavior where possible; source-substring checks only for the
// absence of deleted routes and the diagnostics binary template.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

String _screenSource() =>
    File('lib/ui/plugins_screen.dart').readAsStringSync();

/// Body of the single add sheet, sliced between its declaration and the
/// GitHub-input helper definition that closes it.
String _sheetSlice(String src) {
  final start = src.indexOf('Future<void> showPluginAddSheet');
  assert(start >= 0, 'single add sheet missing');
  final end = src.indexOf('GithubPluginSource? _githubSourceFromInput(String', start);
  assert(end > start, 'sheet end marker missing');
  return src.substring(start, end);
}

McpServer _probeHttp(String name, {List<String> needsEnv = const []}) =>
    McpServer(
      name: name,
      author: 'parity',
      description: 'contraction parity probe',
      category: 'Custom',
      command: 'echo',
      custom: true,
      transport: 'http',
      url: 'https://parity.invalid/mcp',
      requiredEnvNames: needsEnv,
    );

MockClient _okHandshake() => MockClient((request) async {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final id = body['id'];
  if (body['method'] == 'tools/list') {
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [
            {'name': 'parity-tool'},
          ],
        },
      }),
      200,
    );
  }
  return http.Response(
    jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {}}),
    200,
  );
});

MockClient _brokenHandshake(String detail) =>
    MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': body['id'],
          'error': {'message': detail},
        }),
        200,
      );
    });

/// Toggle/connect paths persist asynchronously; poll until the canonical
/// record lands.
Future<PluginRuntimeStatus?> _pollCanonical(
  String canonicalId, {
  Duration budget = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(budget);
  while (DateTime.now().isBefore(end)) {
    final rec = AppState.I.statusFor(canonicalId);
    if (rec != null) return rec;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return AppState.I.statusFor(canonicalId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });

  tearDown(() async {
    McpService.I.httpClientForTest = null;
    for (final s in List<McpServer>.of(AppState.I.mcpServers)) {
      await McpService.I.disconnect(s.canonicalId);
    }
    AppState.resetTestInstance();
  });

  test('contracted surface keeps only the GitHub route', () {
    final src = _screenSource();
    final sheet = _sheetSlice(src);
    // GitHub fetch path survives inside the single sheet.
    expect(sheet, contains('Fetch from GitHub'));
    expect(sheet, contains('_githubSourceFromInput'));
    expect(sheet, contains('_runSourceInstall'));
    // The five removed install routes stay gone from the sheet.
    expect(sheet, isNot(contains('Local folder')));
    expect(sheet, isNot(contains('ZIP archive')));
    expect(sheet, isNot(contains('Install from npm')));
    expect(sheet, isNot(contains('PASTE MCP CONFIG')));
    expect(sheet, isNot(contains('DIRECT MCP SERVER')));
    expect(sheet, isNot(contains('Add MCP server')));
    // File-picker seams stay deleted with their call sites.
    expect(src, isNot(contains('pluginPickDirectoryForTest')));
    expect(src, isNot(contains('pluginPickZipFileForTest')));
    // Old chooser entry point is folded away.
    expect(src, isNot(contains('showPluginSourceChooser')));
  });

  test('single sheet carries both GitHub fetch and marketplace add', () {
    final sheet = _sheetSlice(_screenSource());
    expect(sheet, contains('Add plugin or marketplace'));
    expect(sheet, contains('Add marketplace'));
    expect(sheet, contains('addMarketplace'));
    expect(sheet, contains('fetchMarketplaceCatalog'));
    expect(sheet, contains('YOUR MARKETPLACES'));
  });

  testWidgets('one "+" opens one sheet with both actions', (tester) async {
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

    // Exactly one "+" plus the separate refresh affordance.
    expect(find.byTooltip('Add plugin or marketplace'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byTooltip('Refresh marketplaces'), findsOneWidget);
    expect(find.byTooltip('Add marketplace'), findsNothing);
    expect(find.text('Use + to add from GitHub'), findsOneWidget);

    await tester.tap(find.byTooltip('Add plugin or marketplace'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Fetch from GitHub'), findsOneWidget);
    expect(find.text('Add marketplace'), findsWidgets);
    expect(find.text('Local folder'), findsNothing);
    expect(find.text('Add custom MCP server'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('connect success persists ready plus reason', () async {
    final app = AppState.I;
    McpService.I.httpClientForTest = _okHandshake();
    final s = _probeHttp('parity-ready');
    app.mcpServers.add(s);

    app.toggleMcpServer(s);

    final rec = await _pollCanonical(s.canonicalId);
    expect(rec, isNotNull, reason: 'success must land in the durable store');
    expect(rec!.state, StartupItemState.ready);
    expect(rec.reason, 'connected');
    expect(mcpDurableStatusText(s), 'Ready · connected');
    expect(
      app.serviceStatus['mcp:${s.canonicalId}']?.health,
      ServiceHealth.working,
    );
    expect(s.connected, isTrue);
  });

  test('connect failure persists failed with a scrubbed reason', () async {
    final app = AppState.I;
    McpService.I.httpClientForTest = _brokenHandshake(
      'parity handshake blew up, token=parity-secret-77',
    );
    final s = _probeHttp('parity-broken');
    app.mcpServers.add(s);

    app.toggleMcpServer(s);

    final rec = await _pollCanonical(s.canonicalId);
    expect(rec, isNotNull, reason: 'failure must land in the durable store');
    expect(rec!.state, StartupItemState.failed);
    expect(rec.reason, contains('[REDACTED]'));
    expect(rec.reason, isNot(contains('parity-secret-77')));
    expect(mcpDurableStatusText(s), startsWith('Failed · '));
    expect(
      app.serviceStatus['mcp:${s.canonicalId}']?.health,
      ServiceHealth.failed,
    );
    expect(s.connected, isFalse);
  });

  test('credential block and disconnect persist their reasons', () async {
    final app = AppState.I;
    McpService.I.httpClientForTest = _okHandshake();

    final blocked = _probeHttp(
      'parity-blocked',
      needsEnv: ['PARITY_GATE_TOKEN'],
    );
    app.mcpServers.add(blocked);
    app.toggleMcpServer(blocked);
    final blockedRec = await _pollCanonical(blocked.canonicalId);
    expect(blockedRec, isNotNull);
    expect(blockedRec!.state, StartupItemState.needsSetup);
    expect(blockedRec.reason, contains('PARITY_GATE_TOKEN'));
    expect(blocked.connected, isFalse);

    final live = _probeHttp('parity-live');
    live.connected = true;
    app.mcpServers.add(live);
    app.updateServiceStatus(
      'mcp:${live.canonicalId}',
      ServiceHealth.working,
      detail: 'connected',
    );
    app.toggleMcpServer(live);
    final offRec = await _pollCanonical(live.canonicalId);
    expect(offRec, isNotNull);
    expect(offRec!.state, StartupItemState.disabled);
    expect(offRec.reason, 'disconnected — tap Connect to start');
    expect(mcpDurableStatusText(live), startsWith('Disabled · '));
    expect(app.serviceStatus.containsKey('mcp:${live.canonicalId}'), isFalse);
  });

  testWidgets('no record reads neutral; diagnostics read durable', (
    tester,
  ) async {
    final app = AppState.I;
    final s = _probeHttp('parity-neutral');
    // Live "connected" state must not leak into the durable UI.
    s.connected = true;
    app.updateServiceStatus(
      'mcp:${s.canonicalId}',
      ServiceHealth.working,
      detail: 'connected',
    );
    expect(mcpDurableStatusText(s), 'Not started');

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: McpCard(server: s)),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.text('Not started'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);

    // Once the durable write lands, card + helper agree on label · reason.
    await tester.runAsync(() => app.recordStartupStatus(
      StartupItemStatus(
        id: s.canonicalId,
        kind: StartupItemKind.mcp,
        label: 'Connect parity-neutral',
        state: StartupItemState.ready,
        reason: 'connected',
      ),
      ownerId: s.canonicalId,
    ));
    expect(mcpDurableStatusText(s), 'Ready · connected');

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: McpCard(server: s)),
      ),
    );
    await tester.pump();
    expect(find.text('Ready · connected'), findsOneWidget);

    // Diagnostics row is durable-only: binary template gone, helper wired.
    final src = _screenSource();
    expect(
      src,
      isNot(contains("s.connected ? 'Connected' : 'Not connected'")),
    );
    expect(src, contains('mcpDurableStatusText(s)'));
    expect(tester.takeException(), isNull);
  });
}
