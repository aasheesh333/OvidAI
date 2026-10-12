/// apt trust-root and directory-layout maintenance for the sandbox prefix.
///
/// The app-bundled Termux signing keys (`assets/termux-keyring/*.gpg`) are
/// the AUTHORITATIVE trust roots. `$PREFIX/etc/apt/trusted.gpg.d` must hold
/// each of them as a readable REGULAR file with exactly the bundled bytes:
///
/// * The armeabi-v7a and x86_64 bootstrap payloads ship
///   `etc/apt/trusted.gpg.d/*.gpg` symlinks (SYMLINKS.txt) into
///   `share/termux-keyring/`, which those payloads do not contain, so every
///   entry is a DANGLING link. `File.existsSync` follows links, so the old
///   "seed if missing" logic wrote THROUGH the dangling link into a missing
///   directory and silently failed — apt was left without any usable key.
/// * Payload keyrings can be stale, removed or replaced by a repair, so
///   linking them is never safe.
///
/// Every write is temp-file + fsync + rename in the same directory; rename
/// replaces the directory entry (a symlink included) and never writes through
/// a link.
library;

import 'dart:io';

import 'diag.dart';

/// Outcome of one [AptTrust.reconcileKeyring] pass.
class AptTrustReport {
  /// Human-readable repair lines for the setup log (empty when nothing
  /// changed).
  final List<String> repairs = [];

  /// Keys that could not be made readable regular files.
  final List<String> failures = [];

  /// Bundled keys verified present, readable and byte-identical.
  int verified = 0;

  bool get ok => failures.isEmpty;
  bool get changed => repairs.isNotEmpty;
}

class AptTrust {
  AptTrust._();

  /// Directories apt / apt-key / dpkg expect under the prefix (relative).
  /// A missing one makes apt print "W: Unable to read …/etc/apt/…" or fail
  /// to write its partial downloads.
  static const aptDirectories = [
    'etc/apt',
    'etc/apt/apt.conf.d',
    'etc/apt/preferences.d',
    'etc/apt/sources.list.d',
    'etc/apt/trusted.gpg.d',
    'etc/apt/auth.conf.d',
    'etc/apt/keyrings',
    'var/lib/apt/lists/partial',
    'var/lib/apt/periodic',
    'var/cache/apt/archives/partial',
    'var/lib/dpkg/info',
    'var/lib/dpkg/updates',
    'var/lib/dpkg/triggers',
    'var/log/apt',
    'tmp',
  ];

  /// True when [bytes] start with a binary OpenPGP public-key packet tag
  /// apt-key/gpgv accept (0x99/0x98 old format, 0xC6 new format).
  static bool isBinaryKeyring(List<int> bytes) =>
      bytes.isNotEmpty && (bytes[0] == 0x99 || bytes[0] == 0x98 || bytes[0] == 0xC6);

  /// Create every [aptDirectories] entry (0755). A dangling symlink or a file
  /// squatting on a directory path is removed first. Returns repair lines.
  static List<String> ensureAptDirectories(Directory prefix) {
    final lines = <String>[];
    for (final rel in aptDirectories) {
      final path = '${prefix.path}/$rel';
      try {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        if (type == FileSystemEntityType.link &&
            FileSystemEntity.typeSync(path) != FileSystemEntityType.directory) {
          Link(path).deleteSync();
          lines.add('[apt] removed broken link at $rel');
        } else if (type == FileSystemEntityType.file) {
          File(path).deleteSync();
          lines.add('[apt] replaced file squatting on directory $rel');
        }
        final dir = Directory(path);
        if (!dir.existsSync()) {
          dir.createSync(recursive: true);
          _chmod('0755', path);
          lines.add('[apt] created missing directory $rel');
        }
      } catch (e) {
        lines.add('[apt] could not create $rel: $e');
      }
    }
    return lines;
  }

