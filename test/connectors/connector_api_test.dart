// Connectors must be backed by the gateway, not by a local prefs list.
//
// The wire shapes asserted here come from
//   cloud/apps/gateway/src/routes/mcpCatalog.ts   GET  /mcp/catalog -> {items:[...]}
//   cloud/apps/gateway/src/routes/mcpServers.ts   GET  /mcp/servers -> [...]
//                                                 POST /mcp/servers -> McpServerDto
//                                                 DELETE /mcp/servers/:id -> 204
// — the server is the contract.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/connectors/connector_api.dart';

const String _base = 'https://cloud.test/cloud/v1';

void main() {
  late List<http.Request> requests;

  ConnectorApi apiWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    requests = [];
    return ConnectorApi(
      rest: CloudRestClient(
        httpClient: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
        headers: CloudHeaders.forTest(),
        restBase: _base,
      ),
    );
  }

  http.Response json(Object body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );

  test('listCatalog reads the curated catalog the gateway serves', () async {
    final api = apiWith((r) async => json({
          'items': [
            {
              'curatedId': 'github',
              'displayName': 'GitHub',
              'description': 'Repos, issues and pull requests.',
              'credentialFields': [
                {'key': 'GITHUB_TOKEN', 'label': 'Token', 'secret': true},
              ],
              'tools': [
                {'name': 'github_search', 'description': 'Search code.'},
              ],
              'configured': true,
            },
          ],
        }));

    final items = await api.listCatalog();

    expect(requests.single.method, 'GET');
    expect(requests.single.url.toString(), '$_base/mcp/catalog');
    expect(items, hasLength(1));
    expect(items.single.curatedId, 'github');
    expect(items.single.displayName, 'GitHub');
    expect(items.single.configured, isTrue);
    expect(items.single.credentialFields.single.key, 'GITHUB_TOKEN');
    expect(items.single.toolNames, ['github_search']);
  });

  test('listServers reads the bare array the gateway answers', () async {
    final api = apiWith((r) async => json([
          {
            'id': 'srv-1',
            'name': 'GitHub',
            'transport': 'http',
            'curatedId': 'github',
            'enabled': true,
            'hasSecrets': true,
            'needsAuth': false,
          },
        ]));

    final servers = await api.listServers();

    expect(requests.single.url.toString(), '$_base/mcp/servers');
    expect(servers.single.id, 'srv-1');
    expect(servers.single.curatedId, 'github');
    expect(servers.single.enabled, isTrue);
  });

  test('connectCurated posts the curated id and its secrets', () async {
    final api = apiWith((r) async => json({
          'id': 'srv-2',
          'name': 'Notion',
          'transport': 'http',
          'curatedId': 'notion',
          'enabled': true,
          'hasSecrets': true,
          'needsAuth': false,
        }, 201));

    final server = await api.connectCurated(
      curatedId: 'notion',
      secrets: const {'NOTION_TOKEN': 'secret-value'},
    );

    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(), '$_base/mcp/servers');
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['curatedId'], 'notion');
    expect(body['secrets'], {'NOTION_TOKEN': 'secret-value'});
    expect(server.id, 'srv-2');
  });

  test('disconnect deletes by id', () async {
    final api = apiWith((r) async => http.Response('', 204));

    await api.disconnect('srv-2');

    expect(requests.single.method, 'DELETE');
    expect(requests.single.url.toString(), '$_base/mcp/servers/srv-2');
  });

  test('a plan refusal surfaces as the server code, not a fake success', () async {
    final api = apiWith((r) async => json({
          'error': {
            'code': 'connector_limit_reached',
            'message': 'Your plan includes 5 custom connectors.',
          },
        }, 402));

    await expectLater(
      api.connectCurated(curatedId: 'notion'),
      throwsA(isA<CloudApiException>()
          .having((e) => e.code, 'code', 'connector_limit_reached')),
    );
  });
}
