// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md:
// all new and modified cases in this file remain unexecuted.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/connectors/connector_api.dart';
import 'package:ovid_ai/core/connectors/remote_connector_controller.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/add_connector_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connector_detail_page.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

const String _connectionId = '018f3e11-aaaa-7bbb-8ccc-2d2d2d2d2d2d';

ConnectorCatalogEntry _catalog({
  String providerId = 'google-drive',
  String name = 'Google Drive',
  String readiness = 'supported',
  bool configured = true,
  List<ConnectorCredentialField>? credentialFields,
  List<ConnectorConfigurationField> configurationFields =
      const <ConnectorConfigurationField>[],
}) => ConnectorCatalogEntry(
  curatedId: providerId,
  displayName: name,
  description: 'Read Drive files.',
  credentialFields: credentialFields ??
      const <ConnectorCredentialField>[
        ConnectorCredentialField(
          key: 'CLIENT_ID',
          label: 'Client ID',
          secret: false,
          hint: 'OAuth client identifier',
        ),
        ConnectorCredentialField(
          key: 'CLIENT_SECRET',
          label: 'Client secret',
          secret: true,
          hint: 'OAuth client secret',
        ),
      ],
  toolNames: const <String>['list_files'],
  configured: configured,
  catalogVersion: '2026-10-25-test-catalog',
  readiness: readiness,
  configurationFields: configurationFields,
  operations: const <ConnectorOperation>[
    ConnectorOperation(
      name: 'list_files',
      description: 'List files in Drive.',
      effect: 'read',
      approval: 'mode',
    ),
  ],
);

ConnectorConnection _connection({
  String providerId = 'google-drive',
  String name = 'Google Drive',
  bool enabled = true,
  bool agentEnabled = false,
  String healthState = 'never_checked',
  String authState = 'configured',
  bool hasSecrets = true,
  DateTime? lastCheckedAt,
  DateTime? lastSuccessAt,
}) => ConnectorConnection(
  connectionId: _connectionId,
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
  hasSecrets: hasSecrets,
  createdAt: DateTime.utc(2026, 10, 24, 12),
  updatedAt: DateTime.utc(2026, 10, 24, 12),
);

class _FakeApi implements ConnectorApi {
  List<ConnectorCatalogEntry> catalog = <ConnectorCatalogEntry>[
    _catalog(),
    _catalog(
      providerId: 'candidate-drive',
      name: 'Candidate Drive',
      readiness: 'candidate',
    ),
    _catalog(
      providerId: 'unsupported-drive',
      name: 'Unsupported Drive',
      readiness: 'unsupported',
    ),
  ];
  List<ConnectorConnection> connections = <ConnectorConnection>[_connection()];
  Map<String, String>? createdSecrets;
  Map<String, String>? createdConfig;
  String? createdProviderId;
  bool? createdAgentEnabled;
  int createCalls = 0;
  ConnectorConnection? createResponse;
  bool failSetEnabled = false;
  bool failGetConnection = false;
  bool retainDisconnectedHistory = false;
  String? lastHealthId;
  String? lastAgentId;
  String healthResponseState = 'healthy';
  int getConnectionCalls = 0;
  int listConnectionCalls = 0;
  Completer<ConnectorConnection>? getConnectionGate;

  @override
  Future<List<ConnectorCatalogEntry>> listCatalog() async => catalog;

