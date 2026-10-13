import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/apt_trust.dart';
import 'package:ovid_ai/core/dpkg_compat.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

/// 2026-10-13 device report: `apt-get install nodejs npm` died with
///   dpkg: error: error opening configuration directory
///   '/data/data/com.termux/files/usr/etc/dpkg/dpkg.cfg.d': Permission denied
///   E: Directory '$PREFIX/data/data/com.termux/files/usr/var/log/apt/' missing
/// Pins the generated apt/dpkg configuration and the dpkg compatibility layer.
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ovid-dpkg-paths'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('apt config', () {
    const p = '/data/user/0/com.dhanuk.ovidai/files/sandbox';
    final conf = SandboxService.aptConfigText(p);

    test('every log path is pinned inside the prefix', () {
      expect(conf, contains('Dir::Log "$p/var/log/apt";'));
      expect(conf, contains('Dir::Log::Terminal "$p/var/log/apt/term.log";'));
      expect(conf, contains('Dir::Log::History "$p/var/log/apt/history.log";'));
      expect(conf, contains('Dir::Log::Planner "$p/var/log/apt/eipp.log.xz";'));
    });

    test('dpkg runs with the sandbox admindir/root, chrootless scripts and a sandbox log', () {
      expect(conf, contains('Dir::Bin::dpkg "$p/bin/dpkg";'));
      expect(conf, contains('DPkg::Options:: "--root=$p";'));
      expect(conf, contains('DPkg::Options:: "--admindir=$p/var/lib/dpkg";'));
      expect(conf, contains('DPkg::Options:: "--force-script-chrootless";'));
      expect(conf, contains('DPkg::Options:: "--force-not-root";'));
      expect(conf, contains('DPkg::Options:: "--log=$p/var/log/dpkg.log";'));
      expect(conf, contains('Dir::State::status "$p/var/lib/dpkg/status";'));
      expect(conf, contains('Dir::Cache::archives "$p/var/cache/apt/archives";'));
      expect(conf, contains('Dir::State::lists "$p/var/lib/apt/lists";'));
    });

    test('no setting points at the Termux app prefix', () {
      final settings = conf.split('\n').where((l) => !l.trimLeft().startsWith('//'));
      expect(settings.where((l) => l.contains('/data/data/com.termux')), isEmpty);
    });
  });

  group('apt/dpkg directories', () {
    test('every directory apt and dpkg write to exists before a run', () {
      AptTrust.ensureAptDirectories(tmp);
      for (final rel in [
        'var/log/apt',
        'etc/dpkg/dpkg.cfg.d',
        'etc/apt/apt.conf.d',
        'var/lib/dpkg/info',
        'var/lib/dpkg/updates',
        'var/lib/dpkg/triggers',
        'var/cache/apt/archives/partial',
        'var/lib/apt/lists/partial',
        'tmp',
      ]) {
        expect(Directory('${tmp.path}/$rel').existsSync(), isTrue, reason: rel);
      }
      expect(File('${tmp.path}/var/lib/dpkg/status').existsSync(), isTrue);
      expect(File('${tmp.path}/var/lib/dpkg/available').existsSync(), isTrue);
    });

    test('an existing dpkg status database is never truncated', () {
      File('${tmp.path}/var/lib/dpkg/status')
        ..createSync(recursive: true)
        ..writeAsStringSync('Package: bash\nStatus: install ok installed\n');
      AptTrust.ensureAptDirectories(tmp);
      expect(File('${tmp.path}/var/lib/dpkg/status').readAsStringSync(), contains('Package: bash'));
    });
  });

  group('dpkg compiled-in config dir', () {
    List<int> fakeElf() => [
      ...ascii.encode('\x7fELF'), 0, 0,
      ...ascii.encode('%s/%s.cfg.d'), 0,
      ...ascii.encode(DpkgCompat.termuxConfigDir), 0,
      ...ascii.encode('/data/data/com.termux/files/usr/var/lib/dpkg'), 0,
      // Not a whole string: must be left alone.
      ...ascii.encode('X${DpkgCompat.termuxConfigDir}'), 0,
    ];

    test('neutral path has the same length and keeps the /etc/dpkg tail', () {
      expect(DpkgCompat.neutralPrefix.length, DpkgCompat.termuxPrefix.length);
      expect(DpkgCompat.neutralConfigDir.length, DpkgCompat.termuxConfigDir.length);
      expect(DpkgCompat.neutralConfigDir, endsWith('/etc/dpkg'));
      expect(DpkgCompat.neutralConfigDir, isNot(startsWith('/data/')));
      expect(Directory(DpkgCompat.neutralConfigDir).existsSync(), isFalse);
    });

    test('rewrites only the whole CONFIGDIR string, size unchanged', () {
      final bytes = fakeElf();
      final out = DpkgCompat.patchedConfigDir(bytes)!;
      expect(out.length, bytes.length);
      final text = latin1.decode(out);
      expect(text, contains('${DpkgCompat.neutralConfigDir}\x00'));
      expect(text, contains('/data/data/com.termux/files/usr/var/lib/dpkg\x00'));
      expect(text, contains('X${DpkgCompat.termuxConfigDir}\x00'));
      expect(DpkgCompat.patchedConfigDir(out), isNull, reason: 'idempotent');
    });

    test('patches every bin/dpkg* binary in place of the prefix, keeping its mode', () {
      final bin = Directory('${tmp.path}/bin')..createSync();
      for (final name in ['dpkg', 'dpkg-query']) {
        File('${bin.path}/$name').writeAsBytesSync(fakeElf());
        Process.runSync('chmod', ['0755', '${bin.path}/$name']);
      }
      File('${bin.path}/bash').writeAsBytesSync(fakeElf());

      final lines = DpkgCompat.patchDpkgBinaries(tmp);

      expect(lines, hasLength(2));
      for (final name in ['dpkg', 'dpkg-query']) {
        final f = File('${bin.path}/$name');
        expect(latin1.decode(f.readAsBytesSync()), contains(DpkgCompat.neutralConfigDir));
        expect(f.statSync().mode & 0x1FF, 0x1ED, reason: '$name stays 0755');
      }
      expect(latin1.decode(File('${bin.path}/bash').readAsBytesSync()),
          contains('${DpkgCompat.termuxConfigDir}\x00'));
      expect(bin.listSync().map((e) => e.path).where((p) => p.contains('.ovid-patch')), isEmpty);
      expect(DpkgCompat.patchDpkgBinaries(tmp), isEmpty, reason: 'second pass is a no-op');
    });
  });

  group('Termux prefix alias', () {
    test('maps <prefix>/data/data/com.termux/files/usr onto the prefix', () {
      AptTrust.ensureAptDirectories(tmp);
      DpkgCompat.ensureTermuxPrefixAlias(tmp);
      final logDir = Directory('${tmp.path}/data/data/com.termux/files/usr/var/log/apt');
      expect(logDir.existsSync(), isTrue);
      expect(logDir.resolveSymbolicLinksSync(),
          Directory('${tmp.path}/var/log/apt').resolveSymbolicLinksSync());
      expect(Link('${tmp.path}/${DpkgCompat.aliasPath}').targetSync(), DpkgCompat.aliasTarget);
      expect(DpkgCompat.ensureTermuxPrefixAlias(tmp), isEmpty, reason: 'idempotent');
    });

    test('a stray real tree from an earlier dpkg run is moved aside, not deleted', () {
      final stray = File('${tmp.path}/data/data/com.termux/files/usr/bin/node')
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final lines = DpkgCompat.ensureTermuxPrefixAlias(tmp);
      expect(lines.join('\n'), contains('moved stray'));
      expect(FileSystemEntity.isLinkSync('${tmp.path}/${DpkgCompat.aliasPath}'), isTrue);
      expect(stray.existsSync(), isFalse);
      final aside = Directory('${tmp.path}/data/data/com.termux/files')
          .listSync()
          .where((e) => e.path.contains('usr.orphaned-'));
      expect(aside, hasLength(1));
      expect(File('${aside.single.path}/bin/node').readAsStringSync(), 'old');
    });
  });

  group('runtime install failure classification', () {
    test('the device dpkg errors switch the run to ovid-pkg', () {
      const device = '''
dpkg: error: error opening configuration directory '/data/data/com.termux/files/usr/etc/dpkg/dpkg.cfg.d': Permission denied
E: Directory '/data/user/0/com.dhanuk.ovidai/files/sandbox/data/data/com.termux/files/usr/var/log/apt/' missing
E: Sub-process /data/user/0/com.dhanuk.ovidai/files/sandbox/bin/dpkg returned an error code (2)''';
      expect(SandboxService.looksLikeDpkgUnusable(device), isTrue);
      expect(SandboxService.looksLikeDpkgUnusable('E: Unable to locate package nodejs'), isFalse);
    });

    test('failure message names the groups, the last error and the Retry path', () {
      final m = SandboxService.runtimeGroupFailureMessage(
          ['nodejs npm'], 'StateError: signed install exit 1: x\n[ovid-pkg] download failed: nodejs\n');
      expect(m, contains('Could not install nodejs npm.'));
      expect(m, contains('[ovid-pkg] download failed: nodejs'));
      expect(m, contains('tap Retry'));
    });
  });
}
