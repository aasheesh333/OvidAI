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
import 'state.dart';

/// Preferences key for the persisted install map (plugin id → entry
/// JSON). Deliberately separate from `ovid_plugin_state_v1` (catalog
/// flags) and `ovid_plugin_grants_v1` (Task 5 approvals) — activation
/// records own their lifecycle.
const String kPluginActivationPrefKey = 'ovid_plugin_activation_v1';

/// Preferences key for the monotonically increasing boot epoch.
const String kPluginBootEpochPrefKey = 'ovid_plugin_boot_epoch_v1';

/// Self-describing transaction artifacts written inside the committed
/// content directory (spec §5.2 step 6).
const String kPluginRuntimeManifestFile = 'ovid-plugin.json';
const String kPluginRuntimeActivationFile = 'ovid-activation.json';

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

  PluginDependencyService _deps() =>
      depsForTest ?? PluginDependencyService(runtimeRootOverride: runtimeRootOverrideForTest);

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
    return Directory('${base.path}/plugin-runtime/$safeId/$safeVersion/content');
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

  Future<void> _saveEntries(Map<String, PluginInstallEntry> entries) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        kPluginActivationPrefKey,
        jsonEncode({
          for (final e in entries.entries) e.key: jsonEncode(e.value.toJson()),
        }),
      );
    } catch (_) {}
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
    );
    final resolved = await resolver.resolve(source, onProgress: onProgress);
    try {
      final manifest = await const PluginAdapterRegistry().inspect(
        resolved.stagingDir,
      );
      if (manifest.id.isEmpty) {
        throw const PluginRuntimeException(
          PluginRuntimeErrorCode.identity,
          'plugin manifest has no canonical publisher/name identity — '
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
      depResult = await deps.install(
        manifest,
        grant,
        onProgress: onProgress,
      );
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
      File('${staging.path}/$kPluginRuntimeManifestFile').writeAsStringSync(
        jsonEncode(installed.toJson()),
      );
      File('${staging.path}/$kPluginRuntimeActivationFile').writeAsStringSync(
        jsonEncode(entry.toJson()),
      );
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

  /// Increments the boot epoch EXACTLY once per `AppState._initialize`,
  /// re-mounts persisted installs, and promotes every valid pending
  /// record (`installedBootEpoch < epoch && promoteOnNextBoot`) to
  /// globalActive/degraded exactly once. Corrupt records never propagate
  /// out of initialize.
  Future<void> activateForBoot() async {
    try {
      final epoch = (await _readEpoch()) + 1;
      await _writeEpoch(epoch);
      final entries = await _loadEntries();
      if (entries.isEmpty) return;
      var entriesChanged = false;
      var rowsChanged = false;
      for (final id in entries.keys.toList()) {
        final entry = entries[id]!;
        if (entry.disabled) continue;
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
              rec = PluginActivationRecord(
                pluginId: id,
                state: PluginActivation.failed,
                immediateSessionId: null,
                installedBootEpoch: rec.installedBootEpoch,
                promoteOnNextBoot: false,
              );
              dirty = true;
              PluginContributionRegistry.I.unregisterPlugin(id);
            } else {
              PluginContributionRegistry.I.register(
                entry.manifest,
                activation: rec.state,
                immediateSessionId: rec.immediateSessionId,
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
      if (entriesChanged || rowsChanged) {
        await AppState.I.persistPluginState();
        await AppState.I.persistMergedMarketplaceCatalog();
        AppState.I.refresh();
      }
    } catch (_) {
      // A corrupt record must never brick the boot.
    }
  }

  // ── disable / enable / uninstall ──────────────────────────────────

  /// Unregisters the plugin's contributions and marks the persisted
  /// install disabled (the record survives; [enable] restores it).
  Future<void> disable(String pluginId) async {
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
      if (p.runtimeId == pluginId) p.activation = PluginActivation.disabled;
    }
    notifyListeners();
  }

  /// Re-activates a disabled install, applying any promotion that came
  /// due while it was disabled (spec §7's one-restart rule).
  Future<void> enable(String pluginId) async {
    final entries = await _loadEntries();
    final entry = entries[pluginId];
    if (entry == null) return;
    if (!Directory(entry.contentDir).existsSync()) {
      entries.remove(pluginId);
      await _saveEntries(entries);
      _clearRowRuntime(pluginId);
      return;
    }
    var rec = entry.activation;
    if (rec.promoteOnNextBoot &&
        rec.installedBootEpoch < await _readEpoch()) {
      rec = PluginActivationRecord(
        pluginId: pluginId,
        state: entry.isDegraded
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
      probeFailures: entry.probeFailures,
      disabled: false,
    );
    await _saveEntries(entries);
    PluginContributionRegistry.I.register(
      entry.manifest,
      activation: rec.state,
      immediateSessionId: rec.immediateSessionId,
    );
    _syncRow(rec);
    notifyListeners();
  }

  /// Full teardown: registry, committed content, dependency sandbox,
  /// activation record, grant, and plugin-owned secrets (spec §5.1/§9).
  Future<void> uninstall(String pluginId) async {
    final entries = await _loadEntries();
    final entry = entries.remove(pluginId);
    await _saveEntries(entries);
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
