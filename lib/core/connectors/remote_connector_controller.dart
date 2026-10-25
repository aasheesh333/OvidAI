import 'package:flutter/foundation.dart';

import 'connector_api.dart';

enum ConnectorViewStatus { loading, empty, error, content }

/// Gateway behavior confirmed by the owning backend contract lane.
///
/// Unverified alternate constructors default to [unavailable], so they never
/// offer a control backed only by a planned route. The real app route injects
/// [connectionLifecycle] only after the versioned DTO/composition is present.
@immutable
class ConnectorGatewayCapabilities {
  const ConnectorGatewayCapabilities({
    this.catalogReadiness = false,
    this.itemHealthCheck = false,
    this.createAgentEnabled = false,
    this.optionalCreateName = false,
    this.approvedSourceCreate = false,
  });

  static const unavailable = ConnectorGatewayCapabilities();
  static const approvedParity = ConnectorGatewayCapabilities(
    catalogReadiness: true,
    itemHealthCheck: true,
    createAgentEnabled: true,
    optionalCreateName: true,
    approvedSourceCreate: true,
  );

  /// Current gateway catalog/connection lifecycle without claiming the
  /// separately unavailable approved-source admission route.
  static const connectionLifecycle = ConnectorGatewayCapabilities(
    catalogReadiness: true,
    itemHealthCheck: true,
    createAgentEnabled: true,
    optionalCreateName: true,
  );

  final bool catalogReadiness;
  final bool itemHealthCheck;
  final bool createAgentEnabled;
  final bool optionalCreateName;
  final bool approvedSourceCreate;
}

@immutable
class ConnectorViewState {
  const ConnectorViewState({
    this.status = ConnectorViewStatus.loading,
    this.catalog = const <ConnectorCatalogEntry>[],
    this.connections = const <ConnectorConnection>[],
    this.accountId,
    this.errorMessage = '',
  });

  final ConnectorViewStatus status;
  final List<ConnectorCatalogEntry> catalog;
  final List<ConnectorConnection> connections;
  final String? accountId;
  final String errorMessage;
}

/// Current supported-definition + canonical-DTO agent gate shared by list,
/// detail and controller mutations. An enabled agent keeps its disable control.
bool connectorCanActivateAgent({
  required ConnectorCatalogEntry? definition,
  required ConnectorConnection? connection,
}) {
  if (definition == null || !definition.isSupported || connection == null) {
    return false;
  }
  if (connection.agentEnabled) return true;
  final authenticated = connection.authState == 'configured' ||
      connection.authState == 'authorized';
  final checkable = connection.healthState == 'never_checked' ||
      connection.healthState == 'healthy' ||
      connection.healthState == 'degraded';
  return connection.enabled && authenticated && checkable;
}

/// The one remote catalog/connection cache shared by list, setup and detail.
///
/// Account changes invalidate every in-flight read and mutation. Per-connection
/// operation versions prevent a late failure from rolling back a newer action.
/// Plaintext credentials pass through create calls only and are never stored in
/// this controller or its listenable state.
class RemoteConnectorController extends ValueNotifier<ConnectorViewState> {
  RemoteConnectorController({
    required ConnectorApi api,
    required String? Function() accountId,
    this.capabilities = ConnectorGatewayCapabilities.unavailable,
    // ignore: prefer_initializing_formals
  }) : _api = api,
       _accountIdSource = accountId,
       super(const ConnectorViewState());

  final ConnectorGatewayCapabilities capabilities;

  static const loadError =
      'Connectors did not load. Check your connection and retry.';

  final ConnectorApi _api;
  final String? Function() _accountIdSource;

  String? _accountId;
  bool _accountSnapshot = false;
  int _accountGeneration = 0;
  int _reloadGeneration = 0;
  final Map<String, int> _mutations = <String, int>{};
  final Map<String, int> _cacheVersions = <String, int>{};
  final Map<String, int> _inFlightMutations = <String, int>{};

  ConnectorConnection? connectionById(String connectionId) {
    for (final connection in value.connections) {
      if (connection.connectionId == connectionId) return connection;
    }
    return null;
  }

  ConnectorCatalogEntry? _supportedDefinition(String providerId) {
    for (final entry in value.catalog) {
      if (entry.providerId == providerId && entry.isSupported) return entry;
    }
    return null;
  }

