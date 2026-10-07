import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/health_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HealthService service({
    required Future<void> Function(Set<String>, HealthRepairCancellation, void Function(String))?
        worker,
    bool pythonOk = false,
  }) {
    return HealthService(
      installed: () async => true,
      exec: (args) async => args.first == 'python' && !pythonOk
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
      MaterialApp(theme: Aether.theme(), home: HealthScreen(service: health)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows truthful status labels and a clear summary hierarchy', (tester) async {
    final health = service(worker: null);
    await pumpScreen(tester, health);

    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Missing'), findsWidgets);
    expect(find.textContaining('failed'), findsOneWidget);
    expect(find.text('RUNTIME HEALTH'), findsOneWidget);
    health.dispose();
  });

  testWidgets('requires confirmation before a destructive sandbox reset', (tester) async {
    final health = service(worker: null, pythonOk: true);
    await pumpScreen(tester, health);
    await tester.scrollUntilVisible(find.text('Hard reset the sandbox'), 400);

    await tester.tap(find.text('Hard reset the sandbox'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Reset the sandbox?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Resetting sandbox…'), findsNothing);
    health.dispose();
  });

  testWidgets('reports repair success explicitly', (tester) async {
    var repaired = false;
    final health = HealthService(
      installed: () async => true,
      exec: (args) async => args.first == 'python' && !repaired
          ? (127, 'not found') : (0, 'ok'),
      workspace: () async {},
      providerConfigured: () => true,
      repairWorker: (_, _, _) async => repaired = true,
    );
    await pumpScreen(tester, health);
    await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
    await tester.pumpAndSettle();

    expect(repaired, isTrue);
    expect(find.text('Repair completed successfully.'), findsOneWidget);
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
    await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
    await workerStarted.future;
    await tester.pump();
    await tester.tap(find.text('Cancel repair'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Repair cancelled.'), findsOneWidget);
    health.dispose();
  });

  testWidgets('reports repair failure explicitly', (tester) async {
    final health = service(
      worker: (_, _, _) async => throw StateError('signature verification failed'),
    );
    await pumpScreen(tester, health);
    await tester.tap(find.widgetWithText(FilledButton, 'Repair'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Repair failed: Bad state: signature verification failed'), findsOneWidget);
    health.dispose();
  });
}
