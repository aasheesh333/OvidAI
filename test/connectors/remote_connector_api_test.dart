// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md:
// all new and modified cases in this file remain unexecuted.
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

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md: explicit v2 readiness is the
  // only installable catalog path; legacy/missing readiness fails closed.
  test('listCatalog parses supported v2 config metadata and hides candidates', () async {
    final fetch = <String, Object?>{
      'curatedId': 'fetch',
      'displayName': 'Fetch',
      'description': 'Read public-web resources.',
      'catalogVersion': '2026-10-24-original-read-first',
      'readiness': 'supported',
      'credentialFields': <Object?>[],
      'configurationFields': <Object?>[
        <String, Object?>{
          'key': 'url',
          'label': 'Health check URL',
          'kind': 'url',
          'required': true,
          'maxLength': 2048,
          'hint': 'Credential-free HTTPS on port 443.',
        },
      ],
      'tools': <Object?>[
        <String, Object?>{
          'name': 'fetch',
          'description': 'Read a public resource.',
          'effect': 'read',
          'approval': 'mode',
          'requiredScopes': <String>[],
        },
      ],
      'configured': false,
    };
    final dynamic api = apiWith((request) async => json(<String, Object?>{
      'contractVersion': 2,
      'items': <Object?>[
        fetch,
        <String, Object?>{
          ...fetch,
          'curatedId': 'candidate-fetch',
          'readiness': 'candidate',
        },
        <String, Object?>{
          ...fetch,
          'curatedId': 'blocked-fetch',
          'readiness': 'blocked',
        },
        <String, Object?>{
          ...fetch,
          'curatedId': 'legacy-fetch',
          'readiness': null,
        },
      ],
    }));

    final items = await api.listCatalog() as List<dynamic>;

    expect(items, hasLength(1));
    expect(items.single.providerId, 'fetch');
    expect(items.single.catalogVersion, '2026-10-24-original-read-first');
    expect(items.single.isSupported, isTrue);
    expect(items.single.toolNames, <String>['fetch']);
    expect(items.single.operations.single.effect, 'read');
    expect(items.single.operations.single.approval, 'mode');
    expect(items.single.configurationFields.single.key, 'url');
    expect(items.single.configurationFields.single.kind, 'url');
    expect(items.single.configurationFields.single.required, isTrue);
    expect(items.single.configurationFields.single.maxLength, 2048);
    expect(requests.single.url.toString(), '$_base/mcp/catalog');
  });

  test('listCatalog rejects a legacy envelope and malformed supported config', () async {
    final legacy = apiWith((request) async => json(<String, Object?>{'items': <Object?>[]}));
    await expectLater(legacy.listCatalog(), throwsA(isA<CloudApiException>()));

    final malformed = apiWith((request) async => json(<String, Object?>{
      'contractVersion': 2,
      'items': <Object?>[
        <String, Object?>{
          'curatedId': 'fetch',
          'displayName': 'Fetch',
          'description': 'Public reads.',
          'catalogVersion': '2026-10-24-original-read-first',
          'readiness': 'supported',
          'credentialFields': <Object?>[],
          'configurationFields': <Object?>[
            <String, Object?>{
              'key': 'authorization',
              'label': 'Not allowed',
              'kind': 'url',
              'required': true,
              'maxLength': 2048,
            },
          ],
          'tools': <Object?>[],
          'configured': false,
        },
      ],
    }));
    await expectLater(malformed.listCatalog(), throwsA(isA<CloudApiException>()));
  });

  // UNEXECUTED: every supported row/descriptor is validated as untrusted wire
  // data. Canary values must stay in the fixture, never in the thrown message.
  test('supported catalog rejects malformed descriptors and secret canaries', () async {
    Map<String, Object?> valid() => <String, Object?>{
      'curatedId': 'github',
      'displayName': 'GitHub',
      'description': 'Read repositories and identity.',
      'catalogVersion': '2026-10-24-original-read-first',
      'readiness': 'supported',
      'credentialFields': <Object?>[
        <String, Object?>{
          'key': 'GITHUB_TOKEN',
          'label': 'GitHub token',
          'secret': true,
        },
      ],
      'configurationFields': <Object?>[],
      'tools': <Object?>[
        <String, Object?>{
          'name': 'get_user',
          'description': 'Read the current user.',
          'effect': 'read',
          'approval': 'mode',
          'requiredScopes': <String>[],
        },
      ],
      'configured': false,
    };
    const canary = 'credential-PAT-canary-must-not-echo';
    final malformed = <String, List<Object?>>{
      'credential value': <Object?>[
        <String, Object?>{
          ...valid(),
          'credentialFields': <Object?>[
            <String, Object?>{
              'key': 'GITHUB_TOKEN',
              'label': 'GitHub token',
              'secret': true,
              'value': canary,
            },
          ],
        },
      ],
      'credential PAT': <Object?>[
        <String, Object?>{
          ...valid(),
          'credentialFields': <Object?>[
            <String, Object?>{
              'key': 'GITHUB_TOKEN',
              'label': 'GitHub token',
              'secret': true,
              'pat': canary,
            },
          ],
        },
      ],
      'fetch credential descriptor': <Object?>[
        <String, Object?>{
          ...valid(),
          'curatedId': 'fetch',
          'displayName': 'Fetch',
          'credentialFields': <Object?>[
            <String, Object?>{
              'key': 'GITHUB_TOKEN',
              'label': 'GitHub token',
              'secret': true,
            },
          ],
          'configurationFields': <Object?>[
            <String, Object?>{
              'key': 'url',
              'label': 'Health check URL',
              'kind': 'url',
              'required': true,
              'maxLength': 2048,
            },
          ],
        },
      ],
      'credential missing key': <Object?>[
        <String, Object?>{
          ...valid(),
          'credentialFields': <Object?>[
            <String, Object?>{'label': 'GitHub token', 'secret': true},
          ],
        },
      ],
      'credential wrong secret type': <Object?>[
        <String, Object?>{
          ...valid(),
          'credentialFields': <Object?>[
            <String, Object?>{
              'key': 'GITHUB_TOKEN',
              'label': 'GitHub token',
              'secret': 'true',
            },
          ],
        },
      ],
      'malformed operation': <Object?>[
        <String, Object?>{
          ...valid(),
          'tools': <Object?>[
            <String, Object?>{'effect': 'read', 'approval': 'mode'},
          ],
        },
      ],
      'operation secret property': <Object?>[
        <String, Object?>{
          ...valid(),
          'tools': <Object?>[
            <String, Object?>{
              'name': 'fetch',
              'effect': 'read',
              'approval': 'mode',
              'value': canary,
            },
          ],
        },
      ],
      'operation scopes': <Object?>[
        <String, Object?>{
          ...valid(),
          'tools': <Object?>[
            <String, Object?>{
              'name': 'fetch',
              'effect': 'read',
              'approval': 'mode',
              'requiredScopes': <Object?>['read', 7],
            },
          ],
        },
      ],
      'ambiguous operation arrays': <Object?>[
        <String, Object?>{...valid(), 'operations': <Object?>[]},
      ],
      'empty version': <Object?>[
        <String, Object?>{...valid(), 'catalogVersion': ''},
      ],
      'long version': <Object?>[
        <String, Object?>{...valid(), 'catalogVersion': 'v' * 129},
      ],
      'version type': <Object?>[
        <String, Object?>{...valid(), 'catalogVersion': 2},
      ],
      'long config label': <Object?>[
        <String, Object?>{
          ...valid(),
          'configurationFields': <Object?>[
            <String, Object?>{
              'key': 'url',
              'label': 'x' * 201,
              'kind': 'url',
              'required': true,
              'maxLength': 2048,
            },
          ],
        },
      ],
      'long config hint': <Object?>[
        <String, Object?>{
          ...valid(),
          'configurationFields': <Object?>[
            <String, Object?>{
              'key': 'url',
              'label': 'Health check URL',
              'kind': 'url',
              'required': true,
              'maxLength': 2048,
              'hint': 'x' * 1025,
            },
          ],
        },
      ],
      'top-level secret': <Object?>[
        <String, Object?>{...valid(), 'value': canary},
      ],
    };

    for (final entry in malformed.entries) {
      final api = apiWith((request) async => json(<String, Object?>{
        'contractVersion': 2,
        'items': entry.value,
      }));
      await expectLater(
        api.listCatalog(),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.message,
            'generic message for ${entry.key}',
            allOf(isNot(contains(canary)), isNot(contains('value'))),
          ),
        ),
        reason: entry.key,
      );
    }

    final providerOnly = valid();
    providerOnly['providerId'] = canary;
    providerOnly.remove('curatedId');
    final operationsOnly = valid();
    operationsOnly['operations'] = <Object?>[
      <String, Object?>{
        'name': canary,
        'description': 'Valid operation behind a non-canonical alias.',
        'effect': 'read',
        'approval': 'mode',
        'requiredScopes': <String>[],
      },
    ];
    operationsOnly.remove('tools');
    final aliasCases = <String, List<Object?>>{
      'providerId-only alias': <Object?>[providerOnly],
      'operations-only alias': <Object?>[operationsOnly],
      'additive providerId alias': <Object?>[
        // Same-valued aliases were previously admitted and must now fail too.
        <String, Object?>{...valid(), 'providerId': 'github'},
      ],
      'additive operations alias': <Object?>[
        <String, Object?>{
          ...valid(),
          'operations': <Object?>[
            <String, Object?>{
              'name': canary,
              'description': 'Valid operation behind an additive alias.',
              'effect': 'read',
              'approval': 'mode',
              'requiredScopes': <String>[],
            },
          ],
        },
      ],
    };
    for (final entry in aliasCases.entries) {
      final api = apiWith((request) async => json(<String, Object?>{
        'contractVersion': 2,
        'items': entry.value,
      }));
      await expectLater(
        api.listCatalog(),
        throwsA(
          isA<CloudApiException>().having(
            (error) => error.message,
            'generic non-echoing alias error for ${entry.key}',
            allOf(
              equals('Ovid Cloud returned an unreadable connector catalog.'),
              isNot(contains(canary)),
            ),
          ),
        ),
        reason: entry.key,
      );
    }
  });

  test('fetch health URL validation enforces HTTPS credentials port and length', () {
    const prefix = 'https://example.test/';
    final longest = '$prefix${'a' * (2048 - prefix.length)}';
    expect(longest.length, 2048);
    expect(isValidFetchHealthUrl(longest), isTrue);
    expect(isValidFetchHealthUrl('${longest}a'), isFalse);
    expect(isValidFetchHealthUrl(' https://example.test/public '), isTrue);
    for (final invalid in <String>[
      '',
      'not-a-url',
      'http://example.test/public',
      'https://user:password@example.test/public',
      'https://example.test:8443/public',
    ]) {
      expect(isValidFetchHealthUrl(invalid), isFalse, reason: invalid);
    }
  });

  test('fetch create sends canonical non-secret config without transport or OAuth', () async {
    final dynamic api = apiWith((request) async => json(<String, Object?>{
      ..._fixtureItem(0),
      'providerId': 'fetch',
      'hasSecrets': false,
    }, 201));

    await api.createConnection(
      providerId: 'fetch',
      config: const <String, String>{'url': 'https://example.test/public-health'},
    );

    final body = (jsonDecode(requests.single.body) as Map).cast<String, dynamic>();
    expect(body, <String, Object?>{
      'providerId': 'fetch',
      'config': <String, String>{'url': 'https://example.test/public-health'},
    });
    for (final forbidden in <String>[
      'transport',
      'oauth',
      'curatedId',
      'secrets',
      'agentEnabled',
      'method',
      'body',
    ]) {
      expect(body.containsKey(forbidden), isFalse, reason: forbidden);
    }
  });

  test('fetch create trims optional name and URL before rebuilding the body', () async {
    final dynamic api = apiWith((request) async => json(_fixtureItem(0), 201));

    await api.createFetchConnection(
      name: ' Public fetch ',
      url: ' https://example.test/public-health ',
    );

    final body = (jsonDecode(requests.single.body) as Map).cast<String, dynamic>();
    expect(body, <String, Object?>{
      'providerId': 'fetch',
      'name': 'Public fetch',
      'config': <String, String>{'url': 'https://example.test/public-health'},
    });
  });

  // UNEXECUTED: the public API boundary itself must reject forged fetch fields,
  // not rely on a controller or widget to sanitize them first.
  test('fetch create rejects forged secrets agent and request overrides before HTTP', () async {
    final dynamic api = apiWith((request) async => json(_fixtureItem(0), 201));
    final attempts = <Future<ConnectorConnection> Function()>[
      () => api.createConnection(
        providerId: 'fetch',
        secrets: const <String, String>{'TOKEN': 'fetch-secret-canary'},
        config: const <String, String>{'url': 'https://example.test/public-health'},
      ),
      () => api.createConnection(
        providerId: 'fetch',
        agentEnabled: true,
        config: const <String, String>{'url': 'https://example.test/public-health'},
      ),
      () => api.createConnection(
        providerId: 'fetch',
        config: const <String, String>{
          'url': 'https://example.test/public-health',
          'method': 'POST',
          'body': 'forged-body',
          'oauth': 'forged-oauth',
        },
      ),
      () => api.createFetchConnection(
        name: 'Fetch',
        url: 'https://user:password@example.test/public-health',
      ),
    ];

    for (final attempt in attempts) {
      await expectLater(attempt(), throwsStateError);
    }
    expect(requests, isEmpty);
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
