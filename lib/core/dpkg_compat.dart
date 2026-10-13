/// dpkg / apt layout compatibility for the relocated Termux payload.
///
/// The Termux `dpkg` binary has the Termux prefix COMPILED IN and, unlike
/// apt, offers no option or environment variable to move its configuration
/// directory. Before parsing ANY argument (even `--compare-versions` or
/// `--admindir`) it runs `scandir("/data/data/com.termux/files/usr/etc/dpkg/
/// dpkg.cfg.d")` and aborts on every error except ENOENT. On a device where
/// the Termux app is installed that directory belongs to another app's uid,
/// so the call fails with EACCES:
///
///     dpkg: error: error opening configuration directory
///     '/data/data/com.termux/files/usr/etc/dpkg/dpkg.cfg.d': Permission denied
///
/// (On devices without Termux the lookup reports ENOENT and dpkg carries on,
/// which is why the same APK worked elsewhere.) The termux-exec LD_PRELOAD
/// only rewrites exec paths, not scandir/open, so the only reliable fix is to
/// rewrite the compiled-in configuration path in the sandbox's own dpkg
/// binaries to a same-length path that never exists ([neutralPrefix]):
/// ENOENT is dpkg's documented "no configuration" case. The suffix
/// (`/etc/dpkg`) is kept byte-identical so tail-merged string constants are
/// unaffected. The patch is idempotent and re-applied before every apt /
/// ovid-pkg run (a package upgrade may replace the binary).
///
/// dpkg also extracts package members (`./data/data/com.termux/files/usr/…`)
/// relative to `--root`, and the Termux apt build resolves several of its
/// unset `Dir::*` defaults (e.g. `Dir::Log`) to `$Dir/data/data/com.termux/
/// files/usr/…`. [ensureTermuxPrefixAlias] makes that tree an alias of the
/// prefix itself (`data/data/com.termux/files/usr -> ../../../..`), so both
/// land inside the sandbox prefix instead of a parallel, unused copy.
library;

import 'dart:convert';
import 'dart:io';

import 'diag.dart';

class DpkgCompat {
  DpkgCompat._();

  /// The prefix compiled into every Termux binary.
  static const termuxPrefix = '/data/data/com.termux/files/usr';

  /// dpkg's compiled-in CONFIGDIR.
  static const termuxConfigDir = '$termuxPrefix/etc/dpkg';

  /// Same length as [termuxPrefix]. A top-level path that never exists, so
  /// the patched CONFIGDIR lookups report ENOENT ("no configuration").
  static const neutralPrefix = '/ovid-sandbox/termux-prefix/usr';

  /// The patched CONFIGDIR.
  static const neutralConfigDir = '$neutralPrefix/etc/dpkg';

  /// Relative path (under the sandbox prefix) of the Termux prefix alias.
  static const aliasPath = 'data/data/com.termux/files/usr';

  /// Alias target: four levels up from `data/data/com.termux/files`.
  static const aliasTarget = '../../../..';

  static final List<int> _needle = [...ascii.encode(termuxConfigDir), 0];
  static final List<int> _replacement = [...ascii.encode(neutralConfigDir), 0];

  /// Byte offsets of every NUL-terminated compiled-in CONFIGDIR in [bytes].
  static List<int> configDirOffsets(List<int> bytes) {
    final hits = <int>[];
    final first = _needle.first;
    outer:
    for (var i = 0; i <= bytes.length - _needle.length; i++) {
      if (bytes[i] != first) continue;
      for (var j = 1; j < _needle.length; j++) {
        if (bytes[i + j] != _needle[j]) continue outer;
      }
      // Only a whole string: the previous byte must end another string.
      if (i > 0 && bytes[i - 1] != 0) continue;
      hits.add(i);
    }
    return hits;
  }

  /// [bytes] with every compiled-in CONFIGDIR rewritten to
  /// [neutralConfigDir]; null when there is nothing to patch.
  static List<int>? patchedConfigDir(List<int> bytes) {
    final hits = configDirOffsets(bytes);
    if (hits.isEmpty) return null;
    final out = List<int>.of(bytes);
    for (final at in hits) {
      out.setRange(at, at + _replacement.length, _replacement);
    }
    return out;
  }

  /// Rewrite the compiled-in CONFIGDIR in every `bin/dpkg*` regular file of
  /// [prefix]. Temp file + rename in the same directory (never writes
  /// through a link, no ETXTBSY), permissions preserved. Returns log lines
  /// for the binaries that were patched; never throws.
  static List<String> patchDpkgBinaries(Directory prefix) {
    final lines = <String>[];
    final bin = Directory('${prefix.path}/bin');
    if (!bin.existsSync()) return lines;
    List<FileSystemEntity> entries;
    try {
      entries = bin.listSync(followLinks: false);
    } catch (e) {
      Diag.swallow('dpkg_compat', e);
      return lines;
    }
    for (final entity in entries) {
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('dpkg') || entity is! File) continue;
      try {
        final patched = patchedConfigDir(entity.readAsBytesSync());
        if (patched == null) continue;
        final mode = entity.statSync().mode & 0x1FF;
        final tmp = File('${bin.path}/.$name.ovid-patch');
        tmp.writeAsBytesSync(patched, flush: true);
        _chmod(mode.toRadixString(8).padLeft(4, '0'), tmp.path);
        tmp.renameSync(entity.path);
        lines.add('[dpkg] $name: compiled-in Termux config dir neutralised');
      } catch (e) {
        lines.add('[dpkg] could not patch $name: $e');
      }
    }
    return lines;
  }

  /// Make `<prefix>/data/data/com.termux/files/usr` a relative symlink to the
  /// prefix. A real directory there (files from an earlier dpkg run that
  /// never reached PATH) is moved aside, never deleted. Returns log lines.
  static List<String> ensureTermuxPrefixAlias(Directory prefix) {
    final lines = <String>[];
    final path = '${prefix.path}/$aliasPath';
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        if (Link(path).targetSync() == aliasTarget) return lines;
        Link(path).deleteSync();
      } else if (type == FileSystemEntityType.directory) {
        final aside = '$path.orphaned-${DateTime.now().millisecondsSinceEpoch}';
        Directory(path).renameSync(aside);
        lines.add('[dpkg] moved stray ${aliasPath.split('/').last} tree aside '
            '(${aside.substring(prefix.path.length + 1)})');
      } else if (type != FileSystemEntityType.notFound) {
        File(path).deleteSync();
      }
      Directory(File(path).parent.path).createSync(recursive: true);
      Link(path).createSync(aliasTarget);
      lines.add('[dpkg] mapped the Termux prefix onto the sandbox prefix');
    } catch (e) {
      lines.add('[dpkg] could not map the Termux prefix: $e');
    }
    return lines;
  }

  static void _chmod(String mode, String path) {
    for (final bin in const ['chmod', '/system/bin/chmod']) {
      try {
        if (Process.runSync(bin, [mode, path]).exitCode == 0) return;
      } catch (e) {
        Diag.swallow('dpkg_compat', e);
      }
    }
  }
}
