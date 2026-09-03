import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// ═══════════════════════════════════════════════════════════════════
/// NATIVE BIONIC SANDBOX — Termux-style architecture, NO proot.
/// ═══════════════════════════════════════════════════════════════════
/// The agent-essential payload (bash/dash/coreutils/apt/dpkg/tar/curl/
/// zstd/gpgv + their shared libs + apt methods + SYMLINKS.txt + terminfo)
/// ships inside the APK as `jniLibs/<abi>/libovid_bootstrap.so` — a plain
/// zip with a `.so` name.  Android's PackageManager extracts it to
/// `nativeLibraryDir` WITH exec permission on every version (W^X-safe,
/// Android 6→15+); AAB splits deliver only the device's ABI.
///
/// First Studio open installs it:
///   read the .so bytes → unzip into `<files>/sandbox-staging`
///   → chmod bin/, lib/apt/methods/ executable
///   → create symlinks from SYMLINKS.txt (sh→dash, ls→coreutils, …)
///   → rename staging → `<files>/sandbox`  (the $PREFIX)
///
/// Exec runs `$PREFIX/bin/bash -lc <cmd>` with the Termux environment:
///   PREFIX, HOME, TMPDIR, PATH, LD_LIBRARY_PATH, TERM, and
///   LD_PRELOAD=$PREFIX/lib/libtermux-exec-direct-ld-preload.so
/// The LD_PRELOAD shim (termux-exec) reads TERMUX__PREFIX and redirects
/// the hardcoded /data/data/com.termux paths baked into the binaries to
/// OUR prefix — so no binary patching is ever needed.
///
/// Compatibility: native sandbox needs Android 7+ (API 24) like current
/// Termux.  On API 23 (Android 6) the phone-terminal tier (toybox) is
/// used — it needs no install.  A lazy proot-Ubuntu fallback exists ONLY
/// for glibc-only commands that fail natively (logged, on-demand).
class SandboxService {
  SandboxService._();
  static final SandboxService I = SandboxService._();

  // ── Prefix layout ──────────────────────────────────────────────────
  Directory? _prefix; // <files>/sandbox   (the $PREFIX)
  bool _installed = false;
  bool _checked = false;

  bool get isInstalled => _installed;

  /// Public paths — MCP spawns servers through these.
  String? get prefixPath => _prefix?.path;
  String? get bashPath => _prefix != null ? '${_prefix!.path}/bin/bash' : null;

  // Legacy accessors kept so older call sites compile (MCP checks them).
  Directory? get root => _prefix;
  Directory? get rootfs => _prefix;
  String? get prootPath => bashPath;

  // ── Lazy proot fallback state (on-demand only) ─────────────────────
  final List<Map<String, String>> _fallbackLog = [];
  List<Map<String, String>> get fallbackLog => List.unmodifiable(_fallbackLog);

  static const _nativeChannel = MethodChannel('ovid/native');

  /// Jail working path inside the sandbox (matches our own /work layout).
  static const jailWorkPath = '/work';

  // ── Device arch (Termux-style: engine arch is the source of truth) ──
  String get _deviceArch {
    final v = Platform.version.toLowerCase();
    // x86_64 first — an emulator/Chromebook must NOT be mapped to arm64
    // (that was the "Permission denied" on bash exec: wrong-ISA payload).
    if (v.contains('android_x64') || v.contains('x86_64')) return 'x86_64';
    if (v.contains('android_arm64') || v.contains('aarch64')) {
      return 'arm64';
    }
    if (v.contains('android_arm') ||
        v.contains('armv7') ||
        v.contains('armv8') ||
        v.contains('armeabi')) {
      return 'arm';
    }
    try {
      final r = Process.runSync('/system/bin/getprop', ['ro.product.cpu.abi']);
      final abi = r.stdout.toString().trim().toLowerCase();
      if (abi.contains('arm64')) return 'arm64';
      if (abi.contains('x86_64')) return 'x86_64';
      if (abi.contains('arm')) return 'arm';
    } catch (_) {}
    return 'arm64';
  }

  String get deviceArch => _deviceArch;

  // ── Per-session workspaces ─────────────────────────────────────────
  String workDirNameFor(String sessionSandboxId) => 'ws_$sessionSandboxId';

