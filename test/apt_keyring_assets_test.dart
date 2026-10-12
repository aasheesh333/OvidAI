import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// Every bundled trust root must be a binary OpenPGP keyring that EVERY
/// apt-key build in the payloads accepts: first byte 0x99 (old-format
/// public-key packet, two-octet length) or 0xC6 (new-format public key).
/// Upstream thunder-coding.gpg started with 0x98 (one-octet length) and was
/// re-encoded losslessly by tool/normalize_openpgp_keyring.py.
void main() {
  /// Walks the packet stream; returns the packet tags or throws.
  List<int> packetTags(List<int> data) {
    final tags = <int>[];
    var i = 0;
    while (i < data.length) {
      final h = data[i];
      if (h & 0x80 == 0) throw FormatException('no packet header at $i');
      int tag, length, header;
      if (h & 0x40 != 0) {
        tag = h & 0x3f;
        final f = data[i + 1];
        if (f < 192) {
          length = f;
          header = 2;
        } else if (f < 224) {
          length = ((f - 192) << 8) + data[i + 2] + 192;
          header = 3;
        } else if (f == 255) {
          length = (data[i + 2] << 24) | (data[i + 3] << 16) | (data[i + 4] << 8) | data[i + 5];
          header = 6;
        } else {
          throw FormatException('partial length at $i');
        }
      } else {
        tag = (h >> 2) & 0x0f;
        final size = const [1, 2, 4, 0][h & 3];
        if (size == 0) throw FormatException('indeterminate length at $i');
        length = 0;
        for (var k = 0; k < size; k++) {
          length = (length << 8) | data[i + 1 + k];
        }
        header = 1 + size;
      }
      if (i + header + length > data.length) throw FormatException('truncated packet at $i');
      tags.add(tag);
      i += header + length;
    }
    return tags;
  }

  for (final name in SandboxService.aptKeyringAssetNames) {
    test('$name starts with 0x99/0xC6 and parses as a public keyring', () {
      final bytes = File('assets/termux-keyring/$name').readAsBytesSync();
      expect(bytes.first, anyOf(0x99, 0xC6), reason: 'first byte 0x${bytes.first.toRadixString(16)}');
      final tags = packetTags(bytes);
      expect(tags.first, 6, reason: 'first packet must be a public key');
      expect(tags, contains(13), reason: 'at least one user ID');
      expect(tags, contains(2), reason: 'at least one signature');
    });
  }

  test('pubspec bundles exactly the declared keyring assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final name in SandboxService.aptKeyringAssetNames) {
      expect(pubspec, contains('assets/termux-keyring/$name'));
    }
    final onDisk = Directory('assets/termux-keyring')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((n) => n.endsWith('.gpg'))
        .toSet();
    expect(onDisk, SandboxService.aptKeyringAssetNames.toSet());
  });

  test('re-encoded thunder-coding.gpg keeps its fingerprint (gpg --show-keys)', () {
    final gpg = Process.runSync('sh', ['-c', 'command -v gpg']);
    if (gpg.exitCode != 0) {
      markTestSkipped('gpg not installed');
      return;
    }
    final r = Process.runSync('gpg', [
      '--batch', '--show-keys', '--with-colons', 'assets/termux-keyring/thunder-coding.gpg',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final fprs = '${r.stdout}'
        .split('\n')
        .where((l) => l.startsWith('fpr:'))
        .map((l) => l.split(':')[9])
        .toList();
    expect(fprs, ['94104F935B5362B3150EB7C1FDD928D965207016', '28FC80B28DC8A87A106824AD9BED6E85D67F21EB']);
  });
}
