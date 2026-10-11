import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';

/// Device health premium contract. Formerly pinned the legacy `HealthScreen`;
/// that screen was retired (F-154) and its sections ported into
/// [SettingsHealthScreen], which these tests now exercise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HealthService service({
    required HealthRepairWorker? worker,
    bool Function()? pythonOk,
  }) {
    return HealthService(
      installed: () async => true,
      exec: (args) async =>
          args.first == 'python' && !(pythonOk?.call() ?? false)
          ? (127, 'not found')
          : (0, 'ok'),
      workspace: () async {},
      providerConfigured: () => true,
      repairWorker: worker,
    );
  }

  Future<void> pumpScreen(WidgetTester tester, HealthService health) async {
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: SettingsHealthScreen(service: health),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> startRepair(WidgetTester tester) async {
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.text('Repair selected runtimes'));
  }

  testWidgets('shows truthful status labels and a clear summary hierarchy', (
    tester,
  ) async {
    final health = service(worker: null);
    await pumpScreen(tester, health);

    // python and `python -m pip` both probe the missing interpreter.
    expect(find.text('Needs attention: 2'), findsOneWidget);
    expect(find.text('Missing'), findsNWidgets(2));
    expect(find.text('Available'), findsWidgets);
    expect(find.text('RUNTIME HEALTH'), findsOneWidget);
    health.dispose();
  });

  testWidgets('requires confirmation before a destructive sandbox reset', (
    tester,
  ) async {
    final health = service(worker: null, pythonOk: () => true);
    await pumpScreen(tester, health);

    await tester.tap(find.text('Hard reset the sandbox'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Reset the sandbox?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Resetting sandbox…'), findsNothing);
    health.dispose();
  });

  testWidgets('streams repair lines with progress and elapsed time', (
    tester,
  ) async {
    final release = Completer<void>();
    var repaired = false;
    final health = service(
      pythonOk: () => repaired,
      worker: (_, _, onLine) async {
        onLine('Repairing signed packages: python');
        onLine('Unpacking python (3.12)…');
        await release.future;
        repaired = true;
      },
    );
    await pumpScreen(tester, health);
    await startRepair(tester);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.text('Repair in progress'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('elapsed 0:0'), findsOneWidget);
    expect(find.text('Unpacking python (3.12)…'), findsOneWidget);

    release.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('Repair complete: selected runtime checks now pass.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    health.dispose();
  });

  testWidgets('reports repair cancellation explicitly', (tester) async {
    final workerStarted = Completer<void>();
    final health = service(
      worker: (_, cancellation, _) async {
        workerStarted.complete();
        await cancellation.whenCancelled;
        cancellation.throwIfCancelled();
      },
    );
    await pumpScreen(tester, health);
    await startRepair(tester);
    await tester.pump();
    await workerStarted.future;
    await tester.pump();
    await tester.tap(find.text('Cancel repair'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Repair cancelled'), findsOneWidget);
    health.dispose();
  });

  testWidgets('reports repair failure explicitly', (tester) async {
    final health = service(
      worker: (_, _, _) async =>
          throw StateError('signature verification failed'),
    );
    await pumpScreen(tester, health);
    await startRepair(tester);
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Repair failed: Bad state: signature verification failed',
      ),
      findsOneWidget,
    );
    health.dispose();
  });
}
