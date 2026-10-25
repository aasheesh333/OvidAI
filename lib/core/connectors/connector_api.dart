import '../cloud/cloud_rest.dart';

/// One credential field a curated MCP server needs before it can be used.
///
/// The value is never carried here — only the key the setup sheet must ask
/// for. Secrets travel straight to the gateway and are sealed server-side.
class ConnectorCredentialField {
  const ConnectorCredentialField({
    required this.key,
    required this.label,
    required this.secret,
    this.hint,
  });

  final String key;
  final String label;
  final bool secret;
  final String? hint;

  static ConnectorCredentialField? tryParse(Object? raw) {
    if (raw is! Map) return null;
    const allowed = <String>{'key', 'label', 'secret', 'hint'};
    if (raw.keys.any((key) => key is! String || !allowed.contains(key))) {
      return null;
    }
    final key = raw['key'];
    final label = raw['label'];
    final secret = raw['secret'];
    final hint = raw['hint'];
    if (key is! String || key.isEmpty) return null;
    if (label is! String || label.isEmpty) return null;
    if (secret is! bool) return null;
    if (hint != null && hint is! String) return null;
    return ConnectorCredentialField(
      key: key,
      label: label,
      secret: secret,
      hint: hint as String?,
    );
  }
}

/// Descriptor for non-secret connection config. Values go only to create.
class ConnectorConfigurationField {
  const ConnectorConfigurationField({
    required this.key,
    required this.label,
    required this.kind,
    required this.required,
    required this.maxLength,
    this.hint,
  });

  final String key;
  final String label;
  final String kind;
  final bool required;
  final int maxLength;
  final String? hint;

  static ConnectorConfigurationField? tryParse(Object? raw) {
    if (raw is! Map) return null;
    const allowed = <String>{'key', 'label', 'kind', 'required', 'maxLength', 'hint'};
    if (raw.keys.any((key) => key is! String || !allowed.contains(key))) {
      return null;
    }
    final key = raw['key'];
    final label = raw['label'];
    final kind = raw['kind'];
    final required = raw['required'];
    final maxLength = raw['maxLength'];
    final hint = raw['hint'];
    if (key is! String || key.isEmpty || key.length > 128) return null;
    if (RegExp(
      r'authorization|cookie|credential|password|secret|token|api[_-]?key|oauth',
      caseSensitive: false,
    ).hasMatch(key)) {
      return null;
    }
    if (label is! String || label.isEmpty || label.length > 200) return null;
    if (kind != 'string' && kind != 'url') return null;
    if (required is! bool) return null;
    if (maxLength is! int || maxLength < 1 || maxLength > 2048) return null;
    if (hint != null && (hint is! String || hint.length > 1024)) return null;
    return ConnectorConfigurationField(
      key: key,
      label: label,
      kind: kind as String,
      required: required,
      maxLength: maxLength,
      hint: hint as String?,
    );
  }
}

/// One typed provider operation advertised by the supported catalog.
///
/// Effect and approval metadata is display-only here. Execution remains behind
/// the gateway's activation and per-operation authorization boundaries.
class ConnectorOperation {
  const ConnectorOperation({
    required this.name,
    required this.description,
    required this.effect,
    required this.approval,
  });

  final String name;
  final String description;
  final String? effect;
  final String? approval;

  static ConnectorOperation? tryParse(Object? raw) {
    if (raw is! Map) return null;
    const allowed = <String>{
      'name',
      'description',
      'effect',
      'approval',
      'requiredScopes',
    };
    if (raw.keys.any((key) => key is! String || !allowed.contains(key))) {
      return null;
    }
    final name = raw['name'];
    final description = raw['description'];
    final effect = raw['effect'];
    final approval = raw['approval'];
    final requiredScopes = raw['requiredScopes'];
    if (name is! String || name.isEmpty) return null;
    if (description != null && description is! String) return null;
    if (effect != null && (effect is! String || effect.isEmpty)) return null;
    if (approval != null && (approval is! String || approval.isEmpty)) {
      return null;
    }
    if (requiredScopes != null &&
        (requiredScopes is! List ||
            requiredScopes.any((scope) => scope is! String))) {
      return null;
    }
    return ConnectorOperation(
      name: name,
      description: description is String ? description : '',
      effect: effect as String?,
      approval: approval as String?,
    );
  }
}

