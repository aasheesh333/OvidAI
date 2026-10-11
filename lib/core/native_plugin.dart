import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'native_plugins/utility_limits.dart';
import 'plugin_manifest.dart' show isCanonicalPluginId;
import 'secure_store.dart';

/// A single tool exposed by a native plugin capability.
class NativePluginTool {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const NativePluginTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

/// A single configuration field declared by a native plugin capability.
/// Fields marked [secret] persist in [FlutterSecureStorage]; all others
/// persist in [SharedPreferences].
class NativePluginConfigField {
  final String key;
  final String label;
  final bool secret;
  final String? hint;

  const NativePluginConfigField({
    required this.key,
    required this.label,
    this.secret = false,
    this.hint,
  });
}

/// In-process capability for a catalog plugin: declares tool schemas and
/// configuration fields, persists configuration, and executes tools
/// directly in Dart without external repos, sandboxes, or runtimes.
abstract class NativePluginCapability {
  String get pluginName;
  List<NativePluginConfigField> get configFields;
  List<NativePluginTool> get tools;
  Future<void> configure(Map<String, String> values);
  Future<String> callTool(
    String toolName,
    Map<String, dynamic> args, {
    UtilityCancellation? cancellation,
  });
}

/// Persistent configuration storage for native plugin capabilities and
/// installed plugins' declared settings.
///
/// Secrets (fields declared with `secret: true`) are stored in
/// [FlutterSecureStorage]; non-sensitive settings are stored in
/// [SharedPreferences].
///
/// Two key namespaces that can never collide (F-108):
///  * native capabilities (display names such as `Native JSON`):
///    `native_plugin_<slug>__<field_key>`;
///  * installed plugins (canonical `publisher/name` runtime ids):
///    `plugin_cfg_<base64url(runtimeId)>__<field_key>`. The encoding is
///    injective, so `acme/foo-bar` and `acme-foo/bar` — which slugify
///    alike — get different keys, and no plugin can pre-fill (or later
///    read) another plugin's or a native capability's secret.
class NativePluginConfigStore {
  NativePluginConfigStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? ovidSecureStorage();

  static final NativePluginConfigStore I = NativePluginConfigStore();

  final FlutterSecureStorage _secure;

  /// Prefix of every installed-plugin settings key.
  static const String installedPluginKeyPrefix = 'plugin_cfg_';

  /// True when [pluginName] names an installed plugin (a canonical
  /// `publisher/name` runtime id) rather than a native capability.
  static bool isInstalledPluginName(String pluginName) =>
      isCanonicalPluginId(pluginName);

  /// Collision-free namespace of an installed plugin's settings.
  static String installedPluginNamespace(String runtimeId) =>
      '$installedPluginKeyPrefix'
      '${base64Url.encode(utf8.encode(runtimeId)).replaceAll('=', '')}__';

  /// The pre-F-108 slug namespace, kept only for the one-time migration.
  static String _legacyNamespace(String pluginName) =>
      'native_plugin_${NativePluginRegistry.slugify(pluginName)}__';

  static String _namespace(String pluginName) =>
      isInstalledPluginName(pluginName)
      ? installedPluginNamespace(pluginName)
      : _legacyNamespace(pluginName);

  /// The storage key of [key] for [pluginName] (same in prefs and secure
  /// storage).
  static String storageKeyFor(String pluginName, String key) =>
      '${_namespace(pluginName)}$key';

  static String _prefsKey(String pluginName, String key) =>
      storageKeyFor(pluginName, key);

  static String _secureKey(String pluginName, String key) =>
      storageKeyFor(pluginName, key);

  /// Persists [values], routing each entry to secure storage or prefs
  /// based on the matching [fields] declaration. Unknown keys throw
  /// [ArgumentError] and persist nothing (validated before any write).
  Future<void> save({
    required String pluginName,
    required List<NativePluginConfigField> fields,
    required Map<String, String> values,
  }) async {
    final byKey = {for (final f in fields) f.key: f};
    for (final key in values.keys) {
      if (!byKey.containsKey(key)) {
        throw ArgumentError(
          'Unknown configuration key "$key" for plugin "$pluginName".',
        );
      }
    }
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      if (byKey[entry.key]!.secret) {
        await _secure.write(
          key: _secureKey(pluginName, entry.key),
          value: entry.value,
        );
      } else {
        await prefs.setString(_prefsKey(pluginName, entry.key), entry.value);
      }
    }
  }

  /// Reads a single configuration value. When [secret] is true the value
  /// is read from secure storage, otherwise from prefs.
  Future<String?> read({
    required String pluginName,
    required String key,
    bool secret = false,
  }) async {
    if (secret) {
      return _secure.read(key: _secureKey(pluginName, key));
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey(pluginName, key));
  }

  /// Reads every value in [fields] for [pluginName].
  Future<Map<String, String>> readAll({
    required String pluginName,
    required List<NativePluginConfigField> fields,
  }) async {
    final out = <String, String>{};
    for (final field in fields) {
      final value = await read(
        pluginName: pluginName,
        key: field.key,
        secret: field.secret,
      );
      if (value != null) out[field.key] = value;
    }
    return out;
  }

