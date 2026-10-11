// PR-4a — MCP/plugin correctness and destructive safety (F-078…F-091).
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
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
}