  bool canActivateAgent(String connectionId) {
    final connection = connectionById(connectionId);
    return connectorCanActivateAgent(
      definition: connection == null
          ? null
          : _supportedDefinition(connection.providerId),
      connection: connection,
    );
  }

  void _validateCreateConfiguration(
    String providerId,
    Map<String, String> config,
  ) {
    final definition = _supportedDefinition(providerId);
    if (definition == null) {
      throw StateError('This provider is not supported for connection creation.');
    }
    final fields = definition.configurationFields;
    final allowedKeys = <String>{for (final field in fields) field.key};
    if (config.keys.any((key) => !allowedKeys.contains(key))) {
      throw StateError('Connection config contains an unsupported field.');
    }
    for (final field in fields) {
      final value = config[field.key]?.trim() ?? '';
      if (field.required && value.isEmpty) {
        throw StateError('${field.label} is required.');
      }
      if (value.length > field.maxLength) {
        throw StateError('${field.label} is too long.');
      }
      if (value.isNotEmpty && providerId == 'fetch' && field.key == 'url' &&
          !isValidFetchHealthUrl(value)) {
        throw StateError('Enter a credential-free HTTPS URL on port 443.');
      }
    }
    if (providerId == 'fetch' &&
        (config.length != 1 || !config.containsKey('url'))) {
      throw StateError('Fetch requires exactly one health check URL.');
    }
  }

  void _assertAgentActivation(String connectionId) {
    if (connectionById(connectionId) == null) {
      throw StateError('Connector not found.');
    }
    if (!canActivateAgent(connectionId)) {
      throw StateError('This connection cannot be enabled for agent runs.');
    }
  }

  void _fenceAccount() {
    final current = _accountIdSource();
    if (_accountSnapshot && current == _accountId) return;
    _accountSnapshot = true;
    _accountId = current;
    _accountGeneration++;
    _reloadGeneration++;
    _mutations.clear();
    _cacheVersions.clear();
    _inFlightMutations.clear();
    value = ConnectorViewState(
      status: current == null
          ? ConnectorViewStatus.error
          : ConnectorViewStatus.loading,
      accountId: current,
      errorMessage: current == null ? 'Sign in to manage connectors.' : '',
    );
  }

  bool _accountIsCurrent(int generation) {
    if (generation == _accountGeneration && _accountIdSource() == _accountId) {
      return true;
    }
    _fenceAccount();
    return false;
  }

  int _operationGeneration() {
    _fenceAccount();
    if (_accountId == null) throw StateError('Sign in to manage connectors.');
    return _accountGeneration;
  }

  Never _throwStaleAccount() =>
      throw StateError('The active account changed. Try again.');

  ConnectorViewStatus _statusFor(
    List<ConnectorCatalogEntry> catalog,
    List<ConnectorConnection> connections,
  ) => catalog.isEmpty && connections.isEmpty
      ? ConnectorViewStatus.empty
      : ConnectorViewStatus.content;

  void _emitConnections(List<ConnectorConnection> connections) {
    final catalog = List<ConnectorCatalogEntry>.unmodifiable(value.catalog);
    final rows = List<ConnectorConnection>.unmodifiable(connections);
    value = ConnectorViewState(
      status: _statusFor(catalog, rows),
      catalog: catalog,
      connections: rows,
      accountId: _accountId,
    );
  }

  void _upsert(ConnectorConnection connection) {
    final rows = <ConnectorConnection>[];
    var replaced = false;
    for (final current in value.connections) {
      if (current.connectionId == connection.connectionId) {
        rows.add(connection);
        replaced = true;
      } else {
        rows.add(current);
      }
    }
    if (!replaced) rows.add(connection);
    _emitConnections(rows);
  }

  int _nextMutation(String connectionId) {
    final next = (_mutations[connectionId] ?? 0) + 1;
    _mutations[connectionId] = next;
    return next;
  }

  int _cacheVersion(String connectionId) => _cacheVersions[connectionId] ?? 0;

  void _bumpCacheVersion(String connectionId) {
    _cacheVersions[connectionId] = _cacheVersion(connectionId) + 1;
  }

  void _mutationStarted(String connectionId) {
    _inFlightMutations[connectionId] =
        (_inFlightMutations[connectionId] ?? 0) + 1;
    _bumpCacheVersion(connectionId);
  }

  void _mutationSettled(String connectionId) {
    final pending = _inFlightMutations[connectionId] ?? 0;
    if (pending <= 1) {
      _inFlightMutations.remove(connectionId);
    } else {
      _inFlightMutations[connectionId] = pending - 1;
    }
    _bumpCacheVersion(connectionId);
  }

