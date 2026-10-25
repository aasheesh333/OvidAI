// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md:
// all new and modified cases in this file remain unexecuted.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/connectors/connector_api.dart';
import 'package:ovid_ai/core/connectors/remote_connector_controller.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_catalog_loader.dart';

const String _connectionId = '019a0000-0000-7000-8000-000000000001';

ConnectorCatalogEntry _catalog({
  bool configured = true,
  String providerId = 'google-drive',
  String readiness = 'supported',
  String catalogVersion = '2026-10-25-test-catalog',
  List<ConnectorConfigurationField> configurationFields =
      const <ConnectorConfigurationField>[],
}) => ConnectorCatalogEntry(
      curatedId: providerId,
      displayName: providerId == 'fetch' ? 'Fetch' : 'Google Drive',
      description: 'Read Drive files.',
      credentialFields: const <ConnectorCredentialField>[
        ConnectorCredentialField(
          key: 'CLIENT_ID',
          label: 'Client ID',
          secret: false,
        ),
        ConnectorCredentialField(
          key: 'CLIENT_SECRET',
          label: 'Client secret',
          secret: true,
        ),
      ],
      toolNames: const <String>['list_files'],
      configured: configured,
      catalogVersion: catalogVersion,
      readiness: readiness,
      configurationFields: configurationFields,
      operations: const <ConnectorOperation>[
        ConnectorOperation(
          name: 'list_files',
          description: 'List Drive files.',
          effect: 'read',
          approval: 'mode',
        ),
      ],
    );

ConnectorConnection _connection({
  String connectionId = _connectionId,
  String providerId = 'google-drive',
  String name = 'Google Drive',
  bool enabled = true,
  bool agentEnabled = false,
  String authState = 'configured',
  String healthState = 'never_checked',
  DateTime? lastCheckedAt,
  DateTime? lastSuccessAt,
}) => ConnectorConnection(
  connectionId: connectionId,
  userId: 'fixture-user',
  providerId: providerId,
  name: name,
  transport: 'native',
  enabled: enabled,
  agentEnabled: agentEnabled,
  authState: authState,
  healthState: healthState,
  lastCheckedAt: lastCheckedAt,
  lastSuccessAt: lastSuccessAt,
  configVersion: 1,
  disconnectGeneration: 0,
  hasSecrets: true,
  createdAt: DateTime.utc(2026, 10, 24, 12),
  updatedAt: DateTime.utc(2026, 10, 24, 12),
);

class _PendingGet {
  _PendingGet(this.connection);

  final ConnectorConnection connection;
  final Completer<ConnectorConnection> completer =
      Completer<ConnectorConnection>();
}

class _FakeApi implements ConnectorApi {
  List<ConnectorCatalogEntry> catalog = <ConnectorCatalogEntry>[_catalog()];
  List<ConnectorConnection> connections = <ConnectorConnection>[_connection()];
  final List<Completer<List<ConnectorConnection>>> pendingLists =
      <Completer<List<ConnectorConnection>>>[];
  bool deferLists = false;
  bool deferGets = false;
  final List<_PendingGet> pendingGets = <_PendingGet>[];
  Completer<void>? setEnabledGate;
  Completer<void>? disconnectGate;
  bool failSetEnabled = false;
  bool failDisconnect = false;
  bool retainDisconnectedHistory = false;
  int listCalls = 0;
  int getCalls = 0;
  String? lastMutationId;
  String? lastHealthId;
  Map<String, String>? createdConfig;
  int createCalls = 0;
  ConnectorConnection? createResponse;
  Completer<ConnectorConnection>? createGate;
  Completer<ConnectorConnection>? mutationResultGate;

  @override
  Future<List<ConnectorCatalogEntry>> listCatalog() async => catalog;

  @override
  Future<List<ConnectorConnection>> listConnections() {
    listCalls++;
    if (deferLists) {
      final completer = Completer<List<ConnectorConnection>>();
      pendingLists.add(completer);
      return completer.future;
    }
    return Future<List<ConnectorConnection>>.value(connections);
  }

  @override
  Future<ConnectorConnection> createConnection({
    required String providerId,
    String? name,
    Map<String, String> secrets = const <String, String>{},
    Map<String, String> config = const <String, String>{},
    bool agentEnabled = false,
  }) async {
    createCalls++;
    createdConfig = Map<String, String>.of(config);
    final created = _connection(
      providerId: providerId,
      name: name ?? providerId,
      agentEnabled: agentEnabled,
    );
    connections = <ConnectorConnection>[...connections, created];
    await createGate?.future;
    return createResponse ?? created;
  }

