/// Plugin capability approval and secure grant persistence
/// (design spec §5.1).
///
/// One consolidated user approval per plugin manifest digest. Grants
/// persist by plugin id + digest in ordinary preferences — they carry
/// only non-secret data (capability names, environment variable NAMES,
/// approval time). Secret VALUES live exclusively in FlutterSecureStorage
/// under owner-scoped keys and never appear in any JSON/preferences blob.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';

/// Preferences key for the persisted grant map (plugin id → grant JSON).
/// Deliberately separate from `ovid_plugin_state_v1` — grants own their
/// lifecycle (Task 7 owns the plugin-state extension).
const String kPluginGrantsPrefKey = 'ovid_plugin_grants_v1';

/// Prefix for plugin-owned secret values in secure storage
/// (`ovid_plugin_secret_<plugin-id>/…` — owner-scoped, spec §5.1).
const String _kPluginSecretPrefix = 'ovid_plugin_secret_';

/// Computes the single canonical manifest digest (spec §5.1 binding
/// ledger: "canonical/sorted-key JSON sha256 digest, defined once"):
/// the manifest's JSON is re-serialized with every map's keys sorted
/// (recursively) and every set-like collection emitted as a sorted list,
/// then hashed with SHA-256 and prefixed `sha256:` (the
/// [PluginPermissionGrant.manifestDigest] wire format).
///
/// LOCATION-INDEPENDENT (fix round 1): `rootPath` — the absolute
/// directory the manifest was inspected from — is EXCLUDED, because the
/// same plugin content is inspected at different locations across its
/// lifecycle (resolver staging → content cache → Task 7's post-rename
/// install directory). The digest binds to plugin CONTENT, not to where
/// it currently lives, so a grant saved before an atomic staging→install
/// rename stays effective afterwards.
String pluginManifestDigest(NormalizedPluginManifest manifest) {
  final json = manifest.toJson()..remove('rootPath');
  return 'sha256:${sha256.convert(utf8.encode(_canonicalJson(json))).toString()}';
}

/// The minimum capability set derived from what a manifest actually
/// declares — the same inspection rules the adapters apply (spec §5.1),
/// rebuilt here from the normalized records so approvals always cover
/// what the manifest requests, even when constructed directly.
Set<PluginCapability> inferRequestedCapabilities(
  NormalizedPluginManifest manifest,
) {
  final caps = <PluginCapability>{};
  if (manifest.commands.isNotEmpty ||
      manifest.skills.isNotEmpty ||
      manifest.agents.isNotEmpty) {
    caps.add(PluginCapability.workspaceRead);
  }
  for (final h in manifest.hooks) {
    caps.add(PluginCapability.hooksObserve);
    if (h.type == 'command') caps.add(PluginCapability.shellExecute);
    if (h.canBlock) caps.add(PluginCapability.hooksBlock);
  }
  for (final s in manifest.mcpServers) {
    caps.add(PluginCapability.mcpRegister);
    if (s.transport == 'stdio') caps.add(PluginCapability.processSpawn);
    if (s.transport == 'http') caps.add(PluginCapability.networkConnect);
  }
  final envNames = <String>{...manifest.environmentReadNames};
  for (final s in manifest.mcpServers) {
    envNames.addAll(s.envNames);
  }
  if (envNames.isNotEmpty) caps.add(PluginCapability.environmentRead);
  return Set.unmodifiable(caps);
}

/// Deterministic JSON: maps sorted by key, lists preserved in order
/// except set-backed fields (`requestedCapabilities`,
/// `environmentReadNames`) which are sorted, so digest(manifest) is
/// stable across rebuilds that assemble the same sets in a different
/// insertion order.
const _kSetBackedJsonKeys = {'requestedCapabilities', 'environmentReadNames'};

String _canonicalJson(Object? node, {String? key}) {
  if (node is Map) {
    final keys = node.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(node[k], key: k)}').join(',')}}';
  }
  if (node is Set) {
    final items = node.toList()
      ..sort((a, b) => a.toString().compareTo(b.toString()));
    return '[${items.map(_canonicalJson).join(',')}]';
  }
  if (node is List) {
    final items = _kSetBackedJsonKeys.contains(key)
        ? ([...node]..sort((a, b) => a.toString().compareTo(b.toString())))
        : node;
    return '[${items.map((e) => _canonicalJson(e)).join(',')}]';
  }
  if (node is DateTime) return jsonEncode(node.toIso8601String());
  return jsonEncode(node);
}

