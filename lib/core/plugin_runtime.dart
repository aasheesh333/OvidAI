/// Atomic plugin runtime manager and one-restart activation
/// (design spec §4.1, §5.2, §7).
///
/// The single owner of the production plugin lifecycle. One install is
/// ONE transaction (spec §5.2):
///
/// 1. resolve the source into app-private staging ([PluginSourceResolver]);
/// 2. adapt + validate into a [NormalizedPluginManifest] (adapters);
/// 3. verify the capability grant (never auto-approve — the approval
///    sheet / pre-existing grant is the caller's proof);
/// 4. install dependencies into the versioned private sandbox
///    ([PluginDependencyService]);
/// 5. probe the committed content (contribution files exist);
/// 6. write the normalized manifest + activation record;
/// 7. register contributions for the permitted scope;
/// 8. atomically rename staging into the active version directory — the
///    commit point — and RE-REGISTER with the installed rootPath (the
///    registry bakes `manifest.rootPath` into every contribution, so the
///    staging-era registration must never survive the rename).
///
/// Any failure before step 8 rolls back files, registry, MCP/secrets
/// state created by the transaction; a failed upgrade leaves the prior
/// working version fully active.
///
/// Restart semantics (spec §7): `bootEpoch` increments exactly once per
/// `AppState._initialize` (via [activateForBoot]); agent installs are
/// `sessionActive` in their installing session with
/// `promoteOnNextBoot=true`; Plugins-screen installs are `pendingGlobal`;
/// the NEXT boot promotes both to `globalActive` exactly once and clears
/// the flag. Scope of this leaf: the activation lifecycle only — hook
/// consumption (Task 8) and plugin-owned MCP lifecycle (Task 9) attach
/// to the registration/rollback seams below.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plugin_adapters.dart';
import 'plugin_dependency_service.dart';
import 'plugin_manifest.dart';
import 'plugin_permissions.dart';
import 'plugin_registry.dart';
import 'plugin_source_resolver.dart';
import 'hook_service.dart';
import 'mcp_service.dart';
import 'startup_coordinator.dart';
import 'state.dart';

/// Preferences key for the persisted install map (plugin id → entry
/// JSON). Deliberately separate from `ovid_plugin_state_v1` (catalog
/// flags) and `ovid_plugin_grants_v1` (Task 5 approvals) — activation
/// records own their lifecycle.
const String kPluginActivationPrefKey = 'ovid_plugin_activation_v1';

/// Preferences key for the monotonically increasing boot epoch.
const String kPluginBootEpochPrefKey = 'ovid_plugin_boot_epoch_v1';

/// Canonical UI projection of normalized runtime installs. Both the outer
/// key and each row's runtimeId are the immutable publisher/name identity.
const String kPluginRowsV2PrefKey = 'ovid_plugin_rows_v2';
const String _kPluginRowsV2MigratedPrefKey = 'ovid_plugin_rows_v2_migrated';

const String _kPluginReapprovalReason =
    'Re-approve this plugin before it can run';
const String _kLegacyReapprovalReason =
    'Re-approve this legacy plugin before it can run';
const String _kMissingContentReason = 'Installed content is missing';
const String _kFailedActivationReason = 'Plugin activation failed';

/// Stable synthetic focus id for a legacy (`runtimeId`-null) migration row.
/// Mirrors the per-row migration status id emitted by
/// [PluginRuntimeManager.reconcileRowsAndGrants] so the startup dashboard and
/// the Plugins screen agree on exactly which row to reveal. [ordinal]
/// disambiguates rows sharing the same source/marketplace/name.
String legacyPluginFocusId(PluginItem row, int ordinal) {
  final identity = row.source ?? row.marketplace ?? row.name;
  return 'legacy:$identity:$ordinal';
}

/// Sentinel focus id the aggregate `localSafety.migrate` item carries when
/// more than one row needs re-approval: `Open Plugins` then lands on the
/// Plugins screen filtered to migration-required rows.
const String kMigrationRequiredFocusId = 'legacy:migration-required';

/// Self-describing transaction artifacts written inside the committed
/// content directory (spec §5.2 step 6).
const String kPluginRuntimeManifestFile = 'ovid-plugin.json';
const String kPluginRuntimeActivationFile = 'ovid-activation.json';

/// Versioned durable-status store (spec §5.8): canonical plugin/MCP id →
/// scrubbed terminal startup status. Deliberately separate from the
/// activation/row stores so a status write can never corrupt install state.
const String kPluginRuntimeStatusPrefKey = 'ovid_plugin_runtime_status_v1';
const int kPluginRuntimeStatusWireVersion = 1;
const int kPluginRuntimeStatusMaxLogLines = 100;
const int kPluginRuntimeStatusMaxLogBytes = 32 * 1024;

/// Canonical ids the durable store accepts: a non-empty, whitespace-free
/// one-, two-, or three-segment id — a bare ownerless server name, a plugin
/// `publisher/name`, or a plugin-owned MCP `publisher/name/server`. Every
/// segment must be non-empty and drawn from the canonical id alphabet.
/// Synthetic legacy ids (`legacy:…`) and anything with stray separators are
/// rejected.
bool isCanonicalRuntimeStatusId(String value) {
  if (value.isEmpty || value.trim() != value) return false;
  final parts = value.split('/');
  if (parts.length > 3) return false;
  for (final part in parts) {
    if (part.isEmpty) return false;
    if (part.contains(RegExp(r'[^A-Za-z0-9._~-]'))) return false;
  }
  return true;
}

/// One durable startup outcome for a canonical plugin/MCP id (spec §5.8).
class PluginRuntimeStatus {
  PluginRuntimeStatus({
    required this.pluginId,
    required this.state,
    this.reason,
    DateTime? updatedAt,
    this.logs = const [],
    this.wireVersion = kPluginRuntimeStatusWireVersion,
  }) : updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String pluginId;
  final StartupItemState state;
  final String? reason;
  final DateTime updatedAt;

  /// Scrubbed, capped diagnostic lines. Dormant in this task: the coordinator
  /// and probe surfaces do not currently emit per-item logs, so production
  /// records carry an empty list. The field and its caps/scrubbing are
  /// retained for Task 8/9 diagnostics so the wire shape stays stable.
  final List<String> logs;
  final int wireVersion;

  Map<String, dynamic> toJson() => {
    'pluginId': pluginId,
    'state': state.name,
    'reason': reason,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'logs': logs,
    'wireVersion': wireVersion,
  };

