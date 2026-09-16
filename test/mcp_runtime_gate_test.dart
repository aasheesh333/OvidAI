import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

/// Stdio MCP servers need their language runtime (node/python) BEFORE the
/// handshake budget starts — installing runtimes inside the 30s budget
/// guaranteed a first-enable timeout. Missing runtimes surface as a
/// distinct needsRuntime outcome with an install action, never a timeout.
void main() {
  McpServer stdio(String command) => McpServer(
    name: 'test-stdio',
    author: 'test',
    description: 'test',
    category: 'Custom',
    command: command,
    custom: true,
  );

  tearDown(() {
    McpService.missingRuntimeOverrideForTest = null;
  });

  test('npx without node runtime is missing', () async {
    final missing = await McpService.I.missingRuntimeFor(
      stdio('npx'),
      hasRuntime: (_) async => false,
      sandboxInstalled: true,
    );
    expect(missing, 'node');
  });

  test('present runtime is not missing', () async {
    final missing = await McpService.I.missingRuntimeFor(
      stdio('npx'),
      hasRuntime: (_) async => true,
      sandboxInstalled: true,
    );
    expect(missing, isNull);
  });

  test('non-stdio transports never need runtimes', () async {
    final http = McpServer(
      name: 'test-http',
      author: 'test',
      description: 'test',
      category: 'Custom',
      command: '',
      transport: 'http',
      url: 'https://mcp.example/rpc',
      custom: true,
    );
    expect(
      await McpService.I.missingRuntimeFor(
        http,
        hasRuntime: (_) async => false,
        sandboxInstalled: true,
      ),
      isNull,
    );
  });

  test('unknown commands need nothing', () async {
    expect(
      await McpService.I.missingRuntimeFor(
        stdio('myserver'),
        hasRuntime: (_) async => false,
        sandboxInstalled: true,
      ),
      isNull,
    );
  });

  test('connectOutcome reports needsRuntime instead of burning the budget',
      () async {
    McpService.missingRuntimeOverrideForTest = (_) async => 'node';
    final outcome = await McpService.I.connectOutcome(
      stdio('npx'),
      handshakeBudget: const Duration(seconds: 30),
    );
    expect(outcome.kind, McpConnectOutcomeKind.needsRuntime);
    expect(outcome.reason, contains('ode'));
  });
}
