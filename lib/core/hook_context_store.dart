import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'plugin_manifest.dart';
import 'plugin_permissions.dart';
import 'secure_store.dart';

/// Durable explicit instruction contributions. Never stores stdout envelopes,
/// stderr, environment, or command text. Free-form instructions can contain
/// secrets, so values use the app's authenticated encrypted store, NOT prefs.
class HookContextStore {
  static const maxContributionChars = 8192;
  static const maxStoredChars = 65536;
  static const maxContributions = 128;
  static const _prefix = 'ovid_hook_context_v1_';

  // Serialize read/modify/write and deletion across service resets and sessions.
  static Future<void> _pending = Future.value();

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String descriptor(
    NormalizedPluginManifest manifest,
    PluginHook hook,
  ) => _hash(
    jsonEncode([
      manifest.id,
      manifest.version,
      pluginManifestDigest(manifest),
      manifest.rootPath,
      _canonical(hook.toJson()),
    ]),
  );

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }

  /// Only an explicit instruction field opts in to durable storage. Plain
  /// stdout and the ambiguous top-level `context` fallback remain ephemeral.
  static String? explicitContext(String stdout) {
    try {
      final json = jsonDecode(stdout);
      if (json is! Map || json['suppressOutput'] == true) return null;
      final nested = json['hookSpecificOutput'];
      final value = nested is Map && nested['additionalContext'] is String
          ? nested['additionalContext']
          : json['additionalContext'] ?? json['additional_context'];
      return value is String ? value.trim() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, String>> _read(String key) async {
    final raw = await ovidSecureStorage().read(key: key);
    if (raw == null || raw.length > maxStoredChars * 6 + 16384) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['schema'] != 1 || json['entries'] is! Map) {
        return {};
      }
      final entries = json['entries'] as Map;
      if (entries.length > maxContributions) return {};
      final out = <String, String>{};
      var size = 0;
      for (final entry in entries.entries) {
        if (entry.key is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String) ||
            entry.value is! String ||
            (entry.value as String).length > maxContributionChars) {
          return {};
        }
        final text = entry.value as String;
        size += text.length;
        if (size > maxStoredChars) return {};
        out[entry.key as String] = text;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(String key, Map<String, String> entries) async {
    if (entries.isEmpty) {
      await ovidSecureStorage().delete(key: key);
    } else {
      await ovidSecureStorage().write(
        key: key,
        value: jsonEncode({'schema': 1, 'entries': entries}),
      );
    }
  }

  /// Reconciles after lifecycle activation or a live context read. Old,
  /// disabled, missing and changed descriptors are removed from disk too.
  Future<Map<String, String>> reconcile(String sessionId, Set<String> valid) =>
      _serialized(() async {
        final key = '$_prefix${_hash(sessionId)}';
        final entries = await _read(key);
        entries.removeWhere((descriptor, _) => !valid.contains(descriptor));
        await _write(key, entries);
        return entries;
      });

  Future<void> put(String sessionId, String descriptor, String? context) =>
      _serialized(() async {
        final key = '$_prefix${_hash(sessionId)}';
        final entries = await _read(key);
        entries.remove(descriptor);
        if (context != null &&
            context.isNotEmpty &&
            context.length <= maxContributionChars &&
            entries.length < maxContributions &&
            entries.values.fold<int>(0, (sum, value) => sum + value.length) +
                    context.length <=
                maxStoredChars) {
          entries[descriptor] = context;
        }
        await _write(key, entries);
      });

  Future<void> deleteSession(String sessionId) => _serialized(
    () => ovidSecureStorage().delete(key: '$_prefix${_hash(sessionId)}'),
  );
}
