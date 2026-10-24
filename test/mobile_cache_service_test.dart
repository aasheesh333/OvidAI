import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mobile_cache_service.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/storage_page.dart';

Future<File> _file(Directory root, String relative, List<int> bytes) async {
  final file = File('${root.path}${Platform.pathSeparator}$relative');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ovid-mobile-cache-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'measure and clear report bytes and preserve account and server data',
    () async {
      await _file(root, 'cache/images.png', List.filled(11, 1));
      final credentials = await _file(root, 'credentials.json', [1, 2, 3]);
      final settings = await _file(root, 'settings.json', [4, 5]);
      final serverText = await _file(root, 'server-text/session.txt', [
        6,
        7,
        8,
        9,
      ]);
      final tokenInsideCache = await _file(root, 'cache/auth-token.bin', [10]);
      Object token = Object();
      final service = MobileCacheService(
        rootDirectory: () async => root,
        resetFenceToken: () => token,
        resetWritesAllowed: () => true,
      );

      final measured = await service.measure();
      expect(measured.beforeBytes, 11);
      expect(measured.afterBytes, 11);
      expect(measured.residualBytes, 11);

      final cleared = await service.clear();
      expect(cleared.beforeBytes, 11);
      expect(cleared.afterBytes, 0);
      expect(cleared.residualBytes, 0);
      expect(cleared.freedBytes, 11);
      expect(await credentials.readAsBytes(), [1, 2, 3]);
      expect(await settings.readAsBytes(), [4, 5]);
      expect(await serverText.readAsBytes(), [6, 7, 8, 9]);
      expect(await tokenInsideCache.readAsBytes(), [10]);
    },
  );

  test(
    'clear reports undeletable residual bytes instead of claiming success',
    () async {
      await _file(root, 'cache/remove.png', List.filled(4, 1));
      await _file(root, 'cache/locked.png', List.filled(3, 1));
      final token = Object();
      final service = MobileCacheService(
        rootDirectory: () async => root,
        resetFenceToken: () => token,
        resetWritesAllowed: () => true,
        deleteEntity: (entity) async {
          if (entity.path.endsWith('locked.png')) {
            throw const FileSystemException('locked');
          }
          await entity.delete(recursive: true);
        },
      );

      final report = await service.clear();

      expect(report.beforeBytes, 7);
      expect(report.afterBytes, 3);
      expect(report.residualBytes, 3);
      expect(report.freedBytes, 4);
      expect(await File('${root.path}/cache/locked.png').length(), 3);
    },
  );

  test(
    'a reset fence stops further cache deletion and reports the residue',
    () async {
      await _file(root, 'cache/a.png', List.filled(4, 1));
      await _file(root, 'cache/b.png', List.filled(4, 1));
      var token = Object();
      var deletes = 0;
      final service = MobileCacheService(
        rootDirectory: () async => root,
        resetFenceToken: () => token,
        resetWritesAllowed: () => true,
        deleteEntity: (entity) async {
          if (entity is File) {
            deletes++;
            token = Object();
          }
          await entity.delete(recursive: true);
        },
      );

      final report = await service.clear();

      expect(deletes, 1);
      expect(report.beforeBytes, 8);
      expect(report.afterBytes, 4);
      expect(report.residualBytes, 4);
      expect(report.freedBytes, 4);
    },
  );

  test('an active reset prevents cache deletion before it starts', () async {
    await _file(root, 'cache/a.png', List.filled(4, 1));
    var deletes = 0;
    final token = Object();
    final service = MobileCacheService(
      rootDirectory: () async => root,
      resetFenceToken: () => token,
      resetWritesAllowed: () => false,
      deleteEntity: (entity) async {
        deletes++;
        await entity.delete(recursive: true);
      },
    );

    final report = await service.clear();

    expect(deletes, 0);
    expect(report.beforeBytes, 4);
    expect(report.afterBytes, 4);
    expect(report.residualBytes, 4);
  });

  test(
    'unknown credential and transcript files remain as measured residue',
    () async {
      final canaries = <String, int>{
        'cache/id_rsa': 4,
        'cache/id_rsa.bin': 2,
        'cache/key.pem': 5,
        'cache/conversation.log': 6,
        'cache/transcript.zip': 7,
        'cache/unknown.dat': 8,
      };
      for (final entry in canaries.entries) {
        await _file(root, entry.key, List.filled(entry.value, 1));
      }
      await _file(root, 'cache/image.png', List.filled(9, 1));
      final token = Object();
      final service = MobileCacheService(
        rootDirectory: () async => root,
        resetFenceToken: () => token,
        resetWritesAllowed: () => true,
      );

      final report = await service.clear();

      expect(report.beforeBytes, 41);
      expect(report.afterBytes, 32);
      expect(report.residualBytes, 32);
      expect(report.freedBytes, 9);
      for (final path in canaries.keys) {
        expect(
          await File('${root.path}/$path').readAsBytes(),
          List.filled(canaries[path]!, 1),
          reason: path,
        );
      }
      expect(await File('${root.path}/cache/image.png').exists(), isFalse);
    },
  );

  test(
    'unmeasurable residual is unknown and never reported as empty',
    () async {
      await Directory('${root.path}/cache').create(recursive: true);
      final link = Link('${root.path}/cache/unreadable.png');
      await link.create('${root.path}/missing-target.png');
      final token = Object();
      final service = MobileCacheService(
        rootDirectory: () async => root,
        resetFenceToken: () => token,
        resetWritesAllowed: () => true,
      );

      final report = await service.clear();

      expect(report.residualBytes, isNull);
      expect(report.freedBytes, isNull);
      expect(report.afterBytes, isNull);
      expect(
        FileSystemEntity.typeSync(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
    },
  );

  testWidgets('storage uses the measured report and shows residual bytes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: StoragePage(
          data: V2StoragePageData(
            usedGb: 1,
            totalGb: 3,
            planName: 'Free',
            cacheSizeLabel: '7 B',
            onClearCacheMeasured: () async => const CacheClearReport(
              beforeBytes: 7,
              afterBytes: 3,
              residualBytes: 3,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pump();

    expect(find.text('Freed 4 B; 3 B left.'), findsOneWidget);
  });
}