  @override
  Future<ConnectorConnection> createFetchConnection({
    String? name,
    required String url,
  }) {
    return createConnection(
      providerId: 'fetch',
      name: name,
      config: <String, String>{'url': url},
    );
  }

  @override
  Future<ConnectorConnection> getConnection(String connectionId) {
    getCalls++;
    lastMutationId = connectionId;
    final snapshot = connections.firstWhere(
      (item) => item.connectionId == connectionId,
    );
    if (deferGets) {
      final pending = _PendingGet(snapshot);
      pendingGets.add(pending);
      return pending.completer.future;
    }
    return Future<ConnectorConnection>.value(snapshot);
  }

  @override
  Future<ConnectorConnection> setEnabled(
    String connectionId,
    bool enabled,
  ) async {
    lastMutationId = connectionId;
    await setEnabledGate?.future;
    if (failSetEnabled) throw StateError('write refused');
    final index = connections.indexWhere(
      (item) => item.connectionId == connectionId,
    );
    final updated = connections[index].copyWith(enabled: enabled);
    connections[index] = updated;
    await mutationResultGate?.future;
    return updated;
  }

  @override
  Future<ConnectorConnection> setAgentEnabled(
    String connectionId,
    bool agentEnabled,
  ) async {
    lastMutationId = connectionId;
    final index = connections.indexWhere(
      (item) => item.connectionId == connectionId,
    );
    final updated = connections[index].copyWith(agentEnabled: agentEnabled);
    connections[index] = updated;
    return updated;
  }

  @override
  Future<ConnectorConnection> checkHealth(String connectionId) async {
    lastHealthId = connectionId;
    final index = connections.indexWhere(
      (item) => item.connectionId == connectionId,
    );
    final updated = connections[index].copyWith(
      healthState: 'healthy',
      lastCheckedAt: DateTime.utc(2026, 10, 24, 12, 1),
      lastSuccessAt: DateTime.utc(2026, 10, 24, 12, 0, 30),
    );
    connections[index] = updated;
    return updated;
  }

