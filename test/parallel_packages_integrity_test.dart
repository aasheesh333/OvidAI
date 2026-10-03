import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'parallel_packages_graph_test.dart' show PackageFixture;

void main() {
  late PackageFixture f;
  setUp(() => f = PackageFixture());
  tearDown(() => f.dispose());

  for (final field in ['SHA256', 'Size', 'Filename']) {
    test('missing $field fails before download', () async {
      f.add('app');
      f.records[0] = f.records[0].replaceFirst(RegExp('$field: [^\n]*\n'), '');
      f.expectRejected(await f.install(['app']), 'metadata');
    });
  }

  for (final path in [
    '../app.deb',
    '/pool/app.deb',
    'pool/../app.deb',
    'pool/app.zip',
    'pool/app.deb?redirect=1',
    'pool/app.deb|injected',
  ]) {
    test('unsafe archive metadata path $path fails before download', () async {
      f.add('app');
      f.records[0] = f.records[0].replaceFirst(
        RegExp(r'Filename: [^\n]*'),
        'Filename: $path',
      );
      f.expectRejected(await f.install(['app']), 'metadata');
    });
  }

  test('tampered hash blocks extraction of the entire closure', () async {
    f.add('app', depends: 'lib');
    f.add('lib');
    f.records[0] = f.records[0].replaceFirst(
      RegExp(r'SHA256: [^\n]*'),
      'SHA256: ${'0' * 64}',
    );
    f.expectRejected(await f.install(['app']), 'SHA256', beforeDownload: false);
  });

  test('truncated archive fails size verification before extraction', () async {
    f.add('app');
    final archive = File('${f.root.path}/repo/pool/app_1.0_aarch64.deb');
    archive.writeAsBytesSync(archive.readAsBytesSync().take(100).toList());
    f.expectRejected(await f.install(['app']), 'size', beforeDownload: false);
  });

  test(
    'metadata matching corrupt archive still fails archive validation',
    () async {
      f.add('app');
      final bytes = [1, 2, 3, 4];
      File(
        '${f.root.path}/repo/pool/app_1.0_aarch64.deb',
      ).writeAsBytesSync(bytes);
      f.records[0] = f.records[0]
          .replaceFirst(RegExp(r'Size: [^\n]*'), 'Size: 4')
          .replaceFirst(
            RegExp(r'SHA256: [^\n]*'),
            'SHA256: ${sha256.convert(bytes)}',
          );
      f.expectRejected(
        await f.install(['app']),
        'archive',
        beforeDownload: false,
      );
    },
  );

  test('archive identity must match selected index record', () async {
    f.add('app');
    f.records[0] = f.records[0].replaceFirst('Version: 1.0', 'Version: 2.0');
    f.expectRejected(
      await f.install(['app']),
      'identity',
      beforeDownload: false,
    );
  });

  test('escaping archive symlink is rejected before extraction', () async {
    f.add('app', symlink: '../../outside');
    f.expectRejected(
      await f.install(['app']),
      'archive',
      beforeDownload: false,
    );
  });

  test('safe relative symlink is preserved', () async {
    f.add('app', symlink: 'app');
    final result = await f.install(['app']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(Link('${f.prefix}/share/link').targetSync(), 'app');
  });

  test(
    'existing destination symlink cannot redirect extraction outside prefix',
    () async {
      f.add('app');
      final outside = Directory('${f.root.path}/outside')..createSync();
      Link('${f.prefix}/share').createSync(outside.path);
      final result = await f.install(['app']);
      expect(
        result.exitCode,
        isNot(0),
        reason: '${result.stdout}${result.stderr}',
      );
      expect('${result.stderr}', contains('symlink'));
      expect(File('${outside.path}/app').existsSync(), isFalse);
    },
  );

  test(
    'download exit status wins over success-looking output and valid bytes',
    () async {
      f.add('app');
      f.stub('curl', r'''
previous=""
for arg in "$@"; do
  [ "$previous" = -o ] && cp "$FIXTURE_REPO/pool/app_1.0_aarch64.deb" "$arg"
  previous="$arg"
done
echo '[ovid-pkg] extracted 1 package(s)'
exit 23
''');
      final result = await f.install(['app']);
      expect(result.exitCode, 23);
      expect(Directory('${f.prefix}/share').existsSync(), isFalse);
    },
  );

  test(
    'extraction preserves actual nonzero status despite success text',
    () async {
      f.add('app');
      f.stub('dpkg-deb', r'''
if [ "$1" = -x ]; then echo 'extracted successfully'; exit 7; fi
exec /usr/bin/dpkg-deb "$@"
''');
      final result = await f.install(['app']);
      expect(result.exitCode, 7, reason: '${result.stdout}${result.stderr}');
      expect(Directory('${f.prefix}/share').existsSync(), isFalse);
    },
  );

  test(
    'tar listing exit status wins over apparently safe member list',
    () async {
      f.add('app');
      f.stub('tar', "echo './share/app'; exit 9");
      f.expectRejected(
        await f.install(['app']),
        'archive',
        beforeDownload: false,
      );
    },
  );

  test(
    'list preserves dpkg failure instead of the output truncator status',
    () async {
      f.stub('dpkg', 'echo "package installed"; exit 12');
      final result = await Process.run(
        '/bin/sh',
        ['${f.prefix}/bin/ovid-pkg', 'list'],
        environment: {
          'PREFIX': f.prefix,
          'PATH': '${f.root.path}/stubs:${f.prefix}/bin:/usr/bin:/bin',
        },
      );
      expect(result.exitCode, 12);
    },
  );

  test(
    'Termux rooted payload relocates after verified staged extraction',
    () async {
      f.add('app', termux: true);
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(File('${f.prefix}/share/app').readAsStringSync(), '1.0');
      expect(Directory('${f.prefix}/data').existsSync(), isFalse);
    },
  );

  test('failed relocation cannot print package completion', () async {
    f.add('app', termux: true);
    Directory('${f.prefix}/share').createSync();
    f.stub('cp', r'''
case "$2" in */data/data/com.termux/files/usr/share/.) exit 8;; esac
exec /bin/cp "$@"
''');
    final result = await f.install(['app']);
    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', contains('could not relocate'));
    expect('${result.stdout}', isNot(contains('[ovid-pkg] extracted')));
    expect(File('${f.prefix}/share/app').existsSync(), isFalse);
  });
}