/// One row of the curated catalog the gateway serves (`GET /mcp/catalog`).
///
/// `configured` is the caller's own state, not a global flag: the same server
/// is shared by every user, only the credentials are per-user.
class ConnectorCatalogEntry {
  const ConnectorCatalogEntry({
    required this.curatedId,
    required this.displayName,
    required this.description,
    required this.credentialFields,
    required this.toolNames,
    required this.configured,
    this.catalogVersion = '',
    this.readiness,
    this.configurationFields = const <ConnectorConfigurationField>[],
    this.operations = const <ConnectorOperation>[],
  });

  final String curatedId;
  final String displayName;
  final String description;
  final List<ConnectorCredentialField> credentialFields;
  final List<String> toolNames;
  final bool configured;
  final String catalogVersion;
  final String? readiness;
  final List<ConnectorConfigurationField> configurationFields;
  final List<ConnectorOperation> operations;

  String get providerId => curatedId;

  /// Only the versioned, explicitly supported contract is installable. Legacy
  /// rows and candidate/blocked/deprecated rows never inherit installability.
  bool get isSupported => readiness == 'supported' && catalogVersion.isNotEmpty;

  static ConnectorCatalogEntry? tryParse(Object? raw) {
    if (raw is! Map || raw['readiness'] != 'supported') return null;
    const allowed = <String>{
      'curatedId',
      'displayName',
      'description',
      'catalogVersion',
      'readiness',
      'credentialFields',
      'configurationFields',
      'tools',
      'configured',
    };
    if (raw.keys.any((key) => key is! String || !allowed.contains(key))) {
      return null;
    }
    final id = raw['curatedId'];
    final name = raw['displayName'];
    final description = raw['description'];
    final catalogVersion = raw['catalogVersion'];
    final configured = raw['configured'];
    final fields = raw['credentialFields'];
    final configuration = raw['configurationFields'];
    final tools = raw['tools'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    if (description is! String) return null;
    if (catalogVersion is! String || catalogVersion.trim().isEmpty ||
        catalogVersion.length > 128) {
      return null;
    }
    if (configured is! bool || fields is! List || configuration is! List ||
        tools is! List) {
      return null;
    }

    final credentialFields = <ConnectorCredentialField>[];
    for (final field in fields) {
      final parsed = ConnectorCredentialField.tryParse(field);
      if (parsed == null) return null;
      credentialFields.add(parsed);
    }
    final configurationFields = <ConnectorConfigurationField>[];
    for (final field in configuration) {
      final parsed = ConnectorConfigurationField.tryParse(field);
      if (parsed == null) return null;
      configurationFields.add(parsed);
    }
    final parsedOperations = <ConnectorOperation>[];
    for (final operation in tools) {
      final parsed = ConnectorOperation.tryParse(operation);
      if (parsed == null) return null;
      parsedOperations.add(parsed);
    }
    if (id == 'fetch' &&
        (credentialFields.isNotEmpty || configurationFields.length != 1 ||
            configurationFields.single.key != 'url' ||
            configurationFields.single.kind != 'url' ||
            !configurationFields.single.required ||
            configurationFields.single.maxLength != 2048)) {
      return null;
    }
    return ConnectorCatalogEntry(
      curatedId: id,
      displayName: name,
      description: description,
      credentialFields: credentialFields,
      toolNames: [for (final operation in parsedOperations) operation.name],
      configured: configured,
      catalogVersion: catalogVersion,
      readiness: 'supported',
      configurationFields: configurationFields,
      operations: parsedOperations,
    );
  }
}

/// One connector the user has actually set up (`GET /mcp/servers`).
class ConnectorServer {
  const ConnectorServer({
    required this.id,
    required this.name,
    required this.transport,
    required this.enabled,
    required this.hasSecrets,
    required this.needsAuth,
    this.curatedId,
    this.url,
  });

  final String id;
  final String name;
  final String transport;
  final bool enabled;
  final bool hasSecrets;

  /// A remote server that still needs an OAuth round-trip before it can run.
  final bool needsAuth;
  final String? curatedId;
  final String? url;

