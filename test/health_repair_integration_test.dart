import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';

// No install runs here: only execChecked's actual invocation boundary is faked.
// The production worker, target selection, scopes and cancellation stay real.
class _Process extends Fake implements Process {
  final killed = Completer<void>();
  @override
  int get pid => 99999999;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!killed.isCompleted) killed.complete();
    return true;
  }
}

void main() {
  final sandbox = SandboxService.I;
  late Set<String> missing;
  late List<List<String>> installs;
  late List<List<String>> probes;
  Future<(int, String)> Function(List<String>)? install;

  HealthService service({
    Future<bool> Function()? installed,
    Future<void> Function()? workspace,
  }) {
    final worker = HealthService.I.repairWorker;
    expect(
      worker,
      isNotNull,
      reason: 'UI singleton must own a production worker',
    );
    return HealthService(
      installed: installed ?? () async => true,
      workspace: workspace ?? () async {},
      providerConfigured: () => false,
      repairWorker: worker,
    );
  }

  setUp(() {
    missing = {'python'};
    installs = [];
    probes = [];
    install = null;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      if (args.first == 'ovid-pkg') {
        installs.add(List.of(args));
        return await install?.call(args) ?? (1, 'no install fixture');
      }
      probes.add(List.of(args));
      final id = args.contains('pip') ? 'pip' : args.first;
      return missing.contains(id) ? (127, 'not found') : (0, 'version');
    };
  });

  tearDown(() {
    SandboxService.execCheckedOverrideForTest = null;
  });

  test(
    'UI singleton repairs only the requested signed package and re-probes',
    () async {
      missing = {'python', 'git'};
      install = (_) async {
        missing.remove('python');
        return (0, 'extracted');
      };
      final health = service();
      final report = await health.repair((_) {}, targets: {'python'});
      expect(installs, [
        ['ovid-pkg', 'install', 'python'],
      ]);
      expect(report.checks.singleWhere((c) => c.id == 'python').ok, isTrue);
      expect(report.checks.singleWhere((c) => c.id == 'git').ok, isFalse);
      expect(
        probes.where((a) => a.join(' ') == 'python --version'),
        hasLength(2),
      );
      expect(health.repairing, isFalse);
    },
  );

  test(
    'package aliases are mapped and deduplicated without broad runtimes',
    () async {
      missing = {'node', 'npm', 'npx', 'pip', 'rg', 'ssh'};
      install = (_) async {
        missing.clear();
        return (0, 'extracted');
      };
      await service().repair((_) {});
      expect(installs, [
        [
          'ovid-pkg',
          'install',
          'nodejs',
          'npm',
          'openssh',
          'python-pip',
          'ripgrep',
        ],
      ]);
    },
  );

  test(
    'base runtime and nonruntime failures cannot start targeted installs',
    () async {
      missing = {'bash', 'apt'};
      final health = service();
      final report = await health.runChecks();
      expect(report.anyRepairable, isFalse);
      for (final target in [
        'bash',
        'apt',
        'sandbox',
        'provider',
        'workspace',
        'unknown',
      ]) {
        await expectLater(
          health.repair((_) {}, targets: {target}),
          throwsStateError,
        );
      }
      expect(installs, isEmpty);
    },
  );

  test(
    'nonzero signed installer exit wins over success-looking output',
    () async {
      install = (_) async {
        missing.clear();
        return (23, 'INSTALLED successfully');
      };
      final health = service();
      await expectLater(health.repair((_) {}), throwsStateError);
      expect(installs, hasLength(1));
      expect(health.repairing, isFalse);
    },
  );

  test(
    'signature rejection stays failed and is not retried through another installer',
    () async {
      install = (_) async => (1, 'signed index verification failed');
      final health = service();
      await expectLater(health.repair((_) {}), throwsStateError);
      expect(installs, [
        ['ovid-pkg', 'install', 'python'],
      ]);
      expect(
        health.lastReport!.checks.singleWhere((c) => c.id == 'python').ok,
        isFalse,
      );
    },
  );

  test(
    'zero installer exit cannot replace failing executable probes',
    () async {
      install = (_) async => (0, 'INSTALLED successfully');
      final health = service();
      await expectLater(health.repair((_) {}), throwsStateError);
      expect(
        probes.where((a) => a.join(' ') == 'python --version'),
        hasLength(2),
      );
      expect(
        health.lastReport!.checks.singleWhere((c) => c.id == 'python').ok,
        isFalse,
      );
    },
  );

  test(
    'missing sandbox, denied and unsupported executables are not repaired',
    () async {
      final absent = service(installed: () async => false);
      expect((await absent.runChecks()).anyRepairable, isFalse);
      await expectLater(
        absent.repair((_) {}, targets: {'python'}),
        throwsStateError,
      );
      for (final output in ['Permission denied', 'Exec format error']) {
        SandboxService.execCheckedOverrideForTest = (_, _) async =>
            (126, output);
        final health = service();
        expect((await health.runChecks()).anyRepairable, isFalse);
        await expectLater(
          health.repair((_) {}, targets: {'python'}),
          throwsStateError,
        );
      }
      expect(installs, isEmpty);
    },
  );

  test(
    'direct worker rejects mixed supported and unknown targets before invocation',
    () async {
      final worker = service().repairWorker!;
      await expectLater(
        worker(
          {'python', 'python; touch /tmp/unowned'},
          HealthRepairCancellation(),
          (_) {},
        ),
        throwsUnsupportedError,
      );
      expect(installs, isEmpty);
    },
  );

  test('cancellation wins over a late producer exception', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    install = (_) async {
      entered.complete();
      await release.future;
      throw StateError('transport closed after cancellation');
    };
    final health = service();
    final result = health.repair((_) {});
    final failure = expectLater(result, throwsA(isA<HealthRepairCancelled>()));
    await entered.future;
    health.cancelRepair();
    expect(health.repairing, isTrue);
    release.complete();
    await failure;
    expect(health.repairing, isFalse);
  });

  test('cancellation rejects a producer that returns late success', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    install = (_) async {
      entered.complete();
      await release.future;
      missing.clear();
      return (0, 'INSTALLED');
    };
    final health = service();
    final result = health.repair((_) {});
    final failure = expectLater(result, throwsA(isA<HealthRepairCancelled>()));
    await entered.future;
    health.cancelRepair();
    release.complete();
    await failure;
    expect(
      health.lastReport!.checks.singleWhere((c) => c.id == 'python').ok,
      isFalse,
    );
  });

  test('cancel during preflight never invokes the signed installer', () async {
    final gate = Completer<bool>();
    final health = service(installed: () => gate.future);
    final result = health.repair((_) {});
    final failure = expectLater(result, throwsA(isA<HealthRepairCancelled>()));
    health.cancelRepair();
    gate.complete(true);
    await failure;
    expect(installs, isEmpty);
  });

  test(
    'cancel from progress callback fences invocation before spawning',
    () async {
      final health = service();
      await expectLater(
        health.repair((_) => health.cancelRepair()),
        throwsA(isA<HealthRepairCancelled>()),
      );
      expect(installs, isEmpty);
    },
  );

  test(
    'cancel kills only owned processes and retains admission until producer settles',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final owned = _Process();
      final unrelated = _Process();
      sandbox.trackCallProcessForTest('other-installer', unrelated);
      addTearDown(() => sandbox.killCallProcesses('other-installer'));
      String? key;
      var fenced = false;
      install = (_) async {
        key = Zone.current[SandboxService.callZoneKey] as String?;
        expect(key, isNotNull);
        sandbox.trackCallProcessForTest(key!, owned);
        entered.complete();
        await release.future;
        try {
          sandbox.checkCancellation();
        } on SandboxCancelledException {
          fenced = true;
          rethrow;
        }
        return (0, 'late success');
      };
      final health = service();
      final lines = <String>[];
      final result = health.repair(lines.add);
      final failure = expectLater(
        result,
        throwsA(isA<HealthRepairCancelled>()),
      );
      await entered.future;
      health.cancelRepair();
      await owned.killed.future;
      final count = lines.length;
      expect(health.repairing, isTrue);
      expect(health.cancellationRequested, isTrue);
      expect(unrelated.killed.isCompleted, isFalse);
      await expectLater(health.repair((_) {}), throwsStateError);
      release.complete();
      await failure;
      expect(
        fenced,
        isTrue,
        reason: 'cancel must invalidate delayed work in the scope',
      );
      expect(lines, hasLength(count));
      expect(health.repairing, isFalse);
      expect(sandbox.callProcessesForTest.containsKey(key), isFalse);
      expect(unrelated.killed.isCompleted, isFalse);
      sandbox.killCallProcesses('other-installer');

      install = (_) async {
        expect(Zone.current[SandboxService.callZoneKey], isNot(key));
        sandbox.checkCancellation();
        missing.clear();
        return (0, 'extracted');
      };
      expect(
        (await health.repair(
          (_) {},
        )).checks.singleWhere((c) => c.id == 'python').ok,
        isTrue,
      );
    },
  );

  test(
    'post-repair verification does not reuse checks started during installation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final overlapReady = Completer<void>();
      final overlapRelease = Completer<void>();
      var workspaceCalls = 0;
      install = (_) async {
        entered.complete();
        await release.future;
        missing.clear();
        return (0, 'extracted');
      };
      final health = service(
        workspace: () async {
          if (++workspaceCalls == 2) {
            overlapReady.complete();
            await overlapRelease.future;
          }
        },
      );
      final result = health.repair((_) {});
      await entered.future;
      final overlap = health.runChecks();
      await overlapReady.future;
      release.complete();
      await Future<void>.delayed(Duration.zero);
      overlapRelease.complete();
      await overlap;
      final after = await result;
      expect(after.checks.singleWhere((c) => c.id == 'python').ok, isTrue);
      expect(workspaceCalls, 3);
    },
  );
}
