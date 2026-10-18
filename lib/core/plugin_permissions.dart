/// Plugin capability approval and secure grant persistence
/// (design spec §5.1).
///
/// One consolidated user approval per plugin manifest digest + content-tree
/// hash. Grants carry only non-secret data (capability names, environment
/// variable NAMES, approval time) but they AUTHORIZE execution, so they
/// persist in hardened secure storage, not ordinary preferences (H1).
/// Secret VALUES live in FlutterSecureStorage under owner-scoped keys and
/// never appear in any grant JSON.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_manifest.dart';
import 'secure_store.dart';
import 'diag.dart';

/// LEGACY preferences key for the grant map (plugin id → grant JSON). Read
/// once by the H1 migration into [kPluginGrantsSecureKey], then deleted.
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

/// Plain-language title for [cap] — what users see instead of the enum
/// name on consent and status surfaces.
String pluginCapabilityTitle(PluginCapability cap) => switch (cap) {
  PluginCapability.workspaceRead => 'Read workspace files',
  PluginCapability.workspaceWrite => 'Change workspace files',
  PluginCapability.shellExecute => 'Run shell commands',
  PluginCapability.networkConnect => 'Connect to the internet',
  PluginCapability.processSpawn => 'Start background processes',
  PluginCapability.environmentRead => 'Read saved credentials',
  PluginCapability.mcpRegister => 'Add MCP servers',
  PluginCapability.hooksObserve => 'Watch agent activity',
  PluginCapability.hooksBlock => 'Block or change agent actions',
  PluginCapability.sessionRead => 'Read this chat',
  PluginCapability.sessionWrite => 'Write to this chat',
  PluginCapability.deviceControl => 'Control this device',
};

/// Capabilities the user may decline on the approval sheet while still
/// installing the rest of the plugin (F-106). Each one gates a contribution
/// kind the runtime can skip independently — hooks (all, shell-running,
/// blocking), MCP servers (all, process-spawning, network) — or is not
/// exercised by any runtime path at all (`deviceControl`, which is only
/// ever DECLARED). Everything else (reading the plugin's own commands and
/// skills, the env names its servers need) is the plugin itself: declining
/// it would leave nothing to install, so it stays all-or-nothing.
const Set<PluginCapability> kDeclinablePluginCapabilities = {
  PluginCapability.hooksObserve,
  PluginCapability.hooksBlock,
  PluginCapability.shellExecute,
  PluginCapability.mcpRegister,
  PluginCapability.processSpawn,
  PluginCapability.networkConnect,
  PluginCapability.deviceControl,
};

/// The capabilities [hook] needs to run — mirrors [inferRequestedCapabilities].
Set<PluginCapability> capabilitiesForHook(PluginHook hook) => {
  PluginCapability.hooksObserve,
  if (hook.type == 'command') PluginCapability.shellExecute,
  if (hook.canBlock) PluginCapability.hooksBlock,
};

/// The capabilities [server] needs to mount — mirrors
/// [inferRequestedCapabilities].
Set<PluginCapability> capabilitiesForMcpServer(PluginMcpServer server) => {
  PluginCapability.mcpRegister,
  if (server.transport == 'stdio') PluginCapability.processSpawn,
  if (server.transport == 'http') PluginCapability.networkConnect,
};

/// The first declined capability that keeps a contribution needing
/// [required] from running, or null when nothing it needs was declined.
PluginCapability? firstDeclinedCapability(
  Set<PluginCapability> required,
  Set<PluginCapability> declined,
) {
  for (final c in PluginCapability.values) {
    if (required.contains(c) && declined.contains(c)) return c;
  }
  return null;
}

