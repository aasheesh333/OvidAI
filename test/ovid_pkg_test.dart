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

  /// Writes an executable stub onto PATH.
  void writeStub(Directory dir, String name, String body) {
    final f = File('${dir.path}/$name')
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['0755', f.path]);
  }

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

    test('runs dpkg to a log then tails it instead of masking the exit', () {
      // Piping dpkg into tail makes the pipeline status tail's (0), so a
      // failed install used to look green. The script must redirect to a
      // log and inspect $? instead. Behavior is pinned by the runtime
      // "dpkg exit code is propagated" test.
      expect(content, contains(r'> "$_dlog" 2>&1'));
      expect(content, contains(r'tail -8 "$_dlog"'));
      expect(content, contains(r'rc=$?'));
      expect(content, contains(r'exit "$rc"'));
      expect(content, isNot(contains('2>&1 | tail')));
    });

    test('validates index freshness (at least one Package: line)', () {
      expect(content, contains("grep -q '^Package: '"));
      expect(content, contains('stale'));
    });

    test('enforces index freshness in install and search, not just update', () {
      // One helper definition + a check in update, search, and install.
      final uses = RegExp(r'_index_ok').allMatches(content).length;
      expect(uses, greaterThanOrEqualTo(4));
    });

    test('unknown verbs exit non-zero with usage on stderr', () {
      final start = content.indexOf('*)\n    echo "usage:');
      expect(start, greaterThan(0));
      final branch = content.substring(start, content.indexOf(';;', start));
      expect(branch, contains('exit 2'));
      expect(branch, contains('>&2'));
    });
  });

  group('ovid-pkg runtime behavior', () {
    late Directory tmp;
    late String script;
    late Map<String, String> env;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('ovid-pkg-runtime');
      OvidPkgInstaller.writeAll(tmp, arch: 'aarch64', mirrors: mirrors);
      // The generated shebang is #!$PREFIX/bin/sh; link it so nested
      // `ovid-pkg update` calls resolve on the host.
      Link('${tmp.path}/bin/sh').createSync('/bin/sh');
      script = '${tmp.path}/bin/ovid-pkg';
      env = {
        'PREFIX': tmp.path,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      };
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, String> envWith(Directory stubs) => {
      ...env,
      'PATH': '${stubs.path}:${tmp.path}/bin:${env['PATH']}',
    };

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
      final res = await Process.run(
        '/bin/sh',
        [script, 'update'],
        environment: env,
      ).timeout(const Duration(seconds: 60));
      expect(res.exitCode, isNot(0));
    });

    test('uname fallback maps armv7l to the arm apt arch', () async {
      // Exercise the no-baked-arch path: a stubbed `uname` reports
      // armv7l, so the fetched index URL must use binary-arm (not the
      // raw uname value).
      final fallback = Directory.systemTemp.createTempSync('ovid-pkg-uname');
      addTearDown(() => fallback.deleteSync(recursive: true));
      OvidPkgInstaller.writeAll(fallback, mirrors: mirrors);
      final stubs = Directory('${fallback.path}/stubs')..createSync();
      writeStub(stubs, 'uname', 'echo armv7l');
      writeStub(stubs, 'curl', 'exit 1');
      final fallbackEnv = {
        'PREFIX': fallback.path,
        'PATH':
            '${stubs.path}:${fallback.path}/bin:'
            '${Platform.environment['PATH']}',
      };

      final res = await Process.run(
        '/bin/sh',
        ['${fallback.path}/bin/ovid-pkg', 'update'],
        environment: fallbackEnv,
      ).timeout(const Duration(seconds: 30));
      final out = '${res.stdout}${res.stderr}';

      expect(res.exitCode, isNot(0));
      expect(out, contains('binary-arm/Packages'));
      expect(out, isNot(contains('binary-armv7l/Packages')));
    });

    test('dpkg exit code is propagated (7)', () async {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync(
        'Package: ripgrep\nFilename: ripgrep_1.deb\nDepends: \n\n',
      );
      final stubs = Directory('${tmp.path}/stubs')..createSync();
      // curl "downloads" (creates the -o target) and succeeds.
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      writeStub(stubs, 'dpkg', 'echo "dpkg exploded"; exit 7');

      final res = await Process.run('/bin/sh', [
        script,
        'install',
        'ripgrep',
      ], environment: envWith(stubs)).timeout(const Duration(seconds: 30));

      expect(res.exitCode, 7);
    });

    test('install rejects a stale/empty index', () async {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync('not a package index\n');
      final stubs = Directory('${tmp.path}/stubs')..createSync();
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      // xz "decompresses" to an empty Packages file (still stale).
      writeStub(
        stubs,
        'xz',
        'for a in "\$@"; do case "\$a" in *.xz) : > "\${a%.xz}";; esac; '
            'done; exit 0',
      );

      final res = await Process.run('/bin/sh', [
        script,
        'install',
        'ripgrep',
      ], environment: envWith(stubs)).timeout(const Duration(seconds: 30));

      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('stale'));
    });

    test('search rejects a stale/empty index', () async {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync('not a package index\n');
      final stubs = Directory('${tmp.path}/stubs')..createSync();
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      writeStub(
        stubs,
        'xz',
        'for a in "\$@"; do case "\$a" in *.xz) : > "\${a%.xz}";; esac; '
            'done; exit 0',
      );

      final res = await Process.run('/bin/sh', [
        script,
        'search',
        'ripgrep',
      ], environment: envWith(stubs)).timeout(const Duration(seconds: 30));

      expect(res.exitCode, isNot(0));
    });
  });
}
