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
}) => ConnectorCatalogEntry(
  curatedId: providerId,
  displayName: name,
  description: 'Read Drive files.',
  credentialFields: const <ConnectorCredentialField>[
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
  readiness: readiness,
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
  bool enabled = true,
  bool agentEnabled = false,
  String healthState = 'never_checked',
  DateTime? lastCheckedAt,
  DateTime? lastSuccessAt,
}) => ConnectorConnection(
  connectionId: _connectionId,
  userId: 'fixture-user',
  providerId: 'google-drive',
  name: 'Google Drive',
  transport: 'native',
  enabled: enabled,
  agentEnabled: agentEnabled,
  authState: 'configured',
  healthState: healthState,
  lastCheckedAt: lastCheckedAt,
  lastSuccessAt: lastSuccessAt,
  configVersion: 1,
  disconnectGeneration: 0,
  hasSecrets: true,
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
  String? createdProviderId;
  bool? createdAgentEnabled;
  bool failSetEnabled = false;
  bool retainDisconnectedHistory = false;
  String? lastHealthId;
  String? lastAgentId;

  @override
  Future<List<ConnectorCatalogEntry>> listCatalog() async => catalog;

  @override
  Future<List<ConnectorConnection>> listConnections() async => connections;

  @override
  Future<ConnectorConnection> createConnection({
    required String providerId,
    String? name,
    Map<String, String> secrets = const <String, String>{},
    bool agentEnabled = false,
  }) async {
    createdProviderId = providerId;
    createdSecrets = Map<String, String>.of(secrets);
    createdAgentEnabled = agentEnabled;
    final created = _connection(agentEnabled: agentEnabled);
    connections = <ConnectorConnection>[...connections, created];
    return created;
  }

  @override
  Future<ConnectorConnection> getConnection(String connectionId) async =>
      connections.firstWhere((item) => item.connectionId == connectionId);

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
      healthState: 'healthy',
      lastCheckedAt: DateTime.utc(2026, 10, 24, 12, 1),
      lastSuccessAt: DateTime.utc(2026, 10, 24, 12, 0, 30),
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

  testWidgets('disconnect then reload and reopen keeps disconnected history', (
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

    await _scrollTo(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect').last);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectorDetailPage), findsNothing);

    await controller.reload();
    await tester.pump();
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
}
