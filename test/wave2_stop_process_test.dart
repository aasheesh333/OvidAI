import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

bool alive(int pid) {
  try {
    final stat = File('/proc/$pid/stat').readAsStringSync();
    return stat.substring(stat.lastIndexOf(')') + 2).split(' ').first != 'Z';
  } catch (_) {
    return false;
  }
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() async {
    SandboxService.processStartForTest = null;
    SandboxService.I.sandboxPrefixForTest = null;
    SandboxService.I.killAllProcesses();
    await PtyPool.I.discardAllShells();
  });

  test('cancelled installer rejects its late owned OS spawn', () async {
    final sandbox = SandboxService.I;
    final dir = await Directory.systemTemp.createTemp('ovid-install-scope-');
    Directory('${dir.path}/home').createSync();
    sandbox.sandboxPrefixForTest = dir;
    final entered = Completer<void>();
    final release = Completer<void>();
    Process? child;
    addTearDown(() async {
      child?.kill(ProcessSignal.sigkill);
      await child?.exitCode;
      await dir.delete(recursive: true);
    });
    SandboxService.processStartForTest = (exe, args, cwd, env) async {
      entered.complete();
      await release.future;
      return child = await Process.start('/bin/bash', []);
    };
    // This is the same independent owner zone established by install().
    final pending = runZoned(
      () => sandbox.withProcessScope(
        () => sandbox.spawn(['/bin/bash']),
        runKey: 'sandbox-install-regression',
      ),
      zoneValues: {#ovidInstallOwner: true},
    );
    final failed = expectLater(pending, throwsA(isA<SandboxCancelledException>()));
    await entered.future;
    sandbox.killRunProcesses('sandbox-install-regression');
    release.complete();
    await failed;
    expect(alive(child!.pid), isFalse);
  });

  test('independent runtime command timeout retains invocation ownership', () async {
    final sandbox = SandboxService.I;
    final dir = await Directory.systemTemp.createTemp('ovid-runtime-scope-');
    Directory('${dir.path}/home').createSync();
    sandbox.sandboxPrefixForTest = dir;
    final entered = Completer<void>();
    final release = Completer<void>();
    Process? child;
    addTearDown(() async {
      child?.kill(ProcessSignal.sigkill);
      await child?.exitCode;
      await dir.delete(recursive: true);
    });
    SandboxService.processStartForTest = (exe, args, cwd, env) async {
      entered.complete();
      await release.future;
      return child = await Process.start('/bin/bash', []);
    };
    final pending = runZoned(
      () => sandbox.checkedCommandForTest(['/bin/bash'], timeout: const Duration(milliseconds: 30)),
      zoneValues: {#ovidRuntimeOwner: true},
    );
    final failed = expectLater(pending, throwsA(isA<TimeoutException>()));
    await entered.future;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    release.complete();
    // A regression must fail promptly instead of leaving the test hung.
    await failed.timeout(const Duration(seconds: 3));
    expect(alive(child!.pid), isFalse);
  });

  test(
    'sandbox late OS spawn is killed after session stop, new generation works',
    () async {
      final sandbox = SandboxService.I;
      final dir = await Directory.systemTemp.createTemp('ovid-stop-');
      Directory('${dir.path}/home').createSync();
      sandbox.sandboxPrefixForTest = dir;
      final gate = Completer<void>();
      final entered = Completer<void>();
      Process? late;
      SandboxService.processStartForTest = (exe, args, cwd, env) async {
        entered.complete();
        await gate.future;
        return late = await Process.start('/bin/bash', []);
      };
      final pending = sandbox.withProcessScope(
        () => sandbox.spawn(['/bin/bash']),
        runKey: 'late',
      );
      final failure = expectLater(
        pending,
        throwsA(isA<SandboxCancelledException>()),
      );
      await entered.future;
      sandbox.killRunProcesses('late');
      gate.complete();
      await failure;
      expect(alive(late!.pid), isFalse);
      SandboxService.processStartForTest = (exe, args, cwd, env) =>
          Process.start('/bin/bash', []);
      final fresh = await sandbox.withProcessScope(
        () => sandbox.spawn(['/bin/bash']),
        runKey: 'late',
      );
      expect(alive(fresh.pid), isTrue);
      sandbox.killRunProcesses('late');
      await fresh.exitCode;
      await dir.delete(recursive: true);
    },
  );

  test(
    'workflow scope prevents a next spawn after awaited step completes late',
    () async {
      final sandbox = SandboxService.I;
      final gate = Completer<void>();
      final result = sandbox.withProcessScope(() async {
        await gate.future;
        return sandbox.spawn(['/bin/bash']);
      }, runKey: 'workflow');
      final failure = expectLater(
        result,
        throwsA(isA<SandboxCancelledException>()),
      );
      sandbox.killRunProcesses('workflow');
      gate.complete();
      await failure;
    },
  );

  test('global stop fences late agent spawn but preserves separate studio shell', () async {
    final sandbox = SandboxService.I;
    final dir = await Directory.systemTemp.createTemp('ovid-global-stop-');
    Directory('${dir.path}/home').createSync();
    sandbox.sandboxPrefixForTest = dir;
    final studio = await PtyPool.I.getOrCreate('tab', () => Process.start('/bin/bash', []),
      owner: PtyPool.studioOwner);
    final gate = Completer<void>();
    final pending = sandbox.withProcessScope(() async {
      await gate.future;
      return sandbox.spawn(['/bin/bash']);
    }, runKey: 'agent-session');
    final failure = expectLater(pending, throwsA(isA<SandboxCancelledException>()));
    sandbox.killAllProcesses();
    await PtyPool.I.discardAll();
    gate.complete();
    await failure;
    expect(await studio!.run('echo studio-kept'), contains('studio-kept'));
    await dir.delete(recursive: true);
  });

  test(
    'abandoned spawn after timeout is still reaped after session stop',
    () async {
      final sandbox = SandboxService.I;
      final dir = await Directory.systemTemp.createTemp('ovid-timeout-');
      Directory('${dir.path}/home').createSync();
      sandbox.sandboxPrefixForTest = dir;
      final gate = Completer<void>();
      final entered = Completer<void>();
      Process? abandoned;
      SandboxService.processStartForTest = (exe, args, cwd, env) async {
        entered.complete();
        await gate.future;
        return abandoned = await Process.start('/bin/bash', []);
      };
      final operation = sandbox.withProcessScope(
        () => sandbox.spawn(['/bin/bash']),
        runKey: 'timeout',
      );
      final discarded = operation.then((_) {}, onError: (Object _) {});
      await entered.future;
      await expectLater(
        operation.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      sandbox.killRunProcesses('timeout');
      gate.complete();
      await discarded;
      await until(() => abandoned != null && !alive(abandoned!.pid));
      await dir.delete(recursive: true);
    },
  );

  test('checked command timeout reaps its own child before a retry', () async {
    final sandbox = SandboxService.I;
    final dir = await Directory.systemTemp.createTemp('ovid-command-timeout-');
    Directory('${dir.path}/home').createSync();
    sandbox.sandboxPrefixForTest = dir;
    final started = Completer<int>();
    SandboxService.processStartForTest = (exe, args, cwd, env) async {
      final p = await Process.start('/bin/bash', args);
      started.complete(p.pid);
      return p;
    };
    final outcome = sandbox.checkedCommandForTest(['/bin/bash', '-c', 'sleep 1000'],
      timeout: const Duration(milliseconds: 30));
    final pid = await started.future;
    await expectLater(outcome, throwsA(isA<TimeoutException>()));
    expect(alive(pid), isFalse);
    await dir.delete(recursive: true);
  });

  test(
    'PTY stop rejects a delayed spawn and preserves another session',
    () async {
      final gate = Completer<void>();
      Process? late;
      final pending = PtyPool.I.getOrCreate('a', () async {
        await gate.future;
        return late = await Process.start('/bin/bash', []);
      });
      final other = await PtyPool.I.getOrCreate(
        'b',
        () => Process.start('/bin/bash', []),
      );
      await PtyPool.I.discardFor('a');
      gate.complete();
      final result = await pending;
      expect(result, isNull);
      await until(() => !alive(late!.pid));
      expect(await other!.run('echo survived'), contains('survived'));
    },
  );

  test('concurrent PTY requests share one shell', () async {
    final gate = Completer<void>();
    var starts = 0;
    Future<Process> start() async {
      starts++;
      await gate.future;
      return Process.start('/bin/bash', []);
    }

    final a = PtyPool.I.getOrCreate('same', start);
    final b = PtyPool.I.getOrCreate('same', start);
    gate.complete();
    final shells = await Future.wait([a, b]);
    addTearDown(() async {
      for (final s in shells) {
        await s?.close();
      }
    });
    expect(starts, 1);
    expect(identical(shells[0], shells[1]), isTrue);
  });

  test(
    'session stop kills real parent grandchild tree; unrelated process survives',
    () async {
      // Each generation waits on stdin; no timing-dependent shell sleeps.
      final p = await Process.start('/usr/bin/python3', [
        '-u',
        '-c',
        '''
import os, subprocess, sys
c = subprocess.Popen([sys.executable, '-u', '-c', "import subprocess,sys,signal; c=subprocess.Popen([sys.executable,'-c','import signal; signal.pause()']); print(c.pid,flush=True); signal.pause()"], stdout=subprocess.PIPE, text=True)
print(str(c.pid) + ' ' + c.stdout.readline().strip(), flush=True)
sys.stdin.read()
''',
      ]);
      final ids =
          (await p.stdout
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())
                  .first)
              .split(' ')
              .map(int.parse)
              .toList();
      final unrelated = await Process.start('/bin/bash', []);
      addTearDown(() async {
        p.kill(ProcessSignal.sigkill);
        for (final id in ids) {
          if (alive(id)) Process.killPid(id, ProcessSignal.sigkill);
        }
        unrelated.kill(ProcessSignal.sigkill);
        await unrelated.exitCode;
      });
      SandboxService.I.trackCallProcessForTest('tree', p);
      SandboxService.I.killCallProcesses('tree');
      await p.exitCode.timeout(const Duration(seconds: 3));
      await until(() => ids.every((id) => !alive(id)));
      expect(alive(unrelated.pid), isTrue);
    },
  );

  test('PTY close completes running command and kills its child', () async {
    final shell = (await PtyShell.start(() => Process.start('/bin/bash', [])))!;
    final ready = Completer<int>();
    final sub = shell.output.listen((l) {
      if (l.startsWith('child=')) ready.complete(int.parse(l.substring(6)));
    });
    final command = shell.run('sleep 1000 & echo child=\$!; wait');
    final child = await ready.future.timeout(const Duration(seconds: 3));
    addTearDown(() async {
      if (alive(child)) Process.killPid(child, ProcessSignal.sigkill);
      await sub.cancel();
      await shell.close();
    });
    await shell.close().timeout(const Duration(seconds: 3));
    expect(
      await command.timeout(const Duration(seconds: 3)),
      contains('closed'),
    );
    await until(() => !alive(child));
  });
}
