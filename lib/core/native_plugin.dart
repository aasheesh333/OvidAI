import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  Future<String> callTool(String toolName, Map<String, dynamic> args);
}

/// Persistent configuration storage for native plugin capabilities.
///
/// Secrets (fields declared with `secret: true`) are stored in
/// [FlutterSecureStorage]; non-sensitive settings are stored in
/// [SharedPreferences]. Keys are namespaced per plugin slug:
/// `native_plugin_<slug>__<field_key>`.
class NativePluginConfigStore {
  NativePluginConfigStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  static final NativePluginConfigStore I = NativePluginConfigStore();

  final FlutterSecureStorage _secure;

  static String _prefsKey(String pluginName, String key) =>
      'native_plugin_${NativePluginRegistry.slugify(pluginName)}__$key';

  static String _secureKey(String pluginName, String key) =>
      'native_plugin_${NativePluginRegistry.slugify(pluginName)}__$key';

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
