import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_pkg.dart';

// Offline integration fixtures execute the generated installer and real host
// dpkg-deb/tar/hash tools. Only transport is replaced; nothing is installed.
class PackageFixture {
  final Directory root = Directory.systemTemp.createTempSync(
    'parallel-packages-',
  );
  final List<String> records = [];
  late final String prefix = '${root.path}/prefix';

  PackageFixture() {
    OvidPkgInstaller.writeAll(Directory(prefix), arch: 'aarch64');
    Link('$prefix/bin/sh').createSync('/bin/sh');
    Directory('${root.path}/repo/pool').createSync(recursive: true);
    Directory('${root.path}/stubs').createSync();
    stub('curl', r'''
out=""; url=""; previous=""
for arg in "$@"; do
  [ "$previous" = -o ] && out="$arg"
  case "$arg" in https://*) url="$arg";; esac
  previous="$arg"
done
case "$url" in */pool/*.deb) ;; *) exit 91;; esac
printf '%s\n' "${url##*/}" >> "$PREFIX/downloads"
cp "$FIXTURE_REPO/pool/${url##*/}" "$out"
''');
  }

  void stub(String name, String body) {
    final file = File('${root.path}/stubs/$name')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    expect(Process.runSync('/bin/chmod', ['755', file.path]).exitCode, 0);
  }