  bool _readIsCurrent(String connectionId, int readVersion) {
    return (_inFlightMutations[connectionId] ?? 0) == 0 &&
        _cacheVersion(connectionId) == readVersion;
  }

  Future<void> reload() async {
    _fenceAccount();
    final account = _accountId;
    if (account == null) return;
    final accountGeneration = _accountGeneration;
    final reloadGeneration = ++_reloadGeneration;
    final previousConnections = value.connections;
    final readVersions = Map<String, int>.of(_cacheVersions);
    value = ConnectorViewState(
      status: ConnectorViewStatus.loading,
      catalog: value.catalog,
      connections: previousConnections,
      accountId: account,
    );
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _api.listCatalog(),
        _api.listConnections(),
      ]);
      if (!_accountIsCurrent(accountGeneration) ||
          reloadGeneration != _reloadGeneration) {
        return;
      }
      final catalog = (results[0] as List<ConnectorCatalogEntry>)
          .where(
            (entry) => capabilities.catalogReadiness && entry.isSupported,
          )
          .toList(growable: false);
      final incoming = results[1] as List<ConnectorConnection>;
      final incomingIds = <String>{
        for (final connection in incoming) connection.connectionId,
      };
      final byId = <String, ConnectorConnection>{
        for (final connection in value.connections)
          connection.connectionId: connection,
      };
      final accepted = <String>[];
      for (final connection in incoming) {
        final id = connection.connectionId;
        if (!_readIsCurrent(id, readVersions[id] ?? 0)) continue;
        byId[id] = connection;
        accepted.add(id);
      }
      for (final previous in previousConnections) {
        final id = previous.connectionId;
        if (incomingIds.contains(id) ||
            !_readIsCurrent(id, readVersions[id] ?? 0)) {
          continue;
        }
        byId.remove(id);
        accepted.add(id);
      }
      for (final id in accepted) {
        _bumpCacheVersion(id);
      }
      final connections = byId.values.toList(growable: false);
      value = ConnectorViewState(
        status: _statusFor(catalog, connections),
        catalog: List<ConnectorCatalogEntry>.unmodifiable(catalog),
        connections: List<ConnectorConnection>.unmodifiable(connections),
        accountId: account,
      );
    } catch (_) {
      if (!_accountIsCurrent(accountGeneration) ||
          reloadGeneration != _reloadGeneration) {
        return;
      }
      value = ConnectorViewState(
        status: ConnectorViewStatus.error,
        catalog: value.catalog,
        connections: value.connections,
        accountId: account,
        errorMessage: loadError,
      );
    }
  }

  Future<ConnectorConnection> getConnection(String connectionId) async {
    final generation = _operationGeneration();
    final readVersion = _cacheVersion(connectionId);
    final connection = await _api.getConnection(connectionId);
    if (!_accountIsCurrent(generation)) _throwStaleAccount();
    if (_readIsCurrent(connectionId, readVersion)) {
      _bumpCacheVersion(connectionId);
      _upsert(connection);
    }
    return connection;
  }

  Future<ConnectorConnection> createConnection({
    required String providerId,
    String? name,
    Map<String, String> secrets = const <String, String>{},
    Map<String, String> config = const <String, String>{},
    bool agentEnabled = false,
  }) {
    if (providerId == 'fetch' && (secrets.isNotEmpty || agentEnabled)) {
      return Future<ConnectorConnection>.error(
        StateError('Fetch has no credential or create-time agent fields.'),
      );
    }
    if (agentEnabled && !capabilities.createAgentEnabled) {
      return Future<ConnectorConnection>.error(
        StateError('Create-time agent activation is unavailable.'),
      );
    }
    if (name == null && !capabilities.optionalCreateName) {
      return Future<ConnectorConnection>.error(
        StateError('This gateway requires a connection name.'),
      );
    }
    try {
      _validateCreateConfiguration(providerId, config);
    } catch (error) {
      return Future<ConnectorConnection>.error(error);
    }
    return _create(
      () => providerId == 'fetch'
          ? _api.createFetchConnection(name: name, url: config['url']!)
          : _api.createConnection(
              providerId: providerId,
              name: name,
              secrets: secrets,
              config: config,
              agentEnabled: agentEnabled,
            ),
    );
  }

  Future<ConnectorConnection> createCustomConnection({
    required String providerId,
    required String name,
    required String approvedSourceId,
    required String approvedDigest,
    Map<String, String> secrets = const <String, String>{},
    bool agentEnabled = false,
  }) {
    if (!capabilities.approvedSourceCreate) {
      return Future<ConnectorConnection>.error(
        StateError('Approved-source creation is unavailable.'),
      );
    }
    if (agentEnabled && !capabilities.createAgentEnabled) {
      return Future<ConnectorConnection>.error(
        StateError('Create-time agent activation is unavailable.'),
      );
    }
    return _create(
      () => _api.createCustomConnection(
        providerId: providerId,
        name: name,
        approvedSourceId: approvedSourceId,
        approvedDigest: approvedDigest,
        secrets: secrets,
        agentEnabled: agentEnabled,
      ),
    );
  }

  Future<ConnectorConnection> _create(
    Future<ConnectorConnection> Function() create,
  ) async {
    final generation = _operationGeneration();
    final connection = await create();
    if (!_accountIsCurrent(generation)) _throwStaleAccount();
    // A create response is not health evidence. Publish only the canonical,
    // account-fenced item read; this read is not a provider health probe.
    return getConnection(connection.connectionId);
  }

  Future<ConnectorConnection> _mutate(
    String connectionId,
    Future<ConnectorConnection> Function() mutation,
    ConnectorConnection Function(ConnectorConnection current)? optimistic,
  ) async {
    final generation = _operationGeneration();
    final previous = connectionById(connectionId);
    if (previous == null) throw StateError('Connector not found.');
    final operation = _nextMutation(connectionId);
    _mutationStarted(connectionId);
    if (optimistic != null) _upsert(optimistic(previous));
    try {
      final updated = await mutation();
      if (!_accountIsCurrent(generation)) _throwStaleAccount();
      _mutationSettled(connectionId);
      if (_mutations[connectionId] == operation) _upsert(updated);
      return updated;
    } catch (_) {
      final accountIsCurrent = _accountIsCurrent(generation);
      if (accountIsCurrent) _mutationSettled(connectionId);
      if (accountIsCurrent &&
          _mutations[connectionId] == operation &&
          optimistic != null) {
        _upsert(previous);
      }
      rethrow;
    }
  }

  Future<void> setEnabled(String connectionId, bool enabled) async {
    await _mutate(
      connectionId,
      () => _api.setEnabled(connectionId, enabled),
      (current) => current.copyWith(enabled: enabled),
    );
  }

  Future<void> setAgentEnabled(String connectionId, bool agentEnabled) async {
    if (agentEnabled) _assertAgentActivation(connectionId);
    await _mutate(
      connectionId,
      () => _api.setAgentEnabled(connectionId, agentEnabled),
      (current) => current.copyWith(agentEnabled: agentEnabled),
    );
  }

  Future<ConnectorConnection> checkHealth(String connectionId) {
    if (!capabilities.itemHealthCheck) {
      return Future<ConnectorConnection>.error(
        StateError('Connection health checks are unavailable.'),
      );
    }
    return _mutate(connectionId, () => _api.checkHealth(connectionId), null);
  }

  Future<void> disconnect(String connectionId) async {
    final generation = _operationGeneration();
    final previous = connectionById(connectionId);
    if (previous == null) throw StateError('Connector not found.');
    final operation = _nextMutation(connectionId);
    _mutationStarted(connectionId);
    final previousIndex = value.connections.indexOf(previous);
    _emitConnections(
      value.connections
          .where((item) => item.connectionId != connectionId)
          .toList(growable: false),
    );
    try {
      await _api.disconnect(connectionId);
      if (!_accountIsCurrent(generation)) _throwStaleAccount();
      _mutationSettled(connectionId);
      // Publish the server result immediately: retained rows become visible
      // disconnected history, while removed rows stay removed. No reconnect or
      // provider reauthorization transition is inferred here.
      await reload();
    } catch (_) {
      final accountIsCurrent = _accountIsCurrent(generation);
      if (accountIsCurrent) _mutationSettled(connectionId);
      if (accountIsCurrent &&
          _mutations[connectionId] == operation &&
          connectionById(connectionId) == null) {
        final rows = value.connections.toList();
        rows.insert(previousIndex.clamp(0, rows.length), previous);
        _emitConnections(rows);
      }
      rethrow;
    }
  }
}
