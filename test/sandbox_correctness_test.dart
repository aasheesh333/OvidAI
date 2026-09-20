import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/sandbox_service.dart';

/// Correctness fixes for the sandbox + proot paths:
///   • execProot must enforce the same policy gate as exec/spawn (it skipped it)
///   • ensureFlutter's probe must read an exit code, not a never-returned string
///   • uninstall must clear the lazy-ensure flags (stale `true` broke reinstall)
///   • the ensured flags must be validated against disk, not trusted blindly
///   • the Ubuntu arch must come from one source, not two (`uname -m` vs Dart)
///   • the proot HOST process must not inherit Termux-only env (LD_PRELOAD…)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('execProot enforces the sandbox policy', () {
    test('a denied command is refused before proot is provisioned', () async {
      final result = await SandboxService.I.execProot(['rm', '-rf', '/']);
      expect(result, contains('DENIED by sandbox policy'));
    });

    test('cwd containment is enforced for proot too', () async {
      final sandbox = SandboxService.I;
      final original = sandbox.policy;
      addTearDown(() => sandbox.policy = original);
      sandbox.policy = (
        allowedRoots: ['/data/allowed'],
        deniedCommands: SandboxService.defaultDeniedCommands,
      );
      final result = await sandbox.execProot(
        ['true'],
        hostWorkDir: Directory('/var/log'),
      );
      expect(result, contains('cwd escapes'));
    });
  });

  group('flutter presence probe reads an exit code', () {
    test('exit 0 means present, non-zero means absent', () {
      expect(SandboxService.flutterPresentProbe(0), isTrue);
      expect(SandboxService.flutterPresentProbe(1), isFalse);
      expect(SandboxService.flutterPresentProbe(127), isFalse);
    });
  });

  group('lazy-ensure flags survive uninstall correctly', () {
    test('uninstall clears every lazy flag and the fallback log', () async {
      final sandbox = SandboxService.I;
      sandbox.setLazyFlagsForTest(
        proot: true,
        flutter: true,
        jdk: true,
        kotlin: true,
        compiler: true,
        runtimeNode: true,
      );
      sandbox.recordFallbackForTest('bash -c glibc-thing');

      await sandbox.uninstall();

      final flags = sandbox.lazyFlagsForTest;
      expect(flags['proot'], isFalse);
      expect(flags['flutter'], isFalse);
      expect(flags['jdk'], isFalse);
      expect(flags['kotlin'], isFalse);
      expect(flags['compiler'], isFalse);
      expect(flags['runtimeNode'], isFalse);
      expect(sandbox.fallbackLog, isEmpty);
    });

    test('a stale true flag is ignored when the artifact is gone', () async {
      final sandbox = SandboxService.I;
      final tmp = Directory.systemTemp.createTempSync('ovid-stale-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      sandbox.sandboxPrefixForTest = tmp;
      sandbox.setLazyFlagsForTest(proot: true);

      var provisioned = false;
      SandboxService.prootProvisionOverrideForTest = (onLine) async {
        provisioned = true;
        return true;
      };
      addTearDown(() {
        SandboxService.prootProvisionOverrideForTest = null;
        sandbox.sandboxPrefixForTest = null;
      });

      // ubuntu/ does not exist under the prefix → the cached `true` must not
      // short-circuit; provisioning runs.
      final ok = await sandbox.ensureProotUbuntu();
      expect(ok, isTrue);
      expect(provisioned, isTrue,
          reason: 'stale flag must be re-validated against disk');
    });
  });

  group('ubuntu arch has a single source', () {
    test('the provision script embeds the Dart-computed arch, not uname', () {
      final script = SandboxService.prootProvisionScriptForTest('armhf');
      expect(script, contains('UARCH="armhf"'));
      expect(
        script,
        isNot(contains('uname -m')),
        reason: 'arch must come from Dart, not the guest uname',
      );
    });
  });

  group('proot host env stays minimal', () {
    test('no Termux-only vars leak into the proot host process', () {
      final env = SandboxService.I.prootHostEnvForTest();
      expect(env.containsKey('LD_PRELOAD'), isFalse);
      expect(env.containsKey('PREFIX'), isFalse);
      expect(env.containsKey('TERMUX__PREFIX'), isFalse);
      expect(env.containsKey('APT_CONFIG'), isFalse);
      expect(env.containsKey('GIT_CONFIG_COUNT'), isFalse);
    });
  });

  group('proot status is honest', () {
    test('reports not-provisioned with no prefix, and counts fallbacks', () async {
      final sandbox = SandboxService.I;
      sandbox.sandboxPrefixForTest = null;
      final before = await sandbox.prootStatus();
      expect(before.provisioned, isFalse);
      expect(before.prootBinary, isFalse);

      sandbox.recordFallbackForTest('bash -c glibc-thing');
      final after = await sandbox.prootStatus();
      expect(after.fallbackTriggers, before.fallbackTriggers + 1);
    });
  });

  group('dead / misleading API is gone', () {
    test('the bashPath alias `prootPath` no longer pretends to be proot', () {
      final src = File(
        'lib/core/sandbox_service.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('get prootPath')));
    });
  });
}