  void add(
    String name, {
    String version = '1.0',
    String arch = 'aarch64',
    String depends = '',
    String preDepends = '',
    String provides = '',
    String multiArch = '',
    String extra = '',
    String? symlink,
    bool termux = false,
    void Function(String payload)? layout,
  }) {
    final id = '${name}_${version}_$arch';
    final build = Directory('${root.path}/build/$id');
    Directory('${build.path}/DEBIAN').createSync(recursive: true);
    File('${build.path}/DEBIAN/control').writeAsStringSync(
      'Package: $name\nVersion: $version\nArchitecture: $arch\n'
      'Maintainer: Fixture <fixture@example.test>\nDescription: offline fixture\n',
    );
    final payload = termux
        ? '${build.path}/data/data/com.termux/files/usr'
        : build.path;
    Directory('$payload/share').createSync(recursive: true);
    File('$payload/share/$name').writeAsStringSync(version);
    if (symlink != null) Link('$payload/share/link').createSync(symlink);
    layout?.call(payload);
    final archive = File('${root.path}/repo/pool/$id.deb');
    final built = Process.runSync('/usr/bin/dpkg-deb', [
      '--build',
      build.path,
      archive.path,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');
    records.add(
      'Package: $name\nVersion: $version\nArchitecture: $arch\n'
      'Filename: pool/$id.deb\nSize: ${archive.lengthSync()}\n'
      'SHA256: ${sha256.convert(archive.readAsBytesSync())}\n'
      '${depends.isEmpty ? '' : 'Depends: $depends\n'}'
      '${preDepends.isEmpty ? '' : 'Pre-Depends: $preDepends\n'}'
      '${provides.isEmpty ? '' : 'Provides: $provides\n'}'
      '${multiArch.isEmpty ? '' : 'Multi-Arch: $multiArch\n'}$extra',
    );
  }

  Future<ProcessResult> install(List<String> names) async {
    final index = File('$prefix/var/cache/ovid-pkg/Packages');
    index.parent.createSync(recursive: true);
    index.writeAsStringSync('${records.join('\n')}\n');
    return Process.run(
      '/bin/sh',
      ['$prefix/bin/ovid-pkg', 'install', ...names],
      environment: {
        'PREFIX': prefix,
        'FIXTURE_REPO': '${root.path}/repo',
        'PATH': '${root.path}/stubs:$prefix/bin:/usr/bin:/bin',
        'LC_ALL': 'C',
      },
    ).timeout(const Duration(seconds: 45));
  }

  List<String> get downloads {
    final file = File('$prefix/downloads');
    return file.existsSync() ? file.readAsLinesSync() : [];
  }

  void expectRejected(
    ProcessResult result,
    String diagnostic, {
    bool beforeDownload = true,
  }) {
    expect(
      result.exitCode,
      isNot(0),
      reason: '${result.stdout}${result.stderr}',
    );
    expect('${result.stderr}', contains(diagnostic));
    if (beforeDownload) expect(downloads, isEmpty);
    expect(Directory('$prefix/share').existsSync(), isFalse);
    expect('${result.stdout}', isNot(contains('[ovid-pkg] extracted')));
  }

  void dispose() => root.deleteSync(recursive: true);
}

void main() {
  late PackageFixture f;
  setUp(() => f = PackageFixture());
  tearDown(() => f.dispose());

  test('dependency-first diamond resolves once before any download', () async {
    f.add('app', depends: 'left, right');
    f.add('left', depends: 'shared');
    f.add('right', preDepends: 'shared');
    f.add('shared');
    final result = await f.install(['app', 'app']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(f.downloads, [
      'shared_1.0_aarch64.deb',
      'left_1.0_aarch64.deb',
      'right_1.0_aarch64.deb',
      'app_1.0_aarch64.deb',
    ]);
    expect(File('${f.prefix}/share/shared').readAsStringSync(), '1.0');
  });

  test('cycles fail with graph diagnostic before download', () async {
    f.add('app', depends: 'other');
    f.add('other', depends: 'app');
    f.expectRejected(await f.install(['app']), 'cycle');
  });

  test(
    'missing transitive closure fails before downloading the root',
    () async {
      f.add('app', depends: 'missing');
      f.expectRejected(await f.install(['app']), 'missing');
    },
  );

  test(
    'alternatives backtrack when first candidate closure is unavailable',
    () async {
      f.add('app', depends: 'broken | good');
      f.add('broken', depends: 'absent');
      f.add('good');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, ['good_1.0_aarch64.deb', 'app_1.0_aarch64.deb']);
    },
  );

  test(
    'version alternatives honor Debian epoch tilde and revision ordering',
    () async {
      f.add('app', depends: 'old (>= 2.0) | good (>= 1:2.0-2)');
      f.add('old', version: '2.0~rc1');
      f.add('good', version: '1:2.0-10');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, ['good_1:2.0-10_aarch64.deb', 'app_1.0_aarch64.deb']);
    },
  );

  test(
    'multiple versions and shared constraints select one coherent version',
    () async {
      f.add('app', depends: 'lib (>= 1), peer');
      f.add('lib', version: '1.0');
      f.add('lib', version: '2.0');
      f.add('peer', depends: 'lib (>= 2)');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, [
        'lib_2.0_aarch64.deb',
        'peer_1.0_aarch64.deb',
        'app_1.0_aarch64.deb',
      ]);
    },
  );

  test(
    'incompatible shared version constraints fail without partial install',
    () async {
      f.add('app', depends: 'lib (<< 2), peer');
      f.add('lib', version: '1.0');
      f.add('lib', version: '2.0');
      f.add('peer', depends: 'lib (>= 2)');
      f.expectRejected(await f.install(['app']), 'dependency');
    },
  );

