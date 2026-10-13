import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/dpkg_compat.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';

/// Service-level trust + mirror orchestration (2026-10-12 device report:
/// keys ignored, 522 / IPv6 TLS mirrors, over an hour of retries).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = SandboxService.I;
  late Directory root;
  late Directory prefix;
  final commands = <String>[];
  final lines = <String>[];
  final ready = <String>{};
  late Map<String, List<int>> keys;
  String probeOut = '';

  String trusted(String name) => '${prefix.path}/etc/apt/trusted.gpg.d/$name';
  bool isRegular(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.file;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ovid-apt-trust-');
    prefix = Directory('${root.path}/sandbox');
    for (final name in ['bin/bash', 'bin/coreutils', 'lib/libtermux-exec-direct-ld-preload.so']) {
      File('${prefix.path}/$name')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('fixture');
    }
    keys = {
      for (final n in SandboxService.aptKeyringAssetNames)
        n: File('assets/termux-keyring/$n').readAsBytesSync(),
    };
    SandboxService.bundledAptKeysOverrideForTest = keys;
    commands.clear(); lines.clear(); ready.clear(); probeOut = '';
    sandbox.deadMirrorsForTest.clear();
    sandbox.resetCheckExistingForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    expect(await sandbox.checkExisting(), isTrue);
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      commands.add(command);
      if (command.contains('OVIDMIRROR')) return (0, probeOut);
      if (command.startsWith('awk ')) return (0, '');
      if (command.startsWith('apt-get update') || command.startsWith('ovid-pkg update')) return (0, 'index ready');
      if (command.startsWith('apt-get install') || command.startsWith('ovid-pkg install')) {
        for (final b in ['node', 'npm', 'npx', 'python', 'pip', 'uv', 'uvx', 'git', 'curl']) {
          ready.add(b);
        }
        return (0, 'extracted');
      }
      if (command.contains('--version') || command.contains('command -v')) {
        for (final bin in ['node', 'npm', 'npx', 'python', 'pip', 'git', 'curl', 'uv', 'uvx']) {
          if (RegExp('\\b$bin\\b').hasMatch(command) && !ready.contains(bin)) return (127, 'missing $bin');
        }
        return (0, 'fixture version');
      }
      return (0, '');
    };
  });

  tearDown(() {
    SandboxService.execCheckedOverrideForTest = null;
    SandboxService.bundledAptKeysOverrideForTest = null;
    SandboxService.runtimeInstallBudget = const Duration(minutes: 20);
    SandboxService.runtimeGroupBudget = const Duration(minutes: 10);
    sandbox.resetCheckExistingForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    root.deleteSync(recursive: true);
  });

  test('step 1 seeds readable regular keys, apt dirs and the cmp shim, and logs repairs', () async {
    // Let the boot-time (unawaited) seed finish before breaking the keys.
    await sandbox.ensureAptTrustForTest(prefix);
    final dir = Directory('${prefix.path}/etc/apt/trusted.gpg.d')..createSync(recursive: true);
    for (final n in keys.keys) {
      final link = Link(trusted(n));
      if (link.existsSync()) link.deleteSync();
      if (File(trusted(n)).existsSync()) File(trusted(n)).deleteSync();
      link.createSync('${prefix.path}/share/termux-keyring/$n');
    }
    final report = await sandbox.ensureAptTrustForTest(prefix, onLine: lines.add);
    expect(report!.ok, isTrue, reason: report.failures.join());
    for (final e in keys.entries) {
      expect(isRegular(trusted(e.key)), isTrue, reason: e.key);
      expect(File(trusted(e.key)).readAsBytesSync(), e.value);
      expect(File(trusted(e.key)).statSync().mode & 0x1ff, 0x1a4);
    }
    expect(dir.statSync().mode & 0x1ff, 0x1ed);
    expect(lines.join('\n'), contains('[keys] repaired termux-autobuilds.gpg (dangling symlink)'));
    expect(Directory('${prefix.path}/var/lib/apt/lists/partial').existsSync(), isTrue);
    expect(Directory('${prefix.path}/etc/apt/auth.conf.d').existsSync(), isTrue);
    expect(File('${prefix.path}/bin/cmp').readAsStringSync(), contains('ovid-cmp-shim'));
  });

  test('Retry re-seeds keys that broke after a previous run', () async {
    expect(await sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), isTrue,
        reason: lines.join('\n'));
    File(trusted('termux-autobuilds.gpg')).deleteSync();
    Link(trusted('termux-autobuilds.gpg')).createSync('${prefix.path}/share/termux-keyring/gone.gpg');
    File(trusted('grimler.gpg')).writeAsBytesSync([0x98, 0x01, 0x00]);
    lines.clear();
    expect(await sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), isTrue);
    expect(isRegular(trusted('termux-autobuilds.gpg')), isTrue);
    expect(File(trusted('grimler.gpg')).readAsBytesSync(), keys['grimler.gpg']);
    final log = lines.join('\n');
    expect(log, contains('repaired termux-autobuilds.gpg (dangling symlink)'));
    expect(log, contains('repaired grimler.gpg (stale or unreadable content)'));
    expect(log, contains('9 bundled signing keys verified readable'));
  });

  test('scripts use apt-get, never the unstable apt CLI', () async {
    // Force native apt to run: signed path is the fallback.
    expect(await sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), isTrue);
    expect(commands.where((c) => c.startsWith('apt-get update')), isNotEmpty);
    expect(commands.where((c) => RegExp(r'^apt\s+(update|install)').hasMatch(c)), isEmpty);
  });

  test('a failed index never reports success', () async {
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      commands.add(command);
      if (command.startsWith('apt-get') && command.contains('update')) {
        return (100, 'W: GPG error: NO_PUBKEY 5A897D96E57CF20C\n'
            "E: The repository 'https://x stable InRelease' is not signed.\n"
            'All packages are up to date.');
      }
      if (command.startsWith('ovid-pkg update')) {
        return (1, '[ovid-pkg] signed index verification failed: fetch, signature, hash, expiry or stale generation (signature: gpgv: Can\'t check signature: No public key)');
      }
      if (command.contains('--version') || command.contains('command -v')) return (127, 'missing');
      return (0, '');
    };
    await expectLater(sandbox.installCoreRuntimes((_, _, line) => lines.add(line)),
        throwsA(isA<RuntimeSetupException>()));
    final log = lines.join('\n');
    expect(log, isNot(contains('All packages are up to date')));
    expect(log, contains('apt-get update FAILED (exit 100) — package signature check failed'));
    expect(log, contains('Package signature check failed — repairing keys…'));
    expect(log, contains(SandboxService.signatureFailureAdvice));
    expect(log, isNot(contains('verified ✓')));
    // Native apt stops after two failed index updates in one run.
    expect(commands.where((c) => c.startsWith('apt-get update')).length, lessThanOrEqualTo(4));
  });

  test('successful update still shows the success summary', () async {
    SandboxService.execCheckedOverrideForTest = (args, env) async =>
        args.last.startsWith('apt-get update') ? (0, 'All packages are up to date.') : (0, '');
    final (code, _) = await sandbox.aptCheckedForTest('update 2>&1', onLine: lines.add);
    expect(code, 0);
    expect(lines, contains('All packages are up to date.'));
  });

  test('IPv6 handshake failure retries apt over IPv4 before rotating', () async {
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      commands.add(args.last);
      if (args.last.contains('ForceIPv4=true')) return (0, 'ok');
      return (100, 'Err:1 https://termux.astra.in.ua/apt/termux-main stable InRelease\n'
          '  Could not handshake: Error in the pull function. [IP: 2a10:2f40:1::20e 443]');
    };
    final before = sandbox.currentMirrorIndexForTest;
    final (code, _) = await sandbox.aptCheckedForTest('update 2>&1', onLine: lines.add);
    expect(code, 0);
    expect(commands.last, 'apt-get -o Acquire::ForceIPv4=true update 2>&1');
    expect(sandbox.currentMirrorIndexForTest, before);
    expect(lines.join('\n'), contains('retrying over IPv4'));
  });

  group('mirror health selection', () {
    const cf = 'https://packages-cf.termux.dev/apt/termux-main';
    const official = 'https://packages.termux.dev/apt/termux-main';
    const tuna = 'https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main';
    const nju = 'https://mirror.nju.edu.cn/termux/apt/termux-main';

    test('picks the best healthy mirror, forces IPv4 when needed, drops dead ones', () async {
      // Candidate order = SandboxService pool order (cf, official, tuna, nju, …).
      probeOut = 'OVIDMIRROR|0|http522|30|0|0\n'
          'OVIDMIRROR|1|tls|5000|0|1\n'
          'OVIDMIRROR|2|ok|80|1000|1\n'
          'OVIDMIRROR|3|signature|90|0|0\n'
          'OVIDMIRROR|4|ok|300|1000|0\n'
          'OVIDMIRROR|5|timeout|8000|0|1\n'
          'OVIDMIRROR|6|ok|60|900|0\n';
      expect(await sandbox.selectHealthyMirrorForTest(lines.add), isTrue);
      final order = File('${prefix.path}/etc/apt/ovid-mirrors').readAsLinesSync();
      expect(order.first, tuna);
      expect(order, isNot(contains(cf)));
      expect(order, isNot(contains(nju)));
      expect(File('${prefix.path}/etc/apt/sources.list').readAsStringSync(), contains('deb $tuna stable main'));
      expect(File('${prefix.path}/etc/apt/apt.conf.d/50ovid-ipv4.conf').readAsStringSync(),
          contains('Acquire::ForceIPv4 "true";'));
      expect(File('${prefix.path}/etc/apt/ovid-force-ipv4').existsSync(), isTrue);
      expect(sandbox.deadMirrorsForTest, containsAll([cf, official, nju]));
      expect(lines.join('\n'), contains('[mirror] $cf: http522'));
    });

    test('official mirrors win among equally fresh ones; IPv4 flag cleared', () async {
      File('${prefix.path}/etc/apt/ovid-force-ipv4').writeAsStringSync('1\n');
      probeOut = 'OVIDMIRROR|0|ok|900|2000|0\nOVIDMIRROR|2|ok|50|2000|0\n';
      expect(await sandbox.selectHealthyMirrorForTest(lines.add), isTrue);
      expect(File('${prefix.path}/etc/apt/ovid-mirrors').readAsLinesSync().first, cf);
      expect(File('${prefix.path}/etc/apt/ovid-force-ipv4').existsSync(), isFalse);
    });

    test('no healthy mirror stops the run immediately with a network message', () async {
      probeOut = List.generate(7, (i) => 'OVIDMIRROR|$i|dns|5|0|0').join('\n');
      final clock = Stopwatch()..start();
      await expectLater(sandbox.installCoreRuntimes((_, _, line) => lines.add(line)),
          throwsA(isA<RuntimeSetupException>().having((e) => e.message, 'message', SandboxService.noMirrorAdvice)));
      expect(clock.elapsed, lessThan(const Duration(seconds: 20)));
      expect(commands.where((c) => RegExp(r'^(apt-get|ovid-pkg) (update|install)').hasMatch(c)), isEmpty);
      expect(StudioSetupCoordinator.friendlyError(const RuntimeSetupException(SandboxService.noMirrorAdvice)),
          SandboxService.noMirrorAdvice);
    });

    test('a hard signed-fetch failure drops the mirror for the rest of the run', () async {
      final used = <String>[];
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        final command = args.last;
        if (command.startsWith('apt-get')) return (100, 'E: Failed to fetch');
        if (command.startsWith('ovid-pkg update')) {
          used.add(File('${prefix.path}/etc/apt/ovid-mirrors').readAsLinesSync().first);
          return (1, 'curl: (22) The requested URL returned error: 522');
        }
        if (command.contains('--version') || command.contains('command -v')) return (127, 'missing');
        return (0, '');
      };
      await expectLater(sandbox.installCoreRuntimes((_, _, line) => lines.add(line)),
          throwsA(isA<RuntimeSetupException>()));
      expect(used.toSet().length, used.length, reason: 'no dead mirror is retried: $used');
      expect(used.length, lessThanOrEqualTo(SandboxService.mirrorCountForTest));
      expect(lines.join('\n'), contains(SandboxService.noMirrorAdvice));
    });
  });

  test('step 1 prepares dpkg: sandbox dirs, neutral config dir, Termux prefix alias', () async {
    final dpkg = File('${prefix.path}/bin/dpkg')
      ..writeAsBytesSync([0, ...DpkgCompat.termuxConfigDir.codeUnits, 0, 0]);
    Process.runSync('chmod', ['0755', dpkg.path]);
    final log = <String>[];

    await sandbox.ensureAptTrustForTest(prefix, onLine: log.add);

    expect(String.fromCharCodes(dpkg.readAsBytesSync()), contains(DpkgCompat.neutralConfigDir));
    expect(log.join('\n'), contains('[dpkg] dpkg: compiled-in Termux config dir neutralised'));
    for (final rel in ['etc/dpkg/dpkg.cfg.d', 'var/log/apt', 'var/lib/dpkg/info']) {
      expect(Directory('${prefix.path}/$rel').existsSync(), isTrue, reason: rel);
    }
    // apt's Termux-relative default resolves into the prefix now.
    expect(Directory('${prefix.path}/data/data/com.termux/files/usr/var/log/apt').existsSync(), isTrue);
    expect(File('${prefix.path}/etc/apt/ovid-apt.conf').readAsStringSync(),
        contains('Dir::Log "${prefix.path}/var/log/apt";'));
  });

  test('a structural dpkg failure moves the rest of the run to ovid-pkg at once', () async {
    final aptInstalls = <String>[];
    final pkgInstalls = <String>[];
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      commands.add(command);
      if (command.contains('OVIDMIRROR')) return (0, probeOut);
      if (command.startsWith('apt-get install')) {
        aptInstalls.add(command);
        return (100, "dpkg: error: error opening configuration directory "
            "'/data/data/com.termux/files/usr/etc/dpkg/dpkg.cfg.d': Permission denied\n"
            'E: Sub-process ${prefix.path}/bin/dpkg returned an error code (2)');
      }
      if (command.startsWith('ovid-pkg install')) {
        pkgInstalls.add(command);
        for (final b in ['node', 'npm', 'npx', 'python', 'pip', 'uv', 'uvx', 'git', 'curl']) {
          ready.add(b);
        }
        return (0, 'extracted');
      }
      if (command.contains('--version') || command.contains('command -v')) {
        for (final bin in ['node', 'npm', 'npx', 'python', 'pip', 'git', 'curl', 'uv', 'uvx']) {
          if (RegExp('\\b$bin\\b').hasMatch(command) && !ready.contains(bin)) return (127, 'missing $bin');
        }
        return (0, 'fixture version');
      }
      return (0, '');
    };

    expect(await sandbox.ensureRuntime('python', onLine: lines.add), isTrue);

    expect(aptInstalls, hasLength(1), reason: 'native apt is not retried per group');
    expect(pkgInstalls.first, contains('ovid-pkg install python'));
    expect(lines.join('\n'), contains('native dpkg cannot install here'));
  });

  test('a stuck package fails within its time limit with an actionable message', () async {
    SandboxService.runtimeGroupBudget = const Duration(milliseconds: 300);
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      commands.add(command);
      if (command.contains('OVIDMIRROR')) return (0, probeOut);
      if (RegExp(r'^(apt-get|ovid-pkg) (update|install)').hasMatch(command)) {
        // Stands in for a download that never finishes (reaped after kill).
        await Future<void>.delayed(const Duration(seconds: 1));
        return (137, 'killed');
      }
      if (command.contains('--version') || command.contains('command -v')) return (127, 'missing');
      return (0, '');
    };
    final clock = Stopwatch()..start();

    expect(await sandbox.ensureRuntime('node', onLine: lines.add), isFalse);

    expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
    final log = lines.join('\n');
    expect(log, contains('time limit per package'));
    expect(log, contains('Could not install nodejs npm'));
    expect(log, contains('tap Retry'));
  });

  test('total runtime setup time is bounded', () async {
    SandboxService.runtimeInstallBudget = Duration.zero;
    await expectLater(sandbox.installCoreRuntimes((_, _, line) => lines.add(line)),
        throwsA(isA<RuntimeSetupException>().having((e) => e.message, 'message', contains('stopped after'))));
    expect(commands.where((c) => RegExp(r'^(apt-get|ovid-pkg) (update|install)').hasMatch(c)), isEmpty);
  });
}
