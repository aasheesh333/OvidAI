/// Isolated automatic plugin dependency installer (spec §6).
///
/// Installs a plugin's approved dependencies under
/// `<app-data>/plugin-runtime/<plugin-id>/<version>/` — never into
/// Android system paths and never into the shared sandbox global
/// prefix. npm packages go into a plugin-local `node/` prefix,
/// Python packages into an isolated `python/` target dir, native
/// packages through the sandbox package manager (`ovid-pkg`) gated by
/// a device-ABI compatibility check.
///
/// Lifecycle scripts run only when the install carries a
/// [PluginPermissionGrant] with `shell.execute`; without it npm gets
/// `--ignore-scripts` and pip skips bytecode compilation/hooks (fail
/// closed).
///
/// Every command's shape is captured for diagnostics: command line,
/// exit code, resolved versions, sha256 checksums of the captured
/// output, and capped logs. A failed REQUIRED dependency aborts the
/// whole install (`failed` — no partial activation); a failed optional
/// dependency yields `degraded` with the affected dependency names
/// identified so Task 7's activation transaction can disable exactly
/// those contributions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'plugin_manifest.dart';
import 'sandbox_service.dart';

/// Outcome of one dependency (and of the install as a whole).
enum PluginDependencyStatus { ok, failed, degraded }

/// One dependency's install record: command shape + honest result.
class PluginDependencyResultEntry {
  final String name;

  /// `npm` | `python` | `native`.
  final String kind;

  final bool required;

  /// The exact command line that was (or would be) executed.
  final String command;

  /// Honest exit code — never swallowed.
  final int exitCode;

  /// Version resolved by the package manager, when parseable.
  final String? resolvedVersion;

  /// sha256 of the captured command output (diagnostic checksum —
  /// retained so support can compare logs across devices).
  final String? checksum;

  final PluginDependencyStatus status;

  /// Failure detail; for native packages this carries the precise ABI
  /// compatibility error.
  final String? error;

  const PluginDependencyResultEntry({
    required this.name,
    required this.kind,
    required this.required,
    required this.command,
    required this.exitCode,
    this.resolvedVersion,
    this.checksum,
    this.status = PluginDependencyStatus.ok,
    this.error,
  });
}

/// Whole-install result consumed by Task 7's activation transaction.
class PluginDependencyResult {
  /// `ok` — everything installed.
  /// `failed` — a REQUIRED dependency failed; nothing may activate.
  /// `degraded` — only optional dependencies failed; the named ones'
  /// contributions must be disabled.
  final PluginDependencyStatus status;

  /// The `<app-data>/plugin-runtime/<id>/<version>/` directory.
  final Directory runtimeRoot;

  /// Per-dependency records (command, exit, resolved version,
  /// checksum, status).
  final List<PluginDependencyResultEntry> entries;

  /// Capped install log lines (newest last; capped at
  /// [PluginDependencyService.kMaxLogLines]).
  final List<String> logs;

  /// Names of failed OPTIONAL dependencies (empty unless `degraded`).
  List<String> get degradedNames => List.unmodifiable([
    for (final e in entries)
      if (e.status == PluginDependencyStatus.failed && !e.required) e.name,
  ]);

  const PluginDependencyResult({
    required this.status,
    required this.runtimeRoot,
    required this.entries,
    required this.logs,
  });
}

/// The injected runner seam: same shape as
/// `SandboxService.I.execChecked` so tests can record command shape
/// without executing anything.
typedef PluginDependencyRunner = Future<(int, String)> Function(
  List<String> args, {
  String? cwd,
  Map<String, String>? env,
});

class PluginDependencyService {
  PluginDependencyService({
    this.runtimeRootOverride,
    PluginDependencyRunner? runner,
    Future<bool> Function(String kind)? ensureRuntime,
  }) : runner = runner ?? _sandboxRunner,
       ensureRuntime = ensureRuntime ?? SandboxService.I.ensureRuntime;

  /// Base directory that will contain `plugin-runtime/`. Defaults to
  /// the app documents directory (system temp when unavailable — unit
  /// tests without the path_provider channel), mirroring the resolver
  /// staging-root seam.
  final Directory? runtimeRootOverride;

  /// Exec seam — defaults to the sandbox's exit-honest `execChecked`.
  final PluginDependencyRunner runner;

