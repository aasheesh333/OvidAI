import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/connectors/connector_api.dart';

const String _base = 'https://cloud.test/cloud/v1';
const String _connectionId = '018f3e11-aaaa-7bbb-8ccc-2d2d2d2d2d2d';

String _fixtureBytes() =>
    File('test/fixtures/contracts/mcp-connections-v1.json').readAsStringSync();

Map<String, dynamic> _fixture() =>
    (jsonDecode(_fixtureBytes()) as Map).cast<String, dynamic>();

Map<String, dynamic> _fixtureItem(int index) =>
    ((_fixture()['items'] as List)[index] as Map).cast<String, dynamic>();

void main() {
  late List<http.Request> requests;

  ConnectorApi apiWith(Future<http.Response> Function(http.Request) handler) {
    requests = <http.Request>[];
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

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const <String, String>{'content-type': 'application/json'},
  );

  test('listConnections consumes the byte-identical versioned fixture', () async {
    final raw = _fixtureBytes();
    final dynamic api = apiWith((request) async => http.Response(
      raw,
      200,
      headers: const <String, String>{'content-type': 'application/json'},
    ));

    final items = await api.listConnections() as List<dynamic>;

    expect(requests.single.method, 'GET');
    expect(requests.single.url.toString(), '$_base/mcp/connections');
    expect(items, hasLength(2));
    expect(items[0].connectionId, '019a0000-0000-7000-8000-000000000001');
    expect(items[0].providerId, 'google-drive');
    expect(items[0].connectionId, isNot(items[0].providerId));
    expect(items[0].agentEnabled, isFalse);
    expect(items[0].authState, 'configured');
    expect(items[0].healthState, 'never_checked');
    expect(items[0].lastCheckedAt, isNull);
    expect(items[0].lastSuccessAt, isNull);
    expect(items[1].enabled, isFalse);
    expect(items[1].agentEnabled, isFalse);
    expect(items[1].authState, 'revoked');
    expect(items[1].healthState, 'revoked');
    expect(
      items[1].lastCheckedAt?.toUtc().toIso8601String(),
      '2026-10-24T12:01:00.000Z',
    );
    expect(
      items[1].lastSuccessAt?.toUtc().toIso8601String(),
      '2026-10-24T12:00:30.000Z',
    );
    expect(items[1].approvedSourceId, 'source-fixture');
    expect(items[1].approvedDigest, 'sha256:approved-fixture');
    for (final item in _fixture()['items'] as List) {
      final map = (item as Map).cast<String, dynamic>();
      for (final forbidden in <String>[
        'secrets',
        'secretsSealed',
        'secrets_sealed',
        'config',
        'plaintextSecret',
        'authorization',
        'refreshToken',
      ]) {
        expect(map.containsKey(forbidden), isFalse, reason: forbidden);
      }
    }
  });

  test('multi-field create uses server UUID and explicit agent opt-in', () async {
    final dynamic api = apiWith(
      (request) async => json(<String, Object?>{
        ..._fixtureItem(0),
        'connectionId': _connectionId,
        'agentEnabled': true,
      }, 201),
    );

    final c = await api.createConnection(
      providerId: 'google-drive',
      secrets: const <String, String>{
        'CLIENT_ID': 'a',
        'CLIENT_SECRET': 'b',
      },
      agentEnabled: true,
    );

    expect(c.providerId, 'google-drive');
    expect(c.connectionId, _connectionId);
    expect(c.agentEnabled, isTrue);
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(), '$_base/mcp/connections');
    final body = (jsonDecode(requests.single.body) as Map)
        .cast<String, dynamic>();
    expect(body, <String, Object?>{
      'providerId': 'google-drive',
      'secrets': <String, String>{'CLIENT_ID': 'a', 'CLIENT_SECRET': 'b'},
      'agentEnabled': true,
    });
    expect(body.containsKey('curatedId'), isFalse);
    expect(body.containsKey('connectionId'), isFalse);
    expect(body.containsKey('config'), isFalse);
  });

  test('custom create sends only canonical approved-source fields', () async {
    final dynamic api = apiWith((request) async => json(_fixtureItem(1), 201));

    final connection = await api.createCustomConnection(
      providerId: 'approved-plugin',
      name: 'Approved plugin connector',
      approvedSourceId: 'source-fixture',
      approvedDigest: 'sha256:approved-fixture',
      secrets: const <String, String>{},
      agentEnabled: false,
    );

    expect(connection.connectionId, '019a0000-0000-7000-8000-000000000002');
    final body = (jsonDecode(requests.single.body) as Map)
        .cast<String, dynamic>();
    expect(body, <String, Object?>{
      'providerId': 'approved-plugin',
      'name': 'Approved plugin connector',
      'approvedSourceId': 'source-fixture',
      'approvedDigest': 'sha256:approved-fixture',
      'secrets': <String, String>{},
      'agentEnabled': false,
    });
    for (final forbidden in <String>[
      'url',
      'command',
      'transport',
      'config',
      'pasted',
      'source',
    ]) {
      expect(body.containsKey(forbidden), isFalse, reason: forbidden);
    }
  });

  test('detail mutations and health are keyed by connectionId', () async {
    final dynamic api = apiWith((request) async {
      if (request.method == 'DELETE') return http.Response('', 204);
      if (request.method == 'POST') {
        return json(<String, Object?>{
          ..._fixtureItem(1),
          'connectionId': _connectionId,
          'healthState': 'healthy',
        });
      }
      return json(<String, Object?>{
        ..._fixtureItem(1),
        'connectionId': _connectionId,
        'enabled': false,
        'agentEnabled': false,
      });
    });

    final detail = await api.getConnection(_connectionId);
    expect(detail.connectionId, _connectionId);
    await api.setEnabled(_connectionId, false);
    await api.setAgentEnabled(_connectionId, false);
    final health = await api.checkHealth(_connectionId);
    expect(health.healthState, 'healthy');
    expect(
      health.lastCheckedAt?.toUtc().toIso8601String(),
      '2026-10-24T12:01:00.000Z',
    );
    await api.disconnect(_connectionId);

    expect(requests.map((request) => request.method), <String>[
      'GET',
      'PATCH',
      'PATCH',
      'POST',
      'DELETE',
    ]);
    for (final request in requests) {
      expect(request.url.path, '/cloud/v1/mcp/connections/$_connectionId');
    }
    expect(jsonDecode(requests[1].body), <String, Object?>{'enabled': false});
    expect(
      jsonDecode(requests[2].body),
      <String, Object?>{'agentEnabled': false},
    );
    expect(requests[3].body, isEmpty);
  });

  test('listConnections never falls back to a legacy bare array', () async {
    final dynamic api = apiWith((request) async => json(_fixture()['items']));

    await expectLater(
      api.listConnections(),
      throwsA(isA<CloudApiException>()),
    );
    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), '$_base/mcp/connections');
  });
}