  /// Corrupt-tolerant decode: null when the record is unusable or from a
  /// newer wire version.
  static PluginRuntimeStatus? fromJson(Map<String, dynamic> j) {
    final pluginId = j['pluginId']?.toString() ?? '';
    if (!isCanonicalRuntimeStatusId(pluginId)) return null;
    final stateName = j['state']?.toString();
    StartupItemState? state;
    for (final candidate in StartupItemState.values) {
      if (candidate.name == stateName) {
        state = candidate;
        break;
      }
    }
    if (state == null) return null;
    final wire =
        (j['wireVersion'] as num?)?.toInt() ?? kPluginRuntimeStatusWireVersion;
    if (wire > kPluginRuntimeStatusWireVersion) return null;
    DateTime updatedAt;
    try {
      updatedAt = DateTime.parse(j['updatedAt'] as String).toUtc();
    } catch (_) {
      return null;
    }
    final logs =
        (j['logs'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    return PluginRuntimeStatus(
      pluginId: pluginId,
      state: state,
      reason: j['reason']?.toString(),
      updatedAt: updatedAt,
      logs: logs,
      wireVersion: wire,
    );
  }
}

/// Durable, versioned, secret-scrubbed startup status per canonical id
/// (spec §5.8). Uses the same double-encoded JSON convention as the
/// activation/grant stores: an outer map of canonical id → JSON string of the
/// inner record, keys sorted for stable bytes.
class PluginRuntimeStatusStore {
  PluginRuntimeStatusStore();

  static final PluginRuntimeStatusStore I = PluginRuntimeStatusStore();

  @visibleForTesting
  static bool failWritesForTest = false;

  final Map<String, PluginRuntimeStatus> _statuses = {};
  final Set<String> _removed = {};
  Future<void> _writeChain = Future<void>.value();
  bool _blocked = false;
  int _persistCount = 0;

  @visibleForTesting
  int get persistCountForTest => _persistCount;

  @visibleForTesting
  Map<String, PluginRuntimeStatus> get statusesForTest =>
      Map<String, PluginRuntimeStatus>.unmodifiable(_statuses);

  @visibleForTesting
  bool get blockedForTest => _blocked;

  /// Clears in-memory state (not prefs) — called when the test app instance
  /// is reset so store state never leaks between tests.
  void resetForTest() {
    _statuses.clear();
    _removed.clear();
    _blocked = false;
    _writeChain = Future<void>.value();
    _persistCount = 0;
  }

  /// Hydrates from preferences. Corrupt inner records, noncanonical ids, and
  /// newer wire versions are dropped without blocking the rest of the boot.
  Future<void> hydrate() async {
    _blocked = false;
    _statuses.clear();
    _removed.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPluginRuntimeStatusPrefKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        final id = key.toString();
        if (!isCanonicalRuntimeStatusId(id) || value is! String) return;
        try {
          final inner = jsonDecode(value);
          if (inner is! Map) return;
          final status = PluginRuntimeStatus.fromJson(
            inner.cast<String, dynamic>(),
          );
          if (status != null && status.pluginId == id) {
            _statuses[id] = status;
          }
        } catch (_) {
          // A single damaged inner record never blocks the rest.
        }
      });
    } catch (_) {}
  }

  PluginRuntimeStatus? statusFor(String canonicalId) => _statuses[canonicalId];

  /// Records a terminal status. Non-terminal states, noncanonical ids, stale
  /// writes older than the current record, and writes to a removed id are
  /// ignored. [revive] clears an uninstall tombstone for a fresh install.
  Future<void> record(PluginRuntimeStatus status, {bool revive = false}) {
    if (_blocked) return Future<void>.value();
    if (!status.state.isTerminal) return Future<void>.value();
    if (!isCanonicalRuntimeStatusId(status.pluginId)) {
      return Future<void>.value();
    }
    if (revive) _removed.remove(status.pluginId);
    if (_removed.contains(status.pluginId)) return Future<void>.value();

    final scrubbed = PluginRuntimeStatus(
      pluginId: status.pluginId,
      state: status.state,
      reason: status.reason == null
          ? null
          : redactStartupError(status.reason!),
      updatedAt: status.updatedAt,
      logs: _capLogs(status.logs),
      wireVersion: status.wireVersion,
    );

    final existing = _statuses[scrubbed.pluginId];
    if (existing != null) {
      if (scrubbed.updatedAt.isBefore(existing.updatedAt)) {
        return Future<void>.value();
      }
      if (existing.state == scrubbed.state &&
          existing.reason == scrubbed.reason &&
          _sameLogs(existing.logs, scrubbed.logs) &&
          existing.wireVersion == scrubbed.wireVersion) {
        return Future<void>.value();
      }
    }
    _statuses[scrubbed.pluginId] = scrubbed;
    return _enqueueWrite();
  }

  /// Removes the record and tombstones the id so a late completion cannot
  /// recreate it. Used by uninstall.
  Future<void> remove(String canonicalId) {
    if (!isCanonicalRuntimeStatusId(canonicalId)) {
      return Future<void>.value();
    }
    _removed.add(canonicalId);
    if (_statuses.remove(canonicalId) == null) {
      return Future<void>.value();
    }
    return _enqueueWrite();
  }

  /// Factory reset: clears memory, the persisted key, and tombstones, and
  /// blocks every late completion from recreating a record.
  Future<void> clear() {
    _statuses.clear();
    _removed.clear();
    _blocked = true;
    return _enqueueWrite();
  }

  Future<void> _enqueueWrite() {
    final pending = _writeChain.then((_) => _persist());
    _writeChain = pending.catchError((Object _) {});
    return pending;
  }

  Future<void> _persist() async {
    try {
      if (failWritesForTest) {
        throw StateError('Injected runtime status write failure');
      }
      final prefs = await SharedPreferences.getInstance();
      final ids = _statuses.keys.toList()..sort();
      if (ids.isEmpty) {
        await prefs.remove(kPluginRuntimeStatusPrefKey);
      } else {
        final written = await prefs.setString(
          kPluginRuntimeStatusPrefKey,
          jsonEncode({
            for (final id in ids) id: jsonEncode(_statuses[id]!.toJson()),
          }),
        );
        if (!written) {
          throw StateError('Failed to persist plugin runtime status');
        }
      }
      _persistCount++;
    } catch (_) {
      // A status write must never brick startup or uninstall.
    }
  }

  static bool _sameLogs(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Newest [kPluginRuntimeStatusMaxLogLines] lines, scrubbed, then bounded
  /// to [kPluginRuntimeStatusMaxLogBytes] UTF-8 bytes from the newest end.
  static List<String> _capLogs(List<String> input) {
    final scrubbed = [for (final line in input) redactStartupError(line)];
    final newest = scrubbed.length > kPluginRuntimeStatusMaxLogLines
        ? scrubbed.sublist(scrubbed.length - kPluginRuntimeStatusMaxLogLines)
        : scrubbed;
    final out = <String>[];
    var bytes = 0;
    for (var i = newest.length - 1; i >= 0; i--) {
      final lineBytes = utf8.encode(newest[i]).length;
      if (bytes + lineBytes > kPluginRuntimeStatusMaxLogBytes) break;
      bytes += lineBytes;
      out.insert(0, newest[i]);
    }
    return List<String>.unmodifiable(out);
  }
}

/// Why an install was refused before the transaction started (nothing
/// was rolled back — nothing had begun).
enum PluginRuntimeErrorCode {
  noSource,
  identity,
  requiredIssue,
  capabilityApprovalRequired,
  digestMismatch,
  renameFailed,
}

class PluginRuntimeException implements Exception {
  final PluginRuntimeErrorCode code;
  final String message;

  const PluginRuntimeException(this.code, this.message);

  @override
  String toString() => 'PluginRuntimeException: $message';
}

/// Whole-transaction outcome: `ok`, `degraded` (optional dependency or
/// probe failure — mounted with honest warnings), or `failed` (rolled
/// back, nothing active).
enum PluginInstallStatus { ok, degraded, failed }

/// A resolved + adapted source, holding its staging directory until the
/// install transaction consumes (renames) or discards it.
class PluginInspection {
  PluginInspection._({required this.manifest, required this.source});

  final NormalizedPluginManifest manifest;
  final ResolvedPluginSource source;

  String get manifestDigest => pluginManifestDigest(manifest);

  bool get isDiscarded => source.isDiscarded;

  /// Delete the staging directory (caller abandoned the install).
  void discard() => source.discard();
}

/// Result of one install transaction.
class PluginInstallResult {
  final PluginInstallStatus status;

  /// The manifest re-bound to the INSTALLED rootPath (null on failure —
  /// nothing was committed).
  final NormalizedPluginManifest? manifest;

  /// The persisted activation record (scope + restart semantics).
  final PluginActivationRecord? record;

  final String? manifestDigest;
  final String? installDir;

  /// Failed OPTIONAL dependency package names (degraded activations).
  final List<String> degradedNames;

  /// Contribution files the probe could not find on disk (degraded
  /// activations).
  final List<String> probeFailures;

  final String? error;
  final List<String> logs;

  const PluginInstallResult({
    required this.status,
    this.manifest,
    this.record,
    this.manifestDigest,
    this.installDir,
    this.degradedNames = const [],
    this.probeFailures = const [],
    this.error,
    this.logs = const [],
  });

  const PluginInstallResult.failed({this.error})
    : status = PluginInstallStatus.failed,
      manifest = null,
      record = null,
      manifestDigest = null,
      installDir = null,
      degradedNames = const [],
      probeFailures = const [],
      logs = const [];
}

/// One persisted install: activation record + everything the next boot
/// needs to re-mount the plugin without re-resolving its source.
class PluginInstallEntry {
  final PluginActivationRecord activation;
  final NormalizedPluginManifest manifest;

  /// Committed content directory (the atomic-rename target).
  final String contentDir;
  final String version;

  /// Failed optional dependency packages (degraded honesty, spec §6).
  final List<String> degradedNames;

  /// Missing contribution files found by the probe.
  final List<String> probeFailures;

  /// User-disabled installs stay persisted (enable restores them) but
  /// are never registered or promoted while disabled.
  final bool disabled;

  const PluginInstallEntry({
    required this.activation,
    required this.manifest,
    required this.contentDir,
    required this.version,
    this.degradedNames = const [],
    this.probeFailures = const [],
    this.disabled = false,
  });