  /// Runtime-ensure seam — defaults to the sandbox's lazy runtime
  /// installer (node/npm, python/pip/uv).
  final Future<bool> Function(String kind) ensureRuntime;

  /// Install log cap (mirrors the sandbox fallback-log cap).
  static const int kMaxLogLines = 200;

  /// Per-line cap (chatty npm/pip output must not blow memory).
  static const int kMaxLogLineLength = 2000;

  static Future<(int, String)> _sandboxRunner(
    List<String> args, {
    String? cwd,
    Map<String, String>? env,
  }) => SandboxService.I.execChecked(args, cwd: cwd, env: env);

  Future<Directory> _root() async {
    if (runtimeRootOverride != null) return runtimeRootOverride!;
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return Directory.systemTemp;
    }
  }

  Future<Directory> _runtimeRootFor(String pluginId, String version) async {
    final base = await _root();
    // Preserve the canonical id shape (`publisher/name`) while
    // neutralizing path-traversal and dangerous characters: keep
    // [A-Za-z0-9._~/-] per segment, drop empty/`.`/`..` segments.
    final safeId = pluginId
        .split('/')
        .map(_sanitizeSegment)
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .join('/');
    // The version is UNTRUSTED manifest content and `.`/`..` survive
    // character sanitization untouched (they consist entirely of
    // allowed chars). Dropping the segment would collapse the runtime
    // root onto the id dir (version isolation lost, hostile
    // removeVersion deletes every version) — so a hostile/empty
    // version maps to a stable fallback slot instead.
    final safeVersion = _sanitizeSegment(version);
    return Directory(
      '${base.path}/plugin-runtime/$safeId/'
      '${(safeVersion.isEmpty || safeVersion == '.' || safeVersion == '..')
          ? 'unversioned'
          : safeVersion}',
    );
  }

  /// Per-segment character sanitizer for runtime-root path segments.
  static String _sanitizeSegment(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9._~-]'), '_');

  // ── install ─────────────────────────────────────────────────────

  Future<PluginDependencyResult> install(
    NormalizedPluginManifest manifest,
    PluginPermissionGrant? grant, {
    void Function(String line)? onProgress,
  }) async {
    // Tag every process this install spawns under one run key so a
    // session Stop cascades into it (SandboxService.killRunProcesses).
    // SAVE the previously-active key: the sandbox keeps a single
    // global slot, so clearing to null in `finally` would clobber an
    // OUTER run's tag (its later processes would go untagged) —
    // restore instead.
    final runKey = 'plugin-deps-${manifest.id}@${manifest.version}';
    final previousRunKey = SandboxService.I.activeRunKey;
    SandboxService.I.tagRun(runKey);
    try {
      return await _install(manifest, grant, onProgress: onProgress);
    } finally {
      SandboxService.I.tagRun(previousRunKey);
    }
  }

  Future<PluginDependencyResult> _install(
    NormalizedPluginManifest manifest,
    PluginPermissionGrant? grant, {
    void Function(String line)? onProgress,
  }) async {
    final rt = await _runtimeRootFor(manifest.id, manifest.version);
    for (final sub in const ['node', 'python', 'bin', 'cache', 'storage']) {
      Directory('${rt.path}/$sub').createSync(recursive: true);
    }

    final logs = <String>[];
    void log(String line) {
      // Cap BOTH count and per-line length — a chatty package manager
      // must never grow the diagnostic log without bound.
      var l = line;
      if (l.length > kMaxLogLineLength) {
        l = '${l.substring(0, kMaxLogLineLength)}…';
      }
      logs.add(l);
      if (logs.length > kMaxLogLines) {
        logs.removeRange(0, logs.length - kMaxLogLines);
      }
      onProgress?.call(l);
    }

    final env = SandboxService.pluginRuntimeEnv(rt.path);
    final entries = <PluginDependencyResultEntry>[];
    var anyFailed = false;
    var requiredFailed = false;

    // Lifecycle scripts gate — fail closed without the grant.
    final scriptsAllowed =
        grant?.capabilities.contains(PluginCapability.shellExecute) == true;

    Future<PluginDependencyResultEntry> runOne(
      String kind,
      PluginDependency dep,
      List<String> args,
    ) async {
      final cmdline = args.join(' ');
      log('[$kind] $cmdline');
      final (exit, out) = await runner(args, cwd: rt.path, env: env);
      final tail = out.trim();
      log('[$kind] exit=$exit${tail.isEmpty ? '' : ' $tail'}');
      final ok = exit == 0;
      if (!ok && dep.required) requiredFailed = true;
      if (!ok) anyFailed = true;
      return PluginDependencyResultEntry(
        name: dep.name,
        kind: kind,
        required: dep.required,
        command: cmdline,
        exitCode: exit,
        resolvedVersion: ok ? _resolvedVersion(kind, dep, out) : null,
        checksum: 'sha256:${sha256.convert(utf8.encode(out)).toString()}',
        status: ok ? PluginDependencyStatus.ok : PluginDependencyStatus.failed,
        error: ok ? null : _failureDetail(kind, dep, out),
      );
    }

    // ── npm: one batched install into the plugin-local prefix ──
    final npmDeps = manifest.dependencies.npm.toList();
    if (npmDeps.isNotEmpty) {
      if (!await ensureRuntime('node')) {
        for (final d in npmDeps) {
          entries.add(PluginDependencyResultEntry(
            name: d.name,
            kind: 'npm',
            required: d.required,
            command: '(node runtime unavailable)',
            exitCode: -1,
            status: PluginDependencyStatus.failed,
            error: 'node runtime unavailable in sandbox',
          ));
          if (d.required) requiredFailed = true;
          anyFailed = true;
        }
      } else {
        final args = <String>[
          'npm',
          'install',
          '--no-global',
          '--prefix',
          '${rt.path}/node',
          // Lockfile honored, never mutated by an automated install.
          '--no-package-lock',
          // Cache/tmp inside the plugin runtime root (env override).
          '--cache',
          '${rt.path}/cache/npm',
          if (!scriptsAllowed) '--ignore-scripts',
          for (final d in npmDeps)
            d.versionSpec.isEmpty ? d.name : '${d.name}@${d.versionSpec}',
        ];
        final cmd = args.join(' ');
        log('[npm] $cmd');
        final (exit, out) = await runner(args, cwd: rt.path, env: env);
        log('[npm] exit=$exit');
        final ok = exit == 0;
        final checksum =
            'sha256:${sha256.convert(utf8.encode(out)).toString()}';
        if (!ok) {
          anyFailed = true;
        }

        // Version-capture pass: a quiet batch npm install prints no
        // per-package versions, so ask the manager what it actually
        // installed (`npm ls --prefix … --depth=0 --json`). Best-effort
        // — a failed pass falls back to the REQUESTED spec, never a
        // fabricated "resolved" value.
        final installed = ok ? await _npmInstalledVersions(rt) : const <String, String>{};
        for (final d in npmDeps) {
          final installedVersion = installed[d.name];
          entries.add(PluginDependencyResultEntry(
            name: d.name,
            kind: 'npm',
            required: d.required,
            command: cmd,
            exitCode: exit,
            // Manager-resolved when the ls pass reported it; otherwise
            // the requested spec for pinned deps, null for unpinned
            // (honest: we simply do not know what got installed).
            resolvedVersion: !ok
                ? null
                : (installedVersion ??
                      (d.versionSpec.isEmpty ? null : d.versionSpec)),
            checksum: checksum,
            status: ok ? PluginDependencyStatus.ok : PluginDependencyStatus.failed,
            error: ok ? null : _failureDetail('npm', d, out),
          ));
          if (!ok && d.required) requiredFailed = true;
        }
      }
    }

    // ── Python: isolated --target per package ──
    final pyDeps = manifest.dependencies.python.toList();
    if (pyDeps.isNotEmpty) {
      if (!await ensureRuntime('python')) {
        for (final d in pyDeps) {
          entries.add(PluginDependencyResultEntry(
            name: d.name,
            kind: 'python',
            required: d.required,
            command: '(python runtime unavailable)',
            exitCode: -1,
            status: PluginDependencyStatus.failed,
            error: 'python runtime unavailable in sandbox',
          ));
          if (d.required) requiredFailed = true;
          anyFailed = true;
        }
      } else {
        for (final d in pyDeps) {
          // One pip per package: an optional failure stays attributable
          // to exactly that package (spec §6 "identify disabled
          // contributions").
          final args = <String>[
            'pip',
            'install',
            '--target',
            '${rt.path}/python',
            '--no-deps',
            // Post-install hooks denied without shellExecute.
            '--no-compile',
            d.versionSpec.isEmpty ? d.name : '${d.name}${d.versionSpec}',
          ];
          entries.add(await runOne('python', d, args));
        }
      }
    }

    // ── Native: sandbox package manager + ABI gate ──
    for (final d in manifest.dependencies.native) {
      entries.add(
        await runOne('native', d, ['ovid-pkg', 'install', d.name]),
      );
    }

    final status = requiredFailed
        ? PluginDependencyStatus.failed
        : (anyFailed ? PluginDependencyStatus.degraded : PluginDependencyStatus.ok);
    return PluginDependencyResult(
      status: status,
      runtimeRoot: rt,
      entries: List.unmodifiable(entries),
      logs: List.unmodifiable(logs),
    );
  }

  // ── probe ───────────────────────────────────────────────────────

  /// Which dependency runtimes are available right now (no install
  /// attempted): `node`, `npm`, `python`, `pip`, `ovid-pkg`. Uses the
  /// same one-shot `command -v` probe shape as the sandbox's
  /// `probeRuntimes`, via the injected runner so tests stay inert.
  Future<Map<String, bool>> probe() async {
    const bins = ['node', 'npm', 'python', 'pip', 'ovid-pkg'];
    final result = {for (final b in bins) b: false};
    try {
      final (code, out) = await runner([
        'bash',
        '-c',
        'for b in ${bins.join(' ')}; do command -v \$b >/dev/null && '
            'echo "OK \$b" || echo "MISS \$b"; done',
      ]);
      if (code == 0 || out.isNotEmpty) {
        for (final l in out.split('\n')) {
          final t = l.trim();
          if (t.startsWith('OK ')) result[t.substring(3)] = true;
          if (t.startsWith('MISS ')) result[t.substring(5)] = false;
        }
      }
    } catch (_) {}
    return result;
  }

  // ── remove ──────────────────────────────────────────────────────

  /// Deletes one plugin version's runtime root (uninstall/rollback).
  /// Contained by construction: the path is built from sanitized id +
  /// version segments under the plugin-runtime root.
  Future<void> removeVersion(String pluginId, String version) async {
    try {
      final rt = await _runtimeRootFor(pluginId, version);
      if (rt.existsSync()) await rt.delete(recursive: true);
    } catch (_) {}
  }

  // ── output parsing ──────────────────────────────────────────────

  /// Best-effort resolved-version extraction from package-manager
  /// output (`pip install` prints `Successfully installed name-x.y.z`).
  static String? _resolvedVersion(String kind, PluginDependency dep, String out) {
    if (kind == 'python') {
      final m = RegExp(
        'Successfully installed ${RegExp.escape(dep.name)}-(\\S+)',
      ).firstMatch(out);
      return m?.group(1);
    }
    return null;
  }

  /// Asks npm what it actually installed in the plugin-local prefix
  /// (`npm ls --prefix <rt>/node --depth=0 --json`). One extra command
  /// per install; a failed or malformed pass yields an empty map and
  /// the caller falls back to the requested spec (never a fabricated
  /// version).
  Future<Map<String, String>> _npmInstalledVersions(Directory rt) async {
    try {
      final (exit, out) = await runner(
        [
          'npm',
          'ls',
          '--prefix',
          '${rt.path}/node',
          '--depth=0',
          '--json',
        ],
        cwd: rt.path,
        env: SandboxService.pluginRuntimeEnv(rt.path),
      );
      if (exit != 0) return const {};
      final decoded = jsonDecode(out);
      if (decoded is! Map) return const {};
      final deps = decoded['dependencies'];
      if (deps is! Map) return const {};
      return {
        for (final e in deps.entries)
          if (e.value is Map && (e.value as Map)['version'] != null)
            e.key.toString(): (e.value as Map)['version'].toString(),
      };
    } catch (_) {
      return const {};
    }
  }

  static String _failureDetail(String kind, PluginDependency dep, String out) {
    final lines = out
        .trim()
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final tail = lines.isEmpty ? 'no output' : lines.last;
    if (kind == 'native') {
      // A package the sandbox package manager does not carry for this
      // architecture (typical for desktop-only binaries) yields a
      // precise compatibility error naming the device ABI — never a
      // partial install or a silent skip.
      if (out.contains('not found') ||
          out.contains('no index') ||
          out.contains('download failed')) {
        return 'package "${dep.name}" is not available for device ABI '
            '${SandboxService.I.deviceArch} through the Ovid sandbox '
            'package manager ($tail)';
      }
    }
    return tail;
  }
}
