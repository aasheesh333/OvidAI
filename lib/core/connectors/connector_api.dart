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
    final key = raw['key'];
    if (key is! String || key.isEmpty) return null;
    final label = raw['label'];
    final hint = raw['hint'];
    return ConnectorCredentialField(
      key: key,
      label: label is String && label.isNotEmpty ? label : key,
      secret: raw['secret'] == true,
      hint: hint is String && hint.isNotEmpty ? hint : null,
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
  });

  final String curatedId;
  final String displayName;
  final String description;
  final List<ConnectorCredentialField> credentialFields;
  final List<String> toolNames;
  final bool configured;

  static ConnectorCatalogEntry? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['curatedId'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['displayName'];
    final description = raw['description'];
    final fields = raw['credentialFields'];
    final tools = raw['tools'];
    return ConnectorCatalogEntry(
      curatedId: id,
      displayName: name is String && name.isNotEmpty ? name : id,
      description: description is String ? description : '',
      credentialFields: [
        for (final f in (fields is List ? fields : const []))
          ?ConnectorCredentialField.tryParse(f),
      ],
      toolNames: [
        for (final t in (tools is List ? tools : const []))
          if (t is Map && t['name'] is String) t['name'] as String,
      ],
      configured: raw['configured'] == true,
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
    return [
      for (final item in (items is List ? items : const []))
        ?ConnectorCatalogEntry.tryParse(item),
    ];
  }

  Future<List<ConnectorServer>> listServers() async {
    final items = await _rest.getJsonList('/mcp/servers');
    return [
      for (final item in items) ?ConnectorServer.tryParse(item),
    ];
  }

  /// Enables a curated connector with the credentials the user just entered.
  Future<ConnectorServer> connectCurated({
    required String curatedId,
    Map<String, String> secrets = const {},
    String? name,
  }) async {
    final body = await _rest.postJson('/mcp/servers', body: {
      'curatedId': curatedId,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (secrets.isNotEmpty) 'secrets': secrets,
    });
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
    final body = await _rest.postJson('/mcp/servers', body: {
      'name': name.trim(),
      'transport': transport,
      if (url != null && url.trim().isNotEmpty) 'url': url.trim(),
      if (secrets.isNotEmpty) 'secrets': secrets,
    });
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

  Future<void> setEnabled(String id, bool enabled) =>
      _rest.patchJson('/mcp/servers/$id', body: {'enabled': enabled});

  Future<void> disconnect(String id) => _rest.delete('/mcp/servers/$id');
}
