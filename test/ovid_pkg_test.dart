import 'dart:io';

import 'package:crypto/crypto.dart';
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
      expect(mirrorsFile.readAsStringSync().trim().split('\n'), mirrors);

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

    test('extracts with dpkg-deb -x without masking its status', () {
      // dpkg's compiled-in Termux prefix makes `dpkg -i` fail on-device;
      // dpkg-deb -x extracts the data archive into an owned stage with no
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
        'LC_ALL': 'C',
      };
      final stubs = Directory('${tmp.path}/stubs')..createSync();
      // Every runtime test is offline, including recursive index updates.
      writeStub(stubs, 'curl', 'exit 1');
      writeStub(stubs, 'dpkg-deb', 'exit 99');
      writeStub(stubs, 'dpkg', r'''
[ "$1" = --compare-versions ] || exit 99
exec /usr/bin/dpkg "$@"
''');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Map<String, String> envWith(Directory stubs) => {
      ...env,
      'PATH': '${stubs.path}:${tmp.path}/bin:${env['PATH']}',
    };

    void seedIndex(Map<String, String> packages, {bool share = false}) {
      final idx = File('${tmp.path}/var/cache/ovid-pkg/Packages');
      idx.parent.createSync(recursive: true);
      Directory('${tmp.path}/repo/pool').createSync(recursive: true);
      idx.writeAsStringSync(
        packages.entries.map((entry) {
          final build = '${tmp.path}/build/${entry.key}';
          Directory('$build/DEBIAN').createSync(recursive: true);
          File('$build/DEBIAN/control').writeAsStringSync(
            'Package: ${entry.key}\nVersion: 1.0\nArchitecture: aarch64\n'
            'Maintainer: Fixture <fixture@example.test>\n'
            'Description: harmless offline fixture\n',
          );
          final payload = '$build/data/data/com.termux/files/usr';
          Directory('$payload/bin').createSync(recursive: true);
          File(
            '$payload/bin/${entry.key}',
          ).writeAsStringSync('${entry.key}_1.deb\n');
          if (share) {
            Directory('$payload/share').createSync();
            File('$payload/share/fixture').writeAsStringSync('fixture\n');
          }
          final archive = File('${tmp.path}/repo/pool/${entry.key}_1.deb');
          final built = Process.runSync('/usr/bin/dpkg-deb', [
            '--build',
            build,
            archive.path,
          ]);
          expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');
          return 'Package: ${entry.key}\nVersion: 1.0\n'
              'Architecture: aarch64\nFilename: pool/${entry.key}_1.deb\n'
              'Size: ${archive.lengthSync()}\n'
              'SHA256: ${sha256.convert(archive.readAsBytesSync())}\n'
              '${entry.value.isEmpty ? '' : 'Depends: ${entry.value}\n'}\n';
        }).join(),
      );
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
exec /bin/cp "$PREFIX/repo/pool/${url##*/}" "$out"
''');
      // Preserve real control inspection, tar validation and extraction. Record
      // package identities, independent of operation-owned archive filenames.
      writeStub(stubs, 'dpkg-deb', r'''
if [ "$1" = -x ]; then
  [ "$#" = 3 ] || exit 99
  case "$3" in "$PREFIX"/var/cache/ovid-pkg/archives/install.*/stage) ;; *) exit 98;; esac
  /usr/bin/dpkg-deb -f "$2" Package >> "$PREFIX/extractions" || exit 97
