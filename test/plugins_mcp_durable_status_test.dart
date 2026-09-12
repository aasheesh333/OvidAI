// Task 3 (Plugins/MCP UI Contraction, spec §5.3): durable MCP status
// end-to-end.
//
// Every live MCP outcome records the durable canonical store
// (runtimeStatusStore) under the server's canonical id — connect success
// → ready ("connected"), failure → failed (redacted reason), pre-spawn
// credential block → needsSetup (missing names), user disconnect →
// disabled ("disconnected — tap Connect to start") — and the MCP UI
// (McpCard, McpDetailScreen header, diagnostics row) renders durable-only,
// with neutral "Not started" when no record exists.
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

McpServer _httpServer(String name, {List<String> requiredEnv = const []}) =>
    McpServer(
      name: name,
      author: 'test',
      description: 'durable status probe',
      category: 'Custom',
      command: 'echo',
      custom: true,
      transport: 'http',
      url: 'https://example.test/mcp',
      requiredEnvNames: requiredEnv,
    );

/// HTTP handshake stub: initialize → {}, tools/list → one tool.
MockClient _successClient() => MockClient((request) async {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  final id = body['id'];
  if (body['method'] == 'tools/list') {
    return http.Response(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [
            {'name': 'lookup'},
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

/// HTTP handshake stub: initialize answers a JSON-RPC error carrying
/// [message] (used to prove failure reasons are redacted).
MockClient _failureClient(String message) => MockClient((request) async {
  final body = jsonDecode(request.body) as Map<String, dynamic>;
  return http.Response(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': body['id'],
      'error': {'message': message},
    }),
    200,
  );
});

/// Polls the durable store until a record appears (toggle paths record
/// asynchronously via unawaited futures).
Future<PluginRuntimeStatus?> _waitForStatus(
  String canonicalId, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
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

  group('durable MCP recording (core)', () {
    test('toggle connect success records durable ready with reason', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _successClient();
      final s = _httpServer('durable-ok');
      app.mcpServers.add(s);

      app.toggleMcpServer(s);

      final rec = await _waitForStatus(s.canonicalId);
      expect(rec, isNotNull, reason: 'toggle success must record durably');
      expect(rec!.state, StartupItemState.ready);
      expect(rec.reason, 'connected');
      // Existing live behavior stays intact.
      expect(
        app.serviceStatus['mcp:${s.canonicalId}']?.health,
        ServiceHealth.working,
      );
      expect(s.connected, isTrue);
    });

    test('toggle connect failure records durable failed, redacted', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _failureClient(
        'initialize blew up, token=abc123',
      );
      final s = _httpServer('durable-fail');
      app.mcpServers.add(s);

      app.toggleMcpServer(s);

      final rec = await _waitForStatus(s.canonicalId);
      expect(rec, isNotNull, reason: 'toggle failure must record durably');
      expect(rec!.state, StartupItemState.failed);
      expect(rec.reason, contains('[REDACTED]'));
      expect(rec.reason, isNot(contains('abc123')));
      // Existing live behavior stays intact.
      expect(
        app.serviceStatus['mcp:${s.canonicalId}']?.health,
        ServiceHealth.failed,
      );
      expect(s.connected, isFalse);
    });

    test('toggle credential block records durable needsSetup', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _successClient();
      final s = _httpServer(
        'durable-needs',
        requiredEnv: ['DURABLE_TEST_TOKEN'],
      );
      app.mcpServers.add(s);

      app.toggleMcpServer(s);

      final rec = await _waitForStatus(s.canonicalId);
      expect(
        rec,
        isNotNull,
        reason: 'credential block must record needsSetup durably',
      );
      expect(rec!.state, StartupItemState.needsSetup);
      expect(rec.reason, contains('DURABLE_TEST_TOKEN'));
      expect(s.connected, isFalse);
    });

    test('toggle disconnect records durable disabled', () async {
      final app = AppState.I;
      final s = _httpServer('durable-off');
      s.connected = true;
      app.mcpServers.add(s);
      app.updateServiceStatus(
        'mcp:${s.canonicalId}',
        ServiceHealth.working,
        detail: 'connected',
      );

      app.toggleMcpServer(s);

      final rec = await _waitForStatus(s.canonicalId);
      expect(rec, isNotNull, reason: 'disconnect must record durably');
      expect(rec!.state, StartupItemState.disabled);
      expect(rec.reason, 'disconnected — tap Connect to start');
      // Existing live behavior stays intact: the live entry is removed.
      expect(app.serviceStatus.containsKey('mcp:${s.canonicalId}'), isFalse);
      expect(s.connected, isFalse);
    });

    test('reconnectServices records durable ready (sibling path)', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _successClient();
      final s = _httpServer('durable-reconnect');
      app.mcpServers.add(s);

      await app.reconnectServices(targetServers: [s.canonicalId]);

      final rec = app.statusFor(s.canonicalId);
      expect(rec, isNotNull, reason: 'reconnect must record durably');
      expect(rec!.state, StartupItemState.ready);
      expect(rec.reason, 'connected');
    });

    test('startup connect success records durable ready', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _successClient();
      final s = _httpServer('durable-startup-ok');
      app.mcpServers.add(s);

      final outcome = await app.connectMcpForStartupForTest(
        s.canonicalId,
        const Duration(seconds: 5),
      );

      expect(outcome.kind, McpConnectOutcomeKind.ready);
      final rec = app.statusFor(s.canonicalId);
      expect(rec, isNotNull);
      expect(rec!.state, StartupItemState.ready);
      expect(rec.reason, 'connected');
    });

    test('startup connect failure records durable failed, redacted', () async {
      final app = AppState.I;
      McpService.I.httpClientForTest = _failureClient(
        'handshake denied, api-key=zzz999',
      );
      final s = _httpServer('durable-startup-fail');
      app.mcpServers.add(s);

      final outcome = await app.connectMcpForStartupForTest(
        s.canonicalId,
        const Duration(seconds: 5),
      );

      expect(outcome.kind, McpConnectOutcomeKind.failed);
      final rec = app.statusFor(s.canonicalId);
      expect(rec, isNotNull);
      expect(rec!.state, StartupItemState.failed);
      expect(rec.reason, contains('[REDACTED]'));
      expect(rec.reason, isNot(contains('zzz999')));
    });

    test('startup connect credential block records needsSetup', () async {
      final app = AppState.I;
      final s = _httpServer(
        'durable-startup-needs',
        requiredEnv: ['DURABLE_STARTUP_TOKEN'],
      );
      app.mcpServers.add(s);

      final outcome = await app.connectMcpForStartupForTest(
        s.canonicalId,
        const Duration(seconds: 5),
      );

      expect(outcome.kind, McpConnectOutcomeKind.needsSetup);
      final rec = app.statusFor(s.canonicalId);
      expect(rec, isNotNull);
      expect(rec!.state, StartupItemState.needsSetup);
      expect(rec.reason, contains('DURABLE_STARTUP_TOKEN'));
    });

    test('startup disable records durable disabled', () async {
      final app = AppState.I;
      final s = _httpServer('durable-startup-off');
      s.connected = true;
      app.mcpServers.add(s);
      app.updateServiceStatus(
        'mcp:${s.canonicalId}',
        ServiceHealth.working,
        detail: 'connected',
      );

      await app.disableMcpForStartupForTest(s.canonicalId);

      final rec = app.statusFor(s.canonicalId);
      expect(rec, isNotNull);
      expect(rec!.state, StartupItemState.disabled);
      expect(rec.reason, 'disconnected — tap Connect to start');
      expect(s.connected, isFalse);
    });

    test('mcpDurableStatusText is neutral without a record', () {
      final s = _httpServer('durable-text-none');
      s.connected = true;
      expect(mcpDurableStatusText(s), 'Not started');
    });

    test('mcpDurableStatusText renders durable label and reason', () async {
      final app = AppState.I;
      final s = _httpServer('durable-text-ready');
      await app.recordStartupStatus(
        StartupItemStatus(
          id: s.canonicalId,
          kind: StartupItemKind.mcp,
          label: 'Connect durable-text-ready',
          state: StartupItemState.ready,
          reason: 'connected',
        ),
        ownerId: s.canonicalId,
      );
      expect(mcpDurableStatusText(s), 'Ready · connected');
    });
  });

  group('durable MCP rendering (UI)', () {
    testWidgets('McpCard with no record renders neutral, never live state', (
      tester,
    ) async {
      final app = AppState.I;
      final s = _httpServer('durable-card-neutral');
      s.connected = true;
      app.updateServiceStatus(
        'mcp:${s.canonicalId}',
        ServiceHealth.working,
        detail: 'connected',
      );

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
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      final card = tester.widget<Container>(
        find.byKey(ValueKey('mcp-card-${s.canonicalId}')),
      );
      final decoration = card.decoration! as BoxDecoration;
      expect((decoration.border! as Border).top.color, Aether.hairline);
      expect(tester.takeException(), isNull);
    });

    testWidgets('McpCard renders durable ready and failed', (tester) async {
      final app = AppState.I;
      final s = _httpServer('durable-card-states');

      await tester.runAsync(() => app.recordStartupStatus(
        StartupItemStatus(
          id: s.canonicalId,
          kind: StartupItemKind.mcp,
          label: 'Connect durable-card-states',
          state: StartupItemState.ready,
          reason: 'connected',
        ),
        ownerId: s.canonicalId,
      ));
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: McpCard(server: s)),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.text('Ready · connected'), findsOneWidget);

      await tester.runAsync(() => app.recordStartupStatus(
        StartupItemStatus(
          id: s.canonicalId,
          kind: StartupItemKind.mcp,
          label: 'Connect durable-card-states',
          state: StartupItemState.failed,
          reason: 'boom',
        ),
        ownerId: s.canonicalId,
      ));
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(body: McpCard(server: s)),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.text('Failed · boom'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('McpDetailScreen header is durable-only', (tester) async {
      final app = AppState.I;
      final s = _httpServer('durable-detail');

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: McpDetailScreen(server: s),
        ),
      );
      await tester.pump();
      expect(find.text('Not started'), findsOneWidget);

      await tester.runAsync(() => app.recordStartupStatus(
        StartupItemStatus(
          id: s.canonicalId,
          kind: StartupItemKind.mcp,
          label: 'Connect durable-detail',
          state: StartupItemState.ready,
          reason: 'connected',
        ),
        ownerId: s.canonicalId,
      ));
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: McpDetailScreen(server: s),
        ),
      );
      await tester.pump();
      expect(find.text('Ready · connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('diagnostics MCP row never renders binary connected state', () {
      final src = File('lib/ui/plugins_screen.dart').readAsStringSync();
      expect(
        src,
        isNot(contains("s.connected ? 'Connected' : 'Not connected'")),
      );
      expect(src, contains('mcpDurableStatusText'));
    });
  });
}