  static ConnectorServer? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    final transport = raw['transport'];
    final curatedId = raw['curatedId'];
    final url = raw['url'];
    return ConnectorServer(
      id: id,
      name: name,
      transport: transport is String ? transport : 'http',
      enabled: raw['enabled'] == true,
      hasSecrets: raw['hasSecrets'] == true,
      needsAuth: raw['needsAuth'] == true,
      curatedId: curatedId is String && curatedId.isNotEmpty ? curatedId : null,
      url: url is String && url.isNotEmpty ? url : null,
    );
  }
}

/// Secret-free, server-authoritative state for one configured connection.
///
/// [connectionId] is the per-user server UUID. [providerId] is catalog-owned;
/// the two are deliberately separate and no mutation accepts a provider ID in
/// place of a connection ID. No plaintext secret or connection config is part
/// of this DTO.
class ConnectorConnection {
  const ConnectorConnection({
    required this.connectionId,
    required this.userId,
    required this.providerId,
    required this.name,
    required this.transport,
    required this.enabled,
    required this.agentEnabled,
    required this.authState,
    required this.healthState,
    required this.lastCheckedAt,
    required this.lastSuccessAt,
    required this.configVersion,
    required this.disconnectGeneration,
    required this.hasSecrets,
    required this.createdAt,
    required this.updatedAt,
    this.approvedSourceId,
    this.approvedDigest,
  });

  final String connectionId;
  final String userId;
  final String providerId;
  final String name;
  final String transport;
  final bool enabled;
  final bool agentEnabled;
  final String authState;
  final String healthState;
  final DateTime? lastCheckedAt;
  final DateTime? lastSuccessAt;
  final int configVersion;
  final int disconnectGeneration;
  final bool hasSecrets;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? approvedSourceId;
  final String? approvedDigest;

  /// Canonical disconnect history. The gateway retains this row for auditing
  /// and generation fencing; it is not an installed connection and must never
  /// be projected as one after a later authoritative reload or app reopen.
  bool get isDisconnected =>
      disconnectGeneration > 0 &&
      !enabled &&
      !agentEnabled &&
      authState == 'revoked' &&
      healthState == 'revoked';

  static const _authStates = <String>{
    'missing',
    'configured',
    'needs_auth',
    'authorized',
    'revoked',
  };
  static const _healthStates = <String>{
    'never_checked',
    'checking',
    'healthy',
    'degraded',
    'needs_auth',
    'refreshing',
    'revoked',
    'unavailable',
    'disabled',
  };
  static const _transports = <String>{'stdio', 'http', 'sse', 'native'};