fi
exec /usr/bin/dpkg-deb "$@"
''');
    }

    Future<ProcessResult> install(List<String> packages) => Process.run(
      '/bin/sh',
      [script, 'install', ...packages],
      environment: env,
    ).timeout(const Duration(seconds: 30));

    List<String> recorded(String name) {
      final file = File('${tmp.path}/$name');
      return file.existsSync() ? file.readAsLinesSync() : [];
    }

    test('full install succeeds and relocates the extracted payload', () async {
      seedIndex({'app': ''});
      successfulInstallStubs();

      final res = await install(['app']);

      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, isEmpty);
      expect(recorded('downloads'), ['app_1.deb']);
      expect(recorded('extractions'), ['app']);
      expect(File('${tmp.path}/bin/app').readAsStringSync(), 'app_1.deb\n');
      expect(Directory('${tmp.path}/data').existsSync(), isFalse);
      expect(
        Directory('${tmp.path}/var/cache/ovid-pkg/archives').listSync(),
        isEmpty,
      );
      expect(res.stdout, contains('[ovid-pkg] extracted 1 package(s)'));
    });

    test('strips -y/--yes/-q/--quiet before resolving packages', () async {
      seedIndex({'app': '', 'other': ''});
      successfulInstallStubs();

      final res = await install([
        '-y',
        'app',
        '--yes',
        '-q',
        'other',
        '--quiet',
      ]);

      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, isEmpty);
      expect(recorded('downloads'), ['app_1.deb', 'other_1.deb']);
      expect(recorded('extractions'), ['app', 'other']);
      expect(File('${tmp.path}/bin/app').readAsStringSync(), 'app_1.deb\n');
      expect(File('${tmp.path}/bin/other').readAsStringSync(), 'other_1.deb\n');
    });

    for (final branch in ['merge', 'move']) {
      for (final failingCommand in ['cp', 'rm']) {
        test(
          'relocation $branch $failingCommand failure exits non-zero',
          () async {
            seedIndex({'app': ''}, share: true);
            successfulInstallStubs();
            final stubs = Directory('${tmp.path}/stubs');
            final nested = '${tmp.path}/data/data/com.termux/files/usr';
            // bin exercises the merge branch; share exercises move/copy fallback.
            // A successful sibling must not erase the failed relocation status.
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

            expect(recorded('extractions'), ['app']);
            final relative = branch == 'merge' ? 'bin/app' : 'share/fixture';
            expect(File('$nested/$relative').existsSync(), isTrue);
            expect(
              File('${tmp.path}/$relative').existsSync(),
              failingCommand == 'rm',
            );
            expect(
              res.exitCode,
              isNot(0),
              reason: '${res.stdout}${res.stderr}',
            );
            expect(res.stderr, contains('could not relocate $directory'));
            expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
            final sibling = branch == 'merge' ? 'share/fixture' : 'bin/app';
            expect(File('${tmp.path}/$sibling').existsSync(), isTrue);
            expect(File('$nested/$sibling').existsSync(), isFalse);
          },
        );
      }
    }

    test(
      'relocation move failure with successful copy fallback exits zero',
      () async {
        seedIndex({'app': ''}, share: true);
        successfulInstallStubs();
        writeStub(Directory('${tmp.path}/stubs'), 'mv', 'exit 7');

        final res = await install(['app']);

        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        expect(res.stderr, isEmpty);
        expect(
          File('${tmp.path}/share/fixture').readAsStringSync(),
          'fixture\n',
        );
        expect(File('${tmp.path}/bin/app').readAsStringSync(), 'app_1.deb\n');
        expect(Directory('${tmp.path}/data').existsSync(), isFalse);
      },
    );

    test(
      'acyclic diamond downloads and extracts dependencies once before app',
      () async {
        seedIndex({
          'app': 'left, right',
          'left': 'shared',
          'right': 'shared',
          'shared': '',
        });
        successfulInstallStubs();

        final res = await install(['app', 'app']);

        const archives = [
          'shared_1.deb',
          'left_1.deb',
          'right_1.deb',
          'app_1.deb',
        ];
        expect(recorded('downloads'), archives);
        expect(recorded('extractions'), ['shared', 'left', 'right', 'app']);
        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        for (final name in ['app', 'left', 'right', 'shared']) {
          expect(
            File('${tmp.path}/bin/$name').readAsStringSync(),
            '${name}_1.deb\n',
          );
        }
      },
    );

    test(
      'cycle through a diamond fails before download or extraction',
      () async {
        seedIndex({
          'app': 'left, right',
          'left': 'shared',
          'right': 'shared',
          'shared': 'app',
        });
        successfulInstallStubs();

        final res = await install(['app', 'app']);

        expect(res.exitCode, isNot(0));
        expect(res.stderr, contains('cycle'));
        expect(recorded('downloads'), isEmpty);
        expect(recorded('extractions'), isEmpty);
        expect(File('${tmp.path}/bin/app').existsSync(), isFalse);
        expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
      },
    );

    for (final dependency in ['absent', 'absent (>= 1) | also-absent']) {
      test(
        'missing required dependency $dependency fails before extraction',
        () async {
          seedIndex({'app': dependency});
          successfulInstallStubs();

          final res = await install(['app']);

          expect(res.exitCode, isNot(0));
          expect(res.stderr, contains('dependency'));
          expect(res.stderr, contains('absent'));
          expect(recorded('downloads'), isEmpty);
          expect(recorded('extractions'), isEmpty);
          expect(res.stdout, isNot(contains('[ovid-pkg] installing')));
          expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
        },
      );
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

        expect(recorded('extractions'), ['available', 'required', 'app']);
        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        expect(recorded('downloads'), [
          'available_1.deb',
          'required_1.deb',
          'app_1.deb',
        ]);
        for (final name in ['app', 'available', 'required']) {
          expect(
            File('${tmp.path}/bin/$name').readAsStringSync(),
            '${name}_1.deb\n',
          );
        }
        expect(File('${tmp.path}/bin/other').existsSync(), isFalse);
      });
    }

    test('a missing requested package prevents partial extraction', () async {
      seedIndex({'app': ''});
      successfulInstallStubs();

      final res = await install(['app', 'absent']);

      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('absent'));
      expect(recorded('downloads'), isEmpty);
      expect(recorded('extractions'), isEmpty);
    });

    test('dependency closure beyond 64 levels fails before download', () async {
      seedIndex({
        for (var i = 1; i <= 65; i++) 'p$i': i == 65 ? '' : 'p${i + 1}',
      });
      successfulInstallStubs();

      final res = await install(['p1']);

      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('dependency'));
      expect(res.stderr, contains('depth limit'));
      expect(res.stderr, contains('p65'));
      expect(recorded('downloads'), isEmpty);
      expect(recorded('extractions'), isEmpty);
      expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
    });

    test(
      'complete 17-level acyclic closure installs every dependency',
      () async {
        seedIndex({
          for (var i = 1; i <= 17; i++) 'p$i': i == 17 ? '' : 'p${i + 1}',
        });
        successfulInstallStubs();

        final res = await install(['p1']);

        expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
        expect(recorded('extractions'), [for (var i = 17; i >= 1; i--) 'p$i']);
        expect(recorded('downloads'), [
          for (var i = 17; i >= 1; i--) 'p${i}_1.deb',
        ]);
        for (var i = 1; i <= 17; i++) {
          expect(
            File('${tmp.path}/bin/p$i').readAsStringSync(),
            'p${i}_1.deb\n',
          );
        }
      },
    );

    test(
      'long closure with back edges rejects the cycle before download',
      () async {
        seedIndex({
          for (var i = 1; i <= 16; i++)
            'p$i': i == 16 ? 'p1, p16' : 'p${i + 1}',
        });
        successfulInstallStubs();

        final res = await install(['p1']);

        expect(res.exitCode, isNot(0));
        expect(res.stderr, contains('cycle'));
        expect(recorded('downloads'), isEmpty);
        expect(recorded('extractions'), isEmpty);
        expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
      },
    );

    for (final arch in {
      'armv7l': 'arm',
      'armv8l': 'arm',
      'armv7a': 'arm',
      'arm64': 'aarch64',
      'aarch64': 'aarch64',
    }.entries) {
      test(
        'uname ${arch.key} successfully fetches the ${arch.value} index',
        () async {
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

          final res = await Process.run('/bin/sh', [
            script,
            'update',
          ], environment: env);

          expect(recorded('index-urls'), [
            '${mirrors.first}/dists/stable/main/binary-${arch.value}/Packages',
          ]);
          expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
          expect(res.stderr, isEmpty);
        },
      );
    }

    test('apt install -y does not resolve -y as a package', () async {
      // Pre-seed an index so a non-stripped flag would be looked up
      // rather than triggering a network update.
      seedIndex({'ripgrep': ''});

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
      final res = await Process.run('/bin/sh', [
        script,
        'update',
      ], environment: env).timeout(const Duration(seconds: 60));
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

      final res = await Process.run('/bin/sh', [
        '${fallback.path}/bin/ovid-pkg',
        'update',
      ], environment: fallbackEnv).timeout(const Duration(seconds: 30));
      final out = '${res.stdout}${res.stderr}';

      expect(res.exitCode, isNot(0));
      expect(out, contains('binary-arm/Packages'));
      expect(out, isNot(contains('binary-armv7l/Packages')));
    });

    test(
      'extraction failure preserves exit 7 and leaves prefix payload untouched',
      () async {
        seedIndex({'ripgrep': ''});
        successfulInstallStubs();
        final stubs = Directory('${tmp.path}/stubs');
        // Inspection stays real. Simulate a tool that writes staged bytes then
        // fails: neither its output nor its partial payload may imply success.
        writeStub(stubs, 'dpkg-deb', r'''