  @override
  Future<List<ConnectorConnection>> listConnections() async {
    listConnectionCalls++;
    return connections;
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
    createdProviderId = providerId;
    createdSecrets = Map<String, String>.of(secrets);
    createdConfig = Map<String, String>.of(config);
    createdAgentEnabled = agentEnabled;
    final created = _connection(
      providerId: providerId,
      name: name ?? providerId,
      agentEnabled: agentEnabled,
    );
    connections = <ConnectorConnection>[...connections, created];
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
  Future<ConnectorConnection> getConnection(String connectionId) async {
    getConnectionCalls++;
    await getConnectionGate?.future;
    if (failGetConnection) throw StateError('detail read failed');
    return connections.firstWhere((item) => item.connectionId == connectionId);
  }

  @override
  Future<ConnectorConnection> setEnabled(
    String connectionId,
    bool enabled,
  ) async {
    if (failSetEnabled) throw StateError('write refused');
    final index = connections.indexWhere(
      (item) => item.connectionId == connectionId,
    );
    final updated = connections[index].copyWith(enabled: enabled);
    connections[index] = updated;
    return updated;
  }

  @override
  Future<ConnectorConnection> setAgentEnabled(
    String connectionId,
    bool agentEnabled,
  ) async {
    lastAgentId = connectionId;
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
      healthState: healthResponseState,
      lastCheckedAt: DateTime.utc(2026, 10, 24, 12, 1),
      lastSuccessAt: healthResponseState == 'healthy'
          ? DateTime.utc(2026, 10, 24, 12, 0, 30)
          : null,
    );
    connections[index] = updated;
    return updated;
  }

