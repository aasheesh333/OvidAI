import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/settings_screen.dart'
    show formatStorageBytes, dirBytes, clearDirContents;

/// Storage screen helpers: byte formatting plus measure/clear over real
/// temp dirs (no path_provider mocking needed — helpers take Directory).
void main() {
  test('formatStorageBytes uses B/KB/MB/GB cutovers', () {
    expect(formatStorageBytes(0), '0 B');
    expect(formatStorageBytes(512), '512 B');
    expect(formatStorageBytes(1023), '1023 B');
    expect(formatStorageBytes(1024), '1.0 KB');
    expect(formatStorageBytes(1536), '1.5 KB');
    expect(formatStorageBytes(10240), '10 KB');
    expect(formatStorageBytes(1048576), '1.0 MB');
    expect(formatStorageBytes(10485760), '10 MB');
    expect(formatStorageBytes(1073741824), '1.0 GB');
  });

  test('dirBytes sums nested files, clearDirContents frees them', () async {
    final root = await Directory.systemTemp.createTemp('ovid-storage-test-');
    try {
      final sub = Directory('${root.path}/sub')..createSync();
      await File('${root.path}/a.bin').writeAsBytes(List.filled(100, 1));
      await File('${sub.path}/b.bin').writeAsBytes(List.filled(200, 2));

      expect(await dirBytes(root), 300);

      final freed = await clearDirContents(root);
      expect(freed, 300);
      // Dir itself survives, now empty.
      expect(await root.exists(), isTrue);
      expect(await dirBytes(root), 0);
    } finally {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
  });

  test('dirBytes and clearDirContents tolerate missing dirs', () async {
    final missing = Directory(
      '${Directory.systemTemp.path}/ovid-no-such-dir-${DateTime.now().microsecondsSinceEpoch}',
    );
    expect(await dirBytes(missing), 0);
    expect(await clearDirContents(missing), 0);
  });
}
