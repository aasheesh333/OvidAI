import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/apt_trust.dart';

/// apt trust roots (2026-10-12 device report): apt dropped every key
/// ("unsupported filetype", NO_PUBKEY 5A897D96E57CF20C, "repository is not
/// signed"). The armeabi-v7a / x86_64 payloads ship trusted.gpg.d symlinks
/// into a share/termux-keyring they do not contain, and the old seeder skipped
/// "existing" keys / wrote through dangling links. The bundled keys must end
/// up as readable regular files with the exact bundled bytes.
void main() {
  late Directory tmp;
  late Directory trusted;
  final keyA = [0x99, 0x00, 0x01, 0xAA];
  final keyB = [0x99, 0x00, 0x01, 0xBB];
  Map<String, List<int>> bundled() => {'a.gpg': keyA, 'b.gpg': keyB};

  int mode(String path) => File(path).statSync().mode & 0x1ff;
  bool isRegular(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('apt-keyring');
    trusted = Directory('${tmp.path}/etc/apt/trusted.gpg.d');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('writes missing keys as 0644 regular files in a 0755 directory', () {
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(r.ok, isTrue, reason: r.failures.join());
    expect(r.verified, 2);
    for (final e in bundled().entries) {
      final path = '${trusted.path}/${e.key}';
      expect(isRegular(path), isTrue);
      expect(File(path).readAsBytesSync(), e.value);
      expect(mode(path), 0x1a4, reason: '0644'); // 0644
    }
    expect(mode(trusted.path), 0x1ed, reason: '0755'); // 0755
    expect(r.repairs.join('\n'), contains('repaired a.gpg (missing)'));
  });

  test('dangling symlinks (arm32/x86_64 payload layout) become regular files', () {
    trusted.createSync(recursive: true);
    for (final name in ['a.gpg', 'b.gpg']) {
      Link('${trusted.path}/$name').createSync('${tmp.path}/share/termux-keyring/$name');
    }
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(r.ok, isTrue);
    for (final e in bundled().entries) {
      final path = '${trusted.path}/${e.key}';
      expect(isRegular(path), isTrue, reason: '${e.key} must not stay a link');
      expect(File(path).readAsBytesSync(), e.value);
    }
    // Nothing was written THROUGH the links.
    expect(Directory('${tmp.path}/share').existsSync(), isFalse);
    expect(r.repairs.join('\n'), contains('dangling symlink'));
  });

  test('symlink to a valid file is replaced by a regular copy; target untouched', () {
    final payload = File('${tmp.path}/share/termux-keyring/a.gpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([0x99, 0, 1, 0x11]);
    trusted.createSync(recursive: true);
    Link('${trusted.path}/a.gpg').createSync(payload.path);
    AptTrust.reconcileKeyring(trusted, bundled());
    expect(isRegular('${trusted.path}/a.gpg'), isTrue);
    expect(File('${trusted.path}/a.gpg').readAsBytesSync(), keyA);
    expect(payload.readAsBytesSync(), [0x99, 0, 1, 0x11]);
  });

  test('stale/different key is replaced, correct key is never rewritten', () {
    AptTrust.reconcileKeyring(trusted, bundled());
    final b = File('${trusted.path}/b.gpg');
    final before = b.statSync();
    File('${trusted.path}/a.gpg').writeAsBytesSync([0x98, 0x01, 0x00]);
    sleep(const Duration(milliseconds: 20));
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(File('${trusted.path}/a.gpg').readAsBytesSync(), keyA);
    expect(r.repairs.join('\n'), contains('a.gpg (stale or unreadable content)'));
    expect(r.repairs.join('\n'), isNot(contains('b.gpg')));
    final after = b.statSync();
    expect(after.modified, before.modified);
    expect(after.changed, before.changed, reason: 'no rename over a correct key');
    // Fully idempotent second pass.
    final again = AptTrust.reconcileKeyring(trusted, bundled());
    expect(again.changed, isFalse);
    expect(again.verified, 2);
  });

  test('empty key file and 0600 permissions are repaired', () {
    AptTrust.reconcileKeyring(trusted, bundled());
    File('${trusted.path}/a.gpg').writeAsBytesSync([]);
    Process.runSync('chmod', ['0600', '${trusted.path}/b.gpg']);
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(File('${trusted.path}/a.gpg').readAsBytesSync(), keyA);
    expect(mode('${trusted.path}/b.gpg'), 0x1a4);
    expect(r.repairs.join('\n'), contains('fixed permissions of b.gpg'));
  });

  test('a directory squatting on a key name is replaced', () {
    Directory('${trusted.path}/a.gpg/x').createSync(recursive: true);
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(r.ok, isTrue);
    expect(isRegular('${trusted.path}/a.gpg'), isTrue);
  });

  test('unknown user keys are kept; only broken symlinks are removed', () {
    trusted.createSync(recursive: true);
    File('${trusted.path}/user.gpg').writeAsBytesSync([0x99, 0, 1, 0x42]);
    File('${tmp.path}/elsewhere.gpg').writeAsBytesSync([0x99, 0, 1, 0x43]);
    Link('${trusted.path}/linked.gpg').createSync('${tmp.path}/elsewhere.gpg');
    Link('${trusted.path}/broken.gpg').createSync('${tmp.path}/missing.gpg');
    final r = AptTrust.reconcileKeyring(trusted, bundled());
    expect(File('${trusted.path}/user.gpg').readAsBytesSync(), [0x99, 0, 1, 0x42]);
    expect(FileSystemEntity.isLinkSync('${trusted.path}/linked.gpg'), isTrue);
    expect(FileSystemEntity.typeSync('${trusted.path}/broken.gpg', followLinks: false),
        FileSystemEntityType.notFound);
    expect(r.repairs.join('\n'), contains('removed dangling symlink broken.gpg'));
  });

  test('payload keys are copied only for non-bundled names, as regular files', () {
    final share = Directory('${tmp.path}/share/termux-keyring')..createSync(recursive: true);
    File('${share.path}/a.gpg').writeAsBytesSync([0x99, 0, 1, 0x77]); // stale payload copy
    File('${share.path}/new.gpg').writeAsBytesSync([0xC6, 0x01, 0x00]);
    File('${share.path}/junk.gpg').writeAsStringSync('-----BEGIN PGP');
    AptTrust.reconcileKeyring(trusted, bundled(), payloadKeyring: share);
    expect(File('${trusted.path}/a.gpg').readAsBytesSync(), keyA);
    expect(isRegular('${trusted.path}/new.gpg'), isTrue);
    expect(File('${trusted.path}/new.gpg').readAsBytesSync(), [0xC6, 0x01, 0x00]);
    expect(File('${trusted.path}/junk.gpg').existsSync(), isFalse);
  });

  test('no temp files are left behind', () {
    AptTrust.reconcileKeyring(trusted, bundled());
    final names = trusted.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
    expect(names, ['a.gpg', 'b.gpg']);
  });

  group('apt directories', () {
    test('creates every directory apt expects (0755) and replaces broken links', () {
      final prefix = Directory('${tmp.path}/prefix')..createSync();
      Directory('${prefix.path}/etc/apt').createSync(recursive: true);
      Link('${prefix.path}/etc/apt/preferences.d').createSync('${tmp.path}/gone');
      final lines = AptTrust.ensureAptDirectories(prefix);
      for (final rel in [
        'etc/apt/apt.conf.d', 'etc/apt/preferences.d', 'etc/apt/sources.list.d',
        'etc/apt/trusted.gpg.d', 'etc/apt/auth.conf.d', 'etc/apt/keyrings',
        'var/lib/apt/lists/partial', 'var/cache/apt/archives/partial',
      ]) {
        expect(Directory('${prefix.path}/$rel').existsSync(), isTrue, reason: rel);
        expect(FileSystemEntity.isLinkSync('${prefix.path}/$rel'), isFalse, reason: rel);
      }
      expect(mode('${prefix.path}/var/lib/apt/lists/partial'), 0x1ed);
      expect(lines.join('\n'), contains('removed broken link at etc/apt/preferences.d'));
      expect(AptTrust.ensureAptDirectories(prefix), isEmpty, reason: 'idempotent');
    });
  });

  test('isBinaryKeyring accepts only binary OpenPGP public-key packets', () {
    expect(AptTrust.isBinaryKeyring([0x99]), isTrue);
    expect(AptTrust.isBinaryKeyring([0x98]), isTrue);
    expect(AptTrust.isBinaryKeyring([0xC6]), isTrue);
    expect(AptTrust.isBinaryKeyring('-----BEGIN'.codeUnits), isFalse);
    expect(AptTrust.isBinaryKeyring([]), isFalse);
  });
}
