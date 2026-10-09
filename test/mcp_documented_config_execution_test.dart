import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

const _script = r'''
import json, sys
initialized = False
for line in sys.stdin:
    msg = json.loads(line)
    method = msg.get('method')
    if method == 'notifications/initialized':
        initialized = True
    if 'id' not in msg:
        continue
    if method == 'initialize':
        result = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}},
                  'serverInfo': {'name': 'config-probe', 'version': '1'}}
    elif method == 'tools/list' and initialized:
        result = {'tools': [{'name': 'report', 'inputSchema': {'type': 'object'}}]}
    elif method == 'tools/call' and initialized:
        args = msg['params']['arguments']
        result = {'content': [{'type': 'resource_link', 'uri': 'file:///reports/result.json',
                              'name': 'result.json', 'description': 'Generated report',
                              'mimeType': 'application/json'}],
                  'isError': args.get('fail', False)}
    else:
        sys.exit(2)
    print(json.dumps({'jsonrpc': '2.0', 'id': msg['id'], 'result': result}), flush=True)
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    McpService.missingRuntimeOverrideForTest = (_) async => null;
    McpService.spawnProcessForTest = (argv, {env, hostWorkDir}) => Process.start(
      argv.first,
      argv.sublist(1),
      environment: {...Platform.environment, ...?env},
      workingDirectory: hostWorkDir?.path,
    );
  });

  tearDown(() async {
    await McpService.I.disconnectAll();
    McpService.spawnProcessForTest = null;
    McpService.missingRuntimeOverrideForTest = null;
    AppState.resetTestInstance();
  });

  Future<McpServer> connect(String command, {Map<String, String>? env}) async {
    final parsed = parseMcpConfig(jsonEncode({
      'mcpServers': {
        'config-probe': {'command': command, 'args': ['-u', '-c', _script]},
      },
    }), env: env).single;
    final server = McpServer(
      name: parsed.name,
      author: 'test',
      description: '',
      category: 'Custom',
      command: parsed.command,
      args: parsed.args,
      transport: parsed.type,
    );
    final outcome = await McpService.I.connectOutcome(
      server, handshakeBudget: const Duration(seconds: 5),
    );
    expect(outcome.isReady, isTrue, reason: outcome.reason);
    expect(McpService.I.connectedTools[server.canonicalId]!.single.name, 'report');
    return server;
  }

  test('expanded command starts a real stdio server', () async {
    await connect(r'${MCP_EXECUTABLE}', env: {'MCP_EXECUTABLE': 'python3'});
  });

  test('command fallback starts a real stdio server', () async {
    await connect(r'${MCP_EXECUTABLE:-python3}', env: {});
  });

  test('unresolved command remains visible and missing command stays empty', () {
    expect(importedMcpFromJson('s', {'command': r'${MISSING}'}, env: {}).command,
        r'${MISSING}');
    expect(importedMcpFromJson('s', {}, env: {}).command, isEmpty);
  });

  test('resource-link-only result retains the URI and metadata', () async {
    final server = await connect('python3');
    final result = await McpService.I.callTool(server.canonicalId, 'report', {});
    expect(result, contains('file:///reports/result.json'));
    expect(result, contains('Generated report'));
    expect(result, contains('application/json'));
    expect(result, isNot(startsWith('MCP error:')));
  });

  test('resource link in a failed result retains the error flag', () async {
    final server = await connect('python3');
    final result = await McpService.I.callTool(server.canonicalId, 'report', {'fail': true});
    expect(result, startsWith('MCP error:'));
    expect(result, contains('file:///reports/result.json'));
  });
}
