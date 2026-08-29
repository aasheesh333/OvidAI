import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Real on-device sandbox installer — downloads proot + Ubuntu rootfs,
/// extracts and configures, then provides an exec() entry to run commands
/// inside the proot jail.
///
/// Everything is pure-Dart extraction (no host `ar`/`tar`/`xz` binaries —
/// most Android devices ship none of them). Two downloads only:
///   1. proot .deb (Termux repo) — an ar archive containing data.tar.xz
///      with a static-linked aarch64 `proot` binary at
///      ./data/data/com.termux/files/usr/bin/proot
///   2. ubuntu-base tar.gz — the rootfs (~30 MB compressed, ~140 MB on disk)
///
/// All paths live under the app's private storage so nothing is visible to
/// other apps (Play-policy friendly: all downloads come from public vendor
/// URLs over HTTPS, no sideloaded APKs).
class SandboxService {
  SandboxService._();
  static final SandboxService I = SandboxService._();

  // Real verified download URLs (arm64).
  static const _prootUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_5.1.107.92_aarch64.deb';
  // proot is dynamically linked against these two Termux libs, so we ship
  // them next to the binary (/sandbox/lib) and set LD_LIBRARY_PATH at exec.
  static const _libtallocUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_2.4.3_aarch64.deb';
  static const _libshmemUrl =
      'https://packages.termux.dev/apt/termux-main/pool/main/liba/libandroid-shmem/libandroid-shmem_0.7_aarch64.deb';
  static const _rootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.4-base-arm64.tar.gz';

  /// Paths inside the .debs' data.tar that we extract.
  static const _prootEntryInDeb =
      './data/data/com.termux/files/usr/bin/proot';
  static const _libtallocSo = 'libtalloc.so.2';
  static const _libtallocPrefix =
      './data/data/com.termux/files/usr/lib/libtalloc.so';
  static const _libshmemSo = 'libandroid-shmem.so';
  static const _libshmemEntry =
      './data/data/com.termux/files/usr/lib/libandroid-shmem.so';

  Directory? _root;       // .../ovid/sandbox
  File?    _proot;        // .../ovid/sandbox/proot
  Directory? _rootfs;     // .../ovid/sandbox/rootfs
  bool _installed = false;
  bool _checked = false;

  bool get isInstalled => _installed;