  static DateTime? _timestamp(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  static ConnectorConnection? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final connectionId = raw['connectionId'];
    final userId = raw['userId'];
    final providerId = raw['providerId'];
    final name = raw['name'];
    final transport = raw['transport'];
    final enabled = raw['enabled'];
    final agentEnabled = raw['agentEnabled'];
    final authState = raw['authState'];
    final healthState = raw['healthState'];
    final configVersion = raw['configVersion'];
    final disconnectGeneration = raw['disconnectGeneration'];
    final hasSecrets = raw['hasSecrets'];
    final createdAt = _timestamp(raw['createdAt']);
    final updatedAt = _timestamp(raw['updatedAt']);
    if (connectionId is! String || connectionId.isEmpty) return null;
    if (userId is! String || userId.isEmpty) return null;
    if (providerId is! String || providerId.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    if (transport is! String || !_transports.contains(transport)) return null;
    if (enabled is! bool || agentEnabled is! bool) return null;
    if (authState is! String || !_authStates.contains(authState)) return null;
    if (healthState is! String || !_healthStates.contains(healthState)) {
      return null;
    }
    if (configVersion is! int || configVersion < 0) return null;
    if (disconnectGeneration is! int || disconnectGeneration < 0) return null;
    if (hasSecrets is! bool || createdAt == null || updatedAt == null) {
      return null;
    }
    final approvedSourceId = raw['approvedSourceId'];
    final approvedDigest = raw['approvedDigest'];
    return ConnectorConnection(
      connectionId: connectionId,
      userId: userId,
      providerId: providerId,
      name: name,
      transport: transport,
      enabled: enabled,
      agentEnabled: agentEnabled,
      authState: authState,
      healthState: healthState,
      lastCheckedAt: _timestamp(raw['lastCheckedAt']),
      lastSuccessAt: _timestamp(raw['lastSuccessAt']),
      configVersion: configVersion,
      disconnectGeneration: disconnectGeneration,
      hasSecrets: hasSecrets,
      createdAt: createdAt,
      updatedAt: updatedAt,
      approvedSourceId:
          approvedSourceId is String && approvedSourceId.isNotEmpty
          ? approvedSourceId
          : null,
      approvedDigest: approvedDigest is String && approvedDigest.isNotEmpty
          ? approvedDigest
          : null,
    );
  }

  ConnectorConnection copyWith({
    String? name,
    bool? enabled,
    bool? agentEnabled,
    String? authState,
    String? healthState,
    DateTime? lastCheckedAt,
    DateTime? lastSuccessAt,
    int? configVersion,
    int? disconnectGeneration,
    bool? hasSecrets,
    DateTime? updatedAt,
  }) {
    return ConnectorConnection(
      connectionId: connectionId,
      userId: userId,
      providerId: providerId,
      name: name ?? this.name,
      transport: transport,
      enabled: enabled ?? this.enabled,
      agentEnabled: agentEnabled ?? this.agentEnabled,
      authState: authState ?? this.authState,
      healthState: healthState ?? this.healthState,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      configVersion: configVersion ?? this.configVersion,
      disconnectGeneration: disconnectGeneration ?? this.disconnectGeneration,
      hasSecrets: hasSecrets ?? this.hasSecrets,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      approvedSourceId: approvedSourceId,
      approvedDigest: approvedDigest,
    );
  }
}

/// Validate the exact non-secret URL accepted by fetch health configuration.
bool isValidFetchHealthUrl(String value) {
  final text = value.trim();
  if (text.isEmpty || text.length > 2048) return false;
  try {
    final uri = Uri.tryParse(text);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.port == 443;
  } catch (_) {
    return false;
  }
}

/// The connector surface of the gateway.
///
/// Before this client existed the app kept connectors in SharedPreferences
/// and never told the server, so enabling one changed a local flag and gave
/// the agent nothing. Everything here is server-authoritative: the catalog,
/// the user's configured servers, and the plan's refusal.
class ConnectorApi {
  ConnectorApi({CloudRestClient? rest}) : _rest = rest ?? CloudRestClient();

  final CloudRestClient _rest;

