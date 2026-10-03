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

    test('extracts with dpkg-deb -x into PREFIX (never dpkg -i)', () {
      // dpkg's compiled-in Termux prefix makes `dpkg -i` fail on-device;
      // dpkg-deb -x extracts the data archive into our own prefix with no
      // admindir. Behavior pinned by the runtime extraction-failure test.
      expect(content, contains(r'dpkg-deb -x'));
      expect(content, contains(r'> "$_dlog" 2>&1'));
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

    test('index fetch tries .gz before .xz and silences expected probes', () {
      final start = content.indexOf('_fetch_index()');
      expect(start, greaterThan(0));
      final body = content.substring(start, content.indexOf('\n}', start));
      final gz = body.indexOf('.gz');
      final xz = body.indexOf('.xz');
      expect(gz, greaterThan(0));
      expect(xz, greaterThan(0));
      // The mirror serves .gz but not .xz; probing .xz first printed a
      // misleading "curl: (22) ... 404" on every update.
      expect(gz, lessThan(xz), reason: '.gz must be probed before .xz');
      // Both compressed probes suppress stderr; only the final plain fetch
      // is allowed to surface an error.
      expect(
        RegExp(r'\.gz" -o "\$PKG_IDX/Packages\.gz" 2>/dev/null').hasMatch(body),
        isTrue,
      );
      expect(
        RegExp(r'\.xz" -o "\$PKG_IDX/Packages\.xz" 2>/dev/null').hasMatch(body),
        isTrue,
      );
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
        'PATH': '${tmp.path}/stubs:${tmp.path}/bin:/usr/bin:/bin',
      };
      final stubs = Directory('${tmp.path}/stubs')..createSync();
      // Every runtime test is offline, including recursive index updates.
      writeStub(stubs, 'curl', 'exit 1');
      writeStub(stubs, 'dpkg-deb', 'exit 99');
      writeStub(stubs, 'dpkg', 'exit 99');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, String> envWith(Directory stubs) => {
      ...env,
      'PATH': '${stubs.path}:${tmp.path}/bin:${env['PATH']}',
    };

    void seedIndex(Map<String, String> packages) {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync(packages.entries.map((entry) {
        return 'Package: ${entry.key}\nVersion: 1.0\n'
            'Architecture: aarch64\nFilename: pool/${entry.key}_1.deb\n'
            '${entry.value.isEmpty ? '' : 'Depends: ${entry.value}\n'}\n';
      }).join());
    }

    void successfulInstallStubs() {
      final stubs = Directory('${tmp.path}/stubs');
      writeStub(stubs, 'curl', r'''
prev=""; out=""; url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in https://*) url="$a";; esac
  prev="$a"
done
case "$url" in https://mirror-one.test/apt/termux-main/pool/*.deb) ;;
  *) echo "unexpected fixture URL: $url" >&2; exit 99;;
esac
printf '%s\n' "${url##*/}" >> "$PREFIX/downloads"
: > "$out"
''');
      // Emulate only extraction. The generated script performs the real
      // relocation/merge of this harmless payload inside the temporary prefix.
      writeStub(stubs, 'dpkg-deb', r'''
[ "$#" = 3 ] && [ "$1" = "-x" ] && [ "$3" = "$PREFIX" ] || exit 99
[ -f "$2" ] || exit 98
archive="${2##*/}"
printf '%s\n' "$archive" >> "$PREFIX/extractions"
payload="$PREFIX/data/data/com.termux/files/usr/bin"
mkdir -p "$payload"
printf '%s\n' "$archive" > "$payload/${archive%_1.deb}"
''');
    }

    Future<ProcessResult> install(List<String> packages) => Process.run(
      '/bin/sh', [script, 'install', ...packages], environment: env,
    ).timeout(const Duration(seconds: 30));

    List<String> recorded(String name) {
      final file = File('${tmp.path}/$name');
      return file.existsSync() ? file.readAsLinesSync() : [];
    }

    test('full install succeeds and relocates the extracted payload', () async {
      seedIndex({'app': ''});
      successfulInstallStubs();

      final res = await install(['-y', '--yes', '-q', '--quiet', 'app']);

      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, isEmpty);
      expect(recorded('downloads'), ['app_1.deb']);
      expect(recorded('extractions'), ['app_1.deb']);
      expect(File('${tmp.path}/bin/app').readAsStringSync(), 'app_1.deb\n');
      expect(Directory('${tmp.path}/data').existsSync(), isFalse);
    });

    for (final branch in ['merge', 'move']) {
      for (final failingCommand in ['cp', 'rm']) {
        test('relocation $branch $failingCommand failure exits non-zero', () async {
          seedIndex({'app': ''});
          successfulInstallStubs();
          final stubs = Directory('${tmp.path}/stubs');
          final nested = '${tmp.path}/data/data/com.termux/files/usr';
          // bin exercises the merge branch; share exercises move/copy fallback.
          // A successful sibling must not erase the failed relocation status.
          final share = File('$nested/share/fixture');
          share.parent.createSync(recursive: true);
          share.writeAsStringSync('fixture\n');
          final directory = branch == 'merge' ? 'bin' : 'share';
          if (branch == 'move') {
            writeStub(stubs, 'mv', 'exit 7');
          }
          writeStub(stubs, failingCommand, '''
case "\$2" in
  "\$PREFIX/data/data/com.termux/files/usr/$directory"|"\$PREFIX/data/data/com.termux/files/usr/$directory/.") exit 8;;
esac
exec /bin/$failingCommand "\$@"
''');

          final res = await install(['app']);

          expect(recorded('extractions'), ['app_1.deb']);
          final relative = branch == 'merge' ? 'bin/app' : 'share/fixture';
          expect(File('$nested/$relative').existsSync(), isTrue);
          expect(
            File('${tmp.path}/$relative').existsSync(),
            failingCommand == 'rm',
          );
          expect(res.exitCode, isNot(0), reason: '${res.stdout}${res.stderr}');
          expect(res.stderr, contains('could not relocate $directory'));
        });
      }
    }

    test('relocation move failure with successful copy fallback exits zero', () async {
      seedIndex({'app': ''});
      successfulInstallStubs();
      final nested = '${tmp.path}/data/data/com.termux/files/usr';
      final share = File('$nested/share/fixture');
      share.parent.createSync(recursive: true);
      share.writeAsStringSync('fixture\n');
      writeStub(Directory('${tmp.path}/stubs'), 'mv', 'exit 7');

      final res = await install(['app']);

      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, isEmpty);
      expect(File('${tmp.path}/share/fixture').readAsStringSync(), 'fixture\n');
      expect(File('${tmp.path}/bin/app').readAsStringSync(), 'app_1.deb\n');
      expect(Directory('${tmp.path}/data').existsSync(), isFalse);
    });

    test('cycle and diamond download and extract each package once', () async {
      seedIndex({
        'app': 'left, right',
        'left': 'shared',
        'right': 'shared',
        'shared': 'app',
      });
      successfulInstallStubs();

      final res = await install(['app', 'app']);

      const archives = ['app_1.deb', 'left_1.deb', 'right_1.deb', 'shared_1.deb'];
      expect(recorded('downloads'), archives);
      expect(recorded('extractions'), archives);
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
    });

    for (final dependency in ['absent', 'absent (>= 1) | also-absent']) {
      test('missing required dependency $dependency fails before extraction', () async {
        seedIndex({'app': dependency});
        successfulInstallStubs();

        final res = await install(['app']);

        expect(res.exitCode, isNot(0));
        expect(res.stderr, contains('dependency'));
        expect(res.stderr, contains('absent'));
        expect(recorded('extractions'), isEmpty);
        expect(res.stdout, isNot(contains('[ovid-pkg] installing')));
        expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
      });
    }

    for (final alternatives in [
      'absent (>= 1) | available (>= 1)',
      'available (>= 1) | other',
    ]) {
      test('selects the first available alternative: $alternatives', () async {
        seedIndex({
          'app': '$alternatives, required',
          'available': '',
          'other': '',
          'required': '',
        });
        successfulInstallStubs();

        final res = await install(['app']);

        expect(recorded('extractions'), [
          'app_1.deb', 'available_1.deb', 'required_1.deb',
        ]);
        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      });
    }

    test('a missing requested package prevents partial extraction', () async {
      seedIndex({'app': ''});
      successfulInstallStubs();

      final res = await install(['app', 'absent']);

      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('absent'));
      expect(recorded('extractions'), isEmpty);
    });

    test('unfinished dependency closure fails at the traversal limit', () async {
      seedIndex({
        for (var i = 1; i <= 17; i++) 'p$i': i == 17 ? '' : 'p${i + 1}',
      });
      successfulInstallStubs();

      final res = await install(['p1']);

      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('dependency'));
      expect(res.stderr, contains('limit'));
      expect(res.stderr, contains('p17'));
      expect(recorded('extractions'), isEmpty);
      expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
    });

    test('closure completed on the last round succeeds despite back edges', () async {
      seedIndex({
        for (var i = 1; i <= 16; i++) 'p$i': i == 16 ? 'p1, p16' : 'p${i + 1}',
      });
      successfulInstallStubs();

      final res = await install(['p1']);

      expect(recorded('extractions'), hasLength(16));
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
    });

    for (final arch in {
      'armv7l': 'arm',
      'armv8l': 'arm',
      'armv7a': 'arm',
      'arm64': 'aarch64',
      'aarch64': 'aarch64',
    }.entries) {
      test('uname ${arch.key} successfully fetches the ${arch.value} index', () async {
        OvidPkgInstaller.writeAll(tmp, mirrors: mirrors);
        final stubs = Directory('${tmp.path}/stubs');
        writeStub(stubs, 'uname', 'echo ${arch.key}');
        writeStub(stubs, 'curl', r'''
prev=""; out=""; url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  case "$a" in https://*) url="$a";; esac
  prev="$a"
done
case "$url" in */Packages) ;; *) exit 1;; esac
printf '%s\n' "$url" >> "$PREFIX/index-urls"
printf 'Package: app\nFilename: pool/app_1.deb\n\n' > "$out"
''');

        final res = await Process.run('/bin/sh', [script, 'update'], environment: env);

        expect(recorded('index-urls'), [
          '${mirrors.first}/dists/stable/main/binary-${arch.value}/Packages',
        ]);
        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        expect(res.stderr, isEmpty);
      });
    }

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
      // The default curl stub forces every fetch to fail without networking.
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

    test('extraction failure is propagated non-zero', () async {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync(
        'Package: ripgrep\nFilename: ripgrep_1.deb\nDepends: \n\n',
      );
      final stubs = Directory('${tmp.path}/stubs');
      // curl "downloads" (creates the -o target) and succeeds.
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      writeStub(stubs, 'dpkg-deb', 'echo "extract exploded"; exit 7');

      final res = await Process.run('/bin/sh', [
        script,
        'install',
        'ripgrep',
      ], environment: envWith(stubs)).timeout(const Duration(seconds: 30));

      expect(res.exitCode, isNot(0));
      expect('${res.stdout}${res.stderr}', contains('extract failed'));
    });

    test('install rejects a stale/empty index', () async {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      idx.writeAsStringSync('not a package index\n');
      final stubs = Directory('${tmp.path}/stubs');
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      // gzip "decompresses" to an empty Packages file (still stale).
      writeStub(
        stubs,
        'gzip',
        'for a in "\$@"; do case "\$a" in *.gz) : > "\${a%.gz}";; esac; '
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
      final stubs = Directory('${tmp.path}/stubs');
      writeStub(
        stubs,
        'curl',
        'prev=""; for a in "\$@"; do [ "\$prev" = "-o" ] && : > "\$a"; '
            'prev="\$a"; done; exit 0',
      );
      writeStub(
        stubs,
        'gzip',
        'for a in "\$@"; do case "\$a" in *.gz) : > "\${a%.gz}";; esac; '
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