  @override
  Future<void> disconnect(String connectionId) async {
    lastMutationId = connectionId;
    await disconnectGate?.future;
    if (failDisconnect) throw StateError('disconnect refused');
    if (retainDisconnectedHistory) {
      final index = connections.indexWhere(
        (item) => item.connectionId == connectionId,
      );
      final current = connections[index];
      connections[index] = current.copyWith(
        enabled: false,
        agentEnabled: false,
        authState: 'revoked',
        healthState: 'revoked',
        disconnectGeneration: current.disconnectGeneration + 1,
      );
    } else {
      connections.removeWhere((item) => item.connectionId == connectionId);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'one cache combines supported catalog metadata and server connections',
    () async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);

      await controller.reload();

      expect(controller, isA<ValueListenable<ConnectorViewState>>());
      expect(controller.value.status, ConnectorViewStatus.content);
      expect(controller.value.catalog.single.providerId, 'google-drive');
      expect(controller.value.catalog.single.operations.single.effect, 'read');
      expect(controller.value.connections.single.connectionId, _connectionId);
      expect(controller.value.connections.single.providerId, 'google-drive');
      expect(controller.value.connections.single.enabled, isTrue);
      expect(controller.value.connections.single.agentEnabled, isFalse);
      expect(
        controller.connectionById(_connectionId)?.providerId,
        'google-drive',
      );
      expect(api.listCalls, 1);
    },
  );

  test('late account A reads cannot overwrite account B', () async {
    final api = _FakeApi()
      ..deferLists = true
      ..catalog = <ConnectorCatalogEntry>[];
    var account = 'account-a';
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => account,
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);

    final first = controller.reload();
    await _flush();
    expect(api.pendingLists, hasLength(1));
    account = 'account-b';
    final second = controller.reload();
    await _flush();
    expect(api.pendingLists, hasLength(2));

    api.pendingLists[1].complete(<ConnectorConnection>[
      _connection(
        connectionId: '019a0000-0000-7000-8000-00000000000b',
        name: 'Account B connection',
      ),
    ]);
    await second;
    api.pendingLists[0].complete(<ConnectorConnection>[
      _connection(name: 'Account A connection'),
    ]);
    await first;

    expect(controller.value.accountId, 'account-b');
    expect(controller.value.connections, hasLength(1));
    expect(controller.value.connections.single.name, 'Account B connection');
    expect(
      controller.value.connections.single.connectionId,
      '019a0000-0000-7000-8000-00000000000b',
    );
  });

  test(
    'failed enabled mutation rolls back without changing agent opt-in',
    () async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      api.failSetEnabled = true;
      final pending = controller.setEnabled(_connectionId, false);
      expect(controller.connectionById(_connectionId)?.enabled, isFalse);
      await expectLater(pending, throwsStateError);

      final restored = controller.connectionById(_connectionId);
      expect(restored?.enabled, isTrue);
      expect(restored?.agentEnabled, isFalse);
      expect(api.lastMutationId, _connectionId);
    },
  );

  test(
    'agent and connection switches mutate independently by server UUID',
    () async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      await controller.setAgentEnabled(_connectionId, true);
      expect(controller.connectionById(_connectionId)?.agentEnabled, isTrue);
      expect(controller.connectionById(_connectionId)?.enabled, isTrue);
      await controller.setEnabled(_connectionId, false);
      expect(controller.connectionById(_connectionId)?.enabled, isFalse);
      expect(controller.connectionById(_connectionId)?.agentEnabled, isTrue);
      expect(api.lastMutationId, _connectionId);
    },
  );

  test(
    'detail and health replace cache with authoritative timestamps',
    () async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final detail = await controller.getConnection(_connectionId);
      expect(detail.connectionId, _connectionId);
      expect(api.getCalls, 1);
      final checked = await controller.checkHealth(_connectionId);

      expect(checked.healthState, 'healthy');
      expect(controller.connectionById(_connectionId)?.healthState, 'healthy');
      expect(
        controller.connectionById(_connectionId)?.lastCheckedAt,
        DateTime.utc(2026, 10, 24, 12, 1),
      );
      expect(
        controller.connectionById(_connectionId)?.lastSuccessAt,
        DateTime.utc(2026, 10, 24, 12, 0, 30),
      );
      expect(api.lastHealthId, _connectionId);
    },
  );

  test('failed disconnect restores the same connection', () async {
    final api = _FakeApi()..failDisconnect = true;
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    final pending = controller.disconnect(_connectionId);
    expect(controller.connectionById(_connectionId), isNull);
    await expectLater(pending, throwsStateError);

    expect(
      controller.connectionById(_connectionId)?.connectionId,
      _connectionId,
    );
    expect(controller.value.status, ConnectorViewStatus.content);
  });

  test(
    'toggle then stale detail cannot overwrite the completed PATCH',
    () async {
      final api = _FakeApi()
        ..deferGets = true
        ..setEnabledGate = Completer<void>();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final toggle = controller.setEnabled(_connectionId, false);
      await _flush();
      final detail = controller.getConnection(_connectionId);
      await _flush();
      expect(api.pendingGets, hasLength(1));
      expect(api.pendingGets.single.connection.enabled, isTrue);

      api.setEnabledGate!.complete();
      await toggle;
      expect(controller.connectionById(_connectionId)?.enabled, isFalse);

      api.pendingGets.single.completer.complete(
        api.pendingGets.single.connection,
      );
      await detail;

      expect(
        controller.connectionById(_connectionId)?.enabled,
        isFalse,
        reason: 'The GET read before PATCH must not restore enabled=true.',
      );
    },
  );

  test('reload overlapping a toggle keeps the newer mutation state', () async {
    final api = _FakeApi()..setEnabledGate = Completer<void>();
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    final toggle = controller.setEnabled(_connectionId, false);
    await _flush();
    api.deferLists = true;
    final reload = controller.reload();
    await _flush();
    expect(api.pendingLists, hasLength(1));

    api.setEnabledGate!.complete();
    await toggle;
    api.pendingLists.single.complete(<ConnectorConnection>[
      _connection(enabled: true),
    ]);
    await reload;

    expect(
      controller.connectionById(_connectionId)?.enabled,
      isFalse,
      reason: 'An older list response must not revert a completed toggle.',
    );
  });

  test(
    'reload overlapping disconnect cannot restore the removed row',
    () async {
      final api = _FakeApi()..disconnectGate = Completer<void>();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final disconnect = controller.disconnect(_connectionId);
      await _flush();
      expect(controller.connectionById(_connectionId), isNull);
      api.deferLists = true;
      final reload = controller.reload();
      await _flush();
      expect(api.pendingLists, hasLength(1));

      api.disconnectGate!.complete();
      await _flush();
      expect(api.pendingLists, hasLength(2));
      api.pendingLists[1].complete(<ConnectorConnection>[]);
      await disconnect;
      api.pendingLists[0].complete(<ConnectorConnection>[_connection()]);
      await reload;

      expect(
        controller.connectionById(_connectionId),
        isNull,
        reason: 'A pre-disconnect list response must not resurrect the row.',
      );
    },
  );

  test(
    'reload returning during a toggle cannot undo optimistic state',
    () async {
      final api = _FakeApi()..setEnabledGate = Completer<void>();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final toggle = controller.setEnabled(_connectionId, false);
      await _flush();
      api.deferLists = true;
      final reload = controller.reload();
      await _flush();
      api.pendingLists.single.complete(<ConnectorConnection>[
        _connection(enabled: true),
      ]);
      await reload;

      expect(
        controller.connectionById(_connectionId)?.enabled,
        isFalse,
        reason: 'An in-flight mutation still owns this cache row.',
      );
      api.setEnabledGate!.complete();
      await toggle;
      expect(controller.connectionById(_connectionId)?.enabled, isFalse);
    },
  );

  test('reload returning during disconnect cannot restore the row', () async {
    final api = _FakeApi()..disconnectGate = Completer<void>();
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    final disconnect = controller.disconnect(_connectionId);
    await _flush();
    api.deferLists = true;
    final reload = controller.reload();
    await _flush();
    api.pendingLists.single.complete(<ConnectorConnection>[_connection()]);
    await reload;

    expect(
      controller.connectionById(_connectionId),
      isNull,
      reason: 'The pending disconnect tombstone must survive the list answer.',
    );
    api.disconnectGate!.complete();
    await _flush();
    expect(api.pendingLists, hasLength(2));
    api.pendingLists[1].complete(<ConnectorConnection>[]);
    await disconnect;
    expect(controller.connectionById(_connectionId), isNull);
  });

  test(
    'retained disconnected history survives stale and later reloads',
    () async {
      final api = _FakeApi()
        ..retainDisconnectedHistory = true
        ..disconnectGate = Completer<void>();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await controller.reload();

      final disconnect = controller.disconnect(_connectionId);
      await _flush();
      api.deferLists = true;
      final staleReload = controller.reload();
      await _flush();
      api.disconnectGate!.complete();
      await _flush();
      expect(api.pendingLists, hasLength(2));
      api.pendingLists[1].complete(<ConnectorConnection>[api.connections.single]);
      await disconnect;
      api.pendingLists[0].complete(<ConnectorConnection>[_connection()]);
      await staleReload;

      expect(
        controller.connectionById(_connectionId)?.isDisconnected,
        isTrue,
        reason: 'Canonical history appears immediately; the stale response cannot restore the active row.',
      );

      api.deferLists = false;
      await controller.reload();
      final history = controller.connectionById(_connectionId);
      expect(history?.enabled, isFalse);
      expect(history?.agentEnabled, isFalse);
      expect(history?.authState, 'revoked');
      expect(history?.healthState, 'revoked');
      expect(history?.disconnectGeneration, 1);
      expect(
        remoteConnectorRows(controller.value).single.connected,
        isFalse,
        reason: 'The retained server DTO is history, not an installed row.',
      );

      await controller.reload();
      expect(remoteConnectorRows(controller.value).single.connected, isFalse);
    },
  );

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md: readiness must be explicit and
  // agent/config mutations require the matching supported definition.
  test('candidate blocked and versionless catalog rows stay hidden', () async {
    final api = _FakeApi()
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(),
        _catalog(providerId: 'candidate-drive', readiness: 'candidate'),
        _catalog(providerId: 'blocked-drive', readiness: 'blocked'),
        _catalog(providerId: 'legacy-drive', catalogVersion: ''),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);

    await controller.reload();

    expect(controller.value.catalog.map((entry) => entry.providerId), <String>[
      'google-drive',
    ]);
  });

  test('fetch create validates exact config before any gateway write', () async {
    final api = _FakeApi()
      ..connections = <ConnectorConnection>[]
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          configured: false,
          configurationFields: const <ConnectorConfigurationField>[
            ConnectorConfigurationField(
              key: 'url',
              label: 'Health check URL',
              kind: 'url',
              required: true,
              maxLength: 2048,
            ),
          ],
        ),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    await expectLater(
      controller.createConnection(
        providerId: 'fetch',
        config: const <String, String>{'url': 'https://example.test:8443/no'},
      ),
      throwsStateError,
    );
    await expectLater(
      controller.createConnection(
        providerId: 'fetch',
        config: const <String, String>{
          'url': 'https://example.test/public-health',
          'method': 'POST',
        },
      ),
      throwsStateError,
    );
    expect(api.createCalls, 0);
    expect(api.createdConfig, isNull);

    await controller.createConnection(
      providerId: 'fetch',
      name: 'Fetch',
      config: const <String, String>{'url': 'https://example.test/public-health'},
    );
    expect(api.createCalls, 1);
    expect(api.createdConfig, <String, String>{
      'url': 'https://example.test/public-health',
    });
  });

  test('agent activation rejects unknown IDs and mismatched definitions, not wrong-user ownership', () async {
    final api = _FakeApi()
      ..connections = <ConnectorConnection>[
        _connection(healthState: 'unavailable'),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    await expectLater(
      controller.setAgentEnabled(_connectionId, true),
      throwsStateError,
    );
    await expectLater(controller.setEnabled('foreign-connection', true), throwsStateError);
    expect(api.lastMutationId, isNull);

    api.connections = <ConnectorConnection>[
      _connection(providerId: 'different-definition'),
    ];
    await controller.reload();
    await expectLater(
      controller.setAgentEnabled(_connectionId, true),
      throwsStateError,
    );
    expect(api.lastMutationId, isNull);
  });

  // UNEXECUTED: accepted create responses are not health evidence. Only the
  // account-fenced canonical item read may populate visible health/timestamps.
  test('create refetches canonical health instead of caching a healthy create response', () async {
    final checkedAt = DateTime.utc(2026, 10, 25, 1, 1);
    final api = _FakeApi()
      ..connections = <ConnectorConnection>[]
      ..createResponse = _connection(
        healthState: 'healthy',
        lastCheckedAt: checkedAt,
        lastSuccessAt: checkedAt,
      );
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    final created = await controller.createConnection(
      providerId: 'google-drive',
      name: 'Google Drive',
    );

    expect(created.healthState, 'never_checked');
    expect(created.lastCheckedAt, isNull);
    expect(created.lastSuccessAt, isNull);
    expect(api.getCalls, 1);
    expect(api.createCalls, 1);
    expect(controller.connectionById(_connectionId)?.healthState, 'never_checked');
    expect(controller.connectionById(_connectionId)?.lastCheckedAt, isNull);
    expect(controller.connectionById(_connectionId)?.lastSuccessAt, isNull);
  });

  test('current definition and DTO recompute agent eligibility in both directions', () async {
    final api = _FakeApi()
      ..connections = <ConnectorConnection>[
        _connection(healthState: 'unavailable'),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await controller.reload();
    expect(controller.canActivateAgent(_connectionId), isFalse);

    await controller.checkHealth(_connectionId);
    expect(controller.canActivateAgent(_connectionId), isTrue);

    await controller.setAgentEnabled(_connectionId, true);
    await controller.setEnabled(_connectionId, false);
    expect(
      controller.canActivateAgent(_connectionId),
      isTrue,
      reason: 'An already-enabled agent still needs its disable control.',
    );
  });

  test('late account-A create and mutation completions cannot populate account B', () async {
    final api = _FakeApi()
      ..createGate = Completer<ConnectorConnection>()
      ..mutationResultGate = Completer<ConnectorConnection>();
    var account = 'account-a';
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => account,
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await controller.reload();

    final creating = controller.createConnection(
      providerId: 'google-drive',
      name: 'Account A create',
    );
    final mutating = controller.setEnabled(_connectionId, false);
    await _flush();
    account = 'account-b';
    api.connections = <ConnectorConnection>[
      _connection(
        connectionId: '019a0000-0000-7000-8000-00000000000b',
        name: 'Account B connection',
      ),
    ];
    await controller.reload();
    api.createGate!.complete(_connection(name: 'Misleading A health'));
    api.mutationResultGate!.complete(_connection(enabled: false));

    await expectLater(creating, throwsStateError);
    await expectLater(mutating, throwsStateError);
    expect(controller.value.accountId, 'account-b');
    expect(controller.value.connections, hasLength(1));
    expect(controller.value.connections.single.name, 'Account B connection');
    expect(controller.value.connections.single.enabled, isTrue);
    expect(
      controller.value.connections.any(
        (connection) => connection.name == 'Misleading A health',
      ),
      isFalse,
    );
  });
}