/// One row of the consolidated approval sheet: what a capability means,
/// why it was inferred, and the declaring source path (spec §5.1: "the
/// install sheet shows why each capability was inferred and the files
/// that requested it").
class CapabilityExplanation {
  final PluginCapability capability;

  /// Human explanation of what the capability grants.
  final String reason;

  /// Source-relative path of the declaring file
  /// (e.g. `hooks/hooks.json`, `.mcp.json`, `commands/review.md`).
  final String sourcePath;

  /// For [PluginCapability.environmentRead]: the specific variable names
  /// behind the request (`environment.read:<name>` detail — spec §5.1).
  final List<String> environmentNames;

  const CapabilityExplanation({
    required this.capability,
    required this.reason,
    required this.sourcePath,
    this.environmentNames = const [],
  });
}

/// Rebuilds capability provenance from the normalized manifest's
/// contribution `path` fields, mirroring the adapter-side inference
/// (spec §5.1 — commands/skills/agents → workspaceRead; hooks →
/// hooksObserve, command hooks → shellExecute, blocking hooks →
/// hooksBlock; MCP servers → mcpRegister, stdio → processSpawn, http →
/// networkConnect; env names → environmentRead). The adapters'
/// `_inferCapabilities` stays private and untouched; this is the
/// user-facing explanation surface.
List<CapabilityExplanation> explainCapabilities(
  NormalizedPluginManifest manifest,
) {
  final out = <CapabilityExplanation>[];
  void add(
    PluginCapability cap,
    String reason,
    String path, {
    List<String> environmentNames = const [],
  }) {
    if (out.any((e) => e.capability == cap)) return;
    out.add(
      CapabilityExplanation(
        capability: cap,
        reason: reason,
        sourcePath: path,
        environmentNames: environmentNames,
      ),
    );
  }

  if (manifest.commands.isNotEmpty ||
      manifest.skills.isNotEmpty ||
      manifest.agents.isNotEmpty) {
    add(
      PluginCapability.workspaceRead,
      'Contributes commands, skills, or agents read from the workspace',
      manifest.commands.isNotEmpty
          ? manifest.commands.first.path
          : (manifest.skills.isNotEmpty
                ? manifest.skills.first.path
                : manifest.agents.first.path),
    );
  }
  for (final h in manifest.hooks) {
    add(
      PluginCapability.hooksObserve,
      'Registers lifecycle hooks (${h.event})',
      h.path,
    );
    if (h.type == 'command') {
      add(
        PluginCapability.shellExecute,
        'Runs shell commands from hooks',
        h.path,
      );
    }
    if (h.canBlock) {
      add(
        PluginCapability.hooksBlock,
        'Hooks on ${h.event} can deny actions',
        h.path,
      );
    }
  }
  for (final s in manifest.mcpServers) {
    add(
      PluginCapability.mcpRegister,
      'Registers MCP server "${s.name}"',
      s.path,
    );
    if (s.transport == 'stdio') {
      add(
        PluginCapability.processSpawn,
        'Spawns the "${s.name}" server process',
        s.path,
      );
    }
    if (s.transport == 'http') {
      add(
        PluginCapability.networkConnect,
        'Connects to the "${s.name}" HTTP endpoint',
        s.path,
      );
    }
  }
  if (manifest.environmentReadNames.isNotEmpty ||
      manifest.mcpServers.any((s) => s.envNames.isNotEmpty)) {
    final names = <String>{...manifest.environmentReadNames};
    for (final s in manifest.mcpServers) {
      names.addAll(s.envNames);
    }
    final server = manifest.mcpServers
        .where((s) => s.envNames.isNotEmpty)
        .firstOrNull;
    add(
      PluginCapability.environmentRead,
      'Reads environment variables (values stay in secure storage)',
      server?.path ?? 'config',
      environmentNames: names.toList()..sort(),
    );
  }
  return out;
}