  @override
  Future<void> disconnect(String connectionId) async {
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

Future<void> _pumpRemote(
  WidgetTester tester,
  RemoteConnectorController controller, {
  bool reload = true,
}) async {
  if (reload) await controller.reload();
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: ConnectorsPage(
        data: const V2ConnectorsData(useBuiltInCatalog: false),
        controller: controller,
        plan: V2ConnectorPlan.plus,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _openDetail(WidgetTester tester) async {
  await tester.tap(find.text('Google Drive').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    260,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets(
    'configured never renders connected and candidate rows are absent',
    (tester) async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await _pumpRemote(tester, controller);

      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Configured'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(
        find.byKey(const ValueKey('connector-switch-$_connectionId')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('connector-switch-google-drive')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('connector-filter')));
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('connector-filter-connected')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('connector-tab-available')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Candidate Drive'), findsNothing);
      expect(find.text('Unsupported Drive'), findsNothing);
      expect(find.bySemanticsLabel('Add connector'), findsNothing);
    },
  );

  testWidgets(
    'a configured catalog flag alone does not install or connect a row',
    (tester) async {
      final api = _FakeApi()..connections = <ConnectorConnection>[];
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await _pumpRemote(tester, controller);

      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Configured'), findsNothing);
      expect(
        find.byKey(const ValueKey('connector-add-google-drive')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'multi-field setup sends both credentials only through the gateway',
    (tester) async {
      final api = _FakeApi()..connections = <ConnectorConnection>[];
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await _pumpRemote(tester, controller);

      await tester.tap(
        find.byKey(const ValueKey('connector-add-google-drive')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(find.byType(AddConnectorPage), findsOneWidget);
      expect(
        find.byKey(const Key('connector-credential-CLIENT_ID')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('connector-credential-CLIENT_SECRET')),
        findsOneWidget,
      );
      expect(find.text('Client ID'), findsOneWidget);
      expect(find.text('Client secret'), findsOneWidget);
      expect(find.byKey(const Key('add-connector-url')), findsNothing);
      expect(find.text('Test connection'), findsNothing);
      expect(find.text('Stored on this device.'), findsNothing);
      final secretField = tester.widget<TextField>(
        find.byKey(const Key('connector-credential-CLIENT_SECRET')),
      );
      expect(secretField.obscureText, isTrue);

      await tester.enterText(
        find.byKey(const Key('connector-credential-CLIENT_ID')),
        'a',
      );
      await tester.enterText(
        find.byKey(const Key('connector-credential-CLIENT_SECRET')),
        'second-field-value',
      );
      expect(find.widgetWithText(Text, 'second-field-value'), findsNothing);
      final agentSwitch = find.byKey(const Key('connector-agent-opt-in'));
      await _scrollTo(tester, agentSwitch);
      expect(tester.widget<Switch>(agentSwitch).value, isFalse);
      await tester.tap(agentSwitch);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('connector-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      expect(api.createdProviderId, 'google-drive');
      expect(api.createdSecrets, <String, String>{
        'CLIENT_ID': 'a',
        'CLIENT_SECRET': 'second-field-value',
      });
      expect(api.createdAgentEnabled, isTrue);
      final created = controller.connectionById(_connectionId);
      expect(created?.providerId, 'google-drive');
      expect(created?.connectionId, _connectionId);
      expect(created?.connectionId, isNot(created?.providerId));
      expect(created?.agentEnabled, isTrue);
      expect(find.byType(AddConnectorPage), findsNothing);
      expect(find.text('second-field-value'), findsNothing);
      expect(find.text('Connected'), findsNothing);
    },
  );

  testWidgets(
    'detail uses UUID operations, independent opt-in, and server health',
    (tester) async {
      final api = _FakeApi();
      final controller = RemoteConnectorController(
        api: api,
        accountId: () => 'account-a',
        capabilities: ConnectorGatewayCapabilities.approvedParity,
      );
      addTearDown(controller.dispose);
      await _pumpRemote(tester, controller);
      await _openDetail(tester);

      expect(find.byType(ConnectorDetailPage), findsOneWidget);
      expect(find.text('Configured'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('Check health'), findsOneWidget);
      expect(find.text('Test connection'), findsNothing);
      expect(find.text('Last checked —'), findsOneWidget);
      expect(find.text('Last successful check —'), findsOneWidget);
      expect(find.text('list_files'), findsOneWidget);
      expect(find.text('List files in Drive.'), findsOneWidget);
      expect(find.text('Effect: read'), findsOneWidget);
      expect(find.text('Approval: mode'), findsOneWidget);

      final agentSwitch = find.byKey(
        const Key('connector-agent-enabled-switch'),
      );
      expect(tester.widget<Switch>(agentSwitch).value, isFalse);
      await tester.tap(agentSwitch);
      await tester.pump(const Duration(milliseconds: 300));
      expect(api.lastAgentId, _connectionId);
      expect(tester.widget<Switch>(agentSwitch).value, isTrue);
      expect(
        tester
            .widget<Switch>(find.byKey(const Key('connector-enabled-switch')))
            .value,
        isTrue,
      );

      await tester.tap(find.text('Check health'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(api.lastHealthId, _connectionId);
      expect(find.text('Healthy'), findsOneWidget);
      expect(
        find.text('Last checked 2026-10-24T12:01:00.000Z'),
        findsOneWidget,
      );
      expect(
        find.text('Last successful check 2026-10-24T12:00:30.000Z'),
        findsOneWidget,
      );

      await _scrollTo(tester, find.text('Disconnect'));
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect').last);
      await tester.pumpAndSettle();
      expect(controller.connectionById(_connectionId), isNull);
      expect(find.byType(ConnectorDetailPage), findsNothing);
    },
  );

  testWidgets('a refused remote toggle rolls the visible switch back', (
    tester,
  ) async {
    final api = _FakeApi()..failSetEnabled = true;
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    final switchFinder = find.byKey(
      const ValueKey('connector-switch-$_connectionId'),
    );
    await tester.tap(switchFinder);
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    expect(controller.connectionById(_connectionId)?.agentEnabled, isFalse);
    expect(find.text('Could not save that change.'), findsOneWidget);
  });

  testWidgets('remote list keeps loading, empty, error, and content states', (
    tester,
  ) async {
    final api = _FakeApi();
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);

    controller.value = const ConnectorViewState(
      status: ConnectorViewStatus.loading,
      accountId: 'account-a',
    );
    await _pumpRemote(tester, controller, reload: false);
    expect(find.byType(OSkeletonList), findsOneWidget);

    controller.value = const ConnectorViewState(
      status: ConnectorViewStatus.empty,
      accountId: 'account-a',
    );
    await tester.pump();
    expect(find.text('No connectors'), findsOneWidget);

    controller.value = const ConnectorViewState(
      status: ConnectorViewStatus.error,
      accountId: 'account-a',
      errorMessage: 'Connectors did not load. Check your connection and retry.',
    );
    await tester.pump();
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await controller.reload();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('Configured'), findsOneWidget);
  });

  testWidgets('unverified catalog capability offers no provider setup rows', (
    tester,
  ) async {
    final controller = RemoteConnectorController(
      api: _FakeApi()..connections = <ConnectorConnection>[],
      accountId: () => 'account-a',
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    await tester.tap(find.byKey(const Key('connector-tab-available')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('connector-add-google-drive')),
      findsNothing,
    );
    expect(find.text('Candidate Drive'), findsNothing);
    expect(find.text('Unsupported Drive'), findsNothing);
  });

  testWidgets('unavailable item health renders no check-health control', (
    tester,
  ) async {
    final controller = RemoteConnectorController(
      api: _FakeApi(),
      accountId: () => 'account-a',
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);
    await _openDetail(tester);

    expect(find.text('Check health'), findsNothing);
    expect(find.text('Test connection'), findsNothing);
    expect(find.text('Last checked —'), findsOneWidget);
  });

  testWidgets('unavailable create-time agent opt-in is absent', (tester) async {
    final controller = RemoteConnectorController(
      api: _FakeApi(),
      accountId: () => 'account-a',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: AddConnectorPage(
          data: const V2AddConnectorData(
            presetId: 'google-drive',
            presetName: 'Google Drive',
            credentialFields: <ConnectorCredentialField>[],
          ),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byKey(const Key('connector-agent-opt-in')), findsNothing);
    expect(find.text('Use in agent runs'), findsNothing);
  });

  testWidgets('disconnect refetches retained history immediately and preserves it after reopen', (
    tester,
  ) async {
    final api = _FakeApi()..retainDisconnectedHistory = true;
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);
    await _openDetail(tester);
    final listReadsBeforeDisconnect = api.listConnectionCalls;

    await _scrollTo(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect').last);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectorDetailPage), findsNothing);
    expect(
      api.listConnectionCalls,
      greaterThan(listReadsBeforeDisconnect),
      reason: 'The production disconnect path must publish canonical history without a manual reload.',
    );

    final retained = api.connections.single;
    expect(retained.enabled, isFalse);
    expect(retained.agentEnabled, isFalse);
    expect(retained.authState, 'revoked');
    expect(retained.healthState, 'revoked');
    expect(retained.disconnectGeneration, greaterThan(0));

    await tester.tap(find.byKey(const Key('connector-tab-available')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
    expect(
      find.byKey(const ValueKey('connector-switch-$_connectionId')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('connector-add-$_connectionId')),
      findsNothing,
    );

    await _openDetail(tester);
    expect(find.byType(ConnectorDetailPage), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Check health'), findsNothing);
    expect(find.byKey(const Key('connector-enabled-switch')), findsNothing);

    await controller.reload();
    await tester.pump();
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
  });

  // UNEXECUTED under HEAVY-COMMANDS-PAUSED.md: setup sends only non-secret
  // canonical config; no create/background call is treated as health evidence.
  testWidgets('fetch setup validates and saves health config without OAuth or a probe', (
    tester,
  ) async {
    final api = _FakeApi()
      ..connections = <ConnectorConnection>[]
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          name: 'Fetch',
          configured: false,
          credentialFields: const <ConnectorCredentialField>[],
          configurationFields: const <ConnectorConfigurationField>[
            ConnectorConfigurationField(
              key: 'url',
              label: 'Health check URL',
              kind: 'url',
              required: true,
              maxLength: 2048,
              hint: 'Credential-free HTTPS on port 443.',
            ),
          ],
        ),
      ];
    api.createResponse = _connection(
      providerId: 'fetch',
      name: 'Fetch',
      healthState: 'healthy',
      lastCheckedAt: DateTime.utc(2026, 10, 25, 1, 1),
      lastSuccessAt: DateTime.utc(2026, 10, 25, 1, 1),
    );
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    await tester.tap(find.byKey(const ValueKey('connector-add-fetch')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(AddConnectorPage), findsOneWidget);
    expect(find.byKey(const Key('connector-config-url')), findsOneWidget);
    expect(find.byKey(const Key('connector-credential-CLIENT_SECRET')), findsNothing);
    await _scrollTo(tester, find.textContaining('No OAuth'));
    expect(find.text('Test connection'), findsNothing);

    final field = find.byKey(const Key('connector-config-url'));
    await _scrollTo(tester, field);
    await tester.enterText(field, 'https://example.test:8443/not-allowed');
    await tester.tap(find.byKey(const Key('connector-save')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.createCalls, 0);
    expect(api.createdConfig, isNull);
    await _scrollTo(tester, find.byKey(const Key('connector-save-error')));
    expect(find.textContaining('credential-free HTTPS URL on port 443'), findsOneWidget);

    await _scrollTo(tester, field);
    await tester.enterText(field, 'https://example.test/public-health');
    await tester.tap(find.byKey(const Key('connector-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(api.createCalls, 1);
    expect(api.createdProviderId, 'fetch');
    expect(api.createdSecrets, isEmpty);
    expect(api.createdConfig, <String, String>{
      'url': 'https://example.test/public-health',
    });
    expect(api.lastHealthId, isNull);
    expect(api.getConnectionCalls, 1, reason: 'Create requires one canonical item read, not a health probe.');
    expect(controller.connectionById(_connectionId)?.healthState, 'never_checked');
    expect(controller.connectionById(_connectionId)?.lastCheckedAt, isNull);
    expect(controller.connectionById(_connectionId)?.lastSuccessAt, isNull);
    await tester.tap(find.byKey(const Key('connector-tab-installed')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('unavailable canonical health hides agent activation but keeps explicit health', (
    tester,
  ) async {
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
    await _pumpRemote(tester, controller);
    await _openDetail(tester);

    expect(find.byKey(const Key('connector-enabled-switch')), findsOneWidget);
    expect(find.byKey(const Key('connector-agent-enabled-switch')), findsNothing);
    expect(find.text('Check health'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('fetch disconnect describes only local fencing and retained history', (
    tester,
  ) async {
    final api = _FakeApi()
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          name: 'Fetch',
          credentialFields: const <ConnectorCredentialField>[],
        ),
      ]
      ..connections = <ConnectorConnection>[
        _connection(providerId: 'fetch', name: 'Fetch'),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.approvedParity,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    await tester.tap(find.text('Fetch').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.textContaining('No OAuth'), findsOneWidget);
    expect(find.textContaining('Provider sign-in not applicable'), findsOneWidget);
    expect(find.text('Resource requires authentication'), findsNothing);

    await _scrollTo(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disables this local connection'), findsOneWidget);
    expect(find.textContaining('fences future use'), findsOneWidget);
    expect(find.textContaining('No provider grant or remote credential'), findsOneWidget);
    expect(find.textContaining('revokes cached sign-in'), findsNothing);
  });

  // UNEXECUTED: current detail state, not navigation-time metadata, controls
  // agent visibility. These transitions go through real controller mutations.
  testWidgets('detail recomputes agent eligibility after health and enabled transitions', (
    tester,
  ) async {
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
    await _pumpRemote(tester, controller);
    await _openDetail(tester);

    final agentSwitch = find.byKey(const Key('connector-agent-enabled-switch'));
    expect(agentSwitch, findsNothing);
    await tester.tap(find.text('Check health'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Healthy'), findsOneWidget);
    expect(agentSwitch, findsOneWidget);

    await tester.tap(find.byKey(const Key('connector-enabled-switch')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.connectionById(_connectionId)?.enabled, isFalse);
    expect(agentSwitch, findsNothing);
  });

  testWidgets('production detail navigation awaits loading and exposes inline retry', (
    tester,
  ) async {
    final api = _FakeApi()
      ..getConnectionGate = Completer<ConnectorConnection>();
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    await _openDetail(tester);
    expect(find.byType(ConnectorDetailPage), findsOneWidget);
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Check health'), findsNothing);
    expect(api.getConnectionCalls, 1);

    api.getConnectionGate!.complete(api.connections.single);
    await tester.pumpAndSettle();
    expect(find.byType(OSkeletonList), findsNothing);
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Check health'), findsOneWidget);
  });

  testWidgets('production detail failure retries the real getConnection call', (
    tester,
  ) async {
    final api = _FakeApi()..failGetConnection = true;
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    await tester.tap(find.text('Google Drive').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(ConnectorDetailPage), findsOneWidget);
    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(api.getConnectionCalls, 1);

    api.failGetConnection = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(api.getConnectionCalls, 2);
    expect(find.text('Configured'), findsOneWidget);
    expect(find.text('Check health'), findsOneWidget);
  });

  testWidgets('fetch needs_auth uses resource-auth copy in list and detail', (
    tester,
  ) async {
    final api = _FakeApi()
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          name: 'Fetch',
          credentialFields: const <ConnectorCredentialField>[],
        ),
      ]
      ..connections = <ConnectorConnection>[
        _connection(
          providerId: 'fetch',
          name: 'Fetch',
          healthState: 'needs_auth',
        ),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);

    expect(find.text('Resource requires authentication'), findsOneWidget);
    expect(find.text('Needs authentication'), findsNothing);
    expect(find.text('Needs sign-in'), findsNothing);

    await tester.tap(find.text('Fetch').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Resource requires authentication'), findsOneWidget);
    expect(find.text('Needs authentication'), findsNothing);
    expect(find.text('Needs sign-in'), findsNothing);
    expect(find.text('Authentication not applicable (public web)'), findsNothing);
    expect(find.text('Provider sign-in not applicable (public web)'), findsNothing);
    expect(find.textContaining('No OAuth, scopes, or provider grant'), findsOneWidget);
  });

  // UNEXECUTED: this is canonical DTO presentation only, not backend legacy
  // health evidence. The desired legacy unavailable transition remains blocked
  // on its separately reviewed backend correction and is not synthesized here.
  testWidgets('legacy fetch canonical missing DTO does not claim unavailable backend evidence', (
    tester,
  ) async {
    final api = _FakeApi()
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          name: 'Fetch',
          credentialFields: const <ConnectorCredentialField>[],
        ),
      ]
      ..connections = <ConnectorConnection>[
        _connection(
          providerId: 'fetch',
          name: 'Fetch',
          authState: 'missing',
          hasSecrets: false,
        ),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);
    await tester.tap(find.text('Fetch').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.text('Credentials missing'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.text('Unavailable'), findsNothing);
    expect(find.text('Last successful check —'), findsOneWidget);
    expect(
      find.textContaining('legacy unknown-row health remains a separate backend gate'),
      findsOneWidget,
    );
    expect(find.textContaining('missing or invalid config is unavailable'), findsNothing);
    expect(api.lastHealthId, isNull);
  });

  testWidgets('configured fetch renders a canonical unavailable response without legacy evidence claims', (
    tester,
  ) async {
    final api = _FakeApi()
      ..catalog = <ConnectorCatalogEntry>[
        _catalog(
          providerId: 'fetch',
          name: 'Fetch',
          credentialFields: const <ConnectorCredentialField>[],
        ),
      ]
      ..healthResponseState = 'unavailable'
      ..connections = <ConnectorConnection>[
        _connection(
          providerId: 'fetch',
          name: 'Fetch',
          hasSecrets: false,
        ),
      ];
    final controller = RemoteConnectorController(
      api: api,
      accountId: () => 'account-a',
      capabilities: ConnectorGatewayCapabilities.connectionLifecycle,
    );
    addTearDown(controller.dispose);
    await _pumpRemote(tester, controller);
    await tester.tap(find.text('Fetch').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    await tester.tap(find.text('Check health'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.lastHealthId, _connectionId);
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('Last successful check —'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });
}
