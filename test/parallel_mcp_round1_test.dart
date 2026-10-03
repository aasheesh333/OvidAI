import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final svc = McpService.I;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });
  tearDown(() async {
    await svc.disconnectAll();
    svc.httpClientForTest = null;
    AppState.resetTestInstance();
  });

  for (final missing in [true, false]) {
    for (final badPage in [1, 2]) {
      final label = '${missing ? 'missing' : 'null'} tools on page $badPage';
      test('HTTP discovery rejects $label', () async {
        var pages = 0;
        svc.httpClientForTest = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          final result = <String, dynamic>{};
          if (body['method'] == 'tools/list') {
            pages++;
            if (pages == badPage) {
              if (!missing) result['tools'] = null;
            } else {
              result.addAll({'tools': [{'name': 'partial'}], 'nextCursor': 'next'});
            }
          }
          return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}), 200);
        });
        final server = McpServer(name: 'round1-http', author: 'test', description: '',
            category: 'Custom', command: '', transport: 'http', url: 'https://mcp.test');
        final outcome = await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 2));
        expect(outcome.isReady, isFalse);
        expect(outcome.reason, contains('tools array'));
        expect(pages, badPage);
        expect(svc.connectedTools[server.canonicalId], isNull);
      });

      test('stdio refresh retains previous catalog after $label', () async {
        final process = await Process.start('python3', ['-u', '-c', r'''
import json, sys
bad_page, missing = int(sys.argv[1]), sys.argv[2] == 'true'
pages = 0
for line in sys.stdin:
    m = json.loads(line)
    if m['method'] == 'tools/call':
        if m['params']['name'] == 'trigger':
            print(json.dumps({'jsonrpc':'2.0','method':'notifications/tools/list_changed'}), flush=True)
        result = {'content':[{'type':'text','text':str(pages)}]}
    elif m['method'] == 'tools/list':
        pages += 1
        result = ({} if missing else {'tools':None}) if pages == bad_page else {'tools':[{'name':'partial'}], 'nextCursor':'next'}
    else:
        continue
    print(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':result}), flush=True)
''', '$badPage', '$missing']);
        addTearDown(() => process.kill());
        final server = McpServer(name: 'round1-stdio', author: 'test', description: '',
            category: 'Custom', command: 'python3');
        await svc.attachStdioForTest(server, process,
            initialTools: [McpToolDef(name: 'previous')]);
        await svc.callTool(server.canonicalId, 'trigger', {});
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        var pages = 0;
        while (pages < badPage && DateTime.now().isBefore(deadline)) {
          pages = int.parse(await svc.callTool(server.canonicalId, 'barrier', {}));
        }
        // A second protocol barrier lets the list result continuation settle.
        await svc.callTool(server.canonicalId, 'barrier', {});
        expect(pages, badPage);
        expect(svc.connectedTools[server.canonicalId]!.map((t) => t.name), ['previous']);
        expect(svc.isConnected(server.canonicalId), isTrue);
      });
    }
  }

  const aliases = ['timeout', 'startupTimeoutS', 'startup_timeout_s'];
  for (final format in ['JSON', 'TOML']) {
    for (final first in aliases) {
      for (final second in aliases.where((a) => a != first)) {
        test('$format rejects conflicting $first / $second atomically', () {
          final raw = format == 'JSON'
              ? jsonEncode({'mcpServers': {'good': {'command': 'node'}, 'bad': {'command': 'node', first: 5, second: 8}}})
              : '[mcp_servers.good]\ncommand="node"\n[mcp_servers.bad]\ncommand="node"\n$first=5\n$second=8';
          expect(parseMcpConfig(raw, env: const {}), isEmpty);
        });
      }
    }
    test('$format accepts equivalent timeout aliases', () {
      final raw = format == 'JSON'
          ? '{"mcpServers":{"same":{"command":"node","timeout":5,"startupTimeoutS":5,"startup_timeout_s":5}}}'
          : '[mcp_servers.same]\ncommand="node"\ntimeout=5\nstartupTimeoutS=5\nstartup_timeout_s=5';
      final entry = parseMcpConfig(raw, env: const {}).single;
      expect(entry.startupTimeoutS, 5);
      expect(entry.ignoredKeys, isEmpty);
    });
    test('$format accepts standalone snake-case timeout', () {
      final raw = format == 'JSON'
          ? '{"mcpServers":{"same":{"command":"node","startup_timeout_s":8}}}'
          : '[mcp_servers.same]\ncommand="node"\nstartup_timeout_s=8';
      expect(parseMcpConfig(raw, env: const {}).single.startupTimeoutS, 8);
    });
  }
}