  Future<Directory> workDirFor(String sessionSandboxId) async {
    final root = await _ensureFilesRoot();
    final d = Directory('${root.path}/workspaces/ws_$sessionSandboxId');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Sync view of a session workspace (for @file pickers that cannot
  /// await). Returns the cached-resolved path when available, else a
  /// best-guess Directory that may not exist yet (the picker filters by
  /// existsSync, so this is safe).
  Directory workDirForSync(String sessionSandboxId) {
    if (_syncRoot != null) {
      return Directory('${_syncRoot!.path}/workspaces/ws_$sessionSandboxId');
    }
    return Directory('workspaces/ws_$sessionSandboxId');
  }

  Directory? _syncRoot;

  /// Warm the sync root (call once at app start; safe to repeat).
  Future<void> warmSyncRoot() async {
    _syncRoot ??= await _ensureFilesRoot();
  }

  /// Delete a session's workspace (session deleted → files go too).
  Future<void> deleteWorkspace(String sessionSandboxId) async {
    try {
      final root = await _ensureFilesRoot();
      final d = Directory('${root.path}/workspaces/ws_$sessionSandboxId');
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Storage-quota housekeeping (DSH Part 5 parity):
  /// 1. Orphan sweep — delete ws_* dirs with no matching session id.
  /// 2. LRU eviction — oldest-accessed workspace dirs go when the
  ///    workspaces root exceeds [maxBytes]; active sessions are spared.
  ///    DSH runs this per-session at 500MB; we run the same policy over
  ///    the whole workspaces root on launch.
  Future<void> enforceWorkspaceQuota({
    required Set<String> activeSandboxIds,
    int maxBytes = 500 * 1024 * 1024,
    int graceDays = 30,
  }) async {
    try {
      final root = await _ensureFilesRoot();
      final wsRoot = Directory('${root.path}/workspaces');
      if (!wsRoot.existsSync()) return;

      // 1. Orphan sweep.
      final dirs = wsRoot
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith('ws_'))
          .toList();
      for (final d in dirs) {
        final id = d.path.split('/').last.substring(3);
        if (!activeSandboxIds.contains(id)) {
          try {
            await d.delete(recursive: true);
          } catch (_) {}
        }
      }

      // 2. Size + LRU.
      final byAccess = <(Directory, DateTime, int)>[];
      var total = 0;
      for (final d in dirs.where(
        (d) => activeSandboxIds.contains(d.path.split('/').last.substring(3)),
      )) {
        final stat = d.statSync();
        var size = 0;
        try {
          for (final e in d.listSync(recursive: true, followLinks: false)) {
            if (e is File) {
              try {
                size += e.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
        total += size;
        byAccess.add((d, stat.accessed, size));
      }
      if (total <= maxBytes) return;

      byAccess.sort((a, b) => a.$2.compareTo(b.$2)); // oldest first
      final cutoff = DateTime.now().subtract(Duration(days: graceDays));
      for (final (d, accessed, size) in byAccess) {
        if (total <= maxBytes) break;
        // Spare anything accessed inside the grace window.
        if (accessed.isAfter(cutoff)) break;
        try {
          await d.delete(recursive: true);
          total -= size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ── Files root ─────────────────────────────────────────────────────
  Future<Directory> _ensureFilesRoot() async {
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = Directory.systemTemp; // unit tests lack path_provider
    }
    if (!base.existsSync()) base.createSync(recursive: true);
    return base;
  }

  // ═════════════════════════════════════════════════════════════════
  // CHECK EXISTING — sandbox prefix already installed?
  // ═════════════════════════════════════════════════════════════════
  Future<bool> checkExisting() async {
    if (_checked) return _installed;
    _checked = true;
    try {
      final files = await _ensureFilesRoot();
      final prefix = Directory('${files.path}/sandbox');
      final bash = File('${prefix.path}/bin/bash');
      final coreutils = File('${prefix.path}/bin/coreutils');
      final ldPreload = File(
        '${prefix.path}/lib/libtermux-exec-direct-ld-preload.so',
      );
      if (bash.existsSync() &&
          coreutils.existsSync() &&
          ldPreload.existsSync()) {
        _prefix = prefix;
        _installed = true;
        // Existing installs may predate the apt-CA fix: re-assert the
        // CA bundle + apt config on every boot so apt/git over HTTPS
        // keep working without a reinstall.
        _writeAptConfig(prefix);
        _ensureTlsConfig(prefix);
        _probePythonPath();
        // Self-heal (PR22): installs made by older builds can be missing
        // the usr/ compat symlink, unpatched shebangs ($PREFIX/usr/bin/env
        // → "bad interpreter"), lost exec bits, or broken libz links.
        // Idempotent, best-effort — never blocks the boot.
        await _selfHealSandbox(prefix);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // INSTALL — extract the bundled libovid_bootstrap.so payload.
  // ═════════════════════════════════════════════════════════════════
  Future<void> install({
    required void Function(int phase, double progress, String line) onPhase,
  }) async {
    final files = await _ensureFilesRoot();
    final prefix = Directory('${files.path}/sandbox');
    final staging = Directory('${files.path}/sandbox-staging');

    onPhase(0, 0.0, r'$ ovid sandbox --preflight');
    const buildStamp = String.fromEnvironment(
      'OVID_BUILD',
      defaultValue: 'local-dev',
    );
    onPhase(0, 0.05, 'ovid build ........ $buildStamp');
    final arch = _deviceArch;
    onPhase(0, 0.1, 'device ............ $arch ✓ (native bionic, no proot)');
    if (Platform.version.toLowerCase().contains('android')) {
      // API 24+ required for the native payload (same as current Termux).
      onPhase(0, 0.15, 'runtime ........... native sandbox (API 24+)');
    }

    // ── Locate the bundled bootstrap payload ──
    onPhase(1, 0.0, r'$ read bundled bootstrap (libovid_bootstrap.so)');
    final payloadBytes = await _readBootstrapPayload();
    if (payloadBytes == null) {
      throw Exception(
        'Sandbox payload not found. Reinstall the app — the ABI split '
        'for this device was not included in the install.',
      );
    }
    onPhase(
      1,
      1.0,
      'payload ........... ${(payloadBytes.length / 1024 / 1024).toStringAsFixed(1)} MB ✓',
    );

    // ── Extract zip into staging ──
    onPhase(2, 0.0, 'extracting sandbox payload');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final archive = ZipDecoder().decodeBytes(payloadBytes, verify: false);
    final symlinks = parseSymlinks(archive);
    final count = extractArchive(archive, staging);
    onPhase(2, 1.0, 'extracted ......... $count files ✓');

    // ── chmod executables (TermuxInstaller rule) ──
    onPhase(3, 0.0, 'setting exec bits');
    await _chmodTree(staging, ['bin', 'lib/apt/methods', 'libexec']);
    onPhase(3, 1.0, 'exec bits ......... ✓');

    // ── Symlinks from SYMLINKS.txt ──
    onPhase(4, 0.0, 'linking tool aliases');
    var linked = 0;
    for (final s in symlinks) {
      final target = s.target;
      final linkPath = s.linkPath;
      final link = Link('${staging.path}/$linkPath');
      try {
        link.parent.createSync(recursive: true);
        if (link.existsSync()) link.deleteSync();
        // Only ABSOLUTE termux targets are rewritten — and they are
        // rewritten to the FINAL prefix path (not staging!), because
        // symlinks don't need their target to exist at creation time
        // and the staging dir is renamed away a few lines later.
        // RELATIVE targets (e.g. `libreadline.so.8` for link
        // `./lib/libreadline.so`) are kept EXACTLY as written — resolving
        // them against the link dir would bake in the STAGING path, and
        // the staging→prefix rename would leave every link dangling
        // (that's the "libreadline.so.8 not found" class of failure).
        // TermuxInstaller.java does the same: Os.symlink(oldPath, newPath)
        // with the raw relative target.
        final dest = target.startsWith('/data/data/com.termux/files/usr/')
            ? target.replaceFirst(
                '/data/data/com.termux/files/usr/',
                '${prefix.path}/',
              )
            : target;
        link.createSync(dest);
        linked++;
      } catch (_) {}
    }
    onPhase(4, 1.0, 'linked ............ $linked aliases ✓');

    // ── Config: rewrite Termux prefix → our prefix in text configs ──
    onPhase(5, 0.0, 'configuring prefix');
    _rewritePrefixInConfigs(staging);
    onPhase(5, 1.0, 'prefix configured . ✓');

    // ── Move staging → prefix ──
    if (prefix.existsSync()) prefix.deleteSync(recursive: true);
    staging.renameSync(prefix.path);
    _prefix = prefix;
    _installed = true;

    // ── Create runtime dirs (not in bootstrap payload) ──
    // bash exec uses workingDirectory=$PREFIX/home; without this dir
    // chdir fails with ENOENT → "No such file or directory".
    Directory('${prefix.path}/home').createSync(recursive: true);
    Directory('${prefix.path}/tmp').createSync(recursive: true);
    // ── `usr` compat symlink ──
    // Termux-bundled tooling sometimes hardcodes `<prefix>/usr/bin/...`
    // (npx/npm shebangs from .deb installs, older packages). The payload
    // root IS the "usr" — make `$PREFIX/usr` a self-symlink so
    // `$PREFIX/usr/bin/env` resolves to `$PREFIX/bin/env`.
    try {
      final usr = Link('${prefix.path}/usr');
      if (!usr.existsSync()) usr.createSync('.');
    } catch (_) {}

    // ── Write OUR profile (defense-in-depth) ──
    // Termux's bash has its prefix COMPILED IN, so `bash -l` sources
    // `<termux>/etc/profile` (an unreadable cross-uid path →
    // "Permission denied"). We run non-interactive exec with `-c` (no
    // profile), but the interactive terminal may still want a profile —
    // make sure OUR prefix's etc/profile points at OUR prefix, and drop a
    // bashrc that exports the right PATH/LD_LIBRARY_PATH.
    _writeProfile(prefix);
    // apt/dpkg have Termux's prefix compiled in and LD_PRELOAD redirect is
    // unreliable — give apt an explicit Dir config rooted at OUR prefix.
    _writeAptConfig(prefix);

    // ── Remove stale node tarballs from older installs ──
    // Older builds downloaded node-vXX into HOME instead of using apt —
    // those leftover dirs confuse PATH and waste space.
    _cleanStaleHome(prefix);

    // ── Sanity: run bash --version natively ──
    // execChecked surfaces BOTH the exit code and stderr.  The dynamic
    // linker's "CANNOT LINK EXECUTABLE ... library not found" errors go
    // to stderr with exit 1 — the old exec() swallowed that and reported
    // a false ✓ while every subsequent shell command failed.
    onPhase(6, 0.0, r'$ bash --version (native exec sanity)');
    try {
      final (code, out) = await execChecked([
        'bash',
        '--version',
      ]).timeout(const Duration(seconds: 15));
      if (code != 0) {
        throw Exception(
          'bash --version exited $code: '
          '${out.trim().split('\n').take(2).join(' / ')}',
        );
      }
      final firstLine = out.trim().split('\n').first;
      onPhase(
        6,
        1.0,
        'native exec ....... ✓ ${firstLine.substring(0, firstLine.length.clamp(0, 50))}',
      );
    } catch (e) {
      throw Exception(
        'Sandbox installed but native exec failed: $e. '
        'Report this with your device model.',
      );
    }

    // ── Phase 7: Runtimes — node/npm/npx/pnpm + python/pip/uv ─────────
    // These are REQUIRED for MCP servers (npx/uvx) and for the agent's
    // node/python tooling, so we install them eagerly at first launch and
    // VERIFY each binary actually runs. apt update+install is retried —
    // a single flaky mirror/timeout must not leave the sandbox runtimeless.
    onPhase(7, 0.0, r'$ apt update && apt install runtimes');
    await _installRuntimesWithRetry(onPhase);
  }

  /// Install + verify node/npm/npx/pnpm and python/pip/uv, retrying the
  /// apt steps. Reports progress via [onPhase]. Never throws — on total
  /// failure it logs a clear ⚠ line and leaves the lazy ensureRuntime()
  /// fallback to retry on first use (so the app still opens offline).
  Future<void> _installRuntimesWithRetry(
    void Function(int phase, double progress, String line) onPhase,
  ) async {
    Future<bool> binRuns(String bin, [String args = '--version']) async {
      try {
        final (code, _) = await execChecked([
          'bash',
          '-c',
          '$bin $args 2>&1',
        ]).timeout(const Duration(seconds: 15));
        return code == 0;
      } catch (_) {
        return false;
      }
    }

    // Up to 3 attempts of (apt update && apt install runtimes).
    // git + curl included so the agent has VCS + HTTP tooling out of the box.
    // Every attempt CHECKS the update exit code AND prints its last lines
    // into the log — an empty/failed index used to produce the silent
    // "Unable to locate package git" install failure.
    // zlib: node's dynamic-link dependency — the bootstrap ships the lib
    // but npm/apt-installed node overlays may reference it fresh; keeping
    // the package asserted also guarantees libz.so.1 so-version links.
    // PR30: make + binutils — node-gyp native builds (the reported
    // "node-gyp: Permission denied" class also needs the toolchain
    // present once exec bits are right).
    const pkgs =
        'nodejs npm python python-pip uv git curl zlib make binutils';
    var installed = false;
    for (var attempt = 1; attempt <= 3 && !installed; attempt++) {
      final tag = attempt == 1
          ? r'$ apt update'
          : 'retry $attempt/3 · apt update';
      try {
        onPhase(7, 0.05, tag);
        final (uCode, uOut) = await _aptChecked(
          'update 2>&1',
          timeout: const Duration(minutes: 3),
          onLine: (l) => onPhase(7, 0.05, l),
        );
        if (uCode != 0) {
          final tail = uOut.trim().split('\n').where((l) => l.isNotEmpty);
          onPhase(
            7,
            0.05,
            'apt update failed ($uCode): ${tail.isEmpty ? "no output" : tail.last}',
          );
          // PR30: a failed update means THIS mirror is unusable from
          // this device — rotate NOW so the next attempt (of 3) tries a
          // different mirror instead of burning every retry on the same
          // dead host (the reported 3× "no Release file" on packages-cf).
          _mirrorIdx = (_mirrorIdx + 1) % _aptMirrors.length;
          final prefix0 = _prefix;
          if (prefix0 != null) {
            _writeSourcesList(prefix0, _aptMirrors[_mirrorIdx]);
          }
          onPhase(
            7,
            0.05,
            '[apt] rotated to ${_aptMirrors[_mirrorIdx].split('/')[2]}',
          );
          continue;
        }
        onPhase(7, 0.3, 'apt update ......... ✓');
        onPhase(7, 0.4, '\$ apt install -y $pkgs');
        final (code, out) = await _aptChecked(
          'install -y $pkgs 2>&1',
          timeout: const Duration(minutes: 8),
          onLine: (l) => onPhase(7, 0.4, l),
        );
        installed = code == 0;
        if (installed) {
          // apt path also needs the shebang fix: the debs it installed
          // still contain #!/data/data/com.termux/files/... scripts.
          final prefix = _prefix;
          if (prefix != null) await _patchExtractedShebangs(prefix);
        }
        if (!installed) {
          final lines = out
              .trim()
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .toList();
          onPhase(
            7,
            0.4,
            'apt exit $code — ${lines.isEmpty ? "" : lines.last}',
          );
        }
      } catch (e) {
        onPhase(
          7,
          0.4,
          'attempt $attempt failed: '
          '${e.toString().split('\n').first}',
        );
      }
    }

    // ── Direct .deb download fallback (apt-https transport broken) ──
    // Some devices never complete apt's https method (Cloudflare TLS),
    // making "no Release file" error every retry chain.  curl honors our
    // CA bundle and works — so we fetch the package index + full .deb
    // dependency closure ourselves and extract with a pure-Dart ar parser
    // (dpkg itself can't run — its prefix is the other app's private dir).
    if (!installed) {
      onPhase(7, 0.45, '[deb] apt failed — fetching packages directly…');
      try {
        installed = await _debDirectInstall(onPhase, [
          'nodejs',
          'npm',
          'python',
          'python-pip',
          'uv',
          'git',
          'curl',
          'zlib', // PR30: node's link-time dependency (libz.so.1)
        ]);
      } catch (e) {
        onPhase(
          7,
          0.45,
          '[deb] direct fetch failed: ${e.toString().split('\n').first}',
        );
      }
    }

    // ── Post-install config (env-injection targets) ──
    final prefix = _prefix;
    if (prefix != null) {
      _ensureTlsConfig(prefix);
      _ensurePipConfig(prefix);
      _probePythonPath();
    }

    // Verify node + npm/npx.
    if (await binRuns('node')) {
      final nodeOk = await binRuns('node');
      final npmOk = await binRuns('npm');
      final npxOk = await binRuns('npx');
      if (nodeOk && npmOk && npxOk) {
        // pnpm via corepack (bundled with node) — enable + prepare, non-fatal.
        var pnpmNote = 'pnpm ✗';
        try {
          await execChecked([
            'bash',
            '-c',
            'corepack enable 2>&1; corepack prepare pnpm@latest --activate 2>&1',
          ]).timeout(const Duration(minutes: 2));
          pnpmNote = await binRuns('pnpm') ? 'pnpm ✓' : 'pnpm ✗';
        } catch (_) {}
        onPhase(7, 0.7, 'node ................ ✓ node · npm · npx · $pnpmNote');
      } else {
        onPhase(7, 0.7, 'node ................ ⚠ node ok but npm/npx missing');
      }
    } else {
      onPhase(
        7,
        0.7,
        'node ................ ⚠ not installed (offline?) — '
        'will retry on first MCP connect',
      );
    }

    // Verify python + pip + uvx.
    final pyOk = await binRuns('python');
    final pipOk = await binRuns('pip');
    final uvxOk = await binRuns('uvx');
    onPhase(
      8,
      1.0,
      pyOk && uvxOk
          ? 'python .............. ✓ python · ${pipOk ? "pip" : "pip✗"} · uvx ✓'
          : 'python .............. ⚠ ${pyOk ? "partial (uv missing)" : "not installed"} — will retry on first uvx MCP connect',
    );

    // ── Bootstrap self-test (DSH Part 3) — EXECUTE, never just probe ──
    // git/curl were previously only `command -v`-probed; a broken exec-path
    // or missing libexec went unnoticed until a real clone failed mid-task.
    await selfTest(onPhase);
  }

  /// DSH Part 3 self-test: run each critical runtime and CHECK its
  /// behavior, not just its existence. Results stream to the install log;
  /// failures are warnings (health screen + next-connect retry cover them)
  /// except GIT_EXEC_PATH mismatch — the #1 real-device git failure.
  Future<void> selfTest(
    void Function(int phase, double progress, String line) onPhase,
  ) async {
    if (_prefix == null) return;

    // git — version + exec-path MUST point inside our prefix.
    try {
      final (_, ver) = await execChecked(['bash', '-c', 'git --version 2>&1'])
          .timeout(const Duration(seconds: 30));
      if (!ver.contains('git version')) {
        onPhase(8, 1.0, 'git ...............  ⚠ unexpected version output: '
            '${ver.trim().split('\n').last}');
      }
    } catch (e) {
      onPhase(8, 1.0, 'git ...............  ⚠ exec failed: '
          '${e.toString().split('\n').first}');
    }
    String? execPath;
    try {
      final (_, ep) = await execChecked(['bash', '-c', 'git --exec-path 2>&1'])
          .timeout(const Duration(seconds: 30));
      execPath = ep.trim();
    } catch (_) {}
    final prefixPath = _prefix!.path;
    if (execPath == null || execPath.isEmpty) {
      onPhase(8, 1.0, 'git exec-path .....  ⚠ not reported');
    } else if (!execPath.startsWith(prefixPath)) {
      // Compiled-in Termux prefix leak — clone/push WILL fail with
      // "'remote-https' is not a git command". GIT_EXEC_PATH env fix
      // (set in _sandboxEnv) covers spawned processes; log loudly anyway.
      onPhase(
        8,
        1.0,
        'git exec-path .....  ⚠ points at $execPath — env override active '
            '(GIT_EXEC_PATH=$prefixPath/libexec/git-core)',
      );
    } else {
      onPhase(8, 1.0, 'git exec-path .....  ✓ $execPath');
    }

    // curl — must execute and report a version.
    try {
      final (_, v) = await execChecked(['bash', '-c', 'curl --version 2>&1'])
          .timeout(const Duration(seconds: 30));
      onPhase(
        8,
        1.0,
        v.trimLeft().startsWith('curl')
            ? 'curl ..............  ✓'
            : 'curl ..............  ⚠ ${v.trim().split('\n').last}',
      );
    } catch (e) {
      onPhase(8, 1.0, 'curl ..............  ⚠ exec failed');
    }

    // npm ping — registry reachability over our TLS config.
    try {
      final (_, out) = await execChecked(['bash', '-c', 'npm ping 2>&1'])
          .timeout(const Duration(seconds: 45));
      final l = out.toLowerCase();
      final ok = l.contains('pong') || l.contains('success');
      final lastLine = out
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .lastOrNull;
      onPhase(
        8,
        1.0,
        ok
            ? 'npm registry ......  ✓ ping ok'
            : 'npm registry ......  ⚠ ${lastLine ?? 'no output'}',
      );
    } catch (_) {
      onPhase(8, 1.0, 'npm registry ......  ⚠ ping failed/timeout');
    }
  }

  /// A parsed symlink: `target` is what the link points to, `linkPath` is
  /// where the link is created (both as they appear in SYMLINKS.txt).
  /// TermuxInstaller.java uses `List<Pair<String,String>>` — a Map would
  /// collapse duplicate targets (1177 lines → 220 unique targets; e.g.
  /// `coreutils` is the target of 100 different bin/ links).  The record
  /// list keeps every entry.
  static List<({String target, String linkPath})> parseSymlinks(
    Archive archive,
  ) {
    final file = archive.findFile('SYMLINKS.txt');
    if (file == null) return const [];
    final txt = utf8.decode(file.content as List<int>);
    final symlinks = <({String target, String linkPath})>[];
    for (final line in const LineSplitter().convert(txt)) {
      final parts = line.split('←');
      if (parts.length == 2) {
        symlinks.add((target: parts[0], linkPath: parts[1]));
      }
    }
    return symlinks;
  }

  /// Extract [archive] into [staging].  Handles directory entries (zip
  /// entries with the directory bit set / trailing slash) as Directory
  /// creations — treating them as files throws errno 21 (EISDIR) on
  /// Android.  SYMLINKS.txt is consumed separately, not extracted.
  /// Returns the number of regular files written.
  static int extractArchive(Archive archive, Directory staging) {
    var count = 0;
    for (final f in archive.files) {
      final name = f.name;
      if (name == 'SYMLINKS.txt') continue;
      if (f.isFile) {
        final target = File('${staging.path}/$name');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(f.content as List<int>);
        count++;
      } else {
        // Directory entry — create as Directory, not File (errno 21 fix).
        final dir = Directory('${staging.path}/$name');
        dir.createSync(recursive: true);
      }
    }
    return count;
  }

  /// Write a sane `$PREFIX/etc/profile` + `$PREFIX/etc/bash.bashrc` that
  /// export OUR prefix (not Termux's).  The Termux bootstrap ships these
  /// files pointing at /data/data/com.termux/files/usr; our text rewrite
  /// fixes real files, but this guarantees a correct profile regardless of
  /// symlinks/permissions.
  void _writeProfile(Directory prefix) {
    final p = prefix.path;
    final etc = Directory('$p/etc')..createSync(recursive: true);
    final profile =
        '''
# Ovid sandbox profile (overrides Termux bootstrap default).
export PREFIX="$p"
export HOME="\$PREFIX/home"
export TMPDIR="\$PREFIX/tmp"
export PATH="\$PREFIX/bin:\$PREFIX/bin/applets:/system/bin:/system/xbin"
export LD_LIBRARY_PATH="\$PREFIX/lib"
export LANG="en_US.UTF-8"
export TERM="xterm-256color"
export SHELL="\$PREFIX/bin/bash"
# DSH env-injection parity — interactive shells get the same set the
# spawn-level injection provides (GIT_EXEC_PATH, NODE_PATH, npm/python).
export GIT_EXEC_PATH="\$PREFIX/libexec/git-core"
export GIT_CONFIG_NOSYSTEM=1
export NODE_PATH="\$PREFIX/lib/node_modules"
export npm_config_registry="https://registry.npmjs.org/"
export npm_config_cache="\$HOME/.npm"
export npm_config_userconfig="\$HOME/.npmrc"
export PIP_CACHE_DIR="\$HOME/.cache/pip"
''';
    try {
      File('${etc.path}/profile').writeAsStringSync(profile);
    } catch (_) {}
    try {
      File('${etc.path}/bash.bashrc').writeAsStringSync(profile);
    } catch (_) {}
    // Also drop a ~/.bashrc so interactive `bash -i` picks it up.
    try {
      File('$p/home/.bashrc').writeAsStringSync(profile);
    } catch (_) {}
  }

  /// Delete leftover node-vXX dirs that older builds dropped into HOME.
  void _cleanStaleHome(Directory prefix) {
    final home = Directory('${prefix.path}/home');
    if (!home.existsSync()) return;
    try {
      for (final e in home.listSync()) {
        final name = e.path.split('/').last;
        if (name.startsWith('node-v') ||
            name.startsWith('node_') ||
            name == 'node') {
          try {
            e.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _rewritePrefixInConfigs(Directory prefix) {
    const termux = '/data/data/com.termux/files/usr';
    final ours = prefix.path;
    for (final entity in prefix.listSync(recursive: true)) {
      if (entity is! File) continue;
      final p = entity.path;
      // Only patch small text configs (apt, profile) — skip binaries/libs.
      if (!(p.contains('/etc/') || p.contains('/share/termux'))) continue;
      try {
        final size = entity.lengthSync();
        if (size > 256 * 1024) continue;
        final txt = entity.readAsStringSync();
        if (txt.contains(termux)) {
          entity.writeAsStringSync(txt.replaceAll(termux, ours));
        }
      } catch (_) {}
    }
  }

  /// Write an apt config that points EVERY Dir at OUR prefix and export it
  /// via APT_CONFIG.  The apt/dpkg binaries have Termux's prefix COMPILED
  /// IN, and the LD_PRELOAD path-redirect (termux-exec) is blocked by
  /// SELinux on many devices — so apt would otherwise read
  /// /data/data/com.termux/... → "Permission denied" / "no packaging
  /// system".  An explicit Dir tree makes apt fully prefix-independent.
  void _writeAptConfig(Directory prefix) {
    final p = prefix.path;
    final conf =
        '''
// Ovid sandbox apt config — override the compiled-in Termux prefix.
Dir "$p";
Dir::State "$p/var/lib/apt";
Dir::State::status "$p/var/lib/dpkg/status";
Dir::Cache "$p/var/cache/apt";
Dir::Etc "$p/etc/apt";
Dir::Etc::sourcelist "$p/etc/apt/sources.list";
Dir::Etc::sourceparts "$p/etc/apt/sources.list.d";
Dir::Etc::main "$p/etc/apt/apt.conf";
Dir::Etc::parts "$p/etc/apt/apt.conf.d";
Dir::Etc::trusted "$p/etc/apt/trusted.gpg";
Dir::Etc::trustedparts "$p/etc/apt/trusted.gpg.d";
Dir::Bin::dpkg "$p/bin/dpkg";
Dir::Bin::apt-get "$p/bin/apt-get";
Dir::Bin::methods "$p/lib/apt/methods";
Dir::Bin::solvers "$p/lib/apt/solvers";
Dir::Bin::planners "$p/lib/apt/planners";
DPkg::Pre-Install-Pkgs "";
DPkg::Options:: "--root=$p";
DPkg::Options:: "--admindir=$p/var/lib/dpkg";
GPkg::Source::No-Advance "false";
// TLS for apt's https mirror fetch — the prefix-compiled apt method needs
// an explicit CA bundle (Android has no /etc/ssl; the sandbox's bundle
// lives at etc/tls/cert.pem).  Without this every `apt update` errors
// with "certificate" failures on HTTPS mirrors.
Acquire::https::CAInfo "$p/etc/tls/cert.pem";
Acquire::https::CRLFile "$p/etc/tls/cert.pem";
''';
    try {
      final etc = Directory('$p/etc/apt')..createSync(recursive: true);
      File('${etc.path}/ovid-apt.conf').writeAsStringSync(conf);
    } catch (_) {}
    // Point the default apt.conf at ours too (some apt builds read Dir::Etc::main).
    try {
      File('$p/etc/apt/apt.conf').writeAsStringSync(conf);
    } catch (_) {}
    // apt needs the Termux signing keys to verify packages. They ship under
    // share/termux-keyring/*.gpg — link them into trusted.gpg.d so apt's
    // GPGV verification succeeds (otherwise every install is rejected).
    try {
      final keyring = Directory('$p/share/termux-keyring');
      final trusted = Directory('$p/etc/apt/trusted.gpg.d')
        ..createSync(recursive: true);
      if (keyring.existsSync()) {
        for (final k in keyring.listSync()) {
          if (k.path.endsWith('.gpg')) {
            final name = k.path.split('/').last;
            final dest = '${trusted.path}/$name';
            if (!File(dest).existsSync()) {
              try {
                Link(dest).createSync(k.path);
              } catch (_) {
                try {
                  File(k.path).copySync(dest);
                } catch (_) {}
              }
            }
          }
        }
      }
    } catch (_) {}
    // dpkg needs an admindir + a status file to consider packages installed.
    try {
      Directory('$p/var/lib/dpkg').createSync(recursive: true);
      final status = File('$p/var/lib/dpkg/status');
      if (!status.existsSync()) status.writeAsStringSync('');
    } catch (_) {}
    _ensureSourcesList(prefix);
    _ensureCaBundle(prefix);
    _ensureTlsConfig(prefix);
  }

  /// Generate `$prefix/etc/tls/openssl.cnf` (DSH Part 3 parity) — TLSv1.2
  /// + SECLEVEL=1 so node/npm/pip TLS handshakes work on old Android
  /// OpenSSL builds that default to stricter/weaker-mixed configs.
  void _ensureTlsConfig(Directory prefix) {
    try {
      final tls = Directory('${prefix.path}/etc/tls')
        ..createSync(recursive: true);
      final cnf = File('${tls.path}/openssl.cnf');
      if (cnf.existsSync() && cnf.lengthSync() > 0) return;
      cnf.writeAsStringSync('''
# Ovid sandbox TLS config (auto-generated).
# TLSv1.2 floor + SECLEVEL=1: maximum device compatibility for
# node/npm/pip/git/curl HTTPS against modern registries.
openssl_conf = ovid_init

[ovid_init]
ssl_conf = ssl_sect

[ssl_sect]
system_default = system_default_sect

[system_default_sect]
CipherString = DEFAULT@SECLEVEL=1
MinProtocol = TLSv1.2
''');
    } catch (_) {}
  }

  /// pip.conf — keep pip's index/cache/config inside the sandbox HOME.
  void _ensurePipConfig(Directory prefix) {
    try {
      final conf = File('${prefix.path}/etc/pip.conf')
        ..createSync(recursive: true);
      if (conf.existsSync() && conf.lengthSync() > 0) return;
      conf.writeAsStringSync('''
[global]
cache-dir = ${prefix.path}/home/.cache/pip
no-color = true
''');
      final npmrc = File('${prefix.path}/home/.npmrc')
        ..createSync(recursive: true);
      if (npmrc.existsSync() && npmrc.lengthSync() > 0) return;
      npmrc.writeAsStringSync('''
cache=${prefix.path}/home/.npm
update-notifier=false
fund=false
audit=false
''');
    } catch (_) {}
  }

  /// Known-good Termux main-repo mirrors, tried in order.  A dead or stale
  /// mirror manifest causes "E: Unable to locate package git" even when
  /// `apt update` exits 0 — the retry loop rotates to the next mirror.
  /// PR30: +tsinghua/nju (stable, fast in ASIA) — packages-cf proved flaky
  /// on-device ("does not have a Release file" for 3 straight retries).
  static const _aptMirrors = [
    'https://packages-cf.termux.dev/apt/termux-main',
    'https://packages.termux.dev/apt/termux-main',
    'https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main',
    'https://mirror.nju.edu.cn/termux/apt/termux-main',
    'https://termux.librehat.com/apt/termux-main',
    'https://termux.cdn.lumito.net/apt/termux-main',
    'https://termux.astra.in.ua/apt/termux-main',
  ];
  int _mirrorIdx = 0;

  /// Direct .deb pool installer — bypasses apt's https transport entirely.
  /// curl (bundled, works with our CA bundle) fetches the package index +
  /// each .deb from a Termux mirror pool; dpkg then installs the full
  /// dependency closure.  Used when apt repeatedly fails with TLS or
  /// "no Release file" (its methods/https binary is broken on-device).
  ///
  /// [wanted] are the high-level packages (nodejs, python, …); the real
  /// dependency closure (openssl/libcurl/libexpat/…) is resolved from the
  /// parsed Packages index.
  Future<bool> _debDirectInstall(
    void Function(int phase, double progress, String line) onPhase,
    List<String> wanted,
  ) async {
    final prefix = _prefix;
    if (prefix == null) return false;
    final p = prefix.path;
    final arch = _deviceArch == 'arm64' ? 'aarch64' : _deviceArch;
    // ── 1. Fetch + decompress the binary index (mirrors cycled) ──
    File? indexFile;
    String? mirrorUsed;
    for (var i = 0; i < _aptMirrors.length && indexFile == null; i++) {
      final m = _aptMirrors[(_mirrorIdx + i) % _aptMirrors.length];
      onPhase(7, 0.5, '[deb] $m …');
      final (code, out) = await execChecked([
        'bash',
        '-c',
        'mkdir -p "\$PREFIX/var/cache/apt/archives" && '
            'cd "\$PREFIX/var/cache/apt" && '
            'curl -fsSL --retry 2 --connect-timeout 25 '
            '"$m/dists/stable/main/binary-$arch/Packages.gz" -o Packages.gz '
            '&& (gzip -dkf Packages.gz || gunzip -c Packages.gz > Packages) '
            '&& echo INDEX_OK || '
            '(curl -fsSL --retry 2 '
            '"$m/dists/stable/main/binary-$arch/Packages" -o Packages && '
            'echo INDEX_OK)',
      ]).timeout(const Duration(minutes: 3));
      if (code == 0 && out.contains('INDEX_OK')) {
        _mirrorIdx = (_mirrorIdx + i) % _aptMirrors.length;
        mirrorUsed = m;
        indexFile = File('$p/var/cache/apt/Packages');
        onPhase(7, 0.55, '[deb] index ✓ (${m.split('/').last})');
        break;
      }
    }
    if (indexFile == null || mirrorUsed == null) {
      onPhase(7, 0.55, '[deb] index fetch failed on all mirrors');
      return false;
    }

    // ── 2. Parse the index (name → filename + depends) ──
    final text = await indexFile.readAsString();
    final stanzas = text.split(RegExp(r'\n\s*\n'));
    final table =
        <String, ({String filename, List<String> depends, String? sha256})>{};
    for (final stanza in stanzas) {
      String? name, filename, sha256;
      final depends = <String>[];
      for (final line in stanza.split('\n')) {
        if (line.startsWith(' ')) {
          // Continuation line — Depends lists wrap onto these.
          if (depends.isNotEmpty) depends.add(line);
          continue;
        }
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        final field = line.substring(0, colon).trim();
        final value = line.substring(colon + 1).trim();
        switch (field) {
          case 'Package':
            name = value;
            break;
          case 'Filename':
            filename = value;
            break;
          case 'SHA256':
            sha256 = value;
            break;
          case 'Depends':
            depends.add(value);
            break;
        }
      }
      if (name != null && filename != null) {
        table[name] = (filename: filename, depends: depends, sha256: sha256);
      }
    }
    if (table.isEmpty) {
      onPhase(7, 0.55, '[deb] index parse produced 0 packages');
      return false;
    }

    // ── 3. Resolve the dependency closure ──
    // Depends entries: "libicu (>= 77), openssl | libopenssl ..."
    final depNameRe = RegExp('^[a-zA-Z0-9+._-]+');
    final queue = List<String>.from(wanted);
    final closure = <String>{};
    while (queue.isNotEmpty && closure.length < 400) {
      final name = queue.removeLast();
      if (closure.contains(name)) continue;
      final entry = table[name];
      if (entry == null) continue; // virtual / already-base package
      closure.add(name);
      for (final raw in entry.depends) {
        for (final depList in raw.split(',')) {
          // Alternation "a | b | c": take the FIRST alternative that exists
          // in the index (nodejs | nodejs-lts → only nodejs, they conflict).
          String? picked;
          for (final alt in depList.split('|')) {
            final m = depNameRe.firstMatch(alt.trim());
            if (m != null && table.containsKey(m.group(0)!)) {
              picked = m.group(0)!;
              break;
            }
          }
          if (picked != null) queue.add(picked);
        }
      }
    }
    // Only packages actually in the index get downloaded.
    final toFetch = closure.where(table.containsKey).toList();
    onPhase(7, 0.6, '[deb] ${toFetch.length} packages in closure');

    // ── 4. Download every .deb via curl ──
    final archives = '$p/var/cache/apt/archives';
    var downloaded = 0;
    for (final name in toFetch) {
      final fn = table[name]!.filename;
      final debFile = File('$archives/${fn.split('/').last}');
      if (debFile.existsSync() && debFile.lengthSync() > 1000) {
        downloaded++;
        continue;
      }
      final (code, _) = await execChecked([
        'bash',
        '-c',
        'curl -fsSL --retry 2 --connect-timeout 25 "$mirrorUsed/$fn" '
            '-o "\$PREFIX/var/cache/apt/archives/${fn.split('/').last}"',
      ]).timeout(const Duration(minutes: 5));
      if (code != 0) {
        onPhase(7, 0.65, '[deb] download failed: ${fn.split('/').last}');
        return false;
      }
      // Integrity: the Termux index lists SHA256 per package — a MITM or
      // truncated download that passes curl would otherwise install
      // corrupt binaries into the sandbox.
      final expected = table[name]!.sha256;
      if (expected != null) {
        final (hCode, hOut) = await execChecked([
          'bash',
          '-c',
          'cd "\$PREFIX/var/cache/apt/archives" && '
              'actual=\$(sha256sum "${fn.split('/').last}" | cut -d" " -f1) && '
              '[ "\$actual" = "$expected" ] && echo SHA_OK || '
              'echo "SHA_BAD \$actual"',
        ]).timeout(const Duration(seconds: 30));
        if (hCode != 0 || hOut.contains('SHA_BAD')) {
          onPhase(7, 0.65, '[deb] SHA256 mismatch: ${fn.split('/').last}');
          debFile.deleteSync();
          return false;
        }
      }
      downloaded++;
      if (downloaded % 10 == 0) {
        onPhase(7, 0.65, '[deb] $downloaded/${toFetch.length}…');
      }
    }

    // ── 5. Extract every .deb directly into $PREFIX ──
    // dpkg CANNOT work here: Termux's dpkg has /data/data/com.termux
    // compiled in and always opens THAT config dir → Permission denied
    // (verified on-device, 10+ identical failures).  But a .deb is just
    // an `ar` archive wrapping data.tar.xz — curl/ar need no dpkg.
    // We parse the ar header in Dart, decompress with the bundled xz,
    // and untar straight into our own writable $PREFIX.
    onPhase(7, 0.7, '[deb] extracting $downloaded packages…');
    var extracted = 0;
    for (final name in toFetch) {
      final fn = table[name]!.filename.split('/').last;
      final debPath = '$archives/$fn';
      final deb = File(debPath);
      if (!deb.existsSync()) continue;
      final dataTarXz =
          await _readArMember(deb, 'data.tar.xz') ??
          await _readArMember(deb, 'data.tar.gz');
      if (dataTarXz == null) {
        onPhase(7, 0.72, '[deb] no data.tar in $fn — skipped');
        continue;
      }
      final fmt = dataTarXz.name.endsWith('.xz') ? '-xJf' : '-xzf';
      final tmpTar = '$archives/.data.tar';
      await File(tmpTar).writeAsBytes(dataTarXz.bytes, flush: true);
      // Termux debs contain paths under data/data/com.termux/files/usr/…
      // (derooted Android prefix). Extract to a staging dir, then move the
      // `usr/` subtree up into $PREFIX. Symlinks inside are relative
      // (libzstd.so.1 -> libzstd.so.1.5.7) so they survive the move.
      final stage = '$archives/.stage';
      final (code, out) = await execChecked([
        'bash',
        '-c',
        'rm -rf "$stage" && mkdir -p "$stage" && '
            'tar $fmt "\$PREFIX/var/cache/apt/archives/.data.tar" -C "$stage" && '
            'cp -a "$stage/data/data/com.termux/files/usr/." "\$PREFIX/" && '
            'rm -rf "$stage"'
            ' 2>&1 | tail -3',
      ]).timeout(const Duration(minutes: 3));
      await File(tmpTar).delete().catchError((_) => File(tmpTar));
      if (code != 0) {
        onPhase(
          7,
          0.72,
          '[deb] tar failed on $fn: ${out.trim().split('\n').lastOrNull ?? code}',
        );
        continue;
      }
      extracted++;
    }
    if (extracted == 0) {
      onPhase(7, 0.72, '[deb] nothing extracted — giving up');
      return false;
    }
    onPhase(7, 0.75, '[deb] $extracted/$downloaded packages extracted ✓');

    // ── 5b. Shebang rewrite: extracted SCRIPT bins (npm, npx, uvx…) have
    // "#!/data/data/com.termux/files/usr/bin/env" baked in — the compiled-in
    // Termux prefix — which is another app's private dir → "bad interpreter:
    // Permission denied". Rewrite every shebang mentioning the Termux prefix
    // to OUR prefix (termux-fix-shebang equivalent), then chmod.
    await _patchExtractedShebangs(prefix);

    // ── 6. Idempotent verification ──
    return await runtimesVerified();
  }

  /// Rewrites `#!/data/data/com.termux/files/...` shebangs in extracted
  /// Termux packages to point at OUR sandbox prefix. Runs after BOTH install
  /// paths (apt AND direct-deb) so npm/npx/uvx never hit the cross-app
  /// prefix wall regardless of how they were installed.
  ///
  /// Mapping is the SAME as the symlink phase and the deb file copy:
  /// `/data/data/com.termux/files/usr/X` → `$PREFIX/X` (the Termux payload
  /// root IS the "usr" — our prefix has NO `usr/` directory, so a naive
  /// `files → $PREFIX` rewrite yields `$PREFIX/usr/bin/env`, which never
  /// exists → "bad interpreter: No such file or directory" on every
  /// npm/npx shebang).
  ///
  /// PR31: the previous sed line was MALFORMED — the `;` separator landed
  /// INSIDE the first sed's quoted expression (`"s|…|…|g; `), so sed
  /// exited 2 ("unknown option to s") which `2>/dev/null` swallowed —
  /// the patcher silently never rewrote anything (reported on-device:
  /// npm/npx shebangs still pointing at /data/data/com.termux/.../env →
  /// "Permission denied"). Now: ONE sed with BOTH substitutions (the
  /// /usr/ form first so it wins over the bare-prefix form), and a
  /// VERIFICATION pass that fails loudly when any shebang still
  /// references the Termux app path.
  Future<void> _patchExtractedShebangs(Directory prefix) async {
    final p = prefix.path;
    // One sed, two substitutions separated by `;` INSIDE the single
    // expression (host-verified): /files/usr/ → $p/ first (the payload
    // root IS the usr), then any bare /files/ prefix (legacy scripts).
    // Order matters — the bare form would mangle the usr form's tail.
    final sedExpr = 's|/data/data/com.termux/files/usr/|$p/|g; '
        's|/data/data/com.termux/files|$p|g';
    await execChecked([
      'bash',
      '-c',
      // bin/ first (fast path), then npm's nested lib/node_modules scripts.
      'for dir in "\$PREFIX/bin" "\$PREFIX/lib/node_modules" '
          '"\$PREFIX/lib" "\$PREFIX/etc"; do '
          '[ -d "\$dir" ] || continue; '
          'find "\$dir" -maxdepth 6 -type f ! -name "*.so*" '
          '! -name "*.png" ! -name "*.jpg" ! -name "*.a" '
          '-exec sh -c \'head -c2 "\$1" 2>/dev/null | grep -q "#!" && '
          'sed -i "$sedExpr" "\$1"\' _ {} \\; '
          '2>/dev/null; done; '
          // Exec bits: not just bin/* — npm's node_modules/.bin shims and
          // any nested .bin dir must be executable too, else execve EACCES
          // ("sh: 1: node-gyp: Permission denied").
          'chmod +x "\$PREFIX"/bin/* 2>/dev/null; '
          'find "\$PREFIX/lib/node_modules" -type d -name ".bin" '
          '-exec chmod +x {} + 2>/dev/null; '
          'find "\$PREFIX/lib/node_modules" -type d -name ".bin" '
          '-exec find {} -type f -exec chmod +x {} \\; + 2>/dev/null; '
          'find "\$PREFIX/lib/node_modules" -name "*.sh" '
          '-type f -exec chmod +x {} + 2>/dev/null',
    ]).timeout(const Duration(minutes: 2));
    // Verification (PR31): grep SHEBANG LINES ONLY (head -1) for any
    // remaining Termux app path. Content-level strings are legitimate
    // (configs, docs) and must not trip this. A residual shebang means
    // the patcher failed — report loudly so Health surfaces it (the
    // next self-heal boot re-runs this whole pass).
    final (_, verifyOut) = await execChecked(
      ['bash', '-c', 'cd "\$PREFIX" && '
          'for f in bin/* lib/node_modules/npm/bin/*; do '
          '[ -f "\$f" ] || continue; '
          'head -1 "\$f" 2>/dev/null | grep -q '
          '"data/data/com.termux" && echo "SHEBANG_STALE: \$f"; done | head -5'],
    ).timeout(const Duration(seconds: 30));
    if (verifyOut.contains('SHEBANG_STALE')) {
      // ignore: avoid_print
      print(
        '[ovid-sandbox] PR31 shebang patch left stale interpreters '
        '(first 5): $verifyOut — run Sandbox self-heal / Repair.',
      );
    }
  }

  /// Reads one member of an `ar` archive (`.deb` container) in pure Dart.
  /// Returns null when [wanted] (e.g. `data.tar.xz`) is not present.
  /// ar format: `!<arch>\n` global header, then per-member 60-byte headers
  /// (name[16] mtime[12] uid[6] gid[6] mode[8] size[10] magic[2]="`\n"),
  /// data padded to even byte boundary. Member names like "data.tar.xz/".
  Future<({String name, List<int> bytes})?> _readArMember(
    File ar,
    String wanted,
  ) async {
    try {
      final raf = await ar.open();
      try {
        final magic = await raf.read(8);
        if (magic.length != 8 ||
            String.fromCharCodes(magic.take(7)) != '!<arch>') {
          return null;
        }
        while (true) {
          final header = await raf.read(60);
          if (header.length < 60) break;
          final rawName = String.fromCharCodes(header.sublist(0, 16)).trim();
          final sizeStr = String.fromCharCodes(header.sublist(48, 58)).trim();
          final size = int.tryParse(sizeStr) ?? 0;
          final name = rawName.endsWith('/')
              ? rawName.substring(0, rawName.length - 1)
              : rawName;
          if (name == wanted) {
            final bytes = await raf.read(size);
            return (name: name, bytes: bytes);
          }
          // Skip this member (data padded to even offset).
          await raf.setPosition(
            await raf.position() + size + (size.isOdd ? 1 : 0),
          );
        }
        return null;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Writes `$prefix/etc/apt/sources.list` for one mirror (idempotent).
  void _writeSourcesList(Directory prefix, String mirror) {
    try {
      final dir = Directory('${prefix.path}/etc/apt')
        ..createSync(recursive: true);
      File(
        '${dir.path}/sources.list.d/termux.list',
      ).createSync(recursive: true);
      File('${dir.path}/sources.list').writeAsStringSync(
        '# Ovid sandbox apt mirror (auto-managed)\n'
        'deb $mirror stable main\n',
      );
    } catch (_) {}
  }

  void _ensureSourcesList(Directory prefix) =>
      _writeSourcesList(prefix, _aptMirrors[_mirrorIdx]);

  /// Rotate to the next mirror when apt reports fetch/lookup failures.
  /// PR30: apt's REAL wording is "does not have a Release file" /
  /// "is not (yet) valid" / "InRelease" — the old matcher only knew the
  /// lowercase phrase "no release file" and NEVER matched, so all 3
  /// retries burned on the same dead mirror (reported on-device).
  /// PR30 test seams: mirror state + rotation matcher.
  @visibleForTesting
  int get currentMirrorIndexForTest => _mirrorIdx;

  @visibleForTesting
  static int get mirrorCountForTest => _aptMirrors.length;

  @visibleForTesting
  bool rotateMirrorForTest(String aptOut) => _rotateMirror(aptOut);

  bool _rotateMirror(String aptOut) {
    final l = aptOut.toLowerCase();
    final dead = l.contains('unable to locate package') ||
        l.contains('failed to fetch') ||
        l.contains('does not have a release file') ||
        l.contains('no release file') ||
        l.contains('inrelease') ||
        l.contains('is not signed') ||
        l.contains('is not (yet) valid') ||
        l.contains('404') ||
        l.contains('connection timed out') ||
        l.contains('could not connect') ||
        l.contains('connection refused');
    if (!dead) return false;
    _mirrorIdx = (_mirrorIdx + 1) % _aptMirrors.length;
    final prefix = _prefix;
    if (prefix != null) _writeSourcesList(prefix, _aptMirrors[_mirrorIdx]);
    return true;
  }

  /// Guarantee `$prefix/etc/tls/cert.pem` exists and is non-empty.
  void _ensureCaBundle(Directory prefix) {
    try {
      final tls = Directory('${prefix.path}/etc/tls')
        ..createSync(recursive: true);
      final cert = File('${tls.path}/cert.pem');
      if (cert.existsSync() && cert.lengthSync() > 4096) return;
      // Source 1: Termux bootstrap's ca-certificates target (if present).
      final candidates = [
        File(
          '${prefix.path}/share/ca-certificates/mozilla/GlobalSign_Root_CA.crt',
        ),
      ];
      // Source 2: Android system store — concatenate all *.0 PEM anchors.
      final androidStore = Directory('/system/etc/security/cacerts');
      final out = StringBuffer();
      if (androidStore.existsSync()) {
        final files = androidStore
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.0'))
            .toList();
        for (final f in files) {
          out.write(f.readAsStringSync());
          if (!out.toString().endsWith('\n')) out.write('\n');
        }
      }
      for (final f in candidates) {
        if (f.existsSync()) out.writeln(f.readAsStringSync());
      }
      if (out.length > 4096) {
        cert.writeAsStringSync(out.toString());
      }
    } catch (_) {}
  }

  Future<void> _chmodTree(Directory root, List<String> subdirs) async {
    for (final sub in subdirs) {
      final dir = Directory('${root.path}/$sub');
      if (!dir.existsSync()) continue;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          await _chmod(entity.path, 0x1ED); // 0755
        }
      }
    }
  }

  Future<void> _chmod(String path, int mode) async {
    try {
      await Process.run('/system/bin/chmod', [mode.toRadixString(8), path]);
    } catch (_) {
      // Fallback: some devices lack /system/bin/chmod — try toybox.
      try {
        await Process.run('toybox', ['chmod', mode.toRadixString(8), path]);
      } catch (_) {}
    }
  }

  Future<String?> get _nativeLibraryDir async {
    try {
      final v = await _nativeChannel.invokeMethod<String>(
        'getNativeLibraryDir',
      );
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    return null;
  }

  /// Read the bundled bootstrap zip.  With extractNativeLibs=false
  /// (Flutter default, minSdk ≥ 23) the .so is NOT extracted to
  /// nativeLibraryDir — so we read the zip entry straight out of the
  /// installed APK via the platform channel (no double storage).
  /// Falls back to the extracted file for dev/test environments.
  Future<Uint8List?> _readBootstrapPayload() async {
    // Primary: zip entry inside the installed APK.
    try {
      final bytes = await _nativeChannel.invokeMethod<Uint8List>(
        'readBootstrapPayload',
      );
      if (bytes != null && bytes.isNotEmpty) return bytes;
    } catch (_) {}
    // Fallback: already-extracted copy (older builds / tests).
    try {
      final libDir = await _nativeLibraryDir;
      if (libDir != null) {
        final f = File('$libDir/libovid_bootstrap.so');
        if (f.existsSync()) return f.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  // ═════════════════════════════════════════════════════════════════
  // EXEC — native sandbox (primary path)
  // ═════════════════════════════════════════════════════════════════
  Map<String, String> _sandboxEnv() {
    final p = _prefix!.path;
    // Ensure the dirs the env below points at actually exist — npm/pip
    // try to mkdir them under the compiled-in Termux HOME otherwise
    // (cross-app EACCES). Sync + best-effort: sub-millisecond when they
    // already exist.
    try {
      Directory('$p/tmp').createSync(recursive: true);
      Directory('$p/home/.npm').createSync(recursive: true);
      Directory('$p/home/.cache/pip').createSync(recursive: true);
    } catch (_) {}
    final env = <String, String>{
      'PREFIX': p,
      'TERMUX__PREFIX': p,
      'HOME': '$p/home',
      'TMPDIR': '$p/tmp',
      'PATH': '$p/bin:/system/bin:/system/xbin',
      'LD_LIBRARY_PATH': '$p/lib',
      'LD_PRELOAD': '$p/lib/libtermux-exec-direct-ld-preload.so',
      'LANG': 'en_US.UTF-8',
      'TERM': 'xterm-256color',
      'SHELL': '$p/bin/bash',
      'ANDROID_DATA': '/data',
      'ANDROID_ROOT': '/system',
      // Point apt at our explicit Dir config (bypasses the compiled-in
      // Termux prefix that SELinux-blocked LD_PRELOAD fails to redirect).
      'APT_CONFIG': '$p/etc/apt/ovid-apt.conf',
      // TLS roots for curl/git/wget — they look for the CA bundle at the
      // compiled-in Termux path otherwise and HTTPS fails ("google: 000").
      'CURL_CA_BUNDLE': '$p/etc/tls/cert.pem',
      'SSL_CERT_FILE': '$p/etc/tls/cert.pem',
      'GIT_SSL_CAINFO': '$p/etc/tls/cert.pem',
      // ── DSH-web env-injection parity (spawn-level, never profiles) ──
      // The golden rule: agents run `bash -c` non-interactive, which never
      // reads .bashrc — every runtime var must be in the process env.
      // git: exec-path points at OUR libexec (compiled-in prefix would
      // look at com.termux's path → "git: 'remote-https' is not a git
      // command"). NOSYSTEM skips the read-only /system gitconfig.
      if (Directory('$p/libexec/git-core').existsSync())
        'GIT_EXEC_PATH': '$p/libexec/git-core',
      'GIT_CONFIG_NOSYSTEM': '1',
      // node/npm: global modules + registry + cache + tmp all inside
      // sandbox (a missing cache/tmp dir makes npm try to mkdir it under
      // the compiled-in Termux HOME → cross-app EACCES).
      'NODE_PATH': '$p/lib/node_modules',
      'npm_config_registry': 'https://registry.npmjs.org/',
      'npm_config_cache': '$p/home/.npm',
      'npm_config_userconfig': '$p/home/.npmrc',
      'npm_config_tmp': '$p/tmp',
      // pip cache + config inside sandbox HOME.
      'PIP_CACHE_DIR': '$p/home/.cache/pip',
      'PIP_CONFIG_FILE': '$p/etc/pip.conf',
      // TLS config: some Android openssl builds fail without an explicit
      // config; ours sets TLSv1.2 + SECLEVEL=1 for old device compat.
      // Always set — if the file is missing we write it right now (a
      // missing OPENSSL_CONF makes openssl read the compiled-in Termux
      // path → "system library:BIO_new_file:Permission denied").
      if (File('$p/etc/tls/openssl.cnf').existsSync())
        'OPENSSL_CONF': '$p/etc/tls/openssl.cnf',
    };
    // python: site-packages on PYTHONPATH — only when discovered (empty
    // PYTHONPATH would pollute sys.path with cwd).
    final pysp = _pythonSitePackages;
    if (pysp != null && pysp.isNotEmpty) env['PYTHONPATH'] = pysp;
    return env;
  }

  /// Probed `lib/python3.x/site-packages` (python is apt-installed AFTER
  /// bootstrap, so the version dir must be discovered, not hardcoded).
  String? _pythonSitePackages;

  /// Discover the python site-packages dir once; safe no-op if absent.
  void _probePythonPath() {
    if (_pythonSitePackages != null || _prefix == null) return;
    try {
      final lib = Directory('${_prefix!.path}/lib');
      if (!lib.existsSync()) return;
      for (final e in lib.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        if (!name.startsWith('python3')) continue;
        final sp = Directory('${e.path}/site-packages');
        if (sp.existsSync()) {
          _pythonSitePackages = sp.path;
          return;
        }
      }
    } catch (_) {}
  }

  /// Public self-heal entry (Health repair + tests). Best-effort.
  Future<void> selfHealNow({void Function(String line)? onLine}) async {
    Directory prefix;
    try {
      prefix = _prefix ??
          Directory(
            '${(await _ensureFilesRoot()).path}/sandbox',
          );
    } catch (_) {
      return;
    }
    if (!Directory('${prefix.path}/bin').existsSync()) return;
    onLine?.call('ovid sandbox: self-heal (symlinks, shebangs, exec bits)');
    await _selfHealSandbox(prefix);
    onLine?.call('ovid sandbox: self-heal done');
  }

  /// PR22 self-heal: repairs sandboxes installed by older builds without
  /// forcing a reinstall. Idempotent + best-effort on every boot:
  ///  1. `$PREFIX/usr` compat self-symlink (bad-interpreter fix).
  ///  2. Core lib symlinks that the pre-2f23a57 Map bug could have lost
  ///     (libz.so.1 is the reported one — node dies at link time).
  ///  3. Re-patch shebangs + exec bits (npm .bin shims).
  ///  4. `bin/env` / `bin/sh` / `bin/bash` existence probes — if any of
  ///     the core binaries is missing the sandbox is beyond healing and
  ///     Studio will surface a reinstall prompt (we don't force one here).
  Future<void> _selfHealSandbox(Directory prefix) async {
    final p = prefix.path;
    try {
      // 1. usr compat symlink.
      try {
        final usr = Link('$p/usr');
        if (!usr.existsSync()) usr.createSync('.');
      } catch (_) {}

      // 2. Core so-version links (self-heal only what physically exists
      //    as the versioned file — we never invent libraries).
      const coreLinks = <String, String>{
        'lib/libz.so.1': 'libz.so.1.3.2',
        'lib/libz.so': 'libz.so.1.3.2',
        'lib/libc.so': 'libc.so',
        'lib/libdl.so': 'libdl.so',
        'lib/libm.so': 'libm.so',
      };
      for (final e in coreLinks.entries) {
        try {
          final link = Link('$p/${e.key}');
          final target = '$p/${e.value}';
          if (link.existsSync()) continue;
          if (!File(target).existsSync() && !Link(target).existsSync()) {
            continue;
          }
          link.parent.createSync(recursive: true);
          link.createSync(e.value); // relative, like SYMLINKS.txt
        } catch (_) {}
      }

      // 3. Shebangs + exec bits — same treatment as a fresh install.
      //    Skipped when bin/npx or bin/npm is missing (nothing to patch
      //    yet — runtimes not installed; _installRuntimesWithRetry will
      //    do the full pass after installing them).
      if (File('$p/bin/npm').existsSync() ||
          File('$p/bin/npx').existsSync()) {
        await _patchExtractedShebangs(prefix);
      }
    } catch (_) {
      // Self-heal must never break the boot.
    }
  }

  Future<String> exec(
    List<String> args, {
    String? cwd,
    Directory? hostWorkDir,
    Map<String, String>? env,
    void Function(String line)? onLine,
  }) async {
    if (_prefix == null) {
      final ok = await checkExisting();
      if (!ok) {
        throw Exception(
          'sandbox not installed — open Studio once to install it, then retry the command.',
        );
      }
    }
    final merged = {..._sandboxEnv(), ...?env};
    try {
      final result = await Process.run(
        args[0].startsWith('/') ? args[0] : '${_prefix!.path}/bin/${args[0]}',
        args.sublist(1),
        workingDirectory:
            cwd ??
            (hostWorkDir != null ? hostWorkDir.path : '${_prefix!.path}/home'),
        environment: merged,
        // Decode manually with allowMalformed — apt/gpg/node can emit bytes
        // that aren't valid UTF-8; utf8 directly throws FormatException and
        // kills the whole command ("Unexpected extension byte").
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      final out =
          '${utf8.decode(result.stdout as List<int>, allowMalformed: true)}'
          '${utf8.decode(result.stderr as List<int>, allowMalformed: true)}';
      if (onLine != null) {
        for (final l in const LineSplitter().convert(out)) {
          onLine(l);
        }
      }
      // ── Lazy proot fallback on glibc/ABI failure ──
      if (result.exitCode != 0 && _isGlibcFailure(out)) {
        final retried = await _prootFallback(
          args,
          cwd: cwd,
          hostWorkDir: hostWorkDir,
          env: env,
          onLine: onLine,
        );
        if (retried != null) return retried;
      }
      if (result.exitCode != 0 && out.trim().isEmpty) {
        throw Exception('command exited ${result.exitCode} (no output)');
      }
      return out;
    } catch (e) {
      if ('$e'.contains('sandbox not installed')) rethrow;
      // Exec-format / missing-lib failures → try the fallback once.
      if (_isGlibcFailure('$e')) {
        final retried = await _prootFallback(
          args,
          cwd: cwd,
          hostWorkDir: hostWorkDir,
          env: env,
          onLine: onLine,
        );
        if (retried != null) return retried;
      }
      rethrow;
    }
  }

  bool _isGlibcFailure(String text) {
    final l = text.toLowerCase();
    return l.contains('libc.so.6') ||
        l.contains('glibc') ||
        l.contains('gnu_get_libc') ||
        l.contains('cannot locate symbol') ||
        l.contains('exec format error');
  }

  /// Exit-code-checked exec — returns (exitCode, combinedOutput).
  /// Unlike [exec], this NEVER swallows failures: the caller can see
  /// exitCode != 0 even when the command printed something on stderr
  /// (e.g. the dynamic linker's "CANNOT LINK EXECUTABLE" errors, which
  /// used to make sanity checks false-positive).
  Future<(int, String)> execChecked(
    List<String> args, {
    String? cwd,
    Directory? hostWorkDir,
    Map<String, String>? env,
  }) async {
    if (_prefix == null) {
      final ok = await checkExisting();
      if (!ok) {
        throw Exception(
          'sandbox not installed — open Studio once to install it, then retry the command.',
        );
      }
    }
    final merged = {..._sandboxEnv(), ...?env};
    final result = await Process.run(
      args[0].startsWith('/') ? args[0] : '${_prefix!.path}/bin/${args[0]}',
      args.sublist(1),
      workingDirectory:
          cwd ??
          (hostWorkDir != null ? hostWorkDir.path : '${_prefix!.path}/home'),
      environment: merged,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    final out =
        '${utf8.decode(result.stdout as List<int>, allowMalformed: true)}'
        '${utf8.decode(result.stderr as List<int>, allowMalformed: true)}';
    return (result.exitCode, out);
  }

  // ═════════════════════════════════════════════════════════════════
  // RUNTIME ENSURE — lazily install nodejs/npm or python/uv if the eager
  // install during setup was skipped (offline) or failed.  McpService
  // calls this before spawning a server that needs npx / uvx.
  // ═════════════════════════════════════════════════════════════════
  final Map<String, bool> _runtimeEnsured = {};

  /// apt minus TLS flakiness: run an apt sub-command; on cert/TLS/GPG
  /// failure, append an insecure-HTTPS override once and retry (some
  /// devices/builds ship a broken ca-certificates symlink after the
  /// Termux→ours prefix rewrite — this self-heals existing installs).
  /// apt minus TLS flakiness AND dead-mirror days: run an apt sub-command.
  /// On a cert/TLS/GPG error → loosen HTTPS verification once and retry.
  /// On a fetch/lookup failure → rotate to the next known-good mirror,
  /// refresh the index, and retry the operation.  The caller ALWAYS sees
  /// the final exit code — no silent success on a half-dead mirror.
  Future<(int, String)> _aptChecked(
    String sub, {
    required Duration timeout,
    void Function(String line)? onLine,
  }) async {
    Future<(int, String)> run() =>
        execChecked(['bash', '-c', 'apt $sub']).timeout(timeout);
    var (code, out) = await run();
    if (code != 0 && _looksLikeAptTls(out)) {
      onLine?.call('[apt] cert/TLS error — relaxed HTTPS verify once');
      await _loosenAptTls();
      (code, out) = await run();
    }
    if (code != 0 && _rotateMirror(out)) {
      onLine?.call(
        '[apt] mirror dead/stale — rotated to ${_aptMirrors[_mirrorIdx]}',
      );
      final (uCode, uOut) = await execChecked([
        'bash',
        '-c',
        'apt update 2>&1',
      ]).timeout(const Duration(minutes: 3));
      if (sub.startsWith('update')) {
        (code, out) = (uCode, uOut);
      } else if (uCode != 0) {
        return (uCode, uOut);
      } else {
        (code, out) = await run();
      }
    }
    return (code, out);
  }

  static bool _looksLikeAptTls(String out) {
    final l = out.toLowerCase();
    return l.contains('certificate') ||
        l.contains('ssl') ||
        l.contains('tls') ||
        l.contains('gnutls') ||
        l.contains('gpg: ') ||
        l.contains('repo has no release file');
  }

  bool _aptTlsLoosened = false;

  /// Permanently relax apt HTTPS verification for THIS sandbox prefix
  /// (idempotent; mirrors the packaged config at next writeAptConfig call).
  Future<void> _loosenAptTls() async {
    if (_aptTlsLoosened) return;
    _aptTlsLoosened = true;
    try {
      final p = _prefix!.path;
      const extra =
          '// Auto-added after apt certificate/TLS failure.\n'
          'Acquire::https::Verify-Peer "false";\n'
          'Acquire::https::Verify-Host "false";\n';
      for (final f in [
        File('$p/etc/apt/ovid-apt.conf'),
        File('$p/etc/apt/apt.conf'),
      ]) {
        try {
          final cur = f.existsSync() ? f.readAsStringSync() : '';
          if (!cur.contains('Verify-Peer')) {
            f.writeAsStringSync('$cur$extra');
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Ensure `nodejs`+`npm` (npx) or `python`+`uv` (uvx) are installed.
  /// [kind] is 'node' or 'python'. Returns true if the runtime binary
  /// is available (already there, or freshly installed).
  Future<bool> ensureRuntime(
    String kind, {
    void Function(String line)? onLine,
  }) async {
    final bin = kind == 'node' ? 'node' : 'python';
    if (_runtimeEnsured[kind] == true) return true;
    // Fast path: check if already present (exit-code based —
    // `command -v` prints nothing and exits 1 when missing).
    try {
      final (code, _) = await execChecked([
        'bash',
        '-c',
        'command -v $bin',
      ]).timeout(const Duration(seconds: 10));
      if (code == 0) {
        _runtimeEnsured[kind] = true;
        return true;
      }
    } catch (_) {}
    onLine?.call(
      '[runtime] installing ${kind == 'node' ? 'nodejs + npm + pnpm' : 'python + pip + uv'}…',
    );
    try {
      await _aptChecked('update 2>&1', timeout: const Duration(minutes: 3));
      final pkgs = kind == 'node' ? 'nodejs npm' : 'python python-pip uv';
      await _aptChecked(
        'install -y $pkgs 2>&1',
        timeout: const Duration(minutes: 8),
      );
      if (kind == 'node') {
        // Enable pnpm via corepack (best-effort, non-fatal).
        try {
          await execChecked([
            'bash',
            '-c',
            'corepack enable 2>&1; corepack prepare pnpm@latest --activate 2>&1',
          ]).timeout(const Duration(minutes: 2));
        } catch (_) {}
      }
      final (vCode, _) = await execChecked([
        'bash',
        '-c',
        'command -v $bin',
      ]).timeout(const Duration(seconds: 10));
      final ok = vCode == 0;
      if (ok) _runtimeEnsured[kind] = true;
      onLine?.call(
        '[runtime] ${kind == 'node' ? 'node' : 'python'} '
        '${ok ? 'installed ✓' : 'install FAILED'}',
      );
      return ok;
    } catch (e) {
      onLine?.call('[runtime] $kind install failed: $e');
      return false;
    }
  }

  /// Whether a runtime binary exists right now (no install attempted).
  Future<bool> hasRuntime(String bin) async {
    try {
      final (code, _) = await execChecked([
        'bash',
        '-c',
        'command -v $bin',
      ]).timeout(const Duration(seconds: 10));
      return code == 0;
    } catch (_) {
      return false;
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // HEALTH / RUNTIME REPAIR (Health screen + first-launch gate)
  // ═════════════════════════════════════════════════════════════════

  /// Fast check: every runtime the app treats as REQUIRED is present.
  /// (bash + node + npm + python + git + curl — the full Linux toolchain
  /// the agent and MCP servers need.  Stored flag avoided: real probe.)
  Future<bool> runtimesVerified() async {
    try {
      final (code, _) = await execChecked([
        'bash',
        '-c',
        'command -v node >/dev/null && command -v npm >/dev/null && '
            'command -v python >/dev/null && command -v curl >/dev/null && '
            'command -v git >/dev/null',
      ]).timeout(const Duration(seconds: 15));
      return code == 0;
    } catch (_) {
      return false;
    }
  }

  /// Which runtime binaries are missing right now (for the Health screen
  /// list).  Returns accurate per-binary statuses via one bash probe.
  Future<Map<String, bool>> probeRuntimes() async {
    const bins = ['bash', 'node', 'npm', 'python', 'git', 'curl'];
    final result = <String, bool>{for (final b in bins) b: false};
    if (!_installed) return result;
    try {
      final (code, out) = await execChecked([
        'bash',
        '-c',
        'for b in ${bins.join(' ')}; do command -v \$b >/dev/null && echo "OK \$b" || echo "MISS \$b"; done',
      ]).timeout(const Duration(seconds: 15));
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

  /// Install/repair the runtime toolchain (node+npm+pnpm, python+pip+uv,
  /// git, curl) with retries + apt TLS self-heal.  Called by the
  /// first-launch gate (repair mode) and the Health screen's Repair button.
  Future<bool> installCoreRuntimes(
    void Function(int phase, double progress, String line) onPhase,
  ) async {
    if (!_installed) return false;
    await _installRuntimesWithRetry(onPhase);
    return await runtimesVerified();
  }

  // ═════════════════════════════════════════════════════════════════
  // LAZY PROOT-UBUNTU FALLBACK — provisioned ON DEMAND, never bundled.
  // Only triggered by a real glibc/ABI failure; fully isolated from the
  // native path.  Every trigger is logged for later bionic-native-ifying.
  // ═════════════════════════════════════════════════════════════════
  Future<String?> _prootFallback(
    List<String> args, {
    String? cwd,
    Directory? hostWorkDir,
    Map<String, String>? env,
    void Function(String line)? onLine,
  }) async {
    _fallbackLog.add({
      'cmd': args.join(' '),
      'error': 'glibc/abi',
      'ts': DateTime.now().toIso8601String(),
    });
    if (_fallbackLog.length > 200) {
      _fallbackLog.removeRange(0, _fallbackLog.length - 200);
    }
    // Provisioning the fallback downloads proot + a minimal Ubuntu rootfs
    // on FIRST failure only (~40 MB).  Not implemented inline here — the
    // legacy proot installer is retained separately and wired in the next
    // commit; for now report the miss clearly so the model can adapt.
    onLine?.call(
      '[fallback] command needs a glibc environment — logged for '
      'native packaging; skipping proot (on-demand fallback pending).',
    );
    return null;
  }

  // ═════════════════════════════════════════════════════════════════
  // SPAWN / SHELL — streaming processes (jobs, MCP servers, terminal)
  // ═════════════════════════════════════════════════════════════════
  Future<Process> spawn(
    List<String> args, {
    Directory? hostWorkDir,
    Map<String, String>? env,
  }) async {
    if (_prefix == null) {
      final ok = await checkExisting();
      if (!ok) {
        throw Exception(
          'sandbox not installed — open Studio once to install it, then retry.',
        );
      }
    }
    final merged = {..._sandboxEnv(), ...?env};
    return Process.start(
      args[0].startsWith('/') ? args[0] : '${_prefix!.path}/bin/${args[0]}',
      args.sublist(1),
      workingDirectory: hostWorkDir != null
          ? hostWorkDir.path
          : '${_prefix!.path}/home',
      environment: merged,
      mode: ProcessStartMode.normal,
    );
  }

  Future<Process> shell({Directory? hostWorkDir}) async {
    if (_prefix == null) {
      final ok = await checkExisting();
      if (!ok) {
        throw Exception(
          'sandbox not installed — open Studio once to install it, then retry.',
        );
      }
    }
    return Process.start(
      '${_prefix!.path}/bin/bash',
      ['-l'],
      workingDirectory: hostWorkDir != null
          ? hostWorkDir.path
          : '${_prefix!.path}/home',
      environment: _sandboxEnv(),
      mode: ProcessStartMode.normal,
    );
  }

  // ═════════════════════════════════════════════════════════════════
  // PHONE TERMINAL — device shell, no install needed (Android 6+ incl.)
  // ═════════════════════════════════════════════════════════════════
  Future<String> execHost(String cmd, {Directory? hostWorkDir}) async {
    final result = await Process.run(
      '/system/bin/sh',
      ['-c', cmd],
      workingDirectory: hostWorkDir?.path,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
    return '${utf8.decode(result.stdout as List<int>, allowMalformed: true)}'
        '${utf8.decode(result.stderr as List<int>, allowMalformed: true)}';
  }

  // ═════════════════════════════════════════════════════════════════
  // UNINSTALL
  // ═════════════════════════════════════════════════════════════════
  Future<void> uninstall() async {
    try {
      final files = await _ensureFilesRoot();
      final prefix = Directory('${files.path}/sandbox');
      if (prefix.existsSync()) prefix.deleteSync(recursive: true);
    } catch (_) {}
    _prefix = null;
    _installed = false;
    _checked = false;
  }
}