  bool get isDegraded => degradedNames.isNotEmpty || probeFailures.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'activation': activation.toJson(),
    'manifest': manifest.toJson(),
    'contentDir': contentDir,
    'version': version,
    'degradedNames': degradedNames,
    'probeFailures': probeFailures,
    'disabled': disabled,
  };

  /// Corrupt-tolerant decode; null when the entry has no usable shape
  /// (house style: a damaged record must never brick the boot).
  static PluginInstallEntry? fromJson(Map<String, dynamic> j) {
    final activation = PluginActivationRecord.fromJson(
      (j['activation'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    if (activation.pluginId.isEmpty) return null;
    final manifest = NormalizedPluginManifest.fromJson(
      (j['manifest'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    return PluginInstallEntry(
      activation: activation,
      manifest: manifest,
      contentDir: j['contentDir'] as String? ?? '',
      version: j['version'] as String? ?? '',
      degradedNames: _strings(j['degradedNames']),
      probeFailures: _strings(j['probeFailures']),
      disabled: j['disabled'] as bool? ?? false,
    );
  }

  static List<String> _strings(Object? raw) => raw is List
      ? List.unmodifiable([for (final e in raw) e.toString()])
      : const [];
}

/// Immutable, validated runtime projection used by skill and lifecycle
/// consumers without exposing the manager's persisted mutable maps.
class ActivePluginRuntime {
  final String pluginId;
  final String contentDir;
  final PluginActivation activation;
  final String? immediateSessionId;
  final NormalizedPluginManifest manifest;

  const ActivePluginRuntime({
    required this.pluginId,
    required this.contentDir,
    required this.activation,
    required this.immediateSessionId,
    required this.manifest,
  });
}

/// Builds a GitHub source from a catalog row's `source` string
/// (`owner/repo`, optionally `owner/repo/raw/<ref>/<subpath>`). Null when
/// the string is not a GitHub coordinate — callers fall back to their
/// legacy path.
GithubPluginSource? githubPluginSourceFromSourceString(String source) {
  final parts = source.trim().split('/');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  String? ref;
  String? subPath;
  if (parts.length >= 4 && parts[2] == 'raw') {
    if (parts[3] != 'branch' && parts[3].isNotEmpty) ref = parts[3];
    if (parts.length > 4) {
      final sp = parts.sublist(4).join('/');
      if (sp.isNotEmpty) subPath = sp;
    }
  }
  return GithubPluginSource(
    owner: parts[0],
    repo: parts[1],
    ref: ref,
    subPath: subPath,
  );
}

/// The activation-lifecycle owner (spec §4.1). Process-wide singleton
/// [I]; every mutation is persisted under [kPluginActivationPrefKey] so
/// the next boot can promote/re-mount without the original source.
class PluginRuntimeManager extends ChangeNotifier {
  PluginRuntimeManager._();

  static final PluginRuntimeManager I = PluginRuntimeManager._();

  Object? _bootToken;
  int? _bootEpoch;

  /// In-flight activation shared by concurrent callers carrying the same
  /// boot token. Cleared on completion so retry/re-activation with the same
  /// token re-runs while still reusing [_bootEpoch] (no extra increment).
  Future<void>? _bootActivation;
  Object? _bootActivationToken;

  /// Test seams (resolver/dep-service injection), mirroring the
  /// `AppState.pluginCacheRootOverrideForTest` convention.
  @visibleForTesting
  static Directory? stagingRootOverrideForTest;

  /// Base directory containing `plugin-runtime/<id>/<version>/` — the
  /// committed content root AND the dependency-service root.
  @visibleForTesting
  static Directory? runtimeRootOverrideForTest;

  @visibleForTesting
  static PluginDependencyService? depsForTest;

  /// Task 11 test seams: GitHub / npm base overrides forwarded to the
  /// source resolver so remote source routes (marketplace/GitHub/npm)
  /// resolve against a loopback mock in tests — never the live network.
  @visibleForTesting
  static String? githubBaseOverrideForTest;

  @visibleForTesting
  static String? npmRegistryBaseOverrideForTest;

  /// Test seam: when true, the atomic commit rename (spec §5.2 step 8)
  /// fails on the next install — pins the upgrade rollback path. The
  /// version directory is shared with the dependency sandbox, so no
  /// pure-filesystem block can reach the rename without failing the
  /// dependency stage first.
  @visibleForTesting
  static bool failRenameForTest = false;

  @visibleForTesting
  static bool failMigrationMarkerWriteForTest = false;

  @visibleForTesting
  static bool failCanonicalRowsWriteForTest = false;

  PluginDependencyService _deps() =>
      depsForTest ??
      PluginDependencyService(runtimeRootOverride: runtimeRootOverrideForTest);

  Future<Directory> _base() async {
    final override = runtimeRootOverrideForTest;
    if (override != null) return override;
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  /// Per-segment sanitizer + version fallback, mirroring
  /// `PluginDependencyService._runtimeRootFor` so committed content and
  /// dependency sandboxes always share one version directory.
  static String _sanitizeSegment(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._~-]'), '_');

  Future<Directory> _contentDirFor(String pluginId, String version) async {
    final base = await _base();
    final safeId = pluginId
        .split('/')
        .map(_sanitizeSegment)
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .join('/');
    final sv = _sanitizeSegment(version);
    final safeVersion = (sv.isEmpty || sv == '.' || sv == '..')
        ? 'unversioned'
        : sv;
    return Directory(
      '${base.path}/plugin-runtime/$safeId/$safeVersion/content',
    );
  }

  static NormalizedPluginManifest _withRoot(
    NormalizedPluginManifest m,
    String root,
  ) {
    if (m.rootPath == root) return m;
    final j = m.toJson()..['rootPath'] = root;
    return NormalizedPluginManifest.fromJson(j);
  }

  // ── persisted install map ─────────────────────────────────────────

  Future<Map<String, PluginInstallEntry>> _loadEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPluginActivationPrefKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, PluginInstallEntry>{};
      decoded.forEach((k, v) {
        if (v is! String) return;
        try {
          final entryJson = jsonDecode(v);
          if (entryJson is! Map) return;
          final entry = PluginInstallEntry.fromJson(
            entryJson.cast<String, dynamic>(),
          );
          if (entry != null) out[k.toString()] = entry;
        } catch (_) {
          // A single damaged entry never blocks the rest of the boot.
        }
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveEntries(
    Map<String, PluginInstallEntry> entries, {
    bool reportFailure = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final written = await prefs.setString(
        kPluginActivationPrefKey,
        jsonEncode({
          for (final key in (entries.keys.toList()..sort()))
            key: jsonEncode(entries[key]!.toJson()),
        }),
      );
      if (!written && reportFailure) {
        throw StateError('Failed to persist plugin activation entries');
      }
    } catch (error, stack) {
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  Future<int> _readEpoch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(kPluginBootEpochPrefKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _writeEpoch(int value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kPluginBootEpochPrefKey, value);
    } catch (_) {}
  }

  /// The activation record persisted for [pluginId], or null.
  Future<PluginActivationRecord?> recordFor(String pluginId) async =>
      (await _loadEntries())[pluginId]?.activation;

  Future<void> persistRuntimeRow(
    String pluginId, {
    bool reportFailure = false,
  }) async {
    final entry = (await _loadEntries())[pluginId];
    if (entry == null) return;
    final rows = await _loadRows();
    final current = _catalogRowFor(pluginId);
    rows[pluginId] = _runtimeRow(
      pluginId,
      entry,
      stored: current ?? rows[pluginId],
      catalog: rows[pluginId],
    );
    await _saveRows(rows, reportFailure: reportFailure);
  }

  Future<void> _removeRuntimeRow(String pluginId) async {
    final rows = await _loadRows();
    if (rows.remove(pluginId) != null) await _saveRows(rows);
  }

  Future<Map<String, PluginItem>> _loadRows() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kPluginRowsV2PrefKey);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final rows = <String, PluginItem>{};
      for (final item in decoded.entries) {
        if (item.value is! String) continue;
        try {
          final rowJson = jsonDecode(item.value as String);
          if (rowJson is! Map) continue;
          final row = PluginItem.fromJson(rowJson.cast<String, dynamic>());
          final id = item.key.toString();
          if (row.runtimeId == id) rows[id] = row;
        } catch (_) {}
      }
      return rows;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveRows(
    Map<String, PluginItem> rows, {
    bool reportFailure = false,
  }) async {
    try {
      if (failCanonicalRowsWriteForTest) {
        throw StateError('Injected canonical plugin-row write failure');
      }
      final prefs = await SharedPreferences.getInstance();
      final ids = rows.keys.toList()..sort();
      final written = await prefs.setString(
        kPluginRowsV2PrefKey,
        jsonEncode({for (final id in ids) id: jsonEncode(rows[id]!.toJson())}),
      );
      if (!written && reportFailure) {
        throw StateError('Failed to persist canonical plugin rows');
      }
    } catch (error, stack) {
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  PluginItem? _catalogRowFor(String pluginId) =>
      AppState.I.plugins.where((row) => row.runtimeId == pluginId).firstOrNull;

  /// Restores only activation-backed canonical rows. This runs before legacy
  /// marketplace data is merged, so v1 data can enrich an exact runtime ID
  /// but can never create an orphan normalized row.
  Future<void> restoreCanonicalRows() async {
    final entries = await _loadEntries();
    final storedRows = await _loadRows();
    final rows = <String, PluginItem>{};
    for (final id in (entries.keys.toList()..sort())) {
      final entry = entries[id]!;
      if (!isCanonicalPluginId(id) ||
          id != entry.activation.pluginId ||
          id != entry.manifest.id ||
          !await _isContainedEntry(id, entry)) {
        continue;
      }
      rows[id] = _runtimeRow(
        id,
        entry,
        stored: storedRows[id],
        catalog: _catalogRowFor(id),
      );
    }
    AppState.I.plugins.removeWhere((row) => row.runtimeId != null);
    AppState.I.plugins.addAll(rows.values);
    AppState.I.refresh();
  }

  PluginItem _runtimeRow(
    String pluginId,
    PluginInstallEntry entry, {
    PluginItem? stored,
    PluginItem? catalog,
  }) {
    final manifest = entry.manifest;
    final publisher = pluginId.split('/').first;
    String? text(String? storedValue, String? catalogValue) {
      if (storedValue?.isNotEmpty == true) return storedValue;
      if (catalogValue?.isNotEmpty == true) return catalogValue;
      return null;
    }

    return PluginItem(
      name:
          text(stored?.name, catalog?.name) ??
          (manifest.name.isNotEmpty ? manifest.name : pluginId),
      author: text(stored?.author, catalog?.author) ?? publisher,
      description: text(stored?.description, catalog?.description) ?? '',
      version: entry.version.isNotEmpty ? entry.version : manifest.version,
      category: text(stored?.category, catalog?.category) ?? 'Plugin',
      installed: true,
      enabled:
          !entry.disabled &&
          entry.activation.state != PluginActivation.failed &&
          entry.activation.state != PluginActivation.disabled,
      installs: stored?.installs ?? catalog?.installs ?? 0,
      installsKnown: stored?.installsKnown ?? catalog?.installsKnown ?? false,
      source: text(stored?.source, catalog?.source),
      marketplace: text(stored?.marketplace, catalog?.marketplace),
      runtimeId: pluginId,
      activation: entry.disabled
          ? PluginActivation.disabled
          : entry.activation.state,
      immediateSessionId: entry.activation.immediateSessionId,
      promoteOnNextBoot: entry.activation.promoteOnNextBoot,
      manifestDigest: pluginManifestDigest(manifest),
      compatibilityWarnings: [
        for (final issue in manifest.compatibility)
          if (issue.severity == CompatibilitySeverity.optional) issue,
      ],
      migrationRequired:
          stored?.migrationRequired ?? catalog?.migrationRequired ?? false,
      runtimeReason: stored?.runtimeReason ?? catalog?.runtimeReason,
    );
  }

  static bool _isExecutableLegacyRow(PluginItem row) =>
      row.installed &&
      row.enabled &&
      row.runtimeId == null &&
      (row.source != null ||
          row.hooks.isNotEmpty ||
          row.pluginHooks.isNotEmpty);

  static String _legacyStatusId(PluginItem row, int ordinal) =>
      legacyPluginFocusId(row, ordinal);

  Future<bool> _hasEffectiveGrant(
    String pluginId,
    PluginInstallEntry entry,
  ) async {
    if (pluginId != entry.activation.pluginId ||
        pluginId != entry.manifest.id) {
      return false;
    }
    return await PluginPermissionStore().effectiveRuntimeGrant(
          pluginId: pluginId,
          manifest: entry.manifest,
        ) !=
        null;
  }

  Future<bool> _isContainedEntry(
    String pluginId,
    PluginInstallEntry entry,
  ) async {
    if (!isCanonicalPluginId(pluginId) ||
        entry.version.isEmpty ||
        entry.contentDir.isEmpty) {
      return false;
    }
    final expected = await _contentDirFor(pluginId, entry.version);
    return Directory(entry.contentDir).absolute.path ==
            expected.absolute.path &&
        entry.manifest.rootPath == entry.contentDir;
  }

  PluginInstallEntry _replaceEntry(
    PluginInstallEntry entry, {
    required PluginActivationRecord activation,
    bool? disabled,
    List<String>? probeFailures,
  }) => PluginInstallEntry(
    activation: activation,
    manifest: entry.manifest,
    contentDir: entry.contentDir,
    version: entry.version,
    degradedNames: entry.degradedNames,
    probeFailures: probeFailures ?? entry.probeFailures,
    disabled: disabled ?? entry.disabled,
  );

  PluginActivationRecord _disabledRecord(
    String pluginId,
    PluginInstallEntry entry,
  ) => PluginActivationRecord(
    pluginId: pluginId,
    state: PluginActivation.disabled,
    installedBootEpoch: entry.activation.installedBootEpoch,
  );

  PluginActivationRecord _failedRecord(
    String pluginId,
    PluginInstallEntry entry,
  ) => PluginActivationRecord(
    pluginId: pluginId,
    state: PluginActivation.failed,
    installedBootEpoch: entry.activation.installedBootEpoch,
  );

  Future<void> _deactivateRuntime(
    String pluginId,
    Map<String, PluginInstallEntry> entries,
    PluginInstallEntry entry, {
    required PluginActivation activation,
  }) async {
    final record = activation == PluginActivation.failed
        ? _failedRecord(pluginId, entry)
        : _disabledRecord(pluginId, entry);
    entries[pluginId] = _replaceEntry(
      entry,
      activation: record,
      disabled: activation == PluginActivation.disabled,
    );
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    await AppState.I.unmountPluginOwnedMcpServers(pluginId, uninstall: false);
    for (final row in AppState.I.plugins) {
      if (row.runtimeId != pluginId) continue;
      row
        ..enabled = false
        ..activation = activation
        ..immediateSessionId = null
        ..promoteOnNextBoot = false
        ..migrationRequired = activation == PluginActivation.disabled
        ..runtimeReason = activation == PluginActivation.disabled
            ? _kPluginReapprovalReason
            : _kMissingContentReason;
    }
  }

  Future<void> _failMissingContent(
    String pluginId,
    Map<String, PluginInstallEntry> entries,
    PluginInstallEntry entry, {
    PluginItem? projection,
  }) async {
    await _deactivateRuntime(
      pluginId,
      entries,
      entry,
      activation: PluginActivation.failed,
    );
    if (projection != null) {
      projection
        ..enabled = false
        ..activation = PluginActivation.failed
        ..immediateSessionId = null
        ..promoteOnNextBoot = false
        ..migrationRequired = false
        ..runtimeReason = _kMissingContentReason;
    }
  }

  /// Rebuilds canonical rows before any activation, fails closed on missing
  /// grants/content, then disables executable legacy rows without deleting
  /// their caches or approval history.
  Future<List<StartupItemStatus>> reconcileRowsAndGrants() async {
    final entries = await _loadEntries();
    final storedRows = await _loadRows();
    final rows = <String, PluginItem>{};
    final statuses = <StartupItemStatus>[];
    final ids = entries.keys.toList()..sort();

    for (final id in ids) {
      var entry = entries[id]!;
      if (!isCanonicalPluginId(id) ||
          id != entry.activation.pluginId ||
          id != entry.manifest.id ||
          !await _isContainedEntry(id, entry)) {
        await _deactivateRuntime(
          id,
          entries,
          entry,
          activation: PluginActivation.disabled,
        );
        statuses.add(
          StartupItemStatus.failed(
            id,
            StartupItemKind.plugin,
            entry.manifest.name.isNotEmpty ? entry.manifest.name : id,
            reason: 'Installed runtime identity is invalid',
          ),
        );
        continue;
      }
      final row = _runtimeRow(
        id,
        entry,
        stored: storedRows[id],
        catalog: _catalogRowFor(id),
      );
      if (!Directory(entry.contentDir).existsSync()) {
        await _failMissingContent(id, entries, entry, projection: row);
        entry = entries[id]!;
        statuses.add(
          StartupItemStatus.failed(
            id,
            StartupItemKind.plugin,
            row.name,
            reason: _kMissingContentReason,
          ),
        );
      } else if (!await _hasEffectiveGrant(id, entry)) {
        await _deactivateRuntime(
          id,
          entries,
          entry,
          activation: PluginActivation.disabled,
        );
        entry = entries[id]!;
        row
          ..enabled = false
          ..activation = PluginActivation.disabled
          ..immediateSessionId = null
          ..promoteOnNextBoot = false
          ..migrationRequired = true
          ..runtimeReason = _kPluginReapprovalReason;
        statuses.add(
          StartupItemStatus.migrationRequired(
            id,
            StartupItemKind.plugin,
            row.name,
            reason: _kPluginReapprovalReason,
          ),
        );
      } else {
        row
          ..migrationRequired = false
          ..runtimeReason = entry.activation.state == PluginActivation.failed
              ? _kFailedActivationReason
              : null;
        statuses.add(switch (entry.activation.state) {
          PluginActivation.failed => StartupItemStatus.failed(
            id,
            StartupItemKind.plugin,
            row.name,
            reason: _kFailedActivationReason,
          ),
          PluginActivation.disabled => StartupItemStatus.disabled(
            id,
            StartupItemKind.plugin,
            row.name,
          ),
          _ when entry.disabled => StartupItemStatus.disabled(
            id,
            StartupItemKind.plugin,
            row.name,
          ),
          _ => StartupItemStatus.ready(id, StartupItemKind.plugin, row.name),
        });
      }
      rows[id] = row;
    }

    var legacyOrdinal = 0;
    for (final row in AppState.I.plugins) {
      if (_isExecutableLegacyRow(row)) {
        row
          ..enabled = false
          ..activation = PluginActivation.disabled
          ..migrationRequired = true
          ..runtimeReason = _kLegacyReapprovalReason;
      }
      if (row.runtimeId == null && row.migrationRequired) {
        statuses.add(
          StartupItemStatus.migrationRequired(
            _legacyStatusId(row, legacyOrdinal++),
            StartupItemKind.plugin,
            row.name,
            reason: row.runtimeReason ?? _kLegacyReapprovalReason,
          ),
        );
      }
    }

    await _saveEntries(entries, reportFailure: true);
    await _saveRows(rows, reportFailure: true);
    final canonicalIds = rows.keys.toSet();
    final staleRuntimeIds = <String>{
      for (final row in AppState.I.plugins)
        if (row.runtimeId != null && !canonicalIds.contains(row.runtimeId))
          row.runtimeId!,
      for (final id in storedRows.keys)
        if (!canonicalIds.contains(id)) id,
      for (final id in PluginContributionRegistry.I.registeredPluginIds)
        if (!canonicalIds.contains(id)) id,
    };
    for (final id in staleRuntimeIds) {
      PluginContributionRegistry.I.unregisterPlugin(id);
      await AppState.I.unmountPluginOwnedMcpServers(id, uninstall: false);
    }
    AppState.I.plugins.removeWhere((row) => row.runtimeId != null);
    AppState.I.plugins.addAll([
      for (final id in (rows.keys.toList()..sort())) rows[id]!,
    ]);
    await AppState.I.persistLegacyPluginMigrationState();
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kPluginRowsV2MigratedPrefKey) != true) {
      if (failMigrationMarkerWriteForTest) {
        throw StateError('Injected plugin migration marker write failure');
      }
      final markerWritten = await prefs.setBool(
        _kPluginRowsV2MigratedPrefKey,
        true,
      );
      if (!markerWritten) {
        throw StateError('Failed to persist plugin migration marker');
      }
    }
    AppState.I.refresh();
    return statuses;
  }

  /// One readiness item per persisted normalized runtime (spec §5.7):
  /// canonical id + display label, sorted by id for a stable startup order.
  /// User-disabled installs are excluded (they do not participate in
  /// readiness), matching [activateForBoot]'s skip.
  Future<List<({String id, String label})>> bootRuntimeItems() async {
    final entries = await _loadEntries();
    final ids = entries.keys.toList()..sort();
    return [
      for (final id in ids)
        if (isCanonicalPluginId(id) && !entries[id]!.disabled)
          (
            id: id,
            label: entries[id]!.manifest.name.isNotEmpty
                ? entries[id]!.manifest.name
                : id,
          ),
    ];
  }

  Future<List<ActivePluginRuntime>> activeRuntimes() async {
    final entries = await _loadEntries();
    final out = <ActivePluginRuntime>[];
    for (final id in (entries.keys.toList()..sort())) {
      final entry = entries[id]!;
      final state = entry.activation.state;
      final active =
          state == PluginActivation.globalActive ||
          state == PluginActivation.degraded ||
          (state == PluginActivation.sessionActive &&
              (entry.activation.immediateSessionId?.isNotEmpty ?? false));
      if (!active || entry.disabled) continue;
      if (!await _isContainedEntry(id, entry) ||
          !Directory(entry.contentDir).existsSync() ||
          !await _hasEffectiveGrant(id, entry)) {
        continue;
      }
      out.add(
        ActivePluginRuntime(
          pluginId: id,
          contentDir: entry.contentDir,
          activation: state,
          immediateSessionId: entry.activation.immediateSessionId,
          manifest: entry.manifest,
        ),
      );
    }
    return List.unmodifiable(out);
  }

  /// Truthful health for one canonical runtime row (spec §5.8/§6.2). Probes
  /// the effective grant, committed content, live registration, and the
  /// declared capability surface — roster tools, registered hooks (never
  /// executed), and owned-MCP connectivity. A hook-only or MCP-only plugin is
  /// Ready from its real active capability instead of requiring roster tools.
  Future<StartupItemStatus> probeNormalizedHealth(
    String pluginId, {
    required String label,
  }) async {
    final entries = await _loadEntries();
    final entry = entries[pluginId];
    if (entry == null) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        label,
        reason: 'Plugin is not registered',
      );
    }
    final name = entry.manifest.name.isNotEmpty ? entry.manifest.name : label;
    if (entry.disabled) {
      return StartupItemStatus.disabled(pluginId, StartupItemKind.plugin, name);
    }
    // Containment is a hard integrity failure; a missing/mismatched grant is
    // the fail-closed migration case. They must not collapse into one state.
    if (!await _isContainedEntry(pluginId, entry)) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: 'Installed runtime identity is invalid',
      );
    }
    if (!await _hasEffectiveGrant(pluginId, entry)) {
      return StartupItemStatus.migrationRequired(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: _kPluginReapprovalReason,
      );
    }
    if (!Directory(entry.contentDir).existsSync()) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: _kMissingContentReason,
      );
    }
    if (!PluginContributionRegistry.I.isRegistered(pluginId)) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: 'Plugin is not registered',
      );
    }
    final manifest = entry.manifest;
    final hasRoster =
        manifest.commands.isNotEmpty ||
        manifest.skills.isNotEmpty ||
        manifest.agents.isNotEmpty;
    // Probe EVERY declared capability; a roster tool must never short-circuit
    // a declared hook or owned-MCP requirement (M4).
    if (manifest.hooks.isNotEmpty &&
        !HookService.I.hasRegisteredHooks(pluginId)) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: 'Registered hooks are missing',
      );
    }
    for (final declared in manifest.mcpServers) {
      final canonicalId = '$pluginId/${declared.name}';
      McpServer? server;
      for (final candidate in AppState.I.mcpServers) {
        if (candidate.canonicalId == canonicalId) {
          server = candidate;
          break;
        }
      }
      if (server == null) {
        return StartupItemStatus.failed(
          pluginId,
          StartupItemKind.plugin,
          name,
          reason: 'MCP server is not mounted',
        );
      }
      final unsupported = McpService.I.unsupportedTransportReason(server);
      if (unsupported != null) {
        return StartupItemStatus.unsupported(
          pluginId,
          StartupItemKind.plugin,
          name,
          reason: unsupported,
        );
      }
      final missing = await McpService.I.missingCredentialsFor(server);
      if (missing.isNotEmpty) {
        return StartupItemStatus.needsSetup(
          pluginId,
          StartupItemKind.plugin,
          name,
          reason: 'Needs configuration (${missing.join(', ')})',
        );
      }
      if (!McpService.I.isConnected(canonicalId)) {
        return StartupItemStatus.degraded(
          pluginId,
          StartupItemKind.plugin,
          name,
          reason: 'MCP server is not connected',
        );
      }
    }
    if (!hasRoster && manifest.hooks.isEmpty && manifest.mcpServers.isEmpty) {
      return StartupItemStatus.failed(
        pluginId,
        StartupItemKind.plugin,
        name,
        reason: 'Plugin declares no runtime capability',
      );
    }
    return StartupItemStatus.ready(pluginId, StartupItemKind.plugin, name);
  }

  // ── row sync (catalog rows carrying runtimeId) ────────────────────

  bool _syncRow(PluginActivationRecord rec) {
    var changed = false;
    for (final p in AppState.I.plugins) {
      if (p.runtimeId != rec.pluginId) continue;
      if (p.activation != rec.state) {
        p.activation = rec.state;
        changed = true;
      }
      if (p.immediateSessionId != rec.immediateSessionId) {
        p.immediateSessionId = rec.immediateSessionId;
        changed = true;
      }
      if (p.promoteOnNextBoot != rec.promoteOnNextBoot) {
        p.promoteOnNextBoot = rec.promoteOnNextBoot;
        changed = true;
      }
    }
    return changed;
  }

  void _clearRowRuntime(String pluginId) {
    for (final p in AppState.I.plugins) {
      if (p.runtimeId != pluginId) continue;
      p.runtimeId = null;
      p.manifestDigest = null;
      p.immediateSessionId = null;
      p.promoteOnNextBoot = false;
      p.activation = PluginActivation.disabled;
      // Terminal removal: a removed row must never keep the fail-closed
      // migration marker, which would otherwise surface on an `Available` row.
      p.migrationRequired = false;
      p.runtimeReason = null;
    }
  }

  // ── inspect ───────────────────────────────────────────────────────

  /// Resolves [source] into staging and adapts it into a normalized
  /// manifest. Throws [PluginSourceException] on resolution failure and
  /// [PluginRuntimeException] when the manifest has no usable identity
  /// or carries REQUIRED-severity issues (spec §4.3 fail gate) — staging
  /// is always discarded on failure.
  Future<PluginInspection> inspect(
    PluginSource source, {
    PluginSourceProgress? onProgress,
  }) async {
    final resolver = PluginSourceResolver(
      stagingRootOverride: stagingRootOverrideForTest,
      githubBaseOverride: githubBaseOverrideForTest,
      npmRegistryBaseOverride: npmRegistryBaseOverrideForTest,
    );
    final resolved = await resolver.resolve(source, onProgress: onProgress);
    try {
      final manifest = await const PluginAdapterRegistry().inspect(
        resolved.stagingDir,
      );
      if (!isCanonicalPluginId(manifest.id)) {
        throw const PluginRuntimeException(
          PluginRuntimeErrorCode.identity,
          'plugin manifest has an invalid canonical publisher/name identity - '
          'install refused',
        );
      }
      if (manifest.hasRequiredIssues) {
        final msg = manifest.compatibility
            .where((c) => c.severity == CompatibilitySeverity.required)
            .map((c) => c.message)
            .join('; ');
        throw PluginRuntimeException(
          PluginRuntimeErrorCode.requiredIssue,
          'required compatibility issue(s): $msg',
        );
      }
      return PluginInspection._(manifest: manifest, source: resolved);
    } catch (_) {
      resolved.discard();
      rethrow;
    }
  }

  // ── install (the transaction, spec §5.2) ──────────────────────────

  Future<PluginInstallResult> install(
    PluginInspection inspection, {
    PluginPermissionGrant? grant,
    required PluginInstallOrigin origin,
    String? sessionId,
    void Function(String line)? onProgress,
  }) async {
    PluginInstallResult? result;
    try {
      result = await _install(
        inspection,
        grant: grant,
        origin: origin,
        sessionId: sessionId,
        onProgress: onProgress,
      );
    } catch (_) {
      // Nothing may survive a refused/failed transaction: staging goes,
      // whatever was written is cleaned by the inner rollback paths.
      inspection.source.discard();
      rethrow;
    }
    if (result.status == PluginInstallStatus.failed) {
      inspection.source.discard();
    }
    return result;
  }

  Future<PluginInstallResult> _install(
    PluginInspection inspection, {
    PluginPermissionGrant? grant,
    required PluginInstallOrigin origin,
    String? sessionId,
    void Function(String line)? onProgress,
  }) async {
    final manifest = inspection.manifest;
    final digest = inspection.manifestDigest;

    // Grant gate — fail closed, NEVER auto-approve (spec §5.1).
    if (grant == null) {
      throw const PluginRuntimeException(
        PluginRuntimeErrorCode.capabilityApprovalRequired,
        'capability approval required before install',
      );
    }
    if (grant.pluginId != manifest.id) {
      throw const PluginRuntimeException(
        PluginRuntimeErrorCode.capabilityApprovalRequired,
        'the approved grant belongs to a different plugin',
      );
    }
    if (grant.manifestDigest != digest) {
      throw const PluginRuntimeException(
        PluginRuntimeErrorCode.digestMismatch,
        'the approved grant is for a different manifest version — '
        're-approval required',
      );
    }
    final requested = manifest.requestedCapabilities.isNotEmpty
        ? manifest.requestedCapabilities
        : inferRequestedCapabilities(manifest);
    final missing = [
      for (final c in requested)
        if (!grant.capabilities.contains(c)) c.name,
    ];
    if (missing.isNotEmpty) {
      throw PluginRuntimeException(
        PluginRuntimeErrorCode.capabilityApprovalRequired,
        'capabilities not approved: ${missing.join(', ')}',
      );
    }

    // Dependencies into the versioned private sandbox (spec §6).
    final deps = _deps();
    // A prior install of the SAME id+version must survive a failed
    // reinstall: its content + dependency sandbox share the version
    // directory, so the rollback below may only remove what this
    // transaction created.
    final prior = (await _loadEntries())[manifest.id];
    final overwritesPriorVersion =
        prior != null && prior.version == manifest.version;
    PluginDependencyResult depResult;
    try {
      depResult = await deps.install(manifest, grant, onProgress: onProgress);
    } catch (e) {
      if (!overwritesPriorVersion) {
        await deps.removeVersion(manifest.id, manifest.version);
      }
      return PluginInstallResult.failed(
        error: 'dependency install crashed: $e',
      );
    }
    if (depResult.status == PluginDependencyStatus.failed) {
      // Failed REQUIRED dependency: no partial activation — roll the
      // whole transaction back (files, then nothing else was touched).
      if (!overwritesPriorVersion) {
        await deps.removeVersion(manifest.id, manifest.version);
      }
      final detail = depResult.entries
          .where((e) => e.status == PluginDependencyStatus.failed)
          .map(
            (e) =>
                '${e.name} (${e.kind})${e.error == null ? '' : ': ${e.error}'}',
          )
          .join('; ');
      return PluginInstallResult.failed(
        error: 'required dependency failed: $detail',
      );
    }

    // Activation scope (spec §7): agent installs live ONLY in their
    // session until promotion; screen installs stay pending until the
    // next boot.
    final scope = origin == PluginInstallOrigin.agent
        ? PluginActivation.sessionActive
        : PluginActivation.pendingGlobal;
    final immediateSessionId = origin == PluginInstallOrigin.agent
        ? sessionId
        : null;

    final contentDir = await _contentDirFor(manifest.id, manifest.version);
    final installed = _withRoot(manifest, contentDir.path);
    final record = PluginActivationRecord(
      pluginId: manifest.id,
      state: scope,
      immediateSessionId: immediateSessionId,
      installedBootEpoch: await _readEpoch(),
      promoteOnNextBoot: true,
    );
    var entry = PluginInstallEntry(
      activation: record,
      manifest: installed,
      contentDir: contentDir.path,
      version: manifest.version,
      degradedNames: depResult.degradedNames,
    );

    // Write the self-describing artifacts INTO staging so the committed
    // directory carries its own manifest + activation state (spec §5.2
    // step 6)…
    final staging = inspection.source.stagingDir;
    try {
      File(
        '${staging.path}/$kPluginRuntimeManifestFile',
      ).writeAsStringSync(jsonEncode(installed.toJson()));
      File(
        '${staging.path}/$kPluginRuntimeActivationFile',
      ).writeAsStringSync(jsonEncode(entry.toJson()));
    } catch (e) {
      if (!overwritesPriorVersion) {
        await deps.removeVersion(manifest.id, manifest.version);
      }
      throw PluginRuntimeException(
        PluginRuntimeErrorCode.renameFailed,
        'failed to write transaction artifacts: $e',
      );
    }

    // …register contributions for the permitted scope (spec step 7)…
    PluginContributionRegistry.I.register(
      manifest,
      activation: scope,
      immediateSessionId: immediateSessionId,
    );

    // …then the atomic rename — THE COMMIT POINT (spec step 8). The
    // prior version stays fully intact until the new content is in
    // place; a failure restores it.
    try {
      if (failRenameForTest) {
        throw const FileSystemException('injected rename failure');
      }
      contentDir.parent.createSync(recursive: true);
      final pending = Directory(
        '${contentDir.parent.path}/content-pending-'
        '${inspection.source.transactionId}',
      );
      if (pending.existsSync()) pending.deleteSync(recursive: true);
      staging.renameSync(pending.path);
      final backup = Directory(
        '${contentDir.parent.path}/content-backup-'
        '${inspection.source.transactionId}',
      );
      var hadPrior = false;
      if (contentDir.existsSync()) {
        if (backup.existsSync()) backup.deleteSync(recursive: true);
        contentDir.renameSync(backup.path);
        hadPrior = true;
      }
      try {
        pending.renameSync(contentDir.path);
      } catch (e) {
        if (hadPrior) {
          try {
            backup.renameSync(contentDir.path);
          } catch (_) {}
        }
        try {
          if (pending.existsSync()) pending.deleteSync(recursive: true);
        } catch (_) {}
        rethrow;
      }
      if (hadPrior) {
        try {
          if (backup.existsSync()) backup.deleteSync(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      PluginContributionRegistry.I.unregisterPlugin(manifest.id);
      // The failed registration above REPLACED the prior version's, so
      // the unregister left the plugin with no contributions at all.
      // Restore the prior entry's registration (same id re-registers in
      // place) so the prior working version stays active in-session —
      // content/record/grant were never touched on this path.
      if (prior != null) {
        PluginContributionRegistry.I.register(
          prior.manifest,
          activation: prior.activation.state,
          immediateSessionId: prior.activation.immediateSessionId,
        );
      }
      if (!overwritesPriorVersion) {
        await deps.removeVersion(manifest.id, manifest.version);
      }
      throw PluginRuntimeException(
        PluginRuntimeErrorCode.renameFailed,
        'atomic commit failed: $e',
      );
    }

    // Re-register with the INSTALLED rootPath: contributions baked with
    // the staging path must never survive the rename.
    PluginContributionRegistry.I.register(
      installed,
      activation: scope,
      immediateSessionId: immediateSessionId,
    );

    // Probe the committed content (spec §5.2 step 5): every roster
    // contribution's declaring file must exist on disk.
    final probeFailures = _probeContent(installed);
    if (probeFailures.isNotEmpty) {
      entry = PluginInstallEntry(
        activation: entry.activation,
        manifest: entry.manifest,
        contentDir: entry.contentDir,
        version: entry.version,
        degradedNames: entry.degradedNames,
        probeFailures: probeFailures,
      );
    }

    final entries = await _loadEntries();
    final old = entries[manifest.id];
    entries[manifest.id] = entry;
    await _saveEntries(entries);

    if (scope == PluginActivation.sessionActive ||
        scope == PluginActivation.globalActive ||
        scope == PluginActivation.degraded) {
      await AppState.I.mountPluginOwnedMcpServers(installed);
    }

    // Prior-version cleanup happens only AFTER the new version is fully
    // committed (a failed upgrade above never reaches this).
    if (old != null && old.contentDir != contentDir.path) {
      try {
        final d = Directory(old.contentDir);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
      await deps.removeVersion(manifest.id, old.version);
    }

    notifyListeners();
    return PluginInstallResult(
      status: entry.isDegraded
          ? PluginInstallStatus.degraded
          : PluginInstallStatus.ok,
      manifest: installed,
      record: record,
      manifestDigest: digest,
      installDir: contentDir.path,
      degradedNames: depResult.degradedNames,
      probeFailures: probeFailures,
      logs: depResult.logs,
    );
  }

  /// Files every roster contribution must have on disk; missing ones are
  /// reported by source-relative path (degraded, never silently dead).
  static List<String> _probeContent(NormalizedPluginManifest m) {
    final missing = <String>[];
    void check(String pluginId, String kind, String path) {
      if (path.isEmpty || !isLexicallySafeRelPath(path)) return;
      if (!File('${m.rootPath}/$path').existsSync()) {
        missing.add('$kind:$path');
      }
    }

    for (final c in m.commands) {
      check(c.pluginId, 'command', c.path);
    }
    for (final s in m.skills) {
      check(s.pluginId, 'skill', s.path);
    }
    for (final a in m.agents) {
      check(a.pluginId, 'agent', a.path);
    }
    return missing;
  }

  // ── boot activation (spec §7) ─────────────────────────────────────

  /// Increments the boot epoch once per AppState-owned boot token,
  /// re-mounts persisted installs, and promotes every valid pending
  /// record (`installedBootEpoch < epoch && promoteOnNextBoot`) to
  /// globalActive/degraded exactly once. Corrupt records never propagate
  /// out of initialize.
  Future<void> activateForBoot({
    bool connectMcp = true,
    Object? bootToken,
    bool reportFailure = false,
  }) {
    final inFlight = _bootActivation;
    if (bootToken != null &&
        inFlight != null &&
        identical(_bootActivationToken, bootToken)) {
      return inFlight;
    }
    // Serialize a genuinely new token behind any in-flight activation so the
    // persisted boot-epoch read-modify-write cannot interleave and double/lose
    // an increment (M5).
    final prior = inFlight;
    late final Future<void> attempt;
    Future<void> run() => _runBootActivation(
      connectMcp: connectMcp,
      bootToken: bootToken,
      reportFailure: reportFailure,
    );
    final chained = prior == null
        ? run()
        : prior.catchError((Object _) {}).then((_) => run());
    attempt = chained.whenComplete(() {
      if (identical(_bootActivation, attempt)) {
        _bootActivation = null;
        _bootActivationToken = null;
      }
    });
    if (bootToken != null) {
      _bootActivation = attempt;
      _bootActivationToken = bootToken;
    }
    return attempt;
  }

  Future<void> _runBootActivation({
    required bool connectMcp,
    required Object? bootToken,
    required bool reportFailure,
  }) async {
    try {
      final int epoch;
      if (bootToken != null && identical(_bootToken, bootToken)) {
        epoch = _bootEpoch!;
      } else {
        epoch = (await _readEpoch()) + 1;
        await _writeEpoch(epoch);
      }
      if (bootToken != null && !identical(_bootToken, bootToken)) {
        _bootToken = bootToken;
        _bootEpoch = epoch;
      }
      final entries = await _loadEntries();
      if (entries.isEmpty) return;
      var entriesChanged = false;
      var rowsChanged = false;
      final runtimeRowsToPersist = <String>{};
      for (final id in entries.keys.toList()) {
        var entry = entries[id]!;
        if (entry.disabled) continue;
        if (!await _isContainedEntry(id, entry) ||
            !await _hasEffectiveGrant(id, entry)) {
          await _deactivateRuntime(
            id,
            entries,
            entry,
            activation: PluginActivation.disabled,
          );
          final rec = entries[id]!.activation;
          entriesChanged = true;
          rowsChanged |= _syncRow(rec);
          continue;
        }
        var rec = entry.activation;
        var dirty = false;
        if (rec.promoteOnNextBoot && rec.installedBootEpoch < epoch) {
          rec = PluginActivationRecord(
            pluginId: id,
            state: entry.isDegraded
                ? PluginActivation.degraded
                : PluginActivation.globalActive,
            immediateSessionId: null,
            installedBootEpoch: rec.installedBootEpoch,
            promoteOnNextBoot: false,
          );
          dirty = true;
        }
        switch (rec.state) {
          case PluginActivation.globalActive:
          case PluginActivation.degraded:
          case PluginActivation.sessionActive:
            if (!Directory(entry.contentDir).existsSync()) {
              // Honest failure: committed content vanished (external
              // deletion, cleared storage) — never optimistically mount.
              await _failMissingContent(id, entries, entry);
              rec = entries[id]!.activation;
              entriesChanged = true;
              runtimeRowsToPersist.add(id);
            } else {
              PluginContributionRegistry.I.register(
                entry.manifest,
                activation: rec.state,
                immediateSessionId: rec.immediateSessionId,
              );
              await AppState.I.mountPluginOwnedMcpServers(
                entry.manifest,
                connect: connectMcp,
              );
            }
          case PluginActivation.pendingGlobal:
          case PluginActivation.failed:
          case PluginActivation.disabled:
            break;
        }
        if (dirty) {
          entries[id] = PluginInstallEntry(
            activation: rec,
            manifest: entry.manifest,
            contentDir: entry.contentDir,
            version: entry.version,
            degradedNames: entry.degradedNames,
            probeFailures: entry.probeFailures,
            disabled: entry.disabled,
          );
          entriesChanged = true;
        }
        rowsChanged |= _syncRow(rec);
      }
      if (entriesChanged) await _saveEntries(entries);
      for (final id in runtimeRowsToPersist) {
        await persistRuntimeRow(id);
      }
      if (entriesChanged || rowsChanged) {
        await AppState.I.persistPluginState();
        await AppState.I.persistMergedMarketplaceCatalog();
        AppState.I.refresh();
      }
    } catch (error, stack) {
      // A corrupt record must never brick the boot.
      if (reportFailure) Error.throwWithStackTrace(error, stack);
    }
  }

  // ── disable / enable / uninstall ──────────────────────────────────

  /// Task 11 (spec §11 Retry action): retry the activation of a plugin
  /// whose last transaction ended `failed` or left it stuck pending.
  /// Re-probes the committed content and re-mounts what exists — a
  /// retry NEVER re-runs the install transaction (that is a fresh
  /// install) and never fabricates success: missing content stays
  /// `failed`.
  Future<PluginActivation> retry(String pluginId) async {
    final entries = await _loadEntries();
    final entry = entries[pluginId];
    if (entry == null) return PluginActivation.failed;
    if (entry.disabled) return PluginActivation.disabled;
    if (!await _isContainedEntry(pluginId, entry) ||
        !await _hasEffectiveGrant(pluginId, entry)) {
      await _deactivateRuntime(
        pluginId,
        entries,
        entry,
        activation: PluginActivation.disabled,
      );
      await _saveEntries(entries);
      await persistRuntimeRow(pluginId);
      return PluginActivation.disabled;
    }
    if (!Directory(entry.contentDir).existsSync()) {
      // Committed content vanished — retry cannot invent it and never
      // re-runs the install transaction: persist honest `failed` and
      // keep the record so the row stays Failed (retry stays available).
      await _failMissingContent(pluginId, entries, entry);
      await _saveEntries(entries, reportFailure: true);
      await persistRuntimeRow(pluginId, reportFailure: true);
      notifyListeners();
      return PluginActivation.failed;
    }
    // Re-probe the COMMITTED content (spec §5.2 step 5) — never
    // re-resolve the source, never reinstall dependencies. Fresh probe
    // failures persist as degraded honesty; scope transitions below.
    final probeFailures = _probeContent(entry.manifest);
    final degraded = entry.degradedNames.isNotEmpty || probeFailures.isNotEmpty;
    var rec = entry.activation;
    if (rec.state == PluginActivation.disabled) {
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: degraded
            ? PluginActivation.degraded
            : PluginActivation.globalActive,
        installedBootEpoch: rec.installedBootEpoch,
      );
    } else if (rec.promoteOnNextBoot &&
        rec.installedBootEpoch < await _readEpoch()) {
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: degraded
            ? PluginActivation.degraded
            : PluginActivation.globalActive,
        immediateSessionId: null,
        installedBootEpoch: rec.installedBootEpoch,
        promoteOnNextBoot: false,
      );
    } else if (rec.state == PluginActivation.failed) {
      // Content exists again (restored/external fix): promote to the
      // honest active state. A failed record never carries a session —
      // promotion clears any stale session binding and the flag.
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: degraded
            ? PluginActivation.degraded
            : PluginActivation.globalActive,
        immediateSessionId: null,
        installedBootEpoch: rec.installedBootEpoch,
        promoteOnNextBoot: false,
      );
    }
    entries[pluginId] = PluginInstallEntry(
      activation: rec,
      manifest: entry.manifest,
      contentDir: entry.contentDir,
      version: entry.version,
      degradedNames: entry.degradedNames,
      probeFailures: probeFailures,
      disabled: entry.disabled,
    );
    await _saveEntries(entries);
    for (final row in AppState.I.plugins) {
      if (row.runtimeId != pluginId) continue;
      row
        ..enabled = true
        ..migrationRequired = false
        ..runtimeReason = null;
    }
    PluginContributionRegistry.I.register(
      entry.manifest,
      activation: rec.state,
      immediateSessionId: rec.immediateSessionId,
    );
    if (rec.state == PluginActivation.globalActive ||
        rec.state == PluginActivation.degraded ||
        rec.state == PluginActivation.sessionActive) {
      await AppState.I.mountPluginOwnedMcpServers(entry.manifest);
    }
    _syncRow(rec);
    await persistRuntimeRow(pluginId);
    notifyListeners();
    return rec.state;
  }

  /// Unregisters the plugin's contributions and marks the persisted
  /// install disabled (the record survives; [enable] restores it).
  Future<void> disable(String pluginId) async {
    await AppState.I.unmountPluginOwnedMcpServers(pluginId, uninstall: false);
    final entries = await _loadEntries();
    final entry = entries[pluginId];
    if (entry == null) {
      PluginContributionRegistry.I.unregisterPlugin(pluginId);
      return;
    }
    entries[pluginId] = PluginInstallEntry(
      activation: entry.activation,
      manifest: entry.manifest,
      contentDir: entry.contentDir,
      version: entry.version,
      degradedNames: entry.degradedNames,
      probeFailures: entry.probeFailures,
      disabled: true,
    );
    await _saveEntries(entries);
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    for (final p in AppState.I.plugins) {
      if (p.runtimeId == pluginId) {
        p
          ..enabled = false
          ..activation = PluginActivation.disabled;
      }
    }
    await persistRuntimeRow(pluginId);
    notifyListeners();
  }

  /// Re-activates a disabled install, applying any promotion that came
  /// due while it was disabled (spec §7's one-restart rule). A missing
  /// committed content directory persists honest `failed` (never drops
  /// the record, never invents content); content is re-probed so fresh
  /// deletions degrade honestly instead of mounting dead contributions.
  Future<void> enable(String pluginId) async {
    final entries = await _loadEntries();
    final entry = entries[pluginId];
    if (entry == null) return;
    if (!await _isContainedEntry(pluginId, entry) ||
        !await _hasEffectiveGrant(pluginId, entry)) {
      await _deactivateRuntime(
        pluginId,
        entries,
        entry,
        activation: PluginActivation.disabled,
      );
      await _saveEntries(entries);
      await persistRuntimeRow(pluginId);
      notifyListeners();
      return;
    }
    if (!Directory(entry.contentDir).existsSync()) {
      await _failMissingContent(pluginId, entries, entry);
      await _saveEntries(entries, reportFailure: true);
      await persistRuntimeRow(pluginId, reportFailure: true);
      notifyListeners();
      return;
    }
    final probeFailures = _probeContent(entry.manifest);
    final degraded = entry.degradedNames.isNotEmpty || probeFailures.isNotEmpty;
    var rec = entry.activation;
    if (rec.state == PluginActivation.disabled) {
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: degraded
            ? PluginActivation.degraded
            : PluginActivation.globalActive,
        installedBootEpoch: rec.installedBootEpoch,
      );
    } else if (rec.promoteOnNextBoot &&
        rec.installedBootEpoch < await _readEpoch()) {
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: degraded
            ? PluginActivation.degraded
            : PluginActivation.globalActive,
        immediateSessionId: null,
        installedBootEpoch: rec.installedBootEpoch,
        promoteOnNextBoot: false,
      );
    }
    entries[pluginId] = PluginInstallEntry(
      activation: rec,
      manifest: entry.manifest,
      contentDir: entry.contentDir,
      version: entry.version,
      degradedNames: entry.degradedNames,
      probeFailures: probeFailures,
      disabled: false,
    );
    await _saveEntries(entries);
    for (final row in AppState.I.plugins) {
      if (row.runtimeId != pluginId) continue;
      row
        ..enabled = true
        ..migrationRequired = false
        ..runtimeReason = null;
    }
    PluginContributionRegistry.I.register(
      entry.manifest,
      activation: rec.state,
      immediateSessionId: rec.immediateSessionId,
    );
    if (rec.state == PluginActivation.globalActive ||
        rec.state == PluginActivation.degraded ||
        rec.state == PluginActivation.sessionActive) {
      await AppState.I.mountPluginOwnedMcpServers(entry.manifest);
    }
    _syncRow(rec);
    await persistRuntimeRow(pluginId);
    notifyListeners();
  }

  /// Full teardown: registry, committed content, dependency sandbox,
  /// activation record, grant, and plugin-owned secrets (spec §5.1/§9).
  Future<void> uninstall(String pluginId) async {
    await AppState.I.unmountPluginOwnedMcpServers(pluginId, uninstall: true);
    // Durable status is removed even when there is no activation entry left.
    await PluginRuntimeStatusStore.I.remove(pluginId);
    final entries = await _loadEntries();
    final entry = entries.remove(pluginId);
    await _saveEntries(entries);
    await _removeRuntimeRow(pluginId);
    PluginContributionRegistry.I.unregisterPlugin(pluginId);
    if (entry != null) {
      try {
        final d = Directory(entry.contentDir);
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
      await _deps().removeVersion(pluginId, entry.version);
    }
    await PluginPermissionStore().revoke(pluginId);
    _clearRowRuntime(pluginId);
    notifyListeners();
  }

  /// §7 session visibility: delegated to the registry's fail-closed
  /// scope resolution (sessionActive matches ONLY its immediate
  /// session; pendingGlobal/failed/disabled match nobody).
  bool isActiveForSession(String pluginId, String sessionId) =>
      PluginContributionRegistry.I.isPluginActiveForSession(
        pluginId,
        sessionId,
      );
}
