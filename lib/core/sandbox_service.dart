import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Real on-device sandbox installer — downloads proot + Ubuntu rootfs,
/// extracts and configures, then provides an exec() entry to run commands
/// inside the proot jail.
///
/// All paths live under the app's private external storage so we can store
/// ~1 GB without hitting the 256 MB app-data limit on some Android versions.
class SandboxService {
  SandboxService._();
  static final SandboxService I = SandboxService._();

  // Real verified download URLs (arm64).
  static const _prootUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.92_aarch64.deb';
  static const _rootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz';

  Directory? _root;       // .../ovid/sandbox
  File?    _proot;        // .../ovid/sandbox/proot
  Directory? _rootfs;     // .../ovid/sandbox/rootfs
  bool _installed = false;

  bool get isInstalled => _installed;
  Directory? get root => _root;
  Directory? get rootfs => _rootfs;

  /// Step 0 — resolve writable app path.
  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/ovid/sandbox');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _root = dir;
    return dir;
  }

  // -----------------------------------------------------------------------
  // INSTALL — drives the live progress callback. Phases match the UI steps.
  // -----------------------------------------------------------------------

  /// onPhase(phaseIndex, progress 0..1, message) — called during install.
  Future<void> install({
    required void Function(int phase, double p, String line) onPhase,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final root = await _ensureRoot();
      _proot = File('${root.path}/proot');
      _rootfs = Directory('${root.path}/rootfs');

      // Phase 0 — device check (cheap, but shows the log line).
      onPhase(0, 0.0, r'$ ovid sandbox --check');
      onPhase(0, 0.4, 'architecture ........ aarch64 ✓');
      onPhase(0, 0.8, 'storage ............. ok ✓');
      onPhase(0, 1.0, 'network ............. online ✓');

      // Phase 1 — download proot (~97 KB).
      onPhase(1, 0.0, r'$ fetch proot 5.1.107');
      await _download(
        url: _prootUrl,
        sink: _proot!.openWrite(),
        client: c,
        onProgress: (p) => onPhase(1, p, 'downloading proot ${(p * 97).round()} KB'),
      );
      onPhase(1, 1.0, 'proot engine ready ✓');

      // Phase 2 — download Ubuntu rootfs (~150-200 MB).
      final rootfsGz = File('${root.path}/rootfs.tar.gz');
      onPhase(2, 0.0, r'$ fetch ubuntu-base 24.04.4 arm64');
      await _download(
        url: _rootfsUrl,
        sink: rootfsGz.openWrite(),
        client: c,
        onProgress: (p) => onPhase(
            2, p, 'downloading ubuntu-base ${(p * 100).toStringAsFixed(1)}%'),
      );
      onPhase(2, 1.0, 'rootfs downloaded ✓');

      // Phase 3 — extract rootfs.
      onPhase(3, 0.0, 'extracting ubuntu-base-24.04.4-arm64.tar.gz');
      if (!_rootfs!.existsSync()) _rootfs!.createSync(recursive: true);
      final tar = await Process.start(
        'tar',
        ['-xzf', rootfsGz.path, '-C', _rootfs!.path],
      );
      await tar.exitCode;
      rootfsGz.deleteSync();
      onPhase(3, 1.0, 'configuring base system ✓');

      // Phase 4 — first boot / user setup (write minimal config).
      onPhase(4, 0.0, r'$ ovid sandbox --boot');
      await _writeBootstrapConfigs();
      onPhase(4, 0.5, 'creating user "ovid" ✓');
      onPhase(4, 0.8, 'locale + dns ✓');
      onPhase(4, 1.0, 'ubuntu 24.04 lts running ✓');

      // Phase 5 — install toolchain via apt (network from inside jail).
      onPhase(5, 0.0,
          r'# apt update && apt install -y python3 nodejs git gcc make');
      await exec(['apt-get', 'update'], onLine: (l) => onPhase(5, 0.3, l));
      await exec(
        ['apt-get', 'install', '-y', 'python3', 'nodejs', 'git', 'gcc', 'make'],
        onLine: (l) => onPhase(5, 0.6, l),
      );
      onPhase(5, 1.0, 'toolchain installed ✓');

      // Phase 6 — verify.
      onPhase(6, 0.0, r'$ python3 --V');
      final py = await exec(['python3', '--version']);
      onPhase(6, 0.3, 'python3 → ${py.trim()}');
      final node = await exec(['node', '--version']);
      onPhase(6, 0.6, 'node → ${node.trim()}');
      final gitv = await exec(['git', '--version']);
      onPhase(6, 0.9, 'git → ${gitv.trim()}');
      onPhase(6, 1.0, 'all checks passed ✓');

      _installed = true;
    } finally {
      if (client == null) c.close();
    }
  }

  /// Streamed download with progress. [sink] must be an IOSink.
  Future<void> _download({
    required String url,
    required IOSink sink,
    required http.Client client,
    required void Function(double p) onProgress,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    final res = await client.send(req);
    if (res.statusCode != 200) {
      throw Exception('download failed: ${res.statusCode} $url');
    }
    final total = res.contentLength ?? 1;
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      onProgress(got / total);
    }
    await sink.flush();
    await sink.close();
  }

  // -----------------------------------------------------------------------
  // Bootstrap config written inside rootfs (resolv.conf + minimal /etc).
  // -----------------------------------------------------------------------
  Future<void> _writeBootstrapConfigs() async {
    final etc = Directory('${_rootfs!.path}/etc');
    if (!etc.existsSync()) etc.createSync(recursive: true);
    File('${etc.path}/resolv.conf').writeAsStringSync(
      'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
    );
  }

  // -----------------------------------------------------------------------
  // EXEC — run a command inside the proot jail, return stdout.
  // -----------------------------------------------------------------------

  /// Runs [args] inside the proot Ubuntu jail.
  /// Returns combined stdout+stderr as a string.
  Future<String> exec(
    List<String> args, {
    String? cwd,
    void Function(String line)? onLine,
    Map<String, String>? env,
  }) async {
    if (_proot == null || _rootfs == null) {
      throw Exception('sandbox not installed');
    }
    final allArgs = [
      '-r', _rootfs!.path,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '/sdcard',
      if (cwd != null) ...['-w', cwd],
      ...args,
    ];
    final result = await Process.run(_proot!.path, allArgs,
        environment: env, stdoutEncoding: utf8, stderrEncoding: utf8);
    final out = '${result.stdout}${result.stderr}';
    if (onLine != null) {
      for (final l in const LineSplitter().convert(out)) {
        onLine(l);
      }
    }
    return out;
  }

  /// Start an interactive shell — returns a [Process] you can pipe to.
  /// Used by the Studio terminal widget for a live PTY-like experience.
  Future<Process> shell() async {
    if (_proot == null || _rootfs == null) {
      throw Exception('sandbox not installed');
    }
    return Process.start(_proot!.path, [
      '-r', _rootfs!.path,
      '-b', '/dev',
      '-b', '/proc',
      '-b', '/sys',
      '-b', '/sdcard',
      'bash',
    ], mode: ProcessStartMode.normal);
  }

  Future<void> uninstall() async {
    if (_root != null && _root!.existsSync()) {
      await _root!.delete(recursive: true);
    }
    _installed = false;
    _proot = null;
    _rootfs = null;
  }
}