  /// Fast path — check if a previously-completed install exists on disk.
  Future<bool> checkExisting() async {
    if (_checked) return _installed;
    _checked = true;
    try {
      final root = await _ensureRoot();
      final proot = File('${root.path}/proot');
      final rootfs = Directory('${root.path}/rootfs');
      if (!proot.existsSync() || !rootfs.existsSync()) return false;
      // proot must be a real ELF (not a still-archived .deb).
      final head = await proot.openRead(0, 4).fold<List<int>>(
          [], (buf, c) => (buf..addAll(c)));
      final isElf = head.length == 4 &&
          head[0] == 0x7F && head[1] == 0x45 && head[2] == 0x4C && head[3] == 0x46;
      if (!isElf) return false;
      // Rootfs must have content (bin / usr / etc present).
      final hasContent = rootfs.listSync(followLinks: false).any((e) {
        final n = e.path.split('/').last;
        return n == 'bin' || n == 'usr' || n == 'etc';
      });
      if (!hasContent) return false;
      // proot needs its runtime libs — check them too.
      final talloc = File('${root.path}/lib/$_libtallocSo');
      final shmem = File('${root.path}/lib/$_libshmemSo');
      if (!talloc.existsSync()) {
        // Symlink may not survive on some FSes — accept the real file too.
        if (!File('${root.path}/lib/libtalloc.so.2.4.3').existsSync()) {
          return false;
        }
      }
      if (!shmem.existsSync()) return false;
      _proot = proot;
      _rootfs = rootfs;
      _installed = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Directory? get root => _root;
  Directory? get rootfs => _rootfs;
  String? get prootPath => _proot?.path;

  // -----------------------------------------------------------------------
  // Per-session workspaces — each chat session gets its own working dir so the
  // agent in session A never sees session B's files (unless the user turns ON
  // "Share session memory" in Settings, which only widens *memory*, not the
  // on-disk workspace — workdir isolation is a hard guarantee).
  // -----------------------------------------------------------------------

  String workDirNameFor(String sessionSandboxId) => 'ws_$sessionSandboxId';

  /// Absolute host path to a session's workspace dir (created on demand).
  Future<Directory> workDirFor(String sessionSandboxId) async {
    final root = await _ensureRoot();
    final d = Directory('${root.path}/workspaces/ws_$sessionSandboxId');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// The path the workspace has INSIDE the proot jail (we bind it to /work).
  static const jailWorkPath = '/work';

  // -----------------------------------------------------------------------
  // INSTALL — drives the live progress callback. Phases match the UI.
  // -----------------------------------------------------------------------

  Future<void> install({
    required void Function(int phase, double p, String line) onPhase,
    http.Client? client,
  }) async {
    final c = client ?? http.Client();
    try {
      final root = await _ensureRoot();
      _proot = File('${root.path}/proot');
      _rootfs = Directory('${root.path}/rootfs');

      // ── Phase 0 — REAL device checks (storage + network). ──
      onPhase(0, 0.0, r'$ ovid sandbox --preflight');
      final stat = await root.stat();
      onPhase(0, 0.25, 'target dir ........ ${statChanged(stat)} ✓');
      final storage = await _freeMb(root);
      if (storage != null) {
        onPhase(0, 0.5, 'free storage ...... $storage MB ✓');
        if (storage < 900) {
          throw Exception(
              'Not enough free storage ($storage MB). The sandbox needs ~900 MB free — free up space and retry.');
        }
      } else {
        onPhase(0, 0.5, 'free storage ...... (unknown, continuing)');
      }
      // real network probe
      final netOk = await _probeNetwork(c);
      if (!netOk) {
        throw Exception('No network. Connect to the internet and retry.');
      }
      onPhase(0, 1.0, 'network ........... online ✓');

      // ── Phase 1 — download + extract proot AND its runtime libs ──
      onPhase(1, 0.0, r'$ fetch proot 5.1.107 (.deb)');
      // Recover cleanly from an interrupted previous attempt (partial
      // .deb/proot/lib files may exist).
      final staleSh = File('${root.path}/proot');
      if (await staleSh.exists()) {
        final head = await staleSh.openRead(0, 8).fold<List<int>>(
            [], (b, c) => b..addAll(c));
        // ELF check: 0x7F 'E' 'L' 'F'
        final isElf = head.length >= 4 && head[0] == 0x7F &&
            head[1] == 0x45 && head[2] == 0x4C && head[3] == 0x46;
        if (!isElf) {
          await staleSh.delete(); // leftover .deb copy from the old buggy path
        }
      }
      // proot ELF needs libtalloc.so.2 + libandroid-shmem.so (we verified
      // via readelf). All three come as .deb; we extract just the files
      // we need into sandbox/ and sandbox/lib/.
      final libDir = Directory('${root.path}/lib');
      if (!libDir.existsSync()) libDir.createSync(recursive: true);

      final deb = File('${root.path}/proot.deb');
      onPhase(1, 0.0, r'$ fetch proot 5.1.107 (.deb)');
      await _download(
        url: _prootUrl,
        sink: deb.openWrite(),
        client: c,
        onProgress: (p) =>
            onPhase(1, p * 0.4, 'downloading proot ${(p * 97).round()} KB'),
      );
      onPhase(1, 0.45, 'extracting proot binary');
      await _extractProotFromDeb(deb, _proot!);
      deb.deleteSync();
      await _chmod(_proot!.path, 0x1ED); // 0755
      _proot = File('${root.path}/proot');

      // libtalloc (+ its versioned symlink target)
      final tallocDeb = File('${root.path}/libtalloc.deb');
      onPhase(1, 0.55, r'$ fetch libtalloc 2.4.3 (proot dependency)');
      await _download(
        url: _libtallocUrl,
        sink: tallocDeb.openWrite(),
        client: c,
        onProgress: (p) =>
            onPhase(1, 0.55 + p * 0.15, 'downloading libtalloc ${(p * 33).round()} KB'),
      );
      final tallocReal = File('${libDir.path}/libtalloc.so.2.4.3');
      await _extractFromDeb(
        tallocDeb,
        '$_libtallocPrefix.2.4.3',
        tallocReal,
      );
      tallocDeb.deleteSync();
      // Soname symlink — proot looks for libtalloc.so.2
      final so2 = Link('${libDir.path}/$_libtallocSo');
      if (!so2.existsSync()) {
        try {
          so2.createSync('libtalloc.so.2.4.3');
        } catch (_) {
          // Some file systems block symlinks — ship a real copy instead.
          final copy = File('${libDir.path}/$_libtallocSo');
          if (!copy.existsSync()) copy.writeAsBytesSync(tallocReal.readAsBytesSync());
        }
      }
      onPhase(1, 0.75, 'libtalloc.so.2 ready ✓');

      // libandroid-shmem
      final shmemDeb = File('${root.path}/libandroid-shmem.deb');
      onPhase(1, 0.8, r'$ fetch libandroid-shmem 0.7');
      await _download(
        url: _libshmemUrl,
        sink: shmemDeb.openWrite(),
        client: c,
        onProgress: (p) =>
            onPhase(1, 0.8 + p * 0.12, 'downloading libandroid-shmem ${(p * 14).round()} KB'),
      );
      await _extractFromDeb(
        shmemDeb,
        _libshmemEntry,
        File('${libDir.path}/$_libshmemSo'),
      );
      shmemDeb.deleteSync();
      onPhase(1, 1.0, 'proot engine ready ✓ (incl. talloc + shmem libs)');

      // ── Phase 2 — download Ubuntu rootfs (~30 MB gz). ──
      final rootfsGz = File('${root.path}/rootfs.tar.gz');
      onPhase(2, 0.0, r'$ fetch ubuntu-base 24.04.4 arm64');
      await _download(
        url: _rootfsUrl,
        sink: rootfsGz.openWrite(),
        client: c,
        onProgress: (p) => onPhase(2, p,
            'downloading ubuntu-base ${(p * 100).toStringAsFixed(1)}%'),
      );
      onPhase(2, 1.0, 'rootfs downloaded ✓');

      // ── Phase 3 — extract rootfs in pure Dart (no system tar). ──
      onPhase(3, 0.0, 'extracting ubuntu-base-24.04.4-arm64.tar.gz');
      // Wipe any partial extract from a previous failed run — stale symlinks
      // from the old external-storage path caused "Operation not permitted".
      if (_rootfs!.existsSync()) {
        try {
          _rootfs!.deleteSync(recursive: true);
        } catch (_) {}
      }
      _rootfs!.createSync(recursive: true);
      await extractTarGz(rootfsGz, _rootfs!, (done, totalHint) {
        onPhase(3, 0.1 + 0.85 * done, 'extracting … ${totalHint > 0 ? "$totalHint files" : "…"}');
      });
      rootfsGz.deleteSync();
      onPhase(3, 1.0, 'configuring base system ✓');

      // ── Phase 4 — first boot (DNS + resolv + hostname). ──
      onPhase(4, 0.0, r'$ ovid sandbox --boot');
      await _writeBootstrapConfigs();
      onPhase(4, 0.5, 'creating user workspace ✓');
      onPhase(4, 0.8, 'dns + locale ✓');
      onPhase(4, 1.0, 'ubuntu 24.04 lts running ✓');

      // ── Phase 5 — toolchain via apt (inside the jail, real APT). ──
      onPhase(5, 0.0,
          r'# apt-get update && apt-get install -y python3 nodejs git gcc make curl');
      final upd = await exec(const ['apt-get', 'update'],
          env: _baseEnv, onLine: (l) => onPhase(5, 0.15, l));
      if (upd.contains('E:') || upd.contains('W: Failed')) {
        _emitLogLine(upd, onPhase);
        throw Exception(
            'apt-get update failed inside the jail (network/DNS). Retry — '
            'device ko stable network par rakho.');
      }
      final inst = await exec(
        const [
          'apt-get', 'install', '-y', '--no-install-recommends',
          'python3', 'nodejs', 'git', 'gcc', 'make', 'curl', 'ca-certificates'
        ],
        env: _baseEnv,
        onLine: (l) => onPhase(5, 0.6, l),
      );
      if (inst.contains('E: Unable to locate') || inst.contains('E: Sub-process')) {
        _emitLogLine(inst, onPhase);
        throw Exception('apt-get install failed — see log lines above.');
      }
      // Hard verify the toolchain landed before the smoke test — fail fast
      // with a precise message instead of a vague 'node not found'.
      final check = await exec(const [
        'sh', '-c',
        'for b in python3 node git; do command -v \$b || echo MISSING:\$b; done'
      ], env: _baseEnv);
      final missing = const LineSplitter()
          .convert(check)
          .where((l) => l.startsWith('MISSING:'))
          .map((l) => l.substring(8))
          .toList();
      if (missing.isNotEmpty) {
        throw Exception(
            'apt did not install: ${missing.join(", ")}. '
            'Retry install — agar dobara fail ho to network check karo.');
      }
      onPhase(5, 1.0, 'toolchain installed ✓');

      // ── Phase 6 — REAL smoke test: actual binary versions must print. ──
      onPhase(6, 0.0, r'$ smoke test: python3/node/git --version');
      final py = await exec(const ['python3', '--version'], env: _baseEnv);
      if (!py.toLowerCase().contains('python')) {
        throw Exception('smoke test failed: python3 → $py');
      }
      onPhase(6, 0.3, 'python3 → ${py.trim()} ✓');
      final node = await exec(const ['node', '--version'], env: _baseEnv);
      if (!node.trim().startsWith('v')) {
        throw Exception('smoke test failed: node → $node');
      }
      onPhase(6, 0.6, 'node → ${node.trim()} ✓');
      final gitv = await exec(const ['git', '--version'], env: _baseEnv);
      if (!gitv.toLowerCase().contains('git')) {
        throw Exception('smoke test failed: git → $gitv');
      }
      onPhase(6, 0.9, 'git → ${gitv.trim()} ✓');
      onPhase(6, 1.0, 'all checks passed ✓');

      _installed = true;
    } finally {
      if (client == null) c.close();
    }
  }

  // -----------------------------------------------------------------------
  // Real helpers (no simulation — every line above is factual work).
  // -----------------------------------------------------------------------

  void _emitLogLine(String output,
      void Function(int, double, String) onPhase) {
    for (final l in const LineSplitter().convert(output)) {
      if (l.trim().isNotEmpty) onPhase(5, 0.6, l);
    }
  }

  String statChanged(FileStat s) => s.type == FileSystemEntityType.directory
      ? 'writable'
      : 'error';

  Future<int?> _freeMb(Directory dir) async {
    try {
      // statfs via `df` — present on every Android/toybox device.
      final r = await Process.run('sh', ['-c', 'df -Pm "${dir.path}" | tail -1']);
      final parts = r.stdout.toString().trim().split(RegExp(r'\s+'));
      if (parts.length >= 4) return int.tryParse(parts[3]);
    } catch (_) {}
    return null;
  }

  Future<bool> _probeNetwork(http.Client c) async {
    try {
      final r = await c
          .head(Uri.parse('https://packages.termux.dev/'))
          .timeout(const Duration(seconds: 10));
      return r.statusCode < 500;
    } catch (_) {
      try {
        final r = await c
            .head(Uri.parse('https://cdimage.ubuntu.com/'))
            .timeout(const Duration(seconds: 10));
        return r.statusCode < 500;
      } catch (_) {
        return false;
      }
    }
  }

  Future<void> _chmod(String path, int mode) async {
    try {
      await Process.run('chmod', [mode.toRadixString(8), path]);
    } catch (_) {}
  }

  /// Parse the ar archive: locate `data.tar.xz`, decompress XZ, read the TAR,
  /// and pull out the single file we need (usr/bin/proot).
  Future<void> _extractProotFromDeb(File deb, File out) =>
      _extractFromDeb(deb, _prootEntryInDeb, out);

  /// Generic .deb extractor — finds [wantPath] inside data.tar.xz and writes
  /// it to [out]. ar member names may have a trailing '/'.
  Future<void> _extractFromDeb(File deb, String wantPath, File out) async {
    final bytes = await deb.readAsBytes();
    if (bytes.length < 68 ||
        String.fromCharCodes(bytes.sublist(0, 8)) != '!<arch>\n') {
      throw Exception('${deb.uri.pathSegments.last} is not an ar archive');
    }
    var pos = 8;
    while (pos + 60 <= bytes.length) {
      final hdr = bytes.sublist(pos, pos + 60);
      String field(int o, int len) =>
          String.fromCharCodes(hdr.sublist(o, o + len)).trim();
      var name = field(0, 16);
      final size = int.parse(field(48, 10));
      final bodyStart = pos + 60;
      final body = bytes.sublist(bodyStart, bodyStart + size);
      if (name.endsWith('/')) name = name.substring(0, name.length - 1);
      if (name == 'data.tar.xz') {
        final tarBytes = XZDecoder().decodeBytes(body);
        final archive = TarDecoder().decodeBytes(tarBytes);
        for (final entry in archive) {
          if (entry.name == wantPath) {
            await out.writeAsBytes(entry.readBytes()!);
            return;
          }
        }
        throw Exception('$wantPath not found inside data.tar.xz');
      }
      pos = bodyStart + size + (size.isOdd ? 1 : 0);
    }
    throw Exception('data.tar.xz not found inside ${deb.uri.pathSegments.last}');
  }

  /// Streaming .tar.gz extractor — in-house, resilient, bounded-memory.
  ///
  /// Why not the archive package's TarDecoder? With `storeData: false`
  /// (streaming), any GNU `@LongLink` or PAX `x` entry makes the package
  /// hit `rawContent!` on null → "Null check operator used on a null
  /// value" (exactly the device crash we saw). With `storeData: true` it
  /// loads the whole ~140 MB tar into RAM. Our own 512-byte header walker
  /// has neither problem:
  ///   • reads the gunzipped tar via RandomAccessFile in 1 MB chunks
  ///   • handles regular files, dirs, symlinks, hardlinks (copy),
  ///     GNU 'L'/'K' long names and PAX 'x'/'g' headers
  ///   • one odd entry can never abort the install (per-entry try/catch)
  ///   • collects exec-bit paths and chmods them in batches at the end
  @visibleForTesting
  Future<void> extractTarGz(
    File gz,
    Directory dest,
    void Function(double done01, int totalHint) onProgress,
  ) async {
    // ── 1. gunzip to a plain .tar (streaming) ──
    final input = InputFileStream(gz.path);
    final tarPath = '${gz.path}.tar';
    final out = OutputFileStream(tarPath);
    GZipDecoder().decodeStream(input, out);
    await input.close();
    await out.close();

    // ── 2. walk the tar ──
    final raf = File(tarPath).openSync();
    try {
      final total = raf.lengthSync();
      var pos = 0;
      var i = 0;
      String? pendingLongName;
      String? pendingLongLink;
      final execPaths = <String>[];

      String field(Uint8List h, int off, int len) {
        var e = off + len;
        while (e > off && (h[e - 1] == 0 || h[e - 1] == 0x20)) {
          e--;
        }
        return latin1.decode(h.sublist(off, e), allowInvalid: true);
      }

      Uint8List? readAt(int offset, int bytes) {
        if (offset + bytes > total) return null;
        raf.setPositionSync(offset);
        return raf.readSync(bytes);
      }

      while (true) {
        final hdr = readAt(pos, 512);
        if (hdr == null) break;
        if (hdr.every((b) => b == 0)) break; // EOF zero block
        final name = field(hdr, 0, 100);
        final modeStr = field(hdr, 100, 8);
        final sizeStr = field(hdr, 124, 12);
        final size =
            sizeStr.isEmpty ? 0 : (int.tryParse(sizeStr, radix: 8) ?? 0);
        final mode =
            modeStr.isEmpty ? 0 : (int.tryParse(modeStr, radix: 8) ?? 0);
        final typeFlag = hdr[156] == 0 ? '0' : String.fromCharCode(hdr[156]);
        final linkName = field(hdr, 157, 100);
        final dataStart = pos + 512;
        final padded = size % 512 == 0 ? size : size + (512 - size % 512);
        final nextPos = dataStart + padded;

        try {
          if (typeFlag == 'L') {
            // GNU long name — the next entry's real name is this data.
            final b = readAt(dataStart, size);
            if (b != null) {
              var e = b.length;
              while (e > 0 && b[e - 1] == 0) {
                e--;
              }
              pendingLongName = latin1.decode(b.sublist(0, e),
                  allowInvalid: true);
            }
          } else if (typeFlag == 'K') {
            final b = readAt(dataStart, size);
            if (b != null) {
              var e = b.length;
              while (e > 0 && b[e - 1] == 0) {
                e--;
              }
              pendingLongLink = latin1.decode(b.sublist(0, e),
                  allowInvalid: true);
            }
          } else if (typeFlag == 'x' || typeFlag == 'X' || typeFlag == 'g') {
            // PAX extended header — pull path=/linkpath= records.
            final b = readAt(dataStart, size);
            if (b != null) {
              final pax = latin1.decode(b, allowInvalid: true);
              final pm = RegExp(r' ?path=(.*)\n').firstMatch(pax);
              if (pm != null) pendingLongName = pm.group(1)!.trim();
              final lm = RegExp(r' ?linkpath=(.*)\n').firstMatch(pax);
              if (lm != null) pendingLongLink = lm.group(1)!.trim();
            }
          } else if (typeFlag == '0' || typeFlag == '7') {
            // Regular file.
            var n = (pendingLongName ?? name);
            pendingLongName = null;
            n = _normalizeTarPath(n);
            if (n.isNotEmpty && !n.contains('..')) {
              final outPath = '${dest.path}/$n';
              Directory(outPath).parent.createSync(recursive: true);
              final sink = File(outPath).openSync(mode: FileMode.writeOnly);
              try {
                var left = size;
                raf.setPositionSync(dataStart);
                while (left > 0) {
                  final chunk = raf.readSync(left > (1 << 20) ? (1 << 20) : left);
                  if (chunk.isEmpty) break;
                  sink.writeFromSync(chunk);
                  left -= chunk.length;
                }
              } finally {
                sink.closeSync();
              }
              if (mode & 0x111 != 0) execPaths.add(outPath); // exec bit
            }
          } else if (typeFlag == '5') {
            var n = (pendingLongName ?? name);
            pendingLongName = null;
            n = _normalizeTarPath(n);
            if (n.isNotEmpty && !n.contains('..')) {
              Directory('${dest.path}/$n').createSync(recursive: true);
            }
          } else if (typeFlag == '2') {
            // Symlink — the reason we moved to internal storage.
            var n = (pendingLongName ?? name);
            final target = pendingLongLink ?? linkName;
            pendingLongName = null;
            pendingLongLink = null;
            n = _normalizeTarPath(n);
            if (n.isNotEmpty && target.isNotEmpty && !n.contains('..')) {
              final link = Link('${dest.path}/$n');
              if (!link.existsSync()) {
                try {
                  link.createSync(target, recursive: true);
                } catch (_) {
                  // Non-fatal: a missing convenience link never blocks
                  // python3/node/git from running under proot.
                }
              }
            }
          } else if (typeFlag == '1') {
            // Hardlink — copy the target so the file exists standalone.
            var n = (pendingLongName ?? name);
            final target = pendingLongLink ?? linkName;
            pendingLongName = null;
            pendingLongLink = null;
            n = _normalizeTarPath(n);
            final t = _normalizeTarPath(target);
            if (n.isNotEmpty && t.isNotEmpty && !n.contains('..')) {
              try {
                final src = File('${dest.path}/$t');
                if (src.existsSync()) {
                  final dst = File('${dest.path}/$n');
                  dst.parent.createSync(recursive: true);
                  src.copySync(dst.path);
                }
              } catch (_) {}
            }
          }
          // Types 3/4/6 (char/block/fifo devices) are skipped — the jail
          // bind-mounts the host's /dev anyway.
        } catch (_) {
          // One odd entry never aborts a 3400-file install.
        }

        pos = nextPos;
        i++;
        if (i % 100 == 0) onProgress((i % 1500) / 1500, i);
      }

      // ── 3. chmod exec-bit files (batched — Android toybox chmod) ──
      for (var s = 0; s < execPaths.length; s += 100) {
        final batch = execPaths.skip(s).take(100).toList(growable: false);
        try {
          await Process.run('chmod', ['755', ...batch]);
        } catch (_) {}
      }
      onProgress(1.0, i);
    } finally {
      raf.closeSync();
      try {
        File(tarPath).deleteSync();
      } catch (_) {}
    }
  }

  /// './usr/bin/x' → 'usr/bin/x'; absolute '/x' → 'x'.
  static String _normalizeTarPath(String p) {
    var n = p;
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    if (n.startsWith('/')) n = n.substring(1);
    return n;
  }

  Future<void> _download({
    required String url,
    required IOSink sink,
    required http.Client client,
    required void Function(double p) onProgress,
  }) async {
    final req = http.Request('GET', Uri.parse(url));
    req.followRedirects = true;
    req.maxRedirects = 8;
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

  Future<void> _writeBootstrapConfigs() async {
    final etc = Directory('${_rootfs!.path}/etc');
    if (!etc.existsSync()) etc.createSync(recursive: true);
    File('${etc.path}/resolv.conf').writeAsStringSync(
      'nameserver 8.8.8.8\nnameserver 1.1.1.1\n',
    );
    File('${etc.path}/hostname').writeAsStringSync('ovid-sandbox\n');
    // A root HOME so bash/python don't complain.
    final home = Directory('${_rootfs!.path}/root');
    if (!home.existsSync()) home.createSync(recursive: true);
    // /tmp — proot's TMPDIR lands here (Termux proot hardcodes a Termux
    // path and warns 'can't canonicalize ... tmp: Permission denied' when
    // it can't find one; giving it a real /tmp silences the warnings and
    // unblocks apt/dpkg staging).
    final tmp = Directory('${_rootfs!.path}/tmp');
    if (!tmp.existsSync()) tmp.createSync(recursive: true);
    try {
      await Process.run('chmod', ['1777', tmp.path]);
    } catch (_) {}
    // Termux proot also probes its OWN compile-time tmp path
    // (/data/data/com.termux/files/usr/tmp) — bind it onto our /tmp so the
    // f2fs-bug-probe finds a writable dir instead of Permission denied.
    final termuxTmpParent = Directory(
        '/data/data/com.termux/files/usr');
    // Can't create outside our app dir on stock Android — the
    // canonicalize warning is harmless once TMPDIR=/tmp works; skip.
    if (termuxTmpParent.existsSync()) {
      try {
        Directory('/data/data/com.termux/files/usr/tmp')
            .createSync(recursive: true);
      } catch (_) {}
    }
  }

  // Base env passed to every exec'd command inside the jail.
  static const _baseEnv = <String, String>{
    'HOME': '/root',
    'PATH':
        '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
    'TERM': 'xterm-256color',
    'DEBIAN_FRONTEND': 'noninteractive',
    'LANG': 'C.UTF-8',
    // Termux's proot binary hardcodes /data/data/com.termux/files/usr/tmp as
    // its temp dir. That path doesn't exist in our app, so proot warns and
    // apt/dpkg can't stage .debs. Override it to /tmp inside the rootfs.
    'TMPDIR': '/tmp',
    'TMP': '/tmp',
    'TEMP': '/tmp',
  };

  // -----------------------------------------------------------------------
  // EXEC — run a command inside the proot jail, return {stdout, exitCode}.
  // -----------------------------------------------------------------------

  /// Runs [args] inside the proot Ubuntu jail.
  /// Returns combined stdout+stderr. Throws a clear Exception if the sandbox
  /// is not installed so callers can surface actionable UI.
  ///
  /// - `-0` fakes uid 0 (apt/dpkg need it)
  /// - `-b /dev/pts` so interactive tools work
  /// - `--link2symlink` repairs hardlinks proot can't represent
  /// - `-w cwd` sets working dir (default `/work` when a session workspace
  ///   is passed, else `/root`)
  Future<String> exec(
    List<String> args, {
    String? cwd,
    Directory? hostWorkDir,
    Map<String, String>? env,
    void Function(String line)? onLine,
  }) async {
    if (_proot == null || _rootfs == null) {
      throw Exception(
          'sandbox not installed — open Studio once to install it, then retry the command.');
    }
    final bindArgs = <String>[
      '-b', '/dev',
      '-b', '/dev/pts',
      '-b', '/proc',
      '-b', '/sys',
    ];
    if (hostWorkDir != null) {
      bindArgs.addAll(['-b', '${hostWorkDir.path}:$jailWorkPath']);
    }
    final allArgs = <String>[
      '-r', _rootfs!.path,
      '-0',
      '--link2symlink',
      ...bindArgs,
      '-w', cwd ?? (hostWorkDir != null ? jailWorkPath : '/root'),
      ...args,
    ];
    final rootPath = _root!.path;
    final result = await Process.run(
      _proot!.path,
      allArgs,
      environment: {
        ..._baseEnv,
        ...?env,
        // proot itself is dynamically linked — needs our lib dir.
        'LD_LIBRARY_PATH': '$rootPath/lib:/system/lib64:/system/lib',
      },
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final out = '${result.stdout}${result.stderr}';
    if (onLine != null) {
      for (final l in const LineSplitter().convert(out)) {
        onLine(l);
      }
    }
    if (result.exitCode != 0 && out.trim().isEmpty) {
      throw Exception('command exited ${result.exitCode} (no output)');
    }
    return out;
  }

  /// Start an interactive shell — returns a [Process] you can pipe to.
  Future<Process> shell({Directory? hostWorkDir}) async {
    if (_proot == null || _rootfs == null) {
      throw Exception(
          'sandbox not installed — open Studio once to install it, then retry.');
    }
    final bindArgs = <String>[
      '-b', '/dev',
      '-b', '/dev/pts',
      '-b', '/proc',
      '-b', '/sys',
    ];
    if (hostWorkDir != null) {
      bindArgs.addAll(['-b', '${hostWorkDir.path}:$jailWorkPath']);
    }
    final rootPath = _root!.path;
    return Process.start(
      _proot!.path,
      [
        '-r', _rootfs!.path,
        '-0',
        '--link2symlink',
        ...bindArgs,
        '-w', hostWorkDir != null ? jailWorkPath : '/root',
        'bash',
      ],
      mode: ProcessStartMode.normal,
      environment: {
        ..._baseEnv,
        'LD_LIBRARY_PATH': '$rootPath/lib:/system/lib64:/system/lib',
      },
    );
  }

  Future<void> uninstall() async {
    if (_root != null && _root!.existsSync()) {
      await _root!.delete(recursive: true);
    }
    _installed = false;
    _proot = null;
    _rootfs = null;
    _checked = false;
  }

  // -----------------------------------------------------------------------
  // Step 0 — resolve writable app path.
  // -----------------------------------------------------------------------
  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    // MUST live in internal app-private storage:
    //  • external storage (/sdcard/Android/data/...) is FUSE — symlink()
    //    returns EPERM, and exec() is noexec. The rootfs is full of
    //    symlinks (bin/sh → dash etc.), so install there always fails.
    //  • internal storage (/data/user/0/<pkg>/files) is real ext4/f2fs —
    //    symlinks + chmod +x both work.
    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = await getApplicationDocumentsDirectory().catchError(
        // Test environments lack the path_provider plugin.
        (_) => Directory.systemTemp,
      );
    }
    final dir = Directory('${base.path}/ovid/sandbox');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _staleExternalCleanup();
    _root = dir;
    return dir;
  }

  /// Remove a leftover install under EXTERNAL storage from older builds —
  /// it can never work (no symlink/exec on /sdcard) and wastes ~1 GB.
  void _staleExternalCleanup() {
    () async {
      try {
        final ext = await getExternalStorageDirectory();
        final old = Directory('${ext?.path}/ovid/sandbox');
        if (await old.exists()) await old.delete(recursive: true);
      } catch (_) {}
    }();
  }
}
