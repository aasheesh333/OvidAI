import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
  String? get bashPath =>
      _prefix != null ? '${_prefix!.path}/bin/bash' : null;

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
    if (v.contains('android_arm64') || v.contains('aarch64') ||
        v.contains('x86_64')) {
      return 'arm64';
    }
    if (v.contains('android_arm') || v.contains('armv7') ||
        v.contains('armv8')) {
      return 'arm';
    }
    try {
      final r = Process.runSync('/system/bin/getprop', ['ro.product.cpu.abi']);
      final abi = r.stdout.toString().trim().toLowerCase();
      if (abi.contains('arm64') || abi.contains('x86_64')) return 'arm64';
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
      final ldPreload =
          File('${prefix.path}/lib/libtermux-exec-direct-ld-preload.so');
      if (bash.existsSync() &&
          coreutils.existsSync() &&
          ldPreload.existsSync()) {
        _prefix = prefix;
        _installed = true;
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
    const buildStamp =
        String.fromEnvironment('OVID_BUILD', defaultValue: 'local-dev');
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
          'for this device was not included in the install.');
    }
    onPhase(1, 1.0,
        'payload ........... ${(payloadBytes.length / 1024 / 1024).toStringAsFixed(1)} MB ✓');

    // ── Extract zip into staging ──
    onPhase(2, 0.0, 'extracting sandbox payload');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    final archive = ZipDecoder().decodeBytes(payloadBytes, verify: false);
    final symlinks = <String, String>{};
    var count = 0;
    for (final f in archive.files) {
      final name = f.name;
      if (name == 'SYMLINKS.txt') {
        final txt = utf8.decode(f.content as List<int>);
        for (final line in const LineSplitter().convert(txt)) {
          final parts = line.split('←');
          if (parts.length == 2) symlinks[parts[0]] = parts[1];
        }
        continue;
      }
      final target = File('${staging.path}/$name');
      if (f.isFile) {
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(f.content as List<int>);
        count++;
      } else {
        target.createSync(recursive: true);
      }
    }
    onPhase(2, 1.0, 'extracted ......... $count files ✓');

    // ── chmod executables (TermuxInstaller rule) ──
    onPhase(3, 0.0, 'setting exec bits');
    await _chmodTree(staging, ['bin', 'lib/apt/methods', 'libexec']);
    onPhase(3, 1.0, 'exec bits ......... ✓');

    // ── Symlinks from SYMLINKS.txt ──
    onPhase(4, 0.0, 'linking tool aliases');
    var linked = 0;
    symlinks.forEach((target, linkPath) {
      final link = Link('${staging.path}/$linkPath');
      try {
        link.parent.createSync(recursive: true);
        if (link.existsSync()) link.deleteSync();
        // Absolute-termux targets → point at our own bin/.
        var dest = target;
        if (dest.startsWith('/data/data/com.termux/files/usr/')) {
          dest = dest.replaceFirst(
              '/data/data/com.termux/files/usr/', '${staging.path}/');
        } else if (!dest.startsWith('/')) {
          // Relative target (e.g. ./bin/dash) — resolve against link dir.
          dest = '${link.parent.path}/$dest';
        }
        link.createSync(dest);
        linked++;
      } catch (_) {}
    });
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

    // ── Sanity: run bash --version natively ──
    onPhase(6, 0.0, r'$ bash --version (native exec sanity)');
    try {
      final out = await exec(['bash', '--version'])
          .timeout(const Duration(seconds: 15));
      final firstLine = out.trim().split('\n').first;
      onPhase(6, 1.0, 'native exec ....... ✓ ${firstLine.substring(0, firstLine.length.clamp(0, 50))}');
    } catch (e) {
      throw Exception(
          'Sandbox installed but native exec failed: $e. '
          'Report this with your device model.');
    }
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
      await Process.run('/system/bin/chmod',
          [mode.toRadixString(8), path]);
    } catch (_) {
      // Fallback: some devices lack /system/bin/chmod — try toybox.
      try {
        await Process.run('toybox', ['chmod', mode.toRadixString(8), path]);
      } catch (_) {}
    }
  }

  Future<String?> get _nativeLibraryDir async {
    try {
      final v =
          await _nativeChannel.invokeMethod<String>('getNativeLibraryDir');
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
      final bytes = await _nativeChannel
          .invokeMethod<Uint8List>('readBootstrapPayload');
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
    return {
      'PREFIX': p,
      'TERMUX__PREFIX': p,
      'HOME': '$p/home',
      'TMPDIR': '$p/tmp',
      'PATH': '$p/bin:/system/bin:/system/xbin',
      'LD_LIBRARY_PATH': '$p/lib',
      'LD_PRELOAD': '$p/lib/libtermux-exec-direct-ld-preload.so',
      'LANG': 'en_US.UTF-8',
      'TERM': 'xterm-256color',
      'ANDROID_DATA': '/data',
      'ANDROID_ROOT': '/system',
    };
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
            'sandbox not installed — open Studio once to install it, then retry the command.');
      }
    }
    final merged = {..._sandboxEnv(), ...?env};
    try {
      final result = await Process.run(
        args[0].startsWith('/') ? args[0] : '${_prefix!.path}/bin/${args[0]}',
        args.sublist(1),
        workingDirectory: cwd ??
            (hostWorkDir != null ? hostWorkDir.path : '${_prefix!.path}/home'),
        environment: merged,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final out = '${result.stdout}${result.stderr}';
      if (onLine != null) {
        for (final l in const LineSplitter().convert(out)) {
          onLine(l);
        }
      }
      // ── Lazy proot fallback on glibc/ABI failure ──
      if (result.exitCode != 0 && _isGlibcFailure(out)) {
        final retried = await _prootFallback(args,
            cwd: cwd, hostWorkDir: hostWorkDir, env: env, onLine: onLine);
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
        final retried = await _prootFallback(args,
            cwd: cwd, hostWorkDir: hostWorkDir, env: env, onLine: onLine);
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
        'native packaging; skipping proot (on-demand fallback pending).');
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
            'sandbox not installed — open Studio once to install it, then retry.');
      }
    }
    final merged = {..._sandboxEnv(), ...?env};
    return Process.start(
      args[0].startsWith('/') ? args[0] : '${_prefix!.path}/bin/${args[0]}',
      args.sublist(1),
      workingDirectory:
          hostWorkDir != null ? hostWorkDir.path : '${_prefix!.path}/home',
      environment: merged,
      mode: ProcessStartMode.normal,
    );
  }

  Future<Process> shell({Directory? hostWorkDir}) async {
    if (_prefix == null) {
      final ok = await checkExisting();
      if (!ok) {
        throw Exception(
            'sandbox not installed — open Studio once to install it, then retry.');
      }
    }
    return Process.start(
      '${_prefix!.path}/bin/bash',
      ['-l'],
      workingDirectory:
          hostWorkDir != null ? hostWorkDir.path : '${_prefix!.path}/home',
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
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return '${result.stdout}${result.stderr}';
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
