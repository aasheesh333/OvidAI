import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// First-launch budget: the app must be interactive in under a minute.
/// The sandbox payload extract (a ~32 MB zip) runs in a worker isolate via
/// [compute] so the setup screen never freezes. These tests build a small
/// synthetic payload and exercise the real isolate round-trip.
void main() {
  group('deferred-install payload extract', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ovid-payload-extract');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Uint8List makePayload() {
      final archive = Archive()
        ..addFile(ArchiveFile('bin/bash', 5, [1, 2, 3, 4, 5]))
        ..addFile(ArchiveFile('lib/libfoo.so', 3, [6, 7, 8]))
        ..addFile(
          ArchiveFile.string('SYMLINKS.txt', 'dash←bin/sh\ncoreutils←bin/ls\n'),
        );
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    test('compute round-trip extracts files and parses symlinks', () async {
      final staging = Directory('${tmp.path}/staging')..createSync();
      final result = await compute(decodeAndExtractPayload, (
        bytes: makePayload(),
        stagingPath: staging.path,
      ));
      expect(result.count, 2);
      expect(result.symlinks, hasLength(2));
      expect(result.symlinks[0].target, 'dash');
      expect(result.symlinks[0].linkPath, 'bin/sh');
      expect(File('${staging.path}/bin/bash').readAsBytesSync(), [
        1,
        2,
        3,
        4,
        5,
      ]);
      expect(File('${staging.path}/lib/libfoo.so').readAsBytesSync(), [
        6,
        7,
        8,
      ]);
      // SYMLINKS.txt is consumed, not extracted.
      expect(File('${staging.path}/SYMLINKS.txt').existsSync(), isFalse);
    });

    test(
      'payload without SYMLINKS.txt extracts with empty symlink list',
      () async {
        final archive = Archive()..addFile(ArchiveFile('bin/x', 1, [9]));
        final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
        final staging = Directory('${tmp.path}/staging2')..createSync();
        final result = await compute(decodeAndExtractPayload, (
          bytes: bytes,
          stagingPath: staging.path,
        ));
        expect(result.count, 1);
        expect(result.symlinks, isEmpty);
        expect(File('${staging.path}/bin/x').readAsBytesSync(), [9]);
      },
    );
  });
}
