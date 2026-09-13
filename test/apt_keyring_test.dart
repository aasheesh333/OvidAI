import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// P0 (2026-09-13): apt GPG keyring seeding. Non-arm64 payloads ship no
/// share/termux-keyring, so trusted.gpg.d stays empty and every mirror fails
/// with "InRelease is not signed". The app must seed the bundled
/// architecture-independent keys on boot.
void main() {
  group('apt keyring seeding', () {
    late Directory tmp;
    late Directory trusted;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('apt-keyring');
      trusted = Directory('${tmp.path}/trusted.gpg.d');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('writes missing keys and returns the count', () {
      final written = SandboxService.seedAptKeyring(trusted, {
        'a.gpg': [1, 2, 3],
        'b.gpg': [4, 5],
      });
      expect(written, 2);
      expect(File('${trusted.path}/a.gpg').readAsBytesSync(), [1, 2, 3]);
      expect(File('${trusted.path}/b.gpg').readAsBytesSync(), [4, 5]);
    });

    test('is idempotent and never overwrites a non-empty key', () {
      SandboxService.seedAptKeyring(trusted, {
        'a.gpg': [1, 2, 3],
      });
      expect(SandboxService.seedAptKeyring(trusted, {'a.gpg': [1, 2, 3]}), 0);
      // A real key from the payload (or a previous seed) wins.
      File('${trusted.path}/a.gpg').writeAsBytesSync([9, 9]);
      expect(SandboxService.seedAptKeyring(trusted, {'a.gpg': [1, 2, 3]}), 0);
      expect(File('${trusted.path}/a.gpg').readAsBytesSync(), [9, 9]);
    });

    test('repairs an empty (0-byte) key file', () {
      SandboxService.seedAptKeyring(trusted, {
        'a.gpg': [1, 2, 3],
      });
      File('${trusted.path}/a.gpg').writeAsBytesSync([]);
      expect(SandboxService.seedAptKeyring(trusted, {'a.gpg': [1, 2, 3]}), 1);
      expect(File('${trusted.path}/a.gpg').readAsBytesSync(), [1, 2, 3]);
    });
  });
}
