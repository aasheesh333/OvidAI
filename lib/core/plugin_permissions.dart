/// Plugin capability approval and secure grant persistence
/// (design spec §5.1).
///
/// One consolidated user approval per plugin manifest digest. Grants
/// persist by plugin id + digest in ordinary preferences — they carry
/// only non-secret data (capability names, environment variable NAMES,
/// approval time). Secret VALUES live exclusively in FlutterSecureStorage
/// under owner-scoped keys and never appear in any JSON/preferences blob.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';
import 'secure_store.dart';
import 'diag.dart';

/// Preferences key for the persisted grant map (plugin id → grant JSON).
/// Deliberately separate from `ovid_plugin_state_v1` — grants own their
/// lifecycle (Task 7 owns the plugin-state extension).
const String kPluginGrantsPrefKey = 'ovid_plugin_grants_v1';

/// Prefix for plugin-owned secret values in secure storage
/// (`ovid_plugin_secret_<plugin-id>/…` — owner-scoped, spec §5.1).
const String _kPluginSecretPrefix = 'ovid_plugin_secret_';

/// Digest schema version, folded into the hashed projection. Bump ONLY when
/// the projection itself changes shape — and when you do, keep the previous
/// algorithm reachable as a legacy alias in
/// [PluginPermissionStore.migrateLegacyGrant] so existing approvals carry
/// forward instead of silently invalidating every installed plugin.
const int kManifestDigestSchemaVersion = 2;

/// Manifest JSON keys excluded from the digest projection. Both are
/// NON-ENFORCING and parser-version volatile:
///
///  - `unknownFields`: unrecognized SOURCE fields preserved verbatim, and
///    carried at every nesting level (commands/skills/agents/hooks/
///    mcpServers each keep their own). Nothing interprets them by
///    definition, so they cannot change what a grant permits — but any
///    adapter or normalization tweak reshuffles them.
///  - `compatibility`: advisory findings emitted by the current parser
///    (`hasRequiredIssues` gates inspection separately).
///
/// Hashing either meant an app update that touched normalization re-digested
/// EVERY installed plugin. Because grants are keyed by digest
/// ([PluginPermissionStore.load]), the miss cascaded: plugin disabled with
/// `migrationRequired` → owned MCP servers failed with "Owning plugin is not
/// active" → hooks skipped → tool roster emptied. One representation change
/// silently switched off four subsystems at once.
const Set<String> _kDigestExcludedKeys = {'unknownFields', 'compatibility'};

/// Recursively drops [_kDigestExcludedKeys] from every map in [node].
Object? _digestProjection(Object? node) {
  if (node is Map) {
    return <String, dynamic>{
      for (final e in node.entries)
        if (!_kDigestExcludedKeys.contains(e.key.toString()))
          e.key.toString(): _digestProjection(e.value),
    };
  }
  if (node is List) return node.map(_digestProjection).toList();
  return node;
}

/// Computes the single canonical manifest digest (spec §5.1 binding
/// ledger: "canonical/sorted-key JSON sha256 digest, defined once"):
/// the manifest's JSON is reduced to its ENFORCING projection
/// ([_digestProjection] drops the non-enforcing, parser-volatile
/// `unknownFields`/`compatibility` buckets), stamped with
/// [kManifestDigestSchemaVersion], re-serialized with every map's keys
/// sorted (recursively) and every set-like collection emitted as a sorted
/// list, then hashed with SHA-256 and prefixed `sha256:` (the
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
  final json =
      _digestProjection(manifest.toJson()..remove('rootPath'))!
          as Map<String, dynamic>;
  json['digestSchemaVersion'] = kManifestDigestSchemaVersion;
  return 'sha256:${sha256.convert(utf8.encode(_canonicalJson(json))).toString()}';
}

/// The v1 digest algorithm: the FULL manifest JSON minus `rootPath`, with no
/// schema version and no key exclusions. Retained solely as the migration key
/// for [PluginPermissionStore.migrateLegacyGrant] — it identifies "this exact
/// content was approved under the old scheme". Never use it for a new grant.
String legacyPluginManifestDigest(NormalizedPluginManifest manifest) {
  final json = manifest.toJson()..remove('rootPath');
  return 'sha256:${sha256.convert(utf8.encode(_canonicalJson(json))).toString()}';
}