/// True when [grant] decides on every capability in [requested]: each one
/// is either granted or declined — and only [kDeclinablePluginCapabilities]
/// can be declined. A declined non-declinable capability (a tampered or
/// future-format record) does NOT count, so the grant fails closed.
bool grantCoversRequested(
  PluginPermissionGrant grant,
  Set<PluginCapability> requested,
) {
  for (final c in requested) {
    if (grant.capabilities.contains(c)) continue;
    if (grant.declinedCapabilities.contains(c) &&
        kDeclinablePluginCapabilities.contains(c)) {
      continue;
    }
    return false;
  }
  return true;
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

/// Root-level files the runtime itself writes into a plugin's committed
/// content directory (`kPluginRuntimeManifestFile` /
/// `kPluginRuntimeActivationFile` in the runtime). They are
/// app-authored bookkeeping, not plugin content, so they are excluded from
/// [pluginContentTreeHash] — otherwise staging (approved) and the installed
/// directory (verified) could never hash alike.
const Set<String> kPluginContentTreeIgnoredRootFiles = {
  'ovid-plugin.json',
  'ovid-activation.json',
};

/// Version tag folded into [pluginContentTreeHash]. Bump only together with
/// a migration that re-adopts existing hashes.
const String _kContentTreeHashVersion = 'ovid-plugin-tree-v1';

/// SHA-256 over the plugin's FULL content tree rooted at [rootPath] (H2).
///
/// Every regular file contributes its root-relative path and the SHA-256 of
/// its bytes; directories and symlinks (never followed) contribute their
/// path and, for links, the link target. Entries are sorted by relative
/// path, so the hash is location-independent (staging → installed rename)
/// and order-independent. [kPluginContentTreeIgnoredRootFiles] are skipped.
/// A missing or empty [rootPath] hashes as the empty tree. Unreadable files
/// throw — callers treat that as "content does not match" (fail closed).
String pluginContentTreeHash(String rootPath) {
  final lines = <String>[];
  if (rootPath.isNotEmpty) {
    final root = Directory(rootPath);
    if (root.existsSync()) {
      var base = root.absolute.path.replaceAll('\\', '/');
      while (base.length > 1 && base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      for (final e in root.absolute.listSync(
        recursive: true,
        followLinks: false,
      )) {
        final full = e.path.replaceAll('\\', '/');
        if (!full.startsWith('$base/')) continue;
        final rel = full.substring(base.length + 1);
        if (kPluginContentTreeIgnoredRootFiles.contains(rel)) continue;
        final String entry;
        if (e is Link) {
          entry = 'l:${e.targetSync()}';
        } else if (e is File) {
          entry = 'f:${sha256.convert(e.readAsBytesSync())}';
        } else {
          entry = 'd';
        }
        lines.add('${jsonEncode(rel)}\t$entry');
      }
    }
  }
  lines.sort();
  final body = '$_kContentTreeHashVersion\n${lines.join('\n')}';
  return 'sha256:${sha256.convert(utf8.encode(body))}';
}

/// Secure-storage key holding the grant map (plugin id → grant JSON) — H1.
/// Grants moved out of SharedPreferences: a world-readable-on-root,
/// backup-restorable preferences file must not be able to mint consent.
const String kPluginGrantsSecureKey = 'ovid_plugin_grants_v2';

/// Persistent plugin permission grants (spec §5.1).
///
/// Grants are non-secret but SECURITY-RELEVANT (they authorize execution),
/// so they live in hardened secure storage under [kPluginGrantsSecureKey]
/// (H1), keyed by plugin id; each record stores the approved manifest digest
/// and content-tree hash, so lookups are (plugin id + digest + content).
/// Pre-H1 installs kept them in SharedPreferences under
/// [kPluginGrantsPrefKey]; the first hydration copies them over, verifies the
/// copy by reading it back, and only then deletes the preferences copy —
/// so a grant is never lost, and the migration is idempotent across crashes.
/// Secret VALUES never pass through this store — they live in secure storage
/// under `_kPluginSecretPrefix` keys and [revoke] deletes exactly the revoked
/// plugin's owned secrets.
class PluginPermissionStore {
  static FlutterSecureStorage _secureStorage = ovidSecureStorage();

  /// Swaps the secure-storage backend (null restores the real one) so tests
  /// can inject read/write failures.
  @visibleForTesting
  static set secureStorageForTest(FlutterSecureStorage? storage) =>
      _secureStorage = storage ?? ovidSecureStorage();

  /// Serializes every grant write (process-wide, because callers create
  /// short-lived store instances) so concurrent approvals/revokes cannot
  /// interleave their read-modify-write and clobber each other. The lock is
  /// null while idle, so no cross-operation future is retained.
  static Future<void>? _writeLock;

  // Shared across short-lived stores, tied to the preferences instance so a
  // fresh preferences lifecycle hydrates (and migrates) once. The confirmed
  // snapshot only ever holds what was hydrated or a write actually
  // committed.
  static var _hydration = Expando<Future<Map<String, String>>>();
  static var _confirmed = Expando<Map<String, String>>();
  static var _revoked = Expando<Map<String, Object>>();

  /// Drops every in-process grant cache (after "delete all data" wiped
  /// secure storage) so the next read hydrates from storage again.
  static void forgetCachedGrants() {
    _hydration = Expando();
    _confirmed = Expando();
    _revoked = Expando();
    _declinedByPlugin.clear();
  }

  Map<String, Object> _tombstones(SharedPreferences prefs) =>
      _revoked[prefs] ??= {};

  Future<Map<String, String>> _confirmedMap(SharedPreferences prefs) async {
    var map = _confirmed[prefs];
    if (map == null) {
      // Only the IN-FLIGHT hydration is shared; once done, the result lives
      // in [_confirmed]. A completed future must not be retained and
      // re-awaited: its listeners run in the zone that created it (e.g. a
      // widget test's fake-async zone), which may never be pumped again.
      final pending = _hydration[prefs] ??= _hydrate(prefs);
      final hydrated = await pending;
      if (identical(_hydration[prefs], pending)) _hydration[prefs] = null;
      map = _confirmed[prefs] ??= hydrated;
    }
    map.removeWhere((id, _) => _tombstones(prefs).containsKey(id));
    return map;
  }

  /// Loads the grant map from secure storage, running the one-time
  /// preferences → secure-storage migration (H1) when needed.
  Future<Map<String, String>> _hydrate(SharedPreferences prefs) async {
    String? raw;
    try {
      raw = await _secureStorage.read(key: kPluginGrantsSecureKey);
    } catch (error) {
      // Secure storage is unreadable right now. Keep honoring the grants
      // that still sit in preferences (never lose one); writes go to secure
      // storage and fail loudly, and the preferences copy stays put.
      Diag.swallow('plugin_permissions.secure_read', error);
      return _legacyGrants(prefs);
    }
    final secure = raw == null ? null : _decodeMap(raw);
    if (secure != null) {
      // Migration already verified on an earlier run (or nothing to
      // migrate): secure storage is authoritative; finish any leftover
      // preferences cleanup.
      await _dropLegacy(prefs);
      return secure;
    }
    final legacy = _legacyGrants(prefs);
    if (legacy.isEmpty) {
      await _dropLegacy(prefs);
      return {};
    }
    final encoded = jsonEncode(legacy);
    try {
      await _secureStorage.write(key: kPluginGrantsSecureKey, value: encoded);
      final readBack = await _secureStorage.read(key: kPluginGrantsSecureKey);
      if (readBack != encoded) {
        throw StateError('plugin grant migration did not verify');
      }
    } catch (error) {
      // Not verified: leave preferences as the source of truth and remove
      // any half-written copy so the next run migrates again from scratch.
      Diag.swallow('plugin_permissions.migrate', error);
      try {
        await _secureStorage.delete(key: kPluginGrantsSecureKey);
      } catch (e) {
        Diag.swallow('plugin_permissions.migrate_rollback', e);
      }
      return legacy;
    }
    await _dropLegacy(prefs);
    return legacy;
  }

  /// The pre-H1 preferences grants, each marked for the one-time
  /// content-tree adoption (H2): they were approved before content hashing
  /// existed, so the first runtime use records the installed tree instead
  /// of forcing every installed plugin through re-approval on upgrade.
  Map<String, String> _legacyGrants(SharedPreferences prefs) {
    final raw = prefs.getString(kPluginGrantsPrefKey);
    if (raw == null || raw.isEmpty) return {};
    final map = _decodeMap(raw) ?? {};
    return {
      for (final e in map.entries) e.key: _markForContentAdoption(e.value),
    };
  }

  static String _markForContentAdoption(String entry) {
    try {
      final decoded = jsonDecode(entry);
      if (decoded is! Map) return entry;
      final json = decoded.cast<String, dynamic>();
      if (json['contentTreeHash'] is String) return entry;
      json['adoptContentTreeOnFirstUse'] = true;
      return jsonEncode(json);
    } catch (_) {
      // A damaged record stays damaged: load() fails closed on it.
      return entry;
    }
  }

  Future<void> _dropLegacy(SharedPreferences prefs) async {
    if (!prefs.containsKey(kPluginGrantsPrefKey)) return;
    try {
      await prefs.remove(kPluginGrantsPrefKey);
    } catch (error) {
      // Harmless: secure storage is authoritative, the next run retries.
      Diag.swallow('plugin_permissions.drop_legacy', error);
    }
  }

  Future<void> _commitMap(
    SharedPreferences prefs,
    Map<String, String> next,
  ) async {
    final previous = await _confirmedMap(prefs);
    try {
      await _writeMap(next);
      _confirmed[prefs] = next;
    } catch (_) {
      // Restore the last confirmed snapshot even if storage is still
      // failing; never promote the attempted one.
      try {
        await _writeMap(previous);
      } catch (error) {
        Diag.swallow('plugin_permissions.restore', error);
      }
      rethrow;
    }
    // A commit made while hydration fell back to preferences carries the
    // full map, so the preferences copy is now redundant.
    await _dropLegacy(prefs);
  }

  /// An empty map deletes the key: no approvals leaves no grant residue in
  /// secure storage (uninstall/revoke of the last plugin).
  static Future<void> _writeMap(Map<String, String> map) => map.isEmpty
      ? _secureStorage.delete(key: kPluginGrantsSecureKey)
      : _secureStorage.write(key: kPluginGrantsSecureKey, value: jsonEncode(map));

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
      final entry = (await _confirmedMap(prefs))[pluginId];
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
      final entry = (await _confirmedMap(prefs))[pluginId];
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
    if (!grantCoversRequested(stored, requested)) return null;
    final environmentNames = <String>{...manifest.environmentReadNames};
    for (final server in manifest.mcpServers) {
      environmentNames.addAll(server.envNames);
    }
    if (!stored.environmentReadNames.containsAll(environmentNames)) return null;

    // Preserve the original approval time, content-tree binding and
    // adoption marker — a re-key is not a re-approval.
    final migrated = stored.rebound(manifestDigest: current);
    await save(migrated);
    return migrated;
  }

  /// The grant effective for [manifest] right now: the stored record for
  /// this plugin if and only if its digest matches (unchanged manifest →
  /// stored grant reused; changed manifest → re-approval required) AND its
  /// content-tree hash matches the files at `manifest.rootPath` (H2), after
  /// any pending v1 re-key. Used by approval UIs, so it never records a
  /// pending content adoption — only [effectiveRuntimeGrant] does.
  Future<PluginPermissionGrant?> effectiveGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    final grant = await migrateLegacyGrant(
      pluginId: pluginId,
      manifest: manifest,
    );
    if (grant == null) return null;
    return _verifyContentTree(grant, manifest, adopt: false);
  }

  /// Runtime activation requires a complete approval, not merely a stored
  /// row for the current digest. Raw [load] remains intentionally permissive
  /// so approval UIs can inspect partial grants.
  ///
  /// Also re-verifies the plugin's content tree (H2): a grant whose recorded
  /// hash no longer matches the files at `manifest.rootPath` is not
  /// effective — the plugin needs re-approval. [reverifyContent] forces a
  /// full re-hash instead of trusting the per-process cache (activation
  /// paths pass it).
  Future<PluginPermissionGrant?> effectiveRuntimeGrant({
    required String pluginId,
    required NormalizedPluginManifest manifest,
    bool reverifyContent = false,
  }) async {
    if (pluginId != manifest.id) return null;
    final migrated = await migrateLegacyGrant(
      pluginId: pluginId,
      manifest: manifest,
    );
    if (migrated == null || migrated.pluginId != pluginId) return null;
    final requested = manifest.requestedCapabilities.isNotEmpty
        ? manifest.requestedCapabilities
        : inferRequestedCapabilities(manifest);
    if (!grantCoversRequested(migrated, requested)) return null;
    final environmentNames = <String>{...manifest.environmentReadNames};
    for (final server in manifest.mcpServers) {
      environmentNames.addAll(server.envNames);
    }
    if (!migrated.environmentReadNames.containsAll(environmentNames)) {
      return null;
    }
    final grant = await _verifyContentTree(
      migrated,
      manifest,
      adopt: true,
      reverify: reverifyContent,
    );
    if (grant == null) return null;
    _noteDeclined(grant);
    return grant;
  }

  /// Records the installed content tree for a pre-upgrade grant (H2
  /// trust-on-first-use) without activating anything. Boot calls it for
  /// every installed plugin — disabled ones included — so the window closes
  /// on the first run of the new version rather than whenever a plugin is
  /// next enabled.
  Future<void> adoptPendingContentTree({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    final grant = await load(pluginId, pluginManifestDigest(manifest));
    if (grant == null || !grant.adoptContentTreeOnFirstUse) return;
    await _verifyContentTree(grant, manifest, adopt: true, reverify: true);
  }

  /// Whether the stored grant for [pluginId] matches [manifest]'s digest
  /// but NOT its content tree — i.e. the plugin's files changed after
  /// approval. Lets status surfaces say so precisely.
  Future<bool> contentChangedSinceApproval({
    required String pluginId,
    required NormalizedPluginManifest manifest,
  }) async {
    final grant = await load(pluginId, pluginManifestDigest(manifest));
    if (grant == null || grant.contentTreeHash == null) return false;
    try {
      return contentTreeHashFor(manifest.rootPath) != grant.contentTreeHash;
    } catch (_) {
      return true;
    }
  }

  /// Checks [grant] against the content currently at `manifest.rootPath`.
  /// A recorded hash must match exactly. A missing hash is only acceptable
  /// on a grant carrying the one-time upgrade marker; with [adopt] the
  /// current tree is recorded (and the marker cleared) so every later check
  /// enforces it. Any other hash-less grant fails closed.
  Future<PluginPermissionGrant?> _verifyContentTree(
    PluginPermissionGrant grant,
    NormalizedPluginManifest manifest, {
    required bool adopt,
    bool reverify = false,
  }) async {
    if (grant.contentTreeHash == null && !grant.adoptContentTreeOnFirstUse) {
      return null;
    }
    final String actual;
    try {
      actual = contentTreeHashFor(manifest.rootPath, reverify: reverify);
    } catch (error) {
      Diag.swallow('plugin_permissions.content_tree', error);
      return null;
    }
    final recorded = grant.contentTreeHash;
    if (recorded != null) return recorded == actual ? grant : null;
    if (!adopt) return grant;
    final bound = grant.rebound(
      contentTreeHash: actual,
      adoptContentTreeOnFirstUse: false,
    );
    try {
      await _recordAdoption(bound);
    } catch (error) {
      // The adoption retries on the next use; the pre-upgrade grant keeps
      // working meanwhile (never lose a grant over a storage hiccup).
      Diag.swallow('plugin_permissions.adopt', error);
      return grant;
    }
    return bound;
  }

  /// Writes an adopted content hash ONLY over the exact pre-upgrade record
  /// it was computed for — never resurrecting a grant revoked or replaced
  /// meanwhile (unlike [save], it cannot lift a revocation).
  Future<void> _recordAdoption(PluginPermissionGrant bound) async {
    final prefs = await SharedPreferences.getInstance();
    return _withWriteLock(() async {
      final map = Map<String, String>.of(await _confirmedMap(prefs));
      final raw = map[bound.pluginId];
      if (raw == null) return;
      final current = PluginPermissionGrant.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (current.manifestDigest != bound.manifestDigest ||
          !current.adoptContentTreeOnFirstUse ||
          current.contentTreeHash != null) {
        return;
      }
      map[bound.pluginId] = jsonEncode(bound.toJson());
      await _commitMap(prefs, map);
    });
  }

  /// Per-process content-tree hash cache: root → (stat fingerprint, hash).
  /// The fingerprint (paths, sizes, mtimes) is cheap to re-take, so a
  /// cached hash is reused only while the tree still looks identical;
  /// activation paths bypass it entirely via `reverify`.
  static final Map<String, ({String fingerprint, String hash})>
  _contentTreeCache = {};

  /// [pluginContentTreeHash] for [rootPath], served from the per-process
  /// cache unless the tree's stat fingerprint changed or [reverify] is set.
  static String contentTreeHashFor(String rootPath, {bool reverify = false}) {
    if (rootPath.isEmpty) return pluginContentTreeHash(rootPath);
    final fingerprint = _contentTreeFingerprint(rootPath);
    final cached = _contentTreeCache[rootPath];
    if (!reverify && cached != null && cached.fingerprint == fingerprint) {
      return cached.hash;
    }
    final hash = pluginContentTreeHash(rootPath);
    _contentTreeCache[rootPath] = (fingerprint: fingerprint, hash: hash);
    return hash;
  }

  /// Drops cached content hashes (one root, or all).
  static void forgetContentTree([String? rootPath]) {
    if (rootPath == null) {
      _contentTreeCache.clear();
    } else {
      _contentTreeCache.remove(rootPath);
    }
  }

  static String _contentTreeFingerprint(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) return 'missing';
    final parts = <String>[];
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      final stat = e.statSync();
      parts.add(
        '${e.path}|${stat.type}|${stat.size}|'
        '${stat.modified.microsecondsSinceEpoch}',
      );
    }
    parts.sort();
    return sha256.convert(utf8.encode(parts.join('\n'))).toString();
  }

  /// Declined capabilities per plugin id, as of the last grant this process
  /// loaded, saved or revoked. A SYNCHRONOUS view for the hook and MCP
  /// dispatch paths, which cannot await storage per event. Boot activation
  /// resolves every installed plugin's grant through [effectiveRuntimeGrant]
  /// before registering it, so the view is populated before anything runs.
  static final Map<String, Set<PluginCapability>> _declinedByPlugin = {};

  /// What the user declined for [pluginId] (empty when nothing was).
  static Set<PluginCapability> declinedCapabilitiesFor(String pluginId) =>
      _declinedByPlugin[pluginId] ?? const {};

  static void _noteDeclined(PluginPermissionGrant grant) {
    final declined = grant.declinedCapabilities.intersection(
      kDeclinablePluginCapabilities,
    );
    if (declined.isEmpty) {
      _declinedByPlugin.remove(grant.pluginId);
    } else {
      _declinedByPlugin[grant.pluginId] = Set.unmodifiable(declined);
    }
  }

  @visibleForTesting
  static void resetDeclinedCacheForTest() => _declinedByPlugin.clear();

  /// Persists [grant] (replacing any previous record for its plugin id).
  Future<void> save(PluginPermissionGrant grant) async {
    final prefs = await SharedPreferences.getInstance();
    final revokedAtStart = _tombstones(prefs)[grant.pluginId];
    return _withWriteLock(() async {
      final map = Map<String, String>.of(await _confirmedMap(prefs));
      map[grant.pluginId] = jsonEncode(grant.toJson());
      await _commitMap(prefs, map);
      _noteDeclined(grant);
      // Only an explicit approval begun after the revoke may lift its denial.
      if (identical(_tombstones(prefs)[grant.pluginId], revokedAtStart)) {
        _tombstones(prefs).remove(grant.pluginId);
      }
    });
  }

  /// Undoes an approval that was saved for an install which then FAILED:
  /// the grant is removed (or [restore]d to the record that existed before
  /// the approval sheet), so a later install of the same digest prompts
  /// again instead of silently reusing consent for content that never
  /// installed. Unlike [revoke] this never touches plugin-owned secrets —
  /// an earlier installed revision may still own them — and leaves no
  /// revocation tombstone.
  Future<void> discardApproval(
    String pluginId, {
    PluginPermissionGrant? restore,
  }) async {
    if (restore != null && restore.pluginId == pluginId) {
      await save(restore);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    return _withWriteLock(() async {
      final map = Map<String, String>.of(await _confirmedMap(prefs));
      if (map.remove(pluginId) == null) return;
      await _commitMap(prefs, map);
      _declinedByPlugin.remove(pluginId);
    });
  }

  /// Removes the plugin's grant AND every plugin-owned secret from
  /// secure storage (`ovid_plugin_secret_<plugin-id>/…`). Revocation
  /// immediately disables affected contributions (spec §5.1) — the
  /// runtime reacts to the missing grant; sibling plugins' secrets are
  /// untouched.
  Future<void> revoke(String pluginId) async {
    final prefs = await SharedPreferences.getInstance();
    // Deny before waiting for any pending write: every read filters
    // tombstoned ids after it resolves.
    _tombstones(prefs)[pluginId] = Object();
    _declinedByPlugin.remove(pluginId);
    return _withWriteLock(() async {
      Object? persistenceError;
      StackTrace? persistenceStack;
      try {
        final map = Map<String, String>.of(await _confirmedMap(prefs));
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

  /// Decodes a persisted grant map; corrupted JSON yields null (the caller
  /// treats it as "nothing approved").
  static Map<String, String>? _decodeMap(String raw) {
    try {
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return {
        for (final e in decoded.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    } catch (_) {
      return null;
    }
  }
}
