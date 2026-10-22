import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/secure_store.dart';
import 'connector_models.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// One saved connector: the catalog entry the person set up, or a custom
/// server they added.
///
/// The endpoint, permissions and switches are safe to persist. The credential
/// is **not** here: [V2ConnectorSecrets] keeps it in the platform keystore so
/// an API key never lands in SharedPreferences or a log.
@immutable
class V2ConnectorConnection {
  const V2ConnectorConnection({
    required this.id,
    required this.name,
    required this.endpoint,
    this.description = '',
    this.category = 'Custom',
    this.kind = 'app',
    this.target = V2ConnectorTarget.url,
    this.auth = V2ConnectorAuth.none,
    this.enabled = true,
    this.read = true,
    this.write = false,
    this.execute = false,
    this.autoSync = false,
    this.custom = true,
    this.connectedAt,
    this.disabledTools = const <String>{},
  });

  final String id;
  final String name;
  final String description;
  final String category;

  /// `app`, `plugin` or `mcp` — stored as a string so the persisted format
  /// never depends on enum ordering.
  final String kind;

  /// Server URL or workspace command.
  final String endpoint;
  final V2ConnectorTarget target;
  final V2ConnectorAuth auth;

  /// The connector switch on the list and the detail page.
  final bool enabled;

  final bool read;
  final bool write;
  final bool execute;
  final bool autoSync;

  /// False for a catalog connector, true for one the person defined. Custom
  /// connectors count toward the plan allowance; catalog apps do not.
  final bool custom;

  final DateTime? connectedAt;

  /// Tools the person turned off on the permissions screen.
  final Set<String> disabledTools;

  bool get isCommand => target == V2ConnectorTarget.command;

  bool permissionGranted(V2ConnectorPermissionKind kind) => switch (kind) {
    V2ConnectorPermissionKind.read => read,
    V2ConnectorPermissionKind.write => write,
    V2ConnectorPermissionKind.execute => execute,
  };

  V2ConnectorConnection copyWith({
    String? name,
    String? endpoint,
    String? description,
    String? category,
    String? kind,
    V2ConnectorTarget? target,
    V2ConnectorAuth? auth,
    bool? enabled,
    bool? read,
    bool? write,
    bool? execute,
    bool? autoSync,
    bool? custom,
    Set<String>? disabledTools,
  }) {
    return V2ConnectorConnection(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      category: category ?? this.category,
      kind: kind ?? this.kind,
      endpoint: endpoint ?? this.endpoint,
      target: target ?? this.target,
      auth: auth ?? this.auth,
      enabled: enabled ?? this.enabled,
      read: read ?? this.read,
      write: write ?? this.write,
      execute: execute ?? this.execute,
      autoSync: autoSync ?? this.autoSync,
      custom: custom ?? this.custom,
      connectedAt: connectedAt,
      disabledTools: disabledTools ?? this.disabledTools,
    );
  }

  /// The row this connection renders as in the connector list.
  V2Connector toRow() {
    return V2Connector(
      id: id,
      name: name,
      description: description,
      connected: true,
      category: category,
      kind: switch (kind) {
        'plugin' => V2ConnectorKind.plugin,
        'mcp' => V2ConnectorKind.mcp,
        _ => V2ConnectorKind.app,
      },
      icon: switch (kind) {
        'plugin' => Icons.widgets_outlined,
        'mcp' => Icons.dns_outlined,
        _ => Icons.extension_outlined,
      },
      enabled: enabled,
      builtIn: !custom,
      endpoint: endpoint,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'description': description,
    'category': category,
    'kind': kind,
    'endpoint': endpoint,
    'target': target.name,
    'auth': auth.name,
    'enabled': enabled,
    'read': read,
    'write': write,
    'execute': execute,
    'autoSync': autoSync,
    'custom': custom,
    'connectedAt': connectedAt?.toIso8601String(),
    'disabledTools': disabledTools.toList()..sort(),
  };

  factory V2ConnectorConnection.fromJson(Map<String, Object?> json) {
    T pick<T>(String key, T fallback) {
      final value = json[key];
      return value is T ? value : fallback;
    }

    return V2ConnectorConnection(
      id: pick('id', ''),
      name: pick('name', ''),
      description: pick('description', ''),
      category: pick('category', 'Custom'),
      kind: pick('kind', 'app'),
      endpoint: pick('endpoint', ''),
      target: V2ConnectorTarget.values.firstWhere(
        (value) => value.name == json['target'],
        orElse: () => V2ConnectorTarget.url,
      ),
      auth: V2ConnectorAuth.values.firstWhere(
        (value) => value.name == json['auth'],
        orElse: () => V2ConnectorAuth.none,
      ),
      enabled: pick('enabled', true),
      read: pick('read', true),
      write: pick('write', false),
      execute: pick('execute', false),
      autoSync: pick('autoSync', false),
      custom: pick('custom', true),
      connectedAt: DateTime.tryParse(json['connectedAt'] as String? ?? ''),
      disabledTools: {
        for (final tool in (json['disabledTools'] as List?) ?? const [])
          if (tool is String) tool,
      },
    );
  }
}

/// Connector state, persisted by [V2ConnectorStore].
abstract class V2ConnectorStore {
  Future<List<V2ConnectorConnection>> load();

