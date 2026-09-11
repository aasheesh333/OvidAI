import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_pkg.dart';

/// Task 5 (studio/git reliability §5.5): make `ovid-pkg` honest.
///
/// The generated script must handle `upgrade`/`full-upgrade` without a
/// silent exit 0, strip apt flags before resolving packages, propagate
/// the real dpkg exit code, validate index freshness, bake the payload
/// arch from the Dart ABI map, and read the app mirror list first.
void main() {
  const mirrors = [
    'https://mirror-one.test/apt/termux-main',
    'https://mirror-two.test/apt/termux-main',
  ];

  group('ovid-pkg generated script contract', () {
    late Directory tmp;
    late String script;
    late String content;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ovid-pkg-contract');
      OvidPkgInstaller.writeAll(tmp, arch: 'aarch64', mirrors: mirrors);
      script = '${tmp.path}/bin/ovid-pkg';
      content = File(script).readAsStringSync();
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('bakes the payload arch from the ABI map', () {
      expect(content, contains('ARCH="aarch64"'));
    });

    test('falls back to uname with armv7l/armv8l mapped to arm', () {
      final fallback = Directory.systemTemp.createTempSync('ovid-pkg-fallback');
      addTearDown(() => fallback.deleteSync(recursive: true));
      OvidPkgInstaller.writeAll(fallback);
      final raw = File('${fallback.path}/bin/ovid-pkg').readAsStringSync();
      expect(raw, contains('uname -m'));
      expect(raw, contains('armv7l|armv8l'));
    });

    test('reads the app mirror list before sources.list', () {
      expect(content, contains('etc/apt/ovid-mirrors'));

      final mirrorsFile = File('${tmp.path}/etc/apt/ovid-mirrors');
      expect(mirrorsFile.existsSync(), isTrue);
      expect(
        mirrorsFile.readAsStringSync().trim().split('\n'),
        mirrors,
      );

      final mirrorIdx = content.indexOf(r'-r "$PREFIX/etc/apt/ovid-mirrors"');
      final sourcesIdx = content.indexOf(r'-r "$PREFIX/etc/apt/sources.list"');
      expect(mirrorIdx, greaterThan(0));
      expect(
        mirrorIdx,
        lessThan(sourcesIdx),
        reason: 'the app mirror list is read before the sources.list fallback',
      );
    });

    test('handles upgrade and full-upgrade explicitly', () {
      expect(content, contains('upgrade|full-upgrade)'));
      expect(content, contains('not supported'));
    });

    test('strips -y/--yes/-q/--quiet before the install loop', () {
      expect(content, contains('-y|--yes'));
      expect(content, contains('-q|--quiet'));
      final stripIdx = content.indexOf('for _a in "\$@"');
      final loopIdx = content.indexOf('for round in');
      expect(stripIdx, greaterThan(0));
      expect(stripIdx, lessThan(loopIdx));
    });

    test('propagates the real dpkg exit code instead of masking it', () {
      expect(content, contains(r'rc=$?'));
      expect(content, contains(r'exit "$rc"'));
      expect(content, isNot(contains('2>&1 | tail')));
      expect(content, contains('tail -8'));
    });

    test('validates index freshness (at least one Package: line)', () {
      expect(content, contains("grep -q '^Package: '"));
      expect(content, contains('stale'));
    });

    test('unknown verbs exit non-zero with usage on stderr', () {
      expect(content, contains('*)\n    echo "usage:'));
      expect(content, contains('exit 2'));
    });
  });

  group('ovid-pkg runtime behavior', () {
    late Directory tmp;
    late String script;
    late Map<String, String> env;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ovid-pkg-runtime');
      OvidPkgInstaller.writeAll(tmp, arch: 'aarch64', mirrors: mirrors);
      script = '${tmp.path}/bin/ovid-pkg';
      env = {
        'PREFIX': tmp.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      };
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('apt install -y does not resolve -y as a package', () async {
      // Pre-seed an index so a non-stripped flag would be looked up
      // rather than triggering a network update.
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync(
        'Package: ripgrep\nFilename: ripgrep_1.deb\nDepends: \n\n',
      );

      final res = await Process.run('/bin/sh', [
        script,
        'install',
        '-y',
      ], environment: env);
      final out = '${res.stdout}${res.stderr}';

      expect(res.exitCode, isNot(0));
      expect(out, contains('usage'));
      expect(out, isNot(contains('not found: -y')));
    });

    test('install with no packages exits non-zero', () async {
      final res = await Process.run('/bin/sh', [
        script,
        'install',
      ], environment: env);
      expect(res.exitCode, isNot(0));
    });

    test('upgrade exits non-zero with a stderr message', () async {
      final res = await Process.run('/bin/sh', [
        script,
        'upgrade',
      ], environment: env);
      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('not supported'));
    });

    test('full-upgrade exits non-zero with a stderr message', () async {
      final res = await Process.run('/bin/sh', [
        script,
        'full-upgrade',
      ], environment: env);
      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('not supported'));
    });

    test('unknown verb exits non-zero instead of usage exit 0', () async {
      final res = await Process.run('/bin/sh', [
        script,
        'frobnicate',
      ], environment: env);
      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('usage'));
    });

    test('update fails non-zero when the index is empty/stale', () async {
      // A mirror that cannot be reached forces the fetch to fail.
      File('${tmp.path}/etc/apt/ovid-mirrors')
          .writeAsStringSync('http://127.0.0.1:1/apt/termux-main\n');
      final res = await Process.run('/bin/sh', [
        script,
        'update',
      ], environment: env, ).timeout(const Duration(seconds: 60));
      expect(res.exitCode, isNot(0));
    });
  });
}