  /// One-time move of an installed plugin's settings out of the old slug
  /// namespace (`native_plugin_<slug>__`) into its own (F-108).
  ///
  /// The old namespace is ambiguous by construction, so a value moves ONLY
  /// when exactly one known plugin could own it: no other id in
  /// [installedPluginIds] and no registered native capability slugifies to
  /// the same name. Otherwise it is left for the user to re-enter — handing
  /// it to the wrong plugin is the very leak this fixes. Values already in
  /// the new namespace win. Returns the number of keys moved.
  Future<int> migrateLegacyInstalledSettings({
    required String pluginName,
    required List<NativePluginConfigField> fields,
    required Iterable<String> installedPluginIds,
  }) async {
    if (!isInstalledPluginName(pluginName) || fields.isEmpty) return 0;
    final slug = NativePluginRegistry.slugify(pluginName);
    final contested =
        installedPluginIds.any(
          (id) => id != pluginName && NativePluginRegistry.slugify(id) == slug,
        ) ||
        NativePluginRegistry.I.capabilityForSlug(slug) != null;
    if (contested) return 0;
    final legacy = _legacyNamespace(pluginName);
    final prefs = await SharedPreferences.getInstance();
    var moved = 0;
    for (final field in fields) {
      final oldKey = '$legacy${field.key}';
      final newKey = storageKeyFor(pluginName, field.key);
      if (field.secret) {
        final value = await _secure.read(key: oldKey);
        if (value == null) continue;
        if (await _secure.read(key: newKey) == null) {
          await _secure.write(key: newKey, value: value);
          moved++;
        }
        await _secure.delete(key: oldKey);
      } else {
        final value = prefs.getString(oldKey);
        if (value == null) continue;
        if (prefs.getString(newKey) == null) {
          await prefs.setString(newKey, value);
          moved++;
        }
        await prefs.remove(oldKey);
      }
    }
    return moved;
  }

  /// Deletes EVERY saved setting of the installed plugin [runtimeId] —
  /// secrets and plain values, whatever fields the manifest declares now
  /// (the namespace is the plugin's own, so a prefix sweep is exact). Also
  /// clears [legacyFields] from the old slug namespace unless a native
  /// capability shares that slug. Used by uninstall (F-107).
  Future<void> clearInstalledPlugin(
    String runtimeId, {
    List<NativePluginConfigField> legacyFields = const [],
  }) async {
    if (!isInstalledPluginName(runtimeId)) return;
    final namespace = installedPluginNamespace(runtimeId);
    final secure = await _secure.readAll();
    for (final key in secure.keys.toList()) {
      if (key.startsWith(namespace)) await _secure.delete(key: key);
    }
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(namespace)) await prefs.remove(key);
    }
    final slug = NativePluginRegistry.slugify(runtimeId);
    if (legacyFields.isEmpty ||
        NativePluginRegistry.I.capabilityForSlug(slug) != null) {
      return;
    }
    final legacy = _legacyNamespace(runtimeId);
    for (final field in legacyFields) {
      if (field.secret) {
        await _secure.delete(key: '$legacy${field.key}');
      } else {
        await prefs.remove('$legacy${field.key}');
      }
    }
  }

  /// Clears every value in [fields] for [pluginName].
  Future<void> clear({
    required String pluginName,
    required List<NativePluginConfigField> fields,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    for (final field in fields) {
      if (field.secret) {
        await _secure.delete(key: _secureKey(pluginName, field.key));
      } else {
        await prefs.remove(_prefsKey(pluginName, field.key));
      }
    }
  }
}

/// Process-wide registry of native plugin capabilities.
class NativePluginRegistry {
  NativePluginRegistry._();

  static final NativePluginRegistry I = NativePluginRegistry._();

  final Map<String, NativePluginCapability> _byNormalizedName = {};

  static String _normalizeName(String pluginName) =>
      pluginName.trim().toLowerCase();

  /// Converts a plugin display name to a snake_case identifier for tool
  /// naming (e.g. `JSON Visualizer` -> `json_visualizer`).
  static String slugify(String pluginName) {
    final slug = pluginName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return slug;
  }

  /// Instance alias for [slugify] (brief contract).
  String slugFor(String pluginName) => slugify(pluginName);

  void register(NativePluginCapability capability) {
    _byNormalizedName[_normalizeName(capability.pluginName)] = capability;
  }

  /// True when a capability is registered for [pluginName]
  /// (case-insensitive comparison).
  bool has(String pluginName) =>
      _byNormalizedName.containsKey(_normalizeName(pluginName));

  /// Returns the capability for [pluginName] (case-insensitive), if any.
  NativePluginCapability? capabilityFor(String pluginName) =>
      _byNormalizedName[_normalizeName(pluginName)];

  /// Returns the capability whose slug matches [slug], if any.
  NativePluginCapability? capabilityForSlug(String slug) {
    final want = slug.trim().toLowerCase();
    for (final capability in _byNormalizedName.values) {
      if (slugify(capability.pluginName) == want) return capability;
    }
    return null;
  }

  List<NativePluginCapability> get all =>
      List.unmodifiable(_byNormalizedName.values);

  void clearForTest() => _byNormalizedName.clear();
}
