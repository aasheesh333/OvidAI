import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';

void main() {
  test(
    'cancellation during preflight never starts the repair worker',
    () async {
      final probe = Completer<bool>();
      var repairs = 0;
      final health = HealthService(
        installed: () => probe.future,
        exec: (_) async => (127, 'missing'),
        workspace: () async {},
        providerConfigured: () => false,
        repairWorker: (_, _, _) async {
          repairs++;
        },
      );
      final future = health.repair((_) {}, targets: {'python'});
      final expected = expectLater(
        future,
        throwsA(isA<HealthRepairCancelled>()),
      );
      health.cancelRepair();
      probe.complete(true);
      await expected;
      expect(repairs, 0);
    },
  );
  HealthService service({
    bool installed = true,
    Future<(int, String)> Function(List<String>)? exec,
  }) => HealthService(
    installed: () async => installed,
    exec: exec ?? (_) async => (0, 'version'),
    workspace: () async {},
    providerConfigured: () => false,
  );

  test('bash success does not mark apt, npm or provider as healthy', () async {
    final health = service(
      exec: (args) async => ['apt', 'npm'].contains(args.first)
          ? (127, 'not found')
          : (0, 'version'),
    );
    final report = await health.runChecks();
    expect(report.checks.singleWhere((c) => c.id == 'bash').ok, isTrue);
    expect(report.checks.singleWhere((c) => c.id == 'apt').ok, isFalse);
    expect(report.checks.singleWhere((c) => c.id == 'npm').ok, isFalse);
    expect(
      report.checks.singleWhere((c) => c.id == 'provider').status,
      HealthStatus.missingConfiguration,
    );
  });

  test('failed install probe clears busy and can be retried', () async {
    var calls = 0;
    final health = HealthService(
      installed: () async {
        if (calls++ == 0) throw StateError('probe unavailable');
        return false;
      },
      exec: (_) async => (0, ''),
      workspace: () async {},
      providerConfigured: () => false,
    );
    await health.runChecks();
    expect(health.checking, isFalse);
    await health.runChecks();
    expect(calls, 2);
  });

  test('unsupported and denied runtime failures stay distinct', () async {
    final health = service(
      exec: (args) async => switch (args.first) {
        'python' => (126, 'Exec format error'),
        'git' => (126, 'Permission denied'),
        _ => (0, 'version'),
      },
    );
    final report = await health.runChecks();
    expect(
      report.checks.singleWhere((c) => c.id == 'python').status,
      HealthStatus.unsupported,
    );
    expect(
      report.checks.singleWhere((c) => c.id == 'git').status,
      HealthStatus.denied,
    );
  });

  test('missing repair worker cannot report success', () async {
    final health = service();
    await expectLater(health.repair((_) {}), throwsUnsupportedError);
    expect(health.repairing, isFalse);
  });

  test(
    'targeted repair cancellation waits for worker and rejects late success',
    () async {
      final finished = Completer<void>();
      final started = Completer<void>();
      final health = service(exec: (_) async => (127, 'not found'));
      health.repairWorker = (targets, cancellation, log) async {
        expect(targets, {'python'});
        started.complete();
        await finished.future;
        cancellation.throwIfCancelled();
      };
      await health.runChecks();
      final repair = health.repair((_) {}, targets: {'python'});
      final expected = expectLater(
        repair,
        throwsA(isA<HealthRepairCancelled>()),
      );
      await started.future;
      health.cancelRepair();
      expect(health.repairing, isTrue);
      finished.complete();
      await expected;
      expect(health.repairing, isFalse);
    },
  );
}
