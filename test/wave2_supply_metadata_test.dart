import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_pkg.dart';

import 'wave2_supply_fixture.dart';

void main() {
  late Directory root;
  late String prefix;
  late SignedRepositoryFixture repo;
  const index = 'Package: fixture\nVersion: 1\nArchitecture: aarch64\n\n';
  Future<ProcessResult> command(String verb) => Process.run(
    '/bin/sh',
    ['$prefix/bin/ovid-pkg', verb, 'fixture'],
    environment: {
      'PREFIX': prefix,
      'FIXTURE_REPO': '${root.path}/repo',
      'PATH': '${root.path}/stubs:$prefix/bin:/usr/bin:/bin',
    },
  );
  void reject(ProcessResult r) {
    expect(r.exitCode, isNot(0), reason: '${r.stdout}${r.stderr}');
    expect('${r.stdout}', isNot(contains('index ready')));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('wave2-supply-');
    prefix = '${root.path}/prefix';
    OvidPkgInstaller.writeAll(Directory(prefix), arch: 'aarch64');
    Link('$prefix/bin/sh').createSync('/bin/sh');
    repo = SignedRepositoryFixture(root.path)..trust(prefix);
    Directory('${root.path}/stubs').createSync();
    final curl = File('${root.path}/stubs/curl')
      ..writeAsStringSync(r'''#!/bin/sh
out=""; url=""; previous=""
for arg in "$@"; do
  [ "$previous" = -o ] && out="$arg"
  case "$arg" in https://*) url="$arg";; esac
  previous="$arg"
done
case "$url" in */dists/stable/*) file="$FIXTURE_REPO/dists/stable/${url#*/dists/stable/}";; *) exit 91;; esac
[ -f "$file" ] || exit 22
cp "$file" "$out"
''');
    repo.run('chmod', ['755', curl.path]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  for (final inline in [false, true]) {
    test(
      'real ${inline ? 'InRelease' : 'Release.gpg'} signature authenticates index and cache',
      () async {
        repo.publish(index, inRelease: inline, gzipIndex: true);
        final r = await command('update');
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        Directory('${root.path}/repo').deleteSync(recursive: true);
        final cached = await command('search');
        expect(cached.exitCode, 0, reason: '${cached.stdout}${cached.stderr}');
        expect('${cached.stdout}', contains('Package: fixture'));
      },
    );
  }
  test('tampered Release fails before index readiness', () async {
    repo.publish(index);
    File(
      '${root.path}/repo/dists/stable/Release',
    ).writeAsStringSync('\nSuite: evil\n', mode: FileMode.append);
    reject(await command('update'));
  });
  test('wrong signing key fails', () async {
    repo.publish(index);
    SignedRepositoryFixture('${root.path}/wrong').trust(prefix);
    reject(await command('update'));
  });
  test('expired signed Release fails', () async {
    repo.publish(
      index,
      expires: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
    );
    reject(await command('update'));
  });
  test('missing signed Packages hash fails', () async {
    repo.publish(index, missingHash: true);
    reject(await command('update'));
  });
  test('tampered Packages fails', () async {
    repo.publish(index);
    File(
      '${root.path}/repo/dists/stable/main/binary-aarch64/Packages',
    ).writeAsStringSync('${index}Package: attacker\n');
    reject(await command('update'));
  });
  test('unsigned old cache cannot satisfy search offline', () async {
    final old = File('$prefix/var/cache/ovid-pkg/Packages');
    old.parent.createSync(recursive: true);
    old.writeAsStringSync(index);
    reject(await command('search'));
  });
  for (final verb in ['update', 'search', 'install']) {
    test('unsigned repository cannot satisfy $verb', () async {
      repo.publish(index);
      File('${root.path}/repo/dists/stable/Release.gpg').deleteSync();
      reject(await command(verb));
      expect(File('$prefix/var/cache/ovid-pkg/current').existsSync(), isFalse);
    });
  }
  test(
    'invalid InRelease cannot fall back to valid detached metadata',
    () async {
      repo.publish(index, inRelease: true);
      final inline = File('${root.path}/repo/dists/stable/InRelease');
      inline.writeAsStringSync(
        inline.readAsStringSync().replaceFirst(
          'Suite: stable',
          'Suite: forged',
        ),
      );
      reject(await command('update'));
      expect(File('$prefix/var/cache/ovid-pkg/current').existsSync(), isFalse);
    },
  );
  test('signed repository without seeded trust roots fails closed', () async {
    repo.publish(index);
    Directory('$prefix/etc/apt/trusted.gpg.d').deleteSync(recursive: true);
    reject(await command('update'));
    expect(File('$prefix/var/cache/ovid-pkg/current').existsSync(), isFalse);
  });
  test('failed update revokes earlier generation for offline use', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    Directory('${root.path}/repo').deleteSync(recursive: true);
    reject(await command('update'));
    reject(await command('search'));
  });
  test('signed older generation cannot replace newer generation', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    repo.publish(
      index,
      date: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );
    reject(await command('update'));
  });
  test('tampered authenticated cache is reverified offline', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    final cache = '$prefix/var/cache/ovid-pkg';
    final generation = File('$cache/current').readAsStringSync().trim();
    File(
      '$cache/$generation/Packages',
    ).writeAsStringSync('Package: attacker\n');
    Directory('${root.path}/repo').deleteSync(recursive: true);
    reject(await command('search'));
  });
  test('cached signature is reverified against current trust roots', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    SignedRepositoryFixture('${root.path}/wrong').trust(prefix);
    Directory('${root.path}/repo').deleteSync(recursive: true);
    reject(await command('search'));
  });
  test('cached signed expiry is checked at use time', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    final future =
        DateTime.now()
            .toUtc()
            .add(const Duration(days: 2))
            .millisecondsSinceEpoch ~/
        1000;
    final date = File('${root.path}/stubs/date')
      ..writeAsStringSync(
        '#!/bin/sh\nif [ "\$#" = 2 ]; then echo $future; else exec /bin/date "\$@"; fi\n',
      );
    repo.run('chmod', ['755', date.path]);
    Directory('${root.path}/repo').deleteSync(recursive: true);
    reject(await command('search'));
  });
  test('future Release Date fails', () async {
    repo.publish(
      index,
      date: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
    reject(await command('update'));
  });
  test('old signed Date fails even with a far future Valid-Until', () async {
    repo.publish(
      index,
      date: DateTime.now().toUtc().subtract(const Duration(days: 8)),
      expires: DateTime.now().toUtc().add(const Duration(days: 30)),
    );
    reject(await command('update'));
  });
  test('signed compressed hash mismatch fails before decompression', () async {
    repo.publish(index, gzipIndex: true);
    File(
      '${root.path}/repo/dists/stable/main/binary-aarch64/Packages.gz',
    ).writeAsBytesSync([1, 2, 3]);
    reject(await command('update'));
  });
  test(
    'oversized metadata is bounded even when transport ignores curl flags',
    () async {
      repo.publish(index);
      File(
        '${root.path}/repo/dists/stable/InRelease',
      ).writeAsStringSync('x' * (2 * 1024 * 1024));
      // A failed InRelease download may use a separately signed detached Release;
      // remove that alternative to exercise the bounded failure.
      File('${root.path}/repo/dists/stable/Release.gpg').deleteSync();
      reject(await command('update'));
      expect(File('$prefix/var/cache/ovid-pkg/current').existsSync(), isFalse);
    },
  );
  test('decompression output cannot exceed signed Packages size', () async {
    repo.publish(index, gzipIndex: true);
    final gzip = File('${root.path}/stubs/gzip')
      ..writeAsStringSync(
        '#!/bin/sh\nexec /usr/bin/python3 -c "import sys; sys.stdout.write(\'x\' * 40000000)"\n',
      );
    repo.run('chmod', ['755', gzip.path]);
    reject(await command('update'));
    expect(File('$prefix/var/cache/ovid-pkg/current').existsSync(), isFalse);
  });
  test('busy generation lock fails without changing current pointer', () async {
    repo.publish(index);
    expect((await command('update')).exitCode, 0);
    final current = File('$prefix/var/cache/ovid-pkg/current');
    final before = current.readAsStringSync();
    Directory('$prefix/var/cache/ovid-pkg/lock').createSync();
    reject(await command('update'));
    expect(current.readAsStringSync(), before);
  });
}