  Future<V2ConnectorConnection?> find(String id);

  Future<void> save(V2ConnectorConnection connection);

  Future<void> remove(String id);

  Future<void> setEnabled(String id, bool enabled);

  Future<void> setPermission(
    String id,
    V2ConnectorPermissionKind kind,
    bool granted,
  );

  Future<void> setToolEnabled(String id, String toolId, bool enabled);

  Future<void> setAutoSync(String id, bool autoSync);
}

/// Secrets are kept out of [V2ConnectorStore] on purpose.
abstract class V2ConnectorSecrets {
  Future<void> write(String id, String secret);

  Future<String?> read(String id);

  Future<void> delete(String id);
}

/// SharedPreferences-backed connector state.
///
/// The whole map is rewritten on every change, serialized through one queue so
/// two quick switch flips cannot lose each other. A corrupt blob is treated as
/// "no saved connectors" instead of crashing the screen.
class V2PrefsConnectorStore implements V2ConnectorStore {
  V2PrefsConnectorStore({Future<SharedPreferences> Function()? prefs})
    : _prefs = prefs ?? SharedPreferences.getInstance;

  static const storageKey = 'v2.connectors.v1';

  final Future<SharedPreferences> Function() _prefs;
  Future<void> _queue = Future<void>.value();

  Future<Map<String, V2ConnectorConnection>> _read() async {
    final prefs = await _prefs();
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.trim().isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final list = decoded['connections'];
      if (list is! List) return {};
      final result = <String, V2ConnectorConnection>{};
      for (final item in list) {
        if (item is! Map) continue;
        final connection = V2ConnectorConnection.fromJson(
          item.map((key, value) => MapEntry('$key', value)),
        );
        if (connection.id.isEmpty) continue;
        result[connection.id] = connection;
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _mutate(
    void Function(Map<String, V2ConnectorConnection> connections) change,
  ) {
    return _serialized(() async {
      final connections = await _read();
      change(connections);
      final prefs = await _prefs();
      await prefs.setString(
        storageKey,
        jsonEncode({
          'version': 1,
          'connections': [
            for (final connection in connections.values) connection.toJson(),
          ],
        }),
      );
    });
  }

  @override
  Future<List<V2ConnectorConnection>> load() async {
    final connections = await _read();
    final list = connections.values.toList()
      ..sort((a, b) {
        final at = a.connectedAt;
        final bt = b.connectedAt;
        if (at == null && bt == null) return a.name.compareTo(b.name);
        if (at == null) return 1;
        if (bt == null) return -1;
        final byDate = bt.compareTo(at);
        return byDate != 0 ? byDate : a.name.compareTo(b.name);
      });
    return list;
  }

  @override
  Future<V2ConnectorConnection?> find(String id) async => (await _read())[id];

  @override
  Future<void> save(V2ConnectorConnection connection) =>
      _mutate((connections) => connections[connection.id] = connection);

  @override
  Future<void> remove(String id) =>
      _mutate((connections) => connections.remove(id));

  @override
  Future<void> setEnabled(String id, bool enabled) => _mutate((connections) {
    final current = connections[id];
    if (current == null) return;
    connections[id] = current.copyWith(enabled: enabled);
  });

  @override
  Future<void> setPermission(
    String id,
    V2ConnectorPermissionKind kind,
    bool granted,
  ) => _mutate((connections) {
    final current = connections[id];
    if (current == null) return;
    connections[id] = switch (kind) {
      V2ConnectorPermissionKind.read => current.copyWith(read: granted),
      V2ConnectorPermissionKind.write => current.copyWith(write: granted),
      V2ConnectorPermissionKind.execute => current.copyWith(execute: granted),
    };
  });

  @override
  Future<void> setToolEnabled(String id, String toolId, bool enabled) =>
      _mutate((connections) {
        final current = connections[id];
        if (current == null) return;
        final disabled = {...current.disabledTools};
        if (enabled) {
          disabled.remove(toolId);
        } else {
          disabled.add(toolId);
        }
        connections[id] = current.copyWith(disabledTools: disabled);
      });

  @override
  Future<void> setAutoSync(String id, bool autoSync) => _mutate((connections) {
    final current = connections[id];
    if (current == null) return;
    connections[id] = current.copyWith(autoSync: autoSync);
  });
}

/// Keystore-backed connector secrets.
class V2ConnectorSecretVault implements V2ConnectorSecrets {
  V2ConnectorSecretVault({FlutterSecureStorage? storage})
    : _storage = storage ?? ovidSecureStorage();

  static const _prefix = 'v2.connector.secret.';

  final FlutterSecureStorage _storage;

  static String keyFor(String id) => '$_prefix$id';

  @override
  Future<void> write(String id, String secret) async {
    if (secret.trim().isEmpty) {
      await delete(id);
      return;
    }
    await _storage.write(key: keyFor(id), value: secret);
  }

  @override
  Future<String?> read(String id) => _storage.read(key: keyFor(id));

  @override
  Future<void> delete(String id) => _storage.delete(key: keyFor(id));
}

/// In-memory store for tests and previews.
class V2MemoryConnectorStore implements V2ConnectorStore {
  V2MemoryConnectorStore([Iterable<V2ConnectorConnection> initial = const []])
    : _connections = {for (final item in initial) item.id: item};

  final Map<String, V2ConnectorConnection> _connections;

  int get length => _connections.length;

  @override
  Future<List<V2ConnectorConnection>> load() async =>
      _connections.values.toList();

  @override
  Future<V2ConnectorConnection?> find(String id) async => _connections[id];

  @override
  Future<void> save(V2ConnectorConnection connection) async {
    _connections[connection.id] = connection;
  }

  @override
  Future<void> remove(String id) async {
    _connections.remove(id);
  }

  @override
  Future<void> setEnabled(String id, bool enabled) async {
    final current = _connections[id];
    if (current != null) {
      _connections[id] = current.copyWith(enabled: enabled);
    }
  }

  @override
  Future<void> setPermission(
    String id,
    V2ConnectorPermissionKind kind,
    bool granted,
  ) async {
    final current = _connections[id];
    if (current == null) return;
    _connections[id] = switch (kind) {
      V2ConnectorPermissionKind.read => current.copyWith(read: granted),
      V2ConnectorPermissionKind.write => current.copyWith(write: granted),
      V2ConnectorPermissionKind.execute => current.copyWith(execute: granted),
    };
  }

  @override
  Future<void> setToolEnabled(String id, String toolId, bool enabled) async {
    final current = _connections[id];
    if (current == null) return;
    final disabled = {...current.disabledTools};
    if (enabled) {
      disabled.remove(toolId);
    } else {
      disabled.add(toolId);
    }
    _connections[id] = current.copyWith(disabledTools: disabled);
  }

  @override
  Future<void> setAutoSync(String id, bool autoSync) async {
    final current = _connections[id];
    if (current != null) {
      _connections[id] = current.copyWith(autoSync: autoSync);
    }
  }
}

/// In-memory secrets for tests and previews.
class V2MemoryConnectorSecrets implements V2ConnectorSecrets {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> write(String id, String secret) async {
    if (secret.trim().isEmpty) {
      _values.remove(id);
      return;
    }
    _values[id] = secret;
  }

  @override
  Future<String?> read(String id) async => _values[id];

  @override
  Future<void> delete(String id) async {
    _values.remove(id);
  }
}

/// The process-wide stores. Screens take an optional store so tests and the
/// preview can inject an in-memory one; production uses the persisted pair.
V2ConnectorStore v2ConnectorStore = V2PrefsConnectorStore();
V2ConnectorSecrets v2ConnectorSecrets = V2ConnectorSecretVault();

/// Restores the production stores after a test swapped them.
@visibleForTesting
void resetV2ConnectorStoresForTest() {
  v2ConnectorStore = V2PrefsConnectorStore();
  v2ConnectorSecrets = V2ConnectorSecretVault();
}