if [ "$1" = -x ]; then
  /usr/bin/dpkg-deb -f "$2" Package >> "$PREFIX/extractions" || exit 97
  /usr/bin/dpkg-deb "$@" || exit 98
  echo 'extract exploded'
  exit 7
fi
exec /usr/bin/dpkg-deb "$@"
''');
        File('${tmp.path}/bin/ripgrep').writeAsStringSync('existing payload\n');

        final res = await Process.run('/bin/sh', [
          script,
          'install',
          'ripgrep',
        ], environment: envWith(stubs)).timeout(const Duration(seconds: 30));

        expect(res.exitCode, 7, reason: '${res.stdout}${res.stderr}');
        expect(recorded('downloads'), ['ripgrep_1.deb']);
        expect(recorded('extractions'), ['ripgrep']);
        expect(res.stdout, contains('extract exploded'));
        expect('${res.stdout}${res.stderr}', contains('extract failed'));
        expect(res.stdout, isNot(contains('[ovid-pkg] extracted')));
        expect(
          File('${tmp.path}/bin/ripgrep').readAsStringSync(),
          'existing payload\n',
        );
        expect(Directory('${tmp.path}/data').existsSync(), isFalse);
        expect(
          Directory('${tmp.path}/var/cache/ovid-pkg/archives').listSync(),
          isEmpty,
        );
      },
    );

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