  test(
    'native explicit and any qualifiers accept only compatible packages',
    () async {
      f.add('app', depends: 'native:native, exact:aarch64, portable:any');
      f.add('native');
      f.add('exact');
      f.add('portable', arch: 'all', multiArch: 'allowed');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, [
        'native_1.0_aarch64.deb',
        'exact_1.0_aarch64.deb',
        'portable_1.0_all.deb',
        'app_1.0_aarch64.deb',
      ]);
    },
  );

  for (final depends in ['lib', 'lib:arm', 'lib:any']) {
    test('cross ABI $depends fails before download', () async {
      f.add('app', depends: depends);
      f.add('lib', arch: 'arm', multiArch: 'allowed');
      f.expectRejected(await f.install(['app']), 'dependency');
    });
  }

  test(
    'versioned virtual dependency uses provided version not provider version',
    () async {
      f.add('app', depends: 'virtual-api (>= 3)');
      f.add('wrong', version: '9.0', provides: 'virtual-api (= 2)');
      f.add('provider', provides: 'virtual-api (= 3)');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, ['provider_1.0_aarch64.deb', 'app_1.0_aarch64.deb']);
    },
  );

  test(
    'unversioned virtual provider cannot satisfy version constraint',
    () async {
      f.add('app', depends: 'virtual-api (>= 1)');
      f.add('provider', provides: 'virtual-api');
      f.expectRejected(await f.install(['app']), 'virtual-api');
    },
  );

  test('folded dependency fields retain every requirement', () async {
    f.add('app', depends: 'one,\n two');
    f.add('one');
    f.add('two');
    final result = await f.install(['app']);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(f.downloads, [
      'one_1.0_aarch64.deb',
      'two_1.0_aarch64.deb',
      'app_1.0_aarch64.deb',
    ]);
  });

  test(
    'malformed dependency is rejected rather than dropping syntax',
    () async {
      f.add('app', depends: 'lib (=> 2)');
      f.add('lib');
      f.expectRejected(await f.install(['app']), 'dependency');
    },
  );

  test('oversized wide graph fails before any download', () async {
    f.add('app', depends: List.generate(257, (i) => 'p$i').join(', '));
    // Reuse harmless archive metadata: resolution must enforce graph bounds
    // before archive control matching or transport is reached.
    final template = f.records.single;
    for (var i = 0; i < 257; i++) {
      f.records.add(
        template
            .replaceFirst('Package: app', 'Package: p$i')
            .replaceFirst(RegExp(r'Depends: [^\n]*\n'), ''),
      );
    }
    f.expectRejected(await f.install(['app']), 'limit');
  });

  test(
    'solver backtracks to lower version to satisfy later shared constraint',
    () async {
      f.add('app', depends: 'lib, peer');
      f.add('lib', version: '2.0');
      f.add('lib', version: '1.0');
      f.add('peer', depends: 'lib (<< 2)');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, [
        'lib_1.0_aarch64.deb',
        'peer_1.0_aarch64.deb',
        'app_1.0_aarch64.deb',
      ]);
    },
  );

  test(
    'cycle in first alternative can recover through acyclic alternative',
    () async {
      f.add('app', depends: 'loop | good');
      f.add('loop', depends: 'app');
      f.add('good');
      final result = await f.install(['app']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(f.downloads, ['good_1.0_aarch64.deb', 'app_1.0_aarch64.deb']);
    },
  );

  test('deep graph reports depth limit without downloads', () async {
    f.add('app');
    final template = f.records.removeLast();
    for (var i = 0; i < 65; i++) {
      f.records.add(
        template.replaceFirst('Package: app', 'Package: p$i') +
            (i == 64 ? '' : 'Depends: p${i + 1}\n'),
      );
    }
    f.expectRejected(await f.install(['p0']), 'depth limit');
  });

  test(
    'total package limit applies across separately requested roots',
    () async {
      f.add('app');
      final template = f.records.removeLast();
      for (var i = 0; i < 257; i++) {
        f.records.add(template.replaceFirst('Package: app', 'Package: p$i'));
      }
      f.expectRejected(
        await f.install(List.generate(257, (i) => 'p$i')),
        'package limit',
      );
    },
  );

  test(
    'candidate explosion is bounded before version sorting and transport',
    () async {
      f.add('app');
      final template = f.records.removeLast();
      for (var i = 1; i <= 65; i++) {
        f.records.add(template.replaceFirst('Version: 1.0', 'Version: $i.0'));
      }
      f.expectRejected(await f.install(['app']), 'candidate limit');
    },
  );

  test(
    'failed version comparator cannot silently satisfy an alternative',
    () async {
      f.add('app', depends: 'lib (>= 1)');
      f.add('lib');
      f.stub('dpkg', 'echo success; exit 7');
      f.expectRejected(await f.install(['app']), 'comparator failed');
    },
  );
}
