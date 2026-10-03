import 'dart:convert';

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

  for (final scenario in ['repeated cursor', 'page cap', 'tool count', 'catalog bytes']) {
    test('discovery rejects $scenario without publishing partial tools', () async {
      var pages = 0;
      svc.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final result = <String, dynamic>{};
        if (body['method'] == 'tools/list') {
          pages++;
          result['tools'] = scenario == 'tool count'
              ? List.generate(10001, (i) => {'name': 'tool-$i'})
              : [{'name': 'tool-$pages', if (scenario == 'catalog bytes') 'description': 'x' * (4 * 1024 * 1024 + 1)}];
          if (scenario == 'repeated cursor') result['nextCursor'] = 'repeat';
          if (scenario == 'page cap') result['nextCursor'] = 'page-$pages';
        }
        return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': result}), 200);
      });
      final server = McpServer(name: 'bounded-$scenario', author: 'test', description: '',
          category: 'Custom', command: '', transport: 'http', url: 'https://mcp.test');
      final result = await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 3));
      expect(result.isReady, isFalse);
      expect(svc.connectedTools[server.canonicalId], isNull);
      if (scenario == 'repeated cursor') expect(pages, 2);
      if (scenario == 'page cap') expect(pages, 50);
    });
  }

  for (final malformed in [null, {'tools': 'invalid'}, {'tools': [{'name': 'echo'}, {'name': 'echo'}]}, {'tools': [], 'nextCursor': 123}]) {
    test('malformed or ambiguous tool page is not a successful catalog: $malformed', () async {
      svc.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        return http.Response(jsonEncode({'jsonrpc': '2.0', 'id': body['id'],
          'result': body['method'] == 'tools/list' ? malformed : {}}), 200);
      });
      final server = McpServer(name: 'malformed', author: 'test', description: '',
          category: 'Custom', command: '', transport: 'http', url: 'https://mcp.test');
      expect((await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 1))).isReady, isFalse);
    });
  }

  final ambiguous = <String, String>{
    'duplicate array name': '[{"name":"same","command":"one"},{"name":"same","command":"two"}]',
    'normalized map name': '{"mcpServers":{"same":{"command":"one"}," same ":{"command":"two"}}}',
    'duplicate JSON key': '{"mcpServers":{"same":{"command":"one"},"same":{"command":"two"}}}',
    'escaped duplicate JSON key': r'{"mcpServers":{"same":{"command":"one"},"\u0073ame":{"command":"two"}}}',
    'multiple wrappers': '{"mcpServers":{"one":{"command":"one"}},"servers":{"two":{"command":"two"}}}',
    'conflicting transport': '{"mcpServers":{"one":{"type":"sse","transport":"http","url":"https://mcp.test"}}}',
    'conflicting command': '{"mcpServers":{"one":{"command":"one","cmd":"two"}}}',
    'duplicate TOML table': '[mcp_servers.same]\ncommand="one"\n[mcp_servers.same]\ncommand="two"',
    'duplicate TOML key': '[mcp_servers.same]\ncommand="one"\ncommand="two"',
    'duplicate TOML env': '[mcp_servers.same]\ncommand="one"\nenv.KEY="one"\n[mcp_servers.same.env]\nKEY="two"',
    'conflicting TOML transport': '[mcp_servers.same]\ntype="sse"\ntransport="http"\nurl="https://mcp.test"',
    'conflicting timeout aliases': '{"mcpServers":{"one":{"command":"one","timeout":5,"startup_timeout_s":8}}}',
  };
  for (final entry in ambiguous.entries) {
    test('import rejects ${entry.key} atomically', () {
      expect(parseMcpConfig(entry.value, env: const {}), isEmpty);
    });
  }

  test('unambiguous aliases preserve args, references, OAuth and timeout', () {
    final imported = parseMcpConfig(r'''{"mcpServers":{"safe":{
      "command":"node","cmd":"node","args":["a b","","quote\""],
      "type":"http","transport":"streamable-http","url":"https://mcp.test",
      "env":{"TOKEN":"${TOKEN}"},"headers":{"Authorization":"Bearer ${AUTH}"},
      "startup_timeout_s":17,"oauth":{"client_id":"id","authorization_url":"https://auth.test","scopes":["read"]}
    }}}''', env: const {}).single;
    expect(imported.args, ['a b', '', 'quote"']);
    expect(imported.env['TOKEN'], r'${TOKEN}');
    expect(imported.headers['Authorization'], r'Bearer ${AUTH}');
    expect(imported.oauth!.scopes, ['read']);
    expect(imported.type, 'http');
    expect(imported.startupTimeoutS, 17);
  });
}
