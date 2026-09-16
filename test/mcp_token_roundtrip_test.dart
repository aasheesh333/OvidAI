import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A saved token must unblock the server end to end: setMcpEnv empties
/// missingCredentialsFor, and the native GitHub handshake then reports
/// ready — no network, no login required.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    McpService.missingRuntimeOverrideForTest = null;
    await McpService.I.disconnect('GitHub');
    AppState.I.mcpServers.removeWhere((s) => s.name == 'GitHub');
  });

  // Exact production seed identity: the native handler resolves by name.
  McpServer githubServer() => McpServer(
    name: 'GitHub',
    author: 'modelcontextprotocol',
    description: 'test github native',
    category: 'Official',
    command: '',
    args: const [],
    envHint: 'GITHUB_TOKEN',
    transport: 'native',
  );

  test('saved GITHUB_TOKEN clears the gate and connects', () async {
    final server = githubServer();
    AppState.I.mcpServers.add(server);

    // Gate starts closed.
    expect(
      await McpService.I.missingCredentialsFor(server),
      contains('GITHUB_TOKEN'),
    );

    await AppState.I.setMcpEnv(server.canonicalId, {
      'GITHUB_TOKEN': 'test-token-123',
    });

    // Gate opens…
    expect(await McpService.I.missingCredentialsFor(server), isEmpty);
    // …and the handshake reports ready.
    final outcome = await McpService.I.connectOutcome(
      server,
      handshakeBudget: const Duration(seconds: 30),
    );
    expect(outcome.kind, McpConnectOutcomeKind.ready);
    expect(McpService.I.isConnected(server.canonicalId), isTrue);
  });
}