  Future<List<ConnectorCatalogEntry>> listCatalog() async {
    final body = await _rest.getJson('/mcp/catalog');
    final items = body['items'];
    if (body['contractVersion'] != 2 || items is! List) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable connector catalog.',
      );
    }
    final entries = <ConnectorCatalogEntry>[];
    for (final item in items) {
      final readiness = item is Map ? item['readiness'] : null;
      if (readiness != 'supported') continue;
      final entry = ConnectorCatalogEntry.tryParse(item);
      if (entry == null || !entry.isSupported) {
        throw CloudApiException(
          status: 200,
          code: 'internal',
          message: 'Ovid Cloud returned an unreadable connector catalog.',
        );
      }
      entries.add(entry);
    }
    return entries;
  }

  Future<List<ConnectorConnection>> listConnections() async {
    final body = await _rest.getJson('/mcp/connections');
    final items = body['items'];
    if (items is! List) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable connector list.',
      );
    }
    return [for (final item in items) ?ConnectorConnection.tryParse(item)];
  }

  Future<ConnectorConnection> createConnection({
    required String providerId,
    String? name,
    Map<String, String> secrets = const <String, String>{},
    Map<String, String> config = const <String, String>{},
    bool agentEnabled = false,
  }) async {
    if (providerId == 'fetch') {
      if (secrets.isNotEmpty || agentEnabled || config.length != 1 ||
          !config.containsKey('url')) {
        throw StateError('Fetch accepts only one public health URL.');
      }
      return createFetchConnection(name: name, url: config['url']!);
    }
    final body = await _rest.postJson(
      '/mcp/connections',
      body: <String, Object?>{
        'providerId': providerId,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        'secrets': secrets,
        'agentEnabled': agentEnabled,
        if (config.isNotEmpty) 'config': config,
      },
    );
    return _connectionResponse(body);
  }

  /// Canonical public-fetch create. No credential/agent/request override can
  /// cross this boundary; only the non-secret health URL is accepted.
  Future<ConnectorConnection> createFetchConnection({
    String? name,
    required String url,
  }) async {
    final trimmed = url.trim();
    if (!isValidFetchHealthUrl(trimmed)) {
      throw StateError('Enter a credential-free HTTPS URL on port 443.');
    }
    final body = await _rest.postJson(
      '/mcp/connections',
      body: <String, Object?>{
        'providerId': 'fetch',
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        'config': <String, String>{'url': trimmed},
      },
    );
    return _connectionResponse(body);
  }

  /// Creates an MCP contribution from an already admitted source. Arbitrary
  /// URLs, commands, pasted manifests, transports and raw config never cross
  /// this client boundary.
  Future<ConnectorConnection> createCustomConnection({
    required String providerId,
    required String name,
    required String approvedSourceId,
    required String approvedDigest,
    Map<String, String> secrets = const <String, String>{},
    bool agentEnabled = false,
  }) async {
    final body = await _rest.postJson(
      '/mcp/connections',
      body: <String, Object?>{
        'providerId': providerId,
        'name': name.trim(),
        'approvedSourceId': approvedSourceId,
        'approvedDigest': approvedDigest,
        'secrets': secrets,
        'agentEnabled': agentEnabled,
      },
    );
    return _connectionResponse(body);
  }

  Future<ConnectorConnection> getConnection(String connectionId) async {
    final body = await _rest.getJson('/mcp/connections/$connectionId');
    return _connectionResponse(body);
  }

  Future<ConnectorConnection> checkHealth(String connectionId) async {
    final body = await _rest.postJson('/mcp/connections/$connectionId');
    return _connectionResponse(body);
  }

  ConnectorConnection _connectionResponse(Map<String, dynamic> body) {
    final parsed = ConnectorConnection.tryParse(body);
    if (parsed == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable connector.',
      );
    }
    return parsed;
  }

  Future<List<ConnectorServer>> listServers() async {
    final items = await _rest.getJsonList('/mcp/servers');
    return [for (final item in items) ?ConnectorServer.tryParse(item)];
  }

  /// Enables a curated connector with the credentials the user just entered.
  Future<ConnectorServer> connectCurated({
    required String curatedId,
    Map<String, String> secrets = const {},
    String? name,
  }) async {
    final body = await _rest.postJson(
      '/mcp/servers',
      body: {
        'curatedId': curatedId,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (secrets.isNotEmpty) 'secrets': secrets,
      },
    );
    final parsed = ConnectorServer.tryParse(body);
    if (parsed == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable connector.',
      );
    }
    return parsed;
  }

  /// Adds a custom MCP server (paid plans only — the server enforces it).
  Future<ConnectorServer> addCustom({
    required String name,
    required String transport,
    String? url,
    Map<String, String> secrets = const {},
  }) async {
    final body = await _rest.postJson(
      '/mcp/servers',
      body: {
        'name': name.trim(),
        'transport': transport,
        if (url != null && url.trim().isNotEmpty) 'url': url.trim(),
        if (secrets.isNotEmpty) 'secrets': secrets,
      },
    );
    final parsed = ConnectorServer.tryParse(body);
    if (parsed == null) {
      throw CloudApiException(
        status: 200,
        code: 'internal',
        message: 'Ovid Cloud returned an unreadable connector.',
      );
    }
    return parsed;
  }

  Future<ConnectorConnection> setEnabled(
    String connectionId,
    bool enabled,
  ) async {
    final body = await _rest.patchJson(
      '/mcp/connections/$connectionId',
      body: <String, Object?>{'enabled': enabled},
    );
    return _connectionResponse(body);
  }

  Future<ConnectorConnection> setAgentEnabled(
    String connectionId,
    bool agentEnabled,
  ) async {
    final body = await _rest.patchJson(
      '/mcp/connections/$connectionId',
      body: <String, Object?>{'agentEnabled': agentEnabled},
    );
    return _connectionResponse(body);
  }

  Future<void> disconnect(String connectionId) {
    // Legacy non-UUID IDs are retained only for the old client compatibility
    // tests. Every remote lifecycle row has a server UUID and uses the new API.
    final isConnectionId = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(connectionId);
    return _rest.delete(
      isConnectionId
          ? '/mcp/connections/$connectionId'
          : '/mcp/servers/$connectionId',
    );
  }
}
