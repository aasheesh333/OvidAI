import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sandbox = SandboxService.I;
  late Directory root;
  late Directory prefix;
  final commands = <String>[];
  final lines = <String>[];
  final ready = <String>{};
  var failOptional = true;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('ovid-runtime-install-');
    prefix = Directory('${root.path}/sandbox');
    for (final name in ['bin/bash', 'bin/coreutils', 'lib/libtermux-exec-direct-ld-preload.so']) {
      final file = File('${prefix.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('fixture');
    }
    commands.clear(); lines.clear(); ready.clear(); failOptional = true;
    sandbox.resetCheckExistingForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => root.path);
    expect(await sandbox.checkExisting(), isTrue);
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      commands.add(command);
      if (command.startsWith('awk ')) return (0, '');
      if (command.startsWith('apt update') || command.startsWith('ovid-pkg update')) return (0, 'signed index ready');
      if (command.startsWith('apt install') || command.startsWith('ovid-pkg install')) {
        if (failOptional && RegExp(r'\b(gh|tmux)\b').hasMatch(command)) return (100, 'Unable to locate package gh');
        if (command.contains('nodejs')) ready.addAll(['node', 'npm', 'npx']);
        if (RegExp(r'\bpython\b').hasMatch(command)) ready.add('python');
        if (command.contains('python-pip')) ready.add('pip');
        if (RegExp(r'\buv\b').hasMatch(command)) ready.addAll(['uv', 'uvx']);
        if (command.contains('git')) ready.add('git');
        if (command.contains('curl')) ready.add('curl');
        return (0, 'extracted');
      }
      // Only subprocesses are replaced: real orchestration, repair writes,
      // retry decisions and success gates run in SandboxService.
      if (command.contains('--version') || command.contains('command -v')) {
        for (final bin in ['node', 'npm', 'npx', 'python', 'pip', 'git', 'curl', 'uv', 'uvx']) {
          if (RegExp('\\b$bin\\b').hasMatch(command) && !ready.contains(bin)) {
            return (127, 'CANNOT LINK EXECUTABLE $bin: missing libfixture.so');
          }
        }
        return (0, 'fixture version');
      }
      if (command == 'git --exec-path 2>&1') return (0, '${prefix.path}/libexec/git-core');
      return (0, '');
    };
  });

  tearDown(() {
    SandboxService.execCheckedOverrideForTest = null;
    sandbox.resetCheckExistingForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    root.deleteSync(recursive: true);
  });

  test('unavailable optional packages do not block Node Python git and curl', () async {
    final ok = await sandbox.installCoreRuntimes((_, _, line) => lines.add(line));
    expect(ok, isTrue, reason: lines.join('\n'));
    expect(ready, containsAll(['node', 'npm', 'npx', 'python', 'git', 'curl']));
    expect(lines.join('\n'), contains('Unable to locate package gh'));
    expect(lines.join('\n'), isNot(contains('offline?')));
  });

  test('required probes reject files whose dynamic linker fails', () async {
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      // Models command lookup succeeding for an unexecutable downloaded ELF.
      if (args.last.contains('command -v')) return (0, '${prefix.path}/bin/node');
      return (127, 'CANNOT LINK EXECUTABLE node');
    };
    expect(await sandbox.runtimesVerified(), isFalse);
    expect(await sandbox.hasRuntime('node'), isFalse);
  });

  test('runtime verification propagates cancellation', () async {
    SandboxService.execCheckedOverrideForTest = (_, _) async => throw SandboxCancelledException();
    await expectLater(sandbox.runtimesVerified(), throwsA(isA<SandboxCancelledException>()));
  });

  test('cancelled signed command releases its owned lock before retry', () async {
    final normal = SandboxService.execCheckedOverrideForTest!;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last.startsWith('apt ')) return (1, 'apt transport failed');
      if (args.last.startsWith('ovid-pkg update')) {
        final lock = Directory('${prefix.path}/var/cache/ovid-pkg/lock')..createSync(recursive: true);
        File('${lock.path}/owner').writeAsStringSync(env['OVID_PKG_OPERATION'] ?? 'unowned');
        throw SandboxCancelledException();
      }
      return normal(args, env);
    };
    await expectLater(sandbox.installCoreRuntimes((_, _, _) {}), throwsA(isA<SandboxCancelledException>()));
    expect(Directory('${prefix.path}/var/cache/ovid-pkg/lock').existsSync(), isFalse);
    SandboxService.execCheckedOverrideForTest = normal;
    failOptional = false;
    expect(await sandbox.installCoreRuntimes((_, _, _) {}), isTrue);
  });

  test('signed retries select a different mirror after failed metadata fetch', () async {
    final mirrors = <String>[];
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last.startsWith('apt ')) return (1, 'apt transport failed');
      if (args.last.startsWith('awk ')) return (0, '');
      if (args.last.startsWith('ovid-pkg update')) {
        mirrors.add(File('${prefix.path}/etc/apt/ovid-mirrors').readAsLinesSync().first);
        if (mirrors.length == 2) throw SandboxCancelledException();
        return (22, 'curl: HTTP 503');
      }
      return (1, 'missing');
    };
    await expectLater(sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), throwsA(isA<SandboxCancelledException>()));
    expect(mirrors, hasLength(2));
    expect(mirrors[1], isNot(mirrors[0]));
    expect(lines.join('\n'), contains('HTTP 503'));
  });

  test('lazy runtime rechecks execution even after a successful ensure', () async {
    ready.addAll(['node', 'npm', 'npx']);
    expect(await sandbox.ensureRuntime('node'), isTrue);
    File('${prefix.path}/bin/node').writeAsStringSync('broken executable');
    ready.remove('node');
    expect(await sandbox.ensureRuntime('node'), isTrue);
    expect(commands.where((c) => c.startsWith('apt install')), isNotEmpty);
  });

  test('broken bootstrap awk never attempts a nested native apt repair', () async {
    var awkWorks = false;
    var signedAttempted = false;
    final normal = SandboxService.execCheckedOverrideForTest!;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      if (command.startsWith('awk ')) return awkWorks ? (0, '') : (127, 'awk: gawk not found');
      if (command.startsWith('apt install') && command.contains('gawk')) {
        awkWorks = true;
        return (0, 'gawk restored');
      }
      if (command.startsWith('apt install')) return (1, 'dpkg prefix failure');
      if (command.startsWith('ovid-pkg update')) {
        signedAttempted = true;
        expect(awkWorks, isTrue, reason: 'signed metadata and resolver both require a working awk');
      }
      return normal(args, env);
    };
    expect(await sandbox.installCoreRuntimes((_, _, _) {}), isFalse);
    expect(signedAttempted, isFalse);
    expect(awkWorks, isFalse);
  });

  for (final missing in ['pip', 'uv', 'uvx']) {
    test('core readiness requires $missing execution', () async {
      ready.addAll(['node', 'npm', 'npx', 'python', 'pip', 'uv', 'uvx', 'git', 'curl']);
      ready.remove(missing);
      expect(await sandbox.runtimesVerified(), isFalse);
    });
  }

  test('pending signed rollback runs before native apt and blocks readiness', () async {
    final transaction = Directory('${prefix.path}/var/cache/ovid-pkg/transaction')..createSync(recursive: true);
    ready.addAll(['node', 'npm', 'npx', 'python', 'pip', 'uv', 'uvx', 'git', 'curl']);
    expect(await sandbox.runtimesVerified(), isFalse);
    final normal = SandboxService.execCheckedOverrideForTest!;
    var recovered = false;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last == 'ovid-pkg recover 2>&1') {
        recovered = true;
        transaction.deleteSync(recursive: true);
        return (0, 'recovered');
      }
      if (args.last.startsWith('apt update') || args.last.startsWith('apt install')) {
        expect(recovered, isTrue);
      }
      return normal(args, env);
    };
    expect(await sandbox.installCoreRuntimes((_, _, _) {}), isTrue);
    expect(recovered, isTrue);
  });

  for (final recoverable in [true, false]) {
    test('signed publication timeout fences next mutation (recoverable=$recoverable)', () async {
      final normal = SandboxService.execCheckedOverrideForTest!;
      var interrupted = false;
      var recoveries = 0;
      final transaction = Directory('${prefix.path}/var/cache/ovid-pkg/transaction');
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        final command = args.last;
        if (command == 'publication-fixture') {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return (0, 'publication subprocess settled');
        }
        if (command == 'ovid-pkg recover 2>&1') {
          recoveries++;
          if (!recoverable) return (1, 'backup unavailable');
          transaction.deleteSync(recursive: true);
          return (0, 'rollback complete');
        }
        if (command.startsWith('apt update') || command.startsWith('apt install') ||
            command.startsWith('ovid-pkg update') || command.startsWith('ovid-pkg install')) {
          expect(transaction.existsSync(), isFalse, reason: 'recovery must precede $command');
        }
        if (!interrupted && command.startsWith('apt install')) return (1, 'native install failed');
        if (!interrupted && command.startsWith('ovid-pkg install')) {
          interrupted = true;
          transaction.createSync(recursive: true);
          File('${transaction.path}/active').writeAsStringSync('');
          final lock = Directory('${prefix.path}/var/cache/ovid-pkg/lock')..createSync();
          File('${lock.path}/owner').writeAsStringSync(env['OVID_PKG_OPERATION']!);
          // Exercise the checked runner's real timer/reap boundary without
          // waiting for the production twelve-minute package timeout.
          return sandbox.checkedCommandForTest(['publication-fixture'],
              timeout: const Duration(milliseconds: 1));
        }
        return normal(args, env);
      };
      final job = sandbox.installCoreRuntimes((_, _, _) {});
      if (recoverable) {
        expect(await job, isTrue);
      } else {
        await expectLater(job, throwsA(isA<StateError>()));
      }
      expect(interrupted, isTrue);
      expect(recoveries, 1);
    });
  }

  test('apt internal mirror retry recovers a journal left by its failed command', () async {
    final normal = SandboxService.execCheckedOverrideForTest!;
    final transaction = Directory('${prefix.path}/var/cache/ovid-pkg/transaction');
    var failed = false;
    var recovered = false;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      if (command == 'ovid-pkg recover 2>&1') {
        recovered = true;
        transaction.deleteSync(recursive: true);
        return (0, 'recovered');
      }
      if (command.startsWith('apt update')) {
        if (!failed) {
          failed = true;
          transaction.createSync(recursive: true);
          return (1, 'TLS failed');
        }
        expect(recovered, isTrue);
        expect(transaction.existsSync(), isFalse);
      }
      return normal(args, env);
    };
    expect(await sandbox.installCoreRuntimes((_, _, _) {}), isTrue);
    expect(recovered, isTrue);
  });

  test('successful extraction with broken execution still uses signed repair', () async {
    var repaired = false;
    final normal = SandboxService.execCheckedOverrideForTest!;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last == 'node --version 2>&1' && !repaired) {
        return (1, 'CANNOT LINK EXECUTABLE node: library missing');
      }
      if (args.last.startsWith('ovid-pkg install nodejs npm')) repaired = true;
      return normal(args, env);
    };
    expect(await sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), isTrue);
    expect(repaired, isTrue);
    expect(lines.join('\n'), contains('CANNOT LINK EXECUTABLE node: library missing'));
  });

  test('permanent Node failure still installs other essential groups', () async {
    final normal = SandboxService.execCheckedOverrideForTest!;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.last.contains('install') && args.last.contains('nodejs')) {
        return (1, 'node archive hash mismatch');
      }
      return normal(args, env);
    };
    expect(await sandbox.installCoreRuntimes((_, _, line) => lines.add(line)), isFalse);
    expect(ready, containsAll(['python', 'git', 'curl']));
    expect(lines.join('\n'), contains('node archive hash mismatch'));
  });

  test('a cancelled command never clears an unknown package owner lock', () async {
    final lock = Directory('${prefix.path}/var/cache/ovid-pkg/lock')..createSync(recursive: true);
    File('${lock.path}/owner').writeAsStringSync('another-terminal');
    SandboxService.execCheckedOverrideForTest = (_, _) async => throw SandboxCancelledException();
    await expectLater(sandbox.checkedCommandForTest(['bash', '-c', 'ovid-pkg update'],
        timeout: const Duration(seconds: 1)), throwsA(isA<SandboxCancelledException>()));
    expect(File('${lock.path}/owner').readAsStringSync(), 'another-terminal');
  });
}
