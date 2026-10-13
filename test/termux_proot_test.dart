import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/termux_proot.dart';

/// Regression tests for the proot design (docs/studio-setup-repro.md):
/// the Termux userland runs unmodified with the sandbox prefix bound at the
/// compiled-in /data/data/com.termux/files/usr.
void writeProotFixture(String prefix) {
  for (final rel in ['bin/bash', 'bin/coreutils', TermuxProot.prootRel, TermuxProot.loaderRel]) {
    File('$prefix/$rel')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('fixture');
  }
  File('$prefix/${TermuxProot.layoutMarker}').writeAsStringSync('${TermuxProot.layoutVersion}\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TermuxProot (pure)', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('ovid-proot-'));
    tearDown(() => root.deleteSync(recursive: true));

    test('absolute Termux symlink targets become relative to the link', () {
      const usr = TermuxProot.guestPrefix;
      expect(TermuxProot.relativeLinkTarget('$usr/share/pacman/keyrings/grimler.gpg',
              './share/termux-keyring/grimler.gpg'),
          '../pacman/keyrings/grimler.gpg');
      expect(TermuxProot.relativeLinkTarget('$usr/bin/coreutils', './bin/ls'), 'coreutils');
      expect(TermuxProot.relativeLinkTarget('$usr/lib/libfoo.so.1', 'bin/foo'), '../lib/libfoo.so.1');
      // Relative targets are kept exactly (staging → prefix rename safe).
      expect(TermuxProot.relativeLinkTarget('libreadline.so.8', './lib/libreadline.so'), 'libreadline.so.8');
      expect(TermuxProot.relativeLinkTarget('/system/bin/sh', './bin/sh-system'), '/system/bin/sh');
    });

    test('wrap binds the prefix at the compiled-in Termux paths', () {
      final p = '${root.path}/sandbox';
      final w = TermuxProot(p).wrap('bash', ['-c', 'node -v'], cwd: '/data/user/0/x/files/workspaces/a');
      expect(w.executable, '$p/bin/proot');
      final a = w.arguments;
      String bindFor(String guest) => a.firstWhere((x) => x.endsWith(':$guest'));
      expect(bindFor('/data/data/com.termux'), '$p/.termux-root:/data/data/com.termux');
      expect(bindFor('/data/data/com.termux/files/usr'), '$p:/data/data/com.termux/files/usr');
      expect(bindFor('/data/data/com.termux/files/home'), '$p/home:/data/data/com.termux/files/home');
      expect(a, containsAllInOrder(['--kill-on-exit', '-w', '/data/user/0/x/files/workspaces/a']));
      // termux-exec is injected INSIDE the guest, never into the host proot.
      expect(a, containsAllInOrder([
        '/data/data/com.termux/files/usr/bin/env',
        'LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so',
        '/data/data/com.termux/files/usr/bin/bash', '-c', 'node -v',
      ]));
      expect(TermuxProot(p).hostEnv().containsKey('LD_PRELOAD'), isFalse);
      expect(TermuxProot(p).hostEnv()['PROOT_LOADER'], '$p/libexec/proot/loader');
      // Absolute host paths inside the prefix map to guest paths.
      expect(TermuxProot(p).wrap('$p/bin/git', [], cwd: '/').arguments,
          contains('/data/data/com.termux/files/usr/bin/git'));
    });

    test('guest env is the stock Termux one (no per-tool relocation vars)', () {
      final env = TermuxProot.guestEnv();
      expect(env['PREFIX'], '/data/data/com.termux/files/usr');
      expect(env['HOME'], '/data/data/com.termux/files/home');
      expect(env['PATH'], startsWith('/data/data/com.termux/files/usr/bin:'));
      for (final k in ['APT_CONFIG', 'GIT_EXEC_PATH', 'LD_LIBRARY_PATH', 'PYTHONPATH', 'OPENSSL_CONF']) {
        expect(env.containsKey(k), isFalse, reason: k);
      }
    });

    test('ensureLayout creates glue dirs, apt.conf.d snippet and marker; idempotent', () {
      final p = '${root.path}/sandbox';
      writeProotFixture(p);
      File('$p/${TermuxProot.layoutMarker}').deleteSync();
      expect(TermuxProot.isProotLayout(p), isFalse);
      TermuxProot(p)..ensureLayout()..ensureLayout();
      expect(TermuxProot.isProotLayout(p), isTrue);
      expect(Directory('$p/.termux-root/cache/apt/archives/partial').existsSync(), isTrue);
      expect(Directory('$p/.termux-root/files/usr').existsSync(), isTrue);
      expect(File('$p/etc/apt/apt.conf.d/99ovid').readAsStringSync(), contains('--force-confold'));
      // Never an apt Dir override or dpkg --root: stock Termux paths only.
      expect(File('$p/etc/apt/apt.conf.d/99ovid').readAsStringSync(), isNot(contains('Dir')));
      expect(File('$p/etc/apt/apt.conf.d/99ovid').readAsStringSync(), isNot(contains('--root')));
    });

    test('legacy (native path-rewriting) prefixes are recognised by their artifacts', () {
      final p = '${root.path}/sandbox';
      File('$p/bin/bash')..parent.createSync(recursive: true)..writeAsStringSync('x');
      expect(TermuxProot.isLegacyLayout(p), isFalse);
      File('$p/etc/apt/ovid-apt.conf')..parent.createSync(recursive: true)..writeAsStringSync('Dir "$p";');
      expect(TermuxProot.isLegacyLayout(p), isTrue);
      File('$p/etc/apt/ovid-apt.conf').deleteSync();
      Directory('$p/data/data/com.termux/files').createSync(recursive: true);
      Link('$p/data/data/com.termux/files/usr').createSync('../../../..');
      expect(TermuxProot.isLegacyLayout(p), isTrue);
      File('$p/${TermuxProot.layoutMarker}').writeAsStringSync(TermuxProot.layoutVersion);
      expect(TermuxProot.isLegacyLayout(p), isFalse);
    });

    test('launcher script enters the same proot environment', () {
      final script = TermuxProot('/data/user/0/app/files/sandbox').launcherScript();
      expect(script, startsWith('#!/system/bin/sh'));
      expect(script, contains(r'-b "$P:/data/data/com.termux/files/usr"'));
      expect(script, contains(r'-b "$P/.termux-root:/data/data/com.termux"'));
      expect(script, contains('LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec-ld-preload.so'));
    });
  });

  group('SandboxService on a proot prefix', () {
    final sandbox = SandboxService.I;
    late Directory root;
    late String prefix;
    final commands = <String>[];

    setUp(() {
      root = Directory.systemTemp.createTempSync('ovid-proot-svc-');
      prefix = '${root.path}/sandbox';
      commands.clear();
      sandbox.resetCheckExistingForTest();
      sandbox.legacyPrefixFound = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    });
    tearDown(() {
      SandboxService.execCheckedOverrideForTest = null;
      sandbox.resetCheckExistingForTest();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
      root.deleteSync(recursive: true);
    });

    test('checkExisting accepts it, every process goes through proot', () async {
      writeProotFixture(prefix);
      expect(await sandbox.checkExisting(), isTrue);
      expect(sandbox.usesProot, isTrue);
      final spec = sandbox.launchSpecForTest('bash', ['-c', 'true'], cwd: '$prefix/home');
      expect(spec.executable, '$prefix/bin/proot');
      expect(spec.environment['PREFIX'], TermuxProot.guestPrefix);
      expect(spec.environment['PROOT_LOADER'], '$prefix/libexec/proot/loader');
      expect(spec.environment.containsKey('APT_CONFIG'), isFalse);
      expect(spec.environment.containsKey('LD_PRELOAD'), isFalse);
      // Boot writes no legacy relocation artifacts.
      expect(File('$prefix/etc/apt/ovid-apt.conf').existsSync(), isFalse);
      expect(File('$prefix/bin/ovid-shell').readAsStringSync(), contains('proot'));
    });

    test('a legacy prefix is reported not installed and left untouched', () async {
      File('$prefix/bin/bash')..parent.createSync(recursive: true)..writeAsStringSync('x');
      File('$prefix/bin/coreutils').writeAsStringSync('x');
      File('$prefix/lib/libtermux-exec-direct-ld-preload.so')..parent.createSync(recursive: true)..writeAsStringSync('x');
      File('$prefix/etc/apt/ovid-apt.conf')..parent.createSync(recursive: true)..writeAsStringSync('legacy');
      File('$prefix/home/notes.txt')..parent.createSync(recursive: true)..writeAsStringSync('mine');
      expect(await sandbox.checkExisting(), isFalse);
      expect(sandbox.legacyPrefixFound, isTrue);
      expect(File('$prefix/home/notes.txt').readAsStringSync(), 'mine');
    });

    test('home is carried over on a core reinstall and never clobbered', () {
      final old = Directory('${root.path}/old')..createSync();
      final fresh = Directory('${root.path}/fresh')..createSync();
      File('${old.path}/home/project/a.js')..parent.createSync(recursive: true)..writeAsStringSync('x');
      File('${old.path}/home/.bashrc').writeAsStringSync('# Ovid sandbox profile (overrides Termux bootstrap default).\nexport PREFIX=/host');
      Directory('${fresh.path}/home').createSync();
      expect(SandboxService.carryHomeOver(old, fresh), isTrue);
      expect(File('${fresh.path}/home/project/a.js').existsSync(), isTrue);
      expect(File('${fresh.path}/home/.bashrc').existsSync(), isFalse, reason: 'legacy host-path profile dropped');
      // A non-empty destination is never replaced.
      File('${old.path}/home/b').createSync(recursive: true);
      expect(SandboxService.carryHomeOver(old, fresh), isFalse);
      expect(File('${old.path}/home/b').existsSync(), isTrue);
    });

    test('interrupted dpkg transactions are detected for `dpkg --configure -a`', () {
      writeProotFixture(prefix);
      final status = File('$prefix/var/lib/dpkg/status')..parent.createSync(recursive: true);
      status.writeAsStringSync('Package: a\nStatus: install ok installed\n');
      expect(SandboxService.dpkgNeedsConfigure(prefix), isFalse);
      status.writeAsStringSync('Package: a\nStatus: install ok unpacked\n');
      expect(SandboxService.dpkgNeedsConfigure(prefix), isTrue);
      status.writeAsStringSync('Package: a\nStatus: install ok installed\n');
      File('$prefix/var/lib/dpkg/updates/0001')..parent.createSync(recursive: true)..writeAsStringSync('');
      expect(SandboxService.dpkgNeedsConfigure(prefix), isTrue);
    });

    test('package names never read as TLS errors (dpkg failure misclassified before)', () {
      const dpkgFailure = '''The following NEW packages will be installed:
  c-ares ca-certificates libc++ openssl resolv-conf
dpkg: error: 2 expected programs not found in PATH or not executable
E: Sub-process /data/data/com.termux/files/usr/bin/dpkg returned an error code (2)''';
      expect(SandboxService.looksLikeAptTlsForTest(dpkgFailure), isFalse);
      expect(SandboxService.looksLikeAptTlsForTest(
          'E: Failed to fetch https://m/x  Certificate verification failed'), isTrue);
    });

    test('runtime setup uses stock apt only: a failed attempt retries apt on the next mirror', () async {
      writeProotFixture(prefix);
      expect(await sandbox.checkExisting(), isTrue);
      final ready = <String>{};
      var failedOnce = false;
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        final c = args.last;
        commands.add(c);
        if (c.contains('OVIDMIRROR')) return (0, '');
        if (c.startsWith('apt-get update')) return (0, 'ok');
        if (c.startsWith('apt-get install')) {
          if (!failedOnce) {
            failedOnce = true;
            return (100, 'E: Failed to fetch https://mirror/pool/x.deb  404  Not Found');
          }
          for (final b in ['node', 'npm', 'npx', 'python', 'pip', 'uv', 'uvx', 'git', 'curl', 'make', 'as', 'rg', 'ssh', 'rsync', 'jq', 'unzip', 'tmux', 'gh']) {
            ready.add(b);
          }
          return (0, 'Setting up nodejs');
        }
        if (c.contains('--version') || c.contains('-V') || c.contains('-v ')) {
          for (final b in ['node', 'npm', 'npx', 'python', 'pip', 'git', 'curl', 'uv', 'uvx']) {
            if (RegExp('^$b\\b').hasMatch(c) && !ready.contains(b)) return (127, '$b: not found');
          }
          return (0, 'v1');
        }
        return (0, '');
      };
      final lines = <String>[];
      expect(await sandbox.installCoreRuntimes((_, _, l) => lines.add(l)), isTrue, reason: lines.join('\n'));
      expect(commands.where((c) => c.contains('ovid-pkg')), isEmpty);
      expect(failedOnce, isTrue);
      expect(commands.where((c) => c.startsWith('apt-get update')).length, greaterThanOrEqualTo(2));
    });
  });
}