/// The NEW capabilities a manifest requests relative to a stored grant
/// (spec §5.1: "a later update requesting new capabilities pauses
/// activation until the delta is approved"). Null [granted] means
/// everything is new (first approval).
Set<PluginCapability> capabilityDelta({
  PluginPermissionGrant? granted,
  required Set<PluginCapability> requested,
}) {
  if (granted == null) return Set.unmodifiable(requested);
  return Set.unmodifiable(requested.difference(granted.capabilities));
}

/// Persistent plugin permission grants (spec §5.1).
///
/// Grants are NON-SECRET and live in SharedPreferences keyed by plugin
/// id; each record stores the approved manifest digest, so lookups are
/// (plugin id + digest). Secret VALUES never pass through this store —
/// they live in secure storage under `_kPluginSecretPrefix` keys and
/// [revoke] deletes exactly the revoked plugin's owned secrets.
class PluginPermissionStore {
  static const _secureStorage = FlutterSecureStorage();

  /// Loads the grant for (plugin id, digest) — null when this exact
  /// manifest version was never approved.
  Future<PluginPermissionGrant?> load(String pluginId, String digest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPluginGrantsPrefKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final entry = decoded[pluginId];
      if (entry is! String) return null;
      final grant = PluginPermissionGrant.fromJson(
        jsonDecode(entry) as Map<String, dynamic>,
      );
      // A stored record for a DIFFERENT digest is not a grant for this
      // manifest version — the update must pause for delta approval.
      if (grant.manifestDigest != digest) return null;
      return grant;
    } catch (_) {
      // Corrupted storage must never crash the app or fake an approval.
      return null;
    }
  }

  /// The grant effective for [manifest] right now: the stored record for
  /// this plugin if and only if its digest matches (unchanged manifest →
  /// stored grant reused; changed manifest → re-approval required).
  Future<PluginPermissionGrant?> effectiveGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) => load(pluginId, pluginManifestDigest(manifest));

  /// Runtime activation requires a complete approval, not merely a stored
  /// row for the current digest. Raw [load] remains intentionally permissive
  /// so approval UIs can inspect partial grants.
  Future<PluginPermissionGrant?> effectiveRuntimeGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    if (pluginId != manifest.id) return null;
    final grant = await load(pluginId, pluginManifestDigest(manifest));
    if (grant == null || grant.pluginId != pluginId) return null;
    final requested = manifest.requestedCapabilities.isNotEmpty
        ? manifest.requestedCapabilities
        : inferRequestedCapabilities(manifest);
    if (!grant.capabilities.containsAll(requested)) return null;
    final environmentNames = <String>{...manifest.environmentReadNames};
    for (final server in manifest.mcpServers) {
      environmentNames.addAll(server.envNames);
    }
    if (!grant.environmentReadNames.containsAll(environmentNames)) return null;
    return grant;
  }

  /// Persists [grant] (replacing any previous record for its plugin id).
  Future<void> save(PluginPermissionGrant grant) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMap(prefs);
      map[grant.pluginId] = jsonEncode(grant.toJson());
      await prefs.setString(kPluginGrantsPrefKey, jsonEncode(map));
    } catch (_) {}
  }

  /// Removes the plugin's grant AND every plugin-owned secret from
  /// secure storage (`ovid_plugin_secret_<plugin-id>/…`). Revocation
  /// immediately disables affected contributions (spec §5.1) — the
  /// runtime reacts to the missing grant; sibling plugins' secrets are
  /// untouched.
  Future<void> revoke(String pluginId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = _readMap(prefs);
      map.remove(pluginId);
      await prefs.setString(kPluginGrantsPrefKey, jsonEncode(map));
    } catch (_) {}
    try {
      final owned = await _secureStorage.readAll();
      final prefix = '$_kPluginSecretPrefix$pluginId/';
      for (final key in owned.keys) {
        if (key.startsWith(prefix)) {
          await _secureStorage.delete(key: key);
        }
      }
    } catch (_) {}
  }

  /// Reads the raw persisted grant map; corrupted JSON yields an empty
  /// map (the honest "nothing approved" state).
  Map<String, String> _readMap(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(kPluginGrantsPrefKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    } catch (_) {
      return {};
    }
  }
}