/// The minimum capability set derived from what a manifest actually
/// declares — the same inspection rules the adapters apply (spec §5.1),
/// rebuilt here from the normalized records so approvals always cover
/// what the manifest requests, even when constructed directly.
///
/// Explicitly declared [NormalizedPluginManifest.requestedCapabilities]
/// are always retained. The source plugin formats carry no capability
/// declaration field, so [PluginCapability.workspaceWrite],
/// [PluginCapability.sessionRead], [PluginCapability.sessionWrite], and
/// [PluginCapability.deviceControl] are ONLY ever requested this way: the
/// contribution shape (hooks, MCP declarations) cannot reliably imply a
/// server's tool surface, session access, or device control, so inferring
/// them would over-grant — and would change adapter manifest digests and
/// the grant gate's required set, invalidating existing approvals.
Set<PluginCapability> inferRequestedCapabilities(
  NormalizedPluginManifest manifest,
) {
  final caps = <PluginCapability>{...manifest.requestedCapabilities};
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
      'Registers lifecycle hooks (${h.event}) — sees tool names and redacted '
      'payloads (secrets are stripped before a hook runs)',
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
  static final _secureStorage = ovidSecureStorage();

  /// Serializes every grant write (process-wide, because callers create
  /// short-lived store instances) so concurrent approvals/revokes cannot
  /// interleave their read-modify-write and clobber each other. The lock is
  /// null while idle, so no cross-operation future is retained.
  static Future<void>? _writeLock;

  // Shared across short-lived stores, tied to the preferences instance so a
  // fresh preferences lifecycle hydrates once. Neither Dart's optimistic cache
  // nor Android getAll() proves a commit: Android mutates memory before disk.
  static final _confirmed = Expando<Map<String, String>>();
  static final _revoked = Expando<Map<String, Object>>();

  Map<String, Object> _tombstones(SharedPreferences prefs) =>
      _revoked[prefs] ??= {};

  Map<String, String> _confirmedMap(SharedPreferences prefs) {
    final map = _confirmed[prefs] ??= _readMap(prefs);
    map.removeWhere((id, _) => _tombstones(prefs).containsKey(id));
    return map;
  }

  Future<void> _commitMap(
    SharedPreferences prefs,
    Map<String, String> next,
  ) async {
    final previous = _confirmedMap(prefs);
    try {
      if (!await prefs.setString(kPluginGrantsPrefKey, jsonEncode(next))) {
        throw StateError('Could not persist plugin permission grant');
      }
      _confirmed[prefs] = next;
    } catch (_) {
      // Restore both caches even if disk is still failing. Never promote the
      // attempted snapshot based on reload, or merge it into a later write.
      // The confirmed snapshot remains authoritative if restoration also fails.
      try {
        await prefs.setString(kPluginGrantsPrefKey, jsonEncode(previous));
      } catch (error) {
        Diag.swallow('plugin_permissions.restore', error);
      }
      rethrow;
    }
  }

  static Future<void> _withWriteLock(Future<void> Function() action) async {
    while (_writeLock != null) {
      await _writeLock;
    }
    final completer = Completer<void>();
    _writeLock = completer.future;
    try {
      await action();
    } finally {
      _writeLock = null;
      completer.complete();
    }
  }

  /// Loads the grant for (plugin id, digest) — null when this exact
  /// manifest version was never approved.
  Future<PluginPermissionGrant?> load(String pluginId, String digest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entry = _confirmedMap(prefs)[pluginId];
      if (entry == null) return null;
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

  /// The stored record for [pluginId] REGARDLESS of digest. Used by
  /// [migrateLegacyGrant] and by callers that must tell "never approved"
  /// apart from "approved an older revision of this plugin" — a distinction
  /// the digest-keyed [load] deliberately collapses to null.
  Future<PluginPermissionGrant?> loadAny(String pluginId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entry = _confirmedMap(prefs)[pluginId];
      if (entry == null) return null;
      return PluginPermissionGrant.fromJson(
        jsonDecode(entry) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// One-time re-key of a v1 grant onto the current digest scheme.
  ///
  /// Fires ONLY when every one of these holds:
  ///  1. no grant exists for [manifest]'s current digest yet;
  ///  2. the stored record's digest equals [legacyPluginManifestDigest] of
  ///     THIS manifest — i.e. byte-identical content that was approved under
  ///     the old algorithm;
  ///  3. the stored approval still covers everything the manifest requests
  ///     (capabilities AND environment variable names).
  ///
  /// Condition 2 is what keeps this safe: a manifest whose content actually
  /// changed produces a different v1 digest too, so it still stops and
  /// demands re-approval. This carries identical plugin CONTENT across a
  /// digest-REPRESENTATION change; it can never widen a grant. Without it,
  /// bumping [kManifestDigestSchemaVersion] (or any normalization tweak
  /// under the old scheme) silently disabled every installed plugin and,
  /// through `_ownerActive`/hook gating, its MCP servers, hooks and tool
  /// roster with it.
  ///
  /// Returns the effective grant (existing, migrated, or null).
  Future<PluginPermissionGrant?> migrateLegacyGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    final current = pluginManifestDigest(manifest);
    final existing = await load(pluginId, current);
    if (existing != null) return existing;

    final stored = await loadAny(pluginId);
    if (stored == null || stored.pluginId != pluginId) return null;
    if (stored.manifestDigest != legacyPluginManifestDigest(manifest)) {
      return null;
    }

    final requested = manifest.requestedCapabilities.isNotEmpty
        ? manifest.requestedCapabilities
        : inferRequestedCapabilities(manifest);
    if (!stored.capabilities.containsAll(requested)) return null;
    final environmentNames = <String>{...manifest.environmentReadNames};
    for (final server in manifest.mcpServers) {
      environmentNames.addAll(server.envNames);
    }
    if (!stored.environmentReadNames.containsAll(environmentNames)) return null;

    final migrated = PluginPermissionGrant(
      pluginId: stored.pluginId,
      manifestDigest: current,
      capabilities: stored.capabilities,
      environmentReadNames: stored.environmentReadNames,
      // Preserve the original approval time — a re-key is not a re-approval,
      // and stamping now would misreport how long this grant has been live.
      approvedAt: stored.approvedAt,
    );
    await save(migrated);
    return migrated;
  }

  /// The grant effective for [manifest] right now: the stored record for
  /// this plugin if and only if its digest matches (unchanged manifest →
  /// stored grant reused; changed manifest → re-approval required), after
  /// any pending v1 re-key.
  Future<PluginPermissionGrant?> effectiveGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) => migrateLegacyGrant(pluginId: pluginId, manifest: manifest);

  /// Runtime activation requires a complete approval, not merely a stored
  /// row for the current digest. Raw [load] remains intentionally permissive
  /// so approval UIs can inspect partial grants.
  Future<PluginPermissionGrant?> effectiveRuntimeGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    if (pluginId != manifest.id) return null;
    final grant = await migrateLegacyGrant(
      pluginId: pluginId,
      manifest: manifest,
    );
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
    final prefs = await SharedPreferences.getInstance();
    final revokedAtStart = _tombstones(prefs)[grant.pluginId];
    return _withWriteLock(() async {
      final map = Map<String, String>.of(_confirmedMap(prefs));
      map[grant.pluginId] = jsonEncode(grant.toJson());
      await _commitMap(prefs, map);
      // Only an explicit approval begun after the revoke may lift its denial.
      if (identical(_tombstones(prefs)[grant.pluginId], revokedAtStart)) {
        _tombstones(prefs).remove(grant.pluginId);
      }
    });
  }

  /// Removes the plugin's grant AND every plugin-owned secret from
  /// secure storage (`ovid_plugin_secret_<plugin-id>/…`). Revocation
  /// immediately disables affected contributions (spec §5.1) — the
  /// runtime reacts to the missing grant; sibling plugins' secrets are
  /// untouched.
  Future<void> revoke(String pluginId) async {
    final prefs = await SharedPreferences.getInstance();
    _tombstones(prefs)[pluginId] = Object();
    _confirmedMap(prefs); // deny before waiting for any pending write
    return _withWriteLock(() async {
      Object? persistenceError;
      StackTrace? persistenceStack;
      try {
        final map = Map<String, String>.of(_confirmedMap(prefs));
        map.remove(pluginId);
        await _commitMap(prefs, map);
      } catch (error, stack) {
        persistenceError = error;
        persistenceStack = stack;
      }
      try {
        final owned = await _secureStorage.readAll();
        final prefix = '$_kPluginSecretPrefix$pluginId/';
        for (final key in owned.keys.toList()) {
          if (key.startsWith(prefix)) {
            await _secureStorage.delete(key: key);
          }
        }
      } catch (e) {
        Diag.swallow('plugin_permissions', e);
      }
      if (persistenceError != null) {
        Error.throwWithStackTrace(persistenceError, persistenceStack!);
      }
    });
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