  /// Make [trustedDir] contain every [bundled] key as a readable regular
  /// file with exactly the bundled bytes. Idempotent: correct keys are never
  /// rewritten. Unknown extra keys are kept unless they are broken symlinks.
  /// Payload keys ([payloadKeyring]) are only copied — as regular files —
  /// when their name is not a bundled one and no usable entry exists.
  static AptTrustReport reconcileKeyring(
    Directory trustedDir,
    Map<String, List<int>> bundled, {
    Directory? payloadKeyring,
  }) {
    final report = AptTrustReport();
    try {
      final type = FileSystemEntity.typeSync(trustedDir.path, followLinks: false);
      if (type == FileSystemEntityType.link &&
          FileSystemEntity.typeSync(trustedDir.path) != FileSystemEntityType.directory) {
        Link(trustedDir.path).deleteSync();
        report.repairs.add('[keys] removed broken trusted.gpg.d link');
      } else if (type == FileSystemEntityType.file) {
        File(trustedDir.path).deleteSync();
        report.repairs.add('[keys] replaced file squatting on trusted.gpg.d');
      }
      trustedDir.createSync(recursive: true);
      _chmod('0755', trustedDir.path);
    } catch (e) {
      report.failures.add('trusted.gpg.d: $e');
      return report;
    }

    for (final e in bundled.entries) {
      final name = e.key;
      final want = e.value;
      final path = '${trustedDir.path}/$name';
      try {
        final type = FileSystemEntity.typeSync(path, followLinks: false);
        String? reason;
        switch (type) {
          case FileSystemEntityType.notFound:
            reason = 'missing';
          case FileSystemEntityType.link:
            reason = FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound
                ? 'dangling symlink'
                : 'symlink';
          case FileSystemEntityType.file:
            if (!_sameBytes(path, want)) {
              reason = 'stale or unreadable content';
            } else if (!_modeReadable(path)) {
              // Right bytes, restrictive mode: fix in place, no rewrite.
              _chmod('0644', path);
              if (_modeReadable(path)) {
                report.repairs.add('[keys] fixed permissions of $name (0644)');
              }
            }
          default:
            Directory(path).deleteSync(recursive: true);
            reason = 'not a regular file';
        }
        if (reason == null) {
          report.verified++;
          continue;
        }
        _atomicWrite(path, want);
        if (!_sameBytes(path, want)) {
          throw const FileSystemException('read-back mismatch after write');
        }
        report.verified++;
        report.repairs.add('[keys] repaired $name ($reason) → bundled key, verified readable');
      } catch (err) {
        report.failures.add('$name: $err');
        Diag.swallow('apt_trust', err);
      }
    }

    // Broken links (any name) only confuse apt-key; unknown real keys stay.
    try {
      for (final entity in trustedDir.listSync(followLinks: false)) {
        if (entity is! Link) continue;
        final name = entity.path.split('/').last;
        if (bundled.containsKey(name)) continue;
        if (FileSystemEntity.typeSync(entity.path) == FileSystemEntityType.notFound) {
          entity.deleteSync();
          report.repairs.add('[keys] removed dangling symlink $name');
        }
      }
    } catch (e) {
      Diag.swallow('apt_trust', e);
    }

    // Newer/unknown payload keys: regular-file copies, never links, never
    // over a bundled name.
    final payload = payloadKeyring;
    if (payload != null) {
      try {
        if (payload.existsSync()) {
          for (final entity in payload.listSync()) {
            final name = entity.path.split('/').last;
            if (!name.endsWith('.gpg') || bundled.containsKey(name)) continue;
            final dest = '${trustedDir.path}/$name';
            if (FileSystemEntity.typeSync(dest, followLinks: false) !=
                FileSystemEntityType.notFound) {
              continue;
            }
            final List<int> bytes;
            try {
              bytes = File(entity.path).readAsBytesSync();
            } catch (_) {
              continue;
            }
            if (!isBinaryKeyring(bytes)) continue;
            _atomicWrite(dest, bytes);
            report.repairs.add('[keys] added payload key $name as a regular file');
          }
        }
      } catch (e) {
        Diag.swallow('apt_trust', e);
      }
    }
    return report;
  }

  static bool _sameBytes(String path, List<int> want) {
    try {
      final got = File(path).readAsBytesSync();
      if (got.length != want.length) return false;
      for (var i = 0; i < got.length; i++) {
        if (got[i] != want[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Owner and group/other read bits (0644-style). apt runs as the app uid,
  /// but a 0600 file is still fixed so the layout matches Termux.
  static bool _modeReadable(String path) {
    if (Platform.isWindows) return true;
    final mode = File(path).statSync().mode;
    return mode & 0x124 == 0x124; // 0444
  }

  static void _atomicWrite(String path, List<int> bytes) {
    final dir = File(path).parent.path;
    final name = path.split('/').last;
    final tmp = File('$dir/.$name.ovid-tmp-$pid');
    try {
      if (FileSystemEntity.typeSync(tmp.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        tmp.deleteSync();
      }
      final raf = tmp.openSync(mode: FileMode.writeOnly);
      try {
        raf.writeFromSync(bytes);
        raf.flushSync(); // fsync
      } finally {
        raf.closeSync();
      }
      _chmod('0644', tmp.path);
      tmp.renameSync(path); // replaces the entry itself, never a link target
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  static void _chmod(String mode, String path) {
    for (final bin in const ['chmod', '/system/bin/chmod']) {
      try {
        if (Process.runSync(bin, [mode, path]).exitCode == 0) return;
      } catch (_) {}
    }
  }
}
