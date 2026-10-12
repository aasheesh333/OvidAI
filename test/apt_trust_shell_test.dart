import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_pkg.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

import 'wave2_supply_fixture.dart';

/// Shell-level trust/mirror behaviour, executed with real sh/bash/gpgv and
/// locally generated keys (no network).
void main() {
  void writeStub(Directory dir, String name, String body) {
    dir.createSync(recursive: true);
    final f = File('${dir.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['0755', f.path]);
  }

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('apt-trust-shell'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('cmp shim for apt-key', () {
    /// The payload's own apt-key `is_supported_keyring` (verbatim).
    String isSupportedKeyring() {
      final zip = ZipDecoder().decodeBytes(File(
              'android/app/src/main/jniLibs/arm64-v8a/libovid_bootstrap.so')
          .readAsBytesSync());
      final aptKey = String.fromCharCodes(
          zip.files.firstWhere((f) => f.name == 'bin/apt-key').content as List<int>);
      final start = aptKey.indexOf('is_supported_keyring() {');
      final end = aptKey.indexOf('\n}\n', start);
      expect(start, greaterThan(0));
      return aptKey.substring(start, end + 3);
    }

    ProcessResult check(String binDir, String key) => Process.runSync('/bin/sh', [
          '-c',
          'apt_warn() { echo "W: \$*" >&2; }\n${isSupportedKeyring()}\nis_supported_keyring "\$1"',
          'sh',
          key,
        ], environment: {'PATH': '$binDir:${tmp.path}/toybox:/usr/bin:/bin'});

    // Older Android toybox cmp: no -n option. Shadows the host cmp.
    void toyboxCmp() => writeStub(Directory('${tmp.path}/toybox'), 'cmp',
        'case "\$*" in *-n*) echo "cmp: Unknown option n" >&2; exit 2;; esac; exec /usr/bin/cmp "\$@"');

    test('without a -n capable cmp apt-key rejects a valid key (device symptom)', () {
      toyboxCmp();
      final r = check('${tmp.path}/toybox', File('assets/termux-keyring/termux-autobuilds.gpg').absolute.path);
      expect(r.exitCode, isNot(0));
      expect(r.stderr, contains('unsupported filetype'));
    });

    test('the shim makes apt-key accept every bundled key and reject garbage', () {
      toyboxCmp();
      final prefix = Directory('${tmp.path}/prefix')..createSync();
      OvidPkgInstaller.writeCmpShim(prefix);
      final bin = '${prefix.path}/bin';
      Link('$bin/sh').createSync('/bin/sh');
      for (final name in SandboxService.aptKeyringAssetNames) {
        final r = check(bin, File('assets/termux-keyring/$name').absolute.path);
        expect(r.exitCode, 0, reason: '$name: ${r.stderr}');
      }
      final junk = File('${tmp.path}/junk.gpg')..writeAsStringSync('-----BEGIN PGP');
      expect(check(bin, junk.path).stderr, contains('unsupported filetype'));
    });

    test('shim semantics: -s, -n, stdin, differ and trouble exit codes', () {
      final prefix = Directory('${tmp.path}/prefix')..createSync();
      OvidPkgInstaller.writeCmpShim(prefix);
      final cmp = '${prefix.path}/bin/cmp';
      final a = File('${tmp.path}/a')..writeAsStringSync('hello');
      final b = File('${tmp.path}/b')..writeAsStringSync('help!');
      ProcessResult run(String script) => Process.runSync('/bin/sh', ['-c', script]);
      expect(run('sh $cmp -s ${a.path} ${a.path}').exitCode, 0);
      expect(run('sh $cmp -s ${a.path} ${b.path}').exitCode, 1);
      expect(run('sh $cmp -s -n 3 ${a.path} ${b.path}').exitCode, 0);
      expect(run("printf 'h' | sh $cmp -s -n 1 - ${a.path}").exitCode, 0);
      expect(run("printf 'x' | sh $cmp -s -n 1 - ${a.path}").exitCode, 1);
      expect(run('sh $cmp -s ${a.path} ${tmp.path}/missing').exitCode, 2);
    });

    test('a real cmp is never replaced; an older shim is refreshed', () {
      final prefix = Directory('${tmp.path}/prefix')..createSync();
      final cmp = File('${prefix.path}/bin/cmp')..createSync(recursive: true);
      cmp.writeAsBytesSync([0x7f, 0x45, 0x4c, 0x46]);
      OvidPkgInstaller.writeCmpShim(prefix);
      expect(cmp.readAsBytesSync(), [0x7f, 0x45, 0x4c, 0x46]);
      cmp.writeAsStringSync('#!/bin/sh\n${OvidPkgInstaller.cmpShimMarker} v0\n');
      OvidPkgInstaller.writeCmpShim(prefix);
      expect(cmp.readAsStringSync(), contains('_digest'));
    });
  });

  group('ovid-pkg _verify_release keyring filtering', () {
    late String script;
    late Map<String, String> env;
    late SignedRepositoryFixture signed;
    late Directory stubs;
    const mirror = 'https://mirror-one.test/apt/termux-main';

    setUp(() {
      OvidPkgInstaller.writeAll(tmp, arch: 'aarch64', mirrors: [mirror]);
      Link('${tmp.path}/bin/sh').createSync('/bin/sh');
      script = '${tmp.path}/bin/ovid-pkg';
      stubs = Directory('${tmp.path}/stubs')..createSync();
      env = {
        'PREFIX': tmp.path,
        'PATH': '${stubs.path}:${tmp.path}/bin:/usr/bin:/bin',
        'LC_ALL': 'C',
      };
      writeStub(stubs, 'dpkg-deb', 'exit 99');
      signed = SignedRepositoryFixture(tmp.path)..trust(tmp.path);
      signed.publish('Package: app\n\n', inRelease: true);
    });

    String curlStub({String extra = ''}) => '''
prev=""; out=""; url=""; v4=0
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  [ "\$a" = "-4" ] && v4=1
  case "\$a" in https://*) url="\$a";; esac
  prev="\$a"
done
$extra
source="\$PREFIX/repo/dists/stable/\${url#*/dists/stable/}"
[ -f "\$source" ] || exit 22
cp "\$source" "\$out"
''';

    void breakKeyrings() {
      final dir = '${tmp.path}/etc/apt/trusted.gpg.d';
      Link('$dir/dangling.gpg').createSync('${tmp.path}/share/termux-keyring/dangling.gpg');
      File('$dir/armored.gpg').writeAsStringSync('-----BEGIN PGP PUBLIC KEY BLOCK-----\n');
      File('$dir/empty.gpg').writeAsBytesSync([]);
    }

    test('real gpgv verification succeeds when other keyrings are broken', () async {
      breakKeyrings();
      writeStub(stubs, 'curl', curlStub());
      final res = await Process.run('/bin/sh', [script, 'update'], environment: env);
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stdout, contains('index ready'));
      expect(res.stderr, contains('skipped keyring dangling.gpg: dangling symlink'));
      expect(res.stderr, contains('skipped keyring armored.gpg: unsupported format (first byte 0x2d)'));
      expect(res.stderr, contains('skipped keyring empty.gpg: empty'));
    });

    test('only broken keyrings: fails with a specific reason', () async {
      File('${tmp.path}/etc/apt/trusted.gpg.d/fixture.gpg').deleteSync();
      breakKeyrings();
      writeStub(stubs, 'curl', curlStub());
      final res = await Process.run('/bin/sh', [script, 'update'], environment: env);
      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('no usable trusted keyring'));
    });

    test('signature by an unknown key names the signature failure', () async {
      final other = SignedRepositoryFixture('${tmp.path}/other');
      File('${tmp.path}/etc/apt/trusted.gpg.d/fixture.gpg').deleteSync();
      other.trust(tmp.path);
      writeStub(stubs, 'curl', curlStub());
      final res = await Process.run('/bin/sh', [script, 'update'], environment: env);
      expect(res.exitCode, isNot(0));
      expect(res.stderr, contains('(signature:'));
    });

    test('TLS handshake failure is retried over IPv4', () async {
      writeStub(stubs, 'curl', curlStub(extra: '[ "\$v4" = 1 ] || { echo "curl: (35) handshake" >&2; exit 35; }'));
      final res = await Process.run('/bin/sh', [script, 'update'], environment: env);
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, contains('retrying over IPv4'));
    });

    test('ovid-force-ipv4 makes every fetch use -4', () async {
      File('${tmp.path}/etc/apt/ovid-force-ipv4').writeAsStringSync('1\n');
      writeStub(stubs, 'curl', curlStub(extra: '[ "\$v4" = 1 ] || exit 35'));
      final res = await Process.run('/bin/sh', [script, 'update'], environment: env);
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');
      expect(res.stderr, isNot(contains('retrying over IPv4')));
    });
  });

  group('mirror health probe', () {
    const mirrors = [
      'https://m522.test/apt',
      'https://m6tls.test/apt',
      'https://mbadsig.test/apt',
      'https://mok.test/apt',
    ];

    test('classifies 522, IPv6-TLS-then-IPv4, bad signature and healthy', () async {
      final prefix = Directory('${tmp.path}/prefix')..createSync();
      Directory('${prefix.path}/tmp').createSync();
      final good = SignedRepositoryFixture('${tmp.path}/good')..trust(prefix.path);
      good.publish('Package: app\n\n', inRelease: true);
      final bad = SignedRepositoryFixture('${tmp.path}/bad');
      bad.publish('Package: app\n\n', inRelease: true);
      final stubs = Directory('${tmp.path}/stubs');
      writeStub(stubs, 'curl', '''
out=""; url=""; v4=0; prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && out="\$a"
  [ "\$a" = "-4" ] && v4=1
  case "\$a" in https://*) url="\$a";; esac
  prev="\$a"
done
case "\$url" in
  https://m522.test/*) echo "curl: (22) The requested URL returned error: 522" >&2; exit 22;;
  https://m6tls.test/*) [ "\$v4" = 1 ] || { echo "curl: (35) Could not handshake" >&2; exit 35; }
     cp "${tmp.path}/good/repo/dists/stable/InRelease" "\$out";;
  https://mbadsig.test/*) cp "${tmp.path}/bad/repo/dists/stable/InRelease" "\$out";;
  https://mok.test/*) cp "${tmp.path}/good/repo/dists/stable/InRelease" "\$out";;
  *) exit 6;;
esac
''');
      final res = await Process.run('bash', ['-c', SandboxService.mirrorProbeScript(mirrors)],
          environment: {
            'PREFIX': prefix.path,
            'TMPDIR': '${prefix.path}/tmp',
            'PATH': '${stubs.path}:/usr/bin:/bin',
            'LC_ALL': 'C',
          });
      expect(res.exitCode, 0, reason: '${res.stderr}');
      final ranked = SandboxService.rankMirrorProbe('${res.stdout}', mirrors);
      final byMirror = {for (final p in ranked) p.mirror: p};
      expect(byMirror[mirrors[0]]!.status, 'http522');
      expect(byMirror[mirrors[1]]!.healthy, isTrue);
      expect(byMirror[mirrors[1]]!.ipv4Only, isTrue);
      expect(byMirror[mirrors[2]]!.status, 'signature');
      expect(byMirror[mirrors[3]]!.healthy, isTrue);
      expect(byMirror[mirrors[3]]!.ipv4Only, isFalse);
      expect(ranked.take(2).map((p) => p.mirror).toSet(), {mirrors[1], mirrors[3]});
      expect(Directory('${prefix.path}/tmp').listSync(), isEmpty, reason: 'probe cleans up');
    });

    test('ranking: freshest first, official preferred among equals, then fastest', () {
      const pool = [
        'https://packages-cf.termux.dev/apt/termux-main',
        'https://packages.termux.dev/apt/termux-main',
        'https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main',
        'https://mirror.nju.edu.cn/termux/apt/termux-main',
      ];
      // cf is slow but fresh; tuna is fastest but older; nju fresh+fast.
      const out = 'OVIDMIRROR|0|ok|900|2000|0\n'
          'OVIDMIRROR|1|http503|10|0|0\n'
          'OVIDMIRROR|2|ok|50|1000|0\n'
          'OVIDMIRROR|3|ok|100|2000|1\n'
          'garbage line\n';
      final ranked = SandboxService.rankMirrorProbe(out, pool);
      expect(ranked.map((p) => p.mirror).toList(), [pool[0], pool[3], pool[2], pool[1]]);
      expect(ranked.last.healthy, isFalse);
    });
  });
}
