import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';

void main() {
  HealthService service({
    HealthRepairWorker? repairWorker,
    bool Function()? pythonOk,
  }) => HealthService(
    installed: () async => true,
    exec: (args) async => args.first == 'python' && !(pythonOk?.call() ?? false)
        ? (127, 'missing')
        : (0, 'version'),
    workspace: () async {},
    providerConfigured: () => false,
    repairWorker: repairWorker ?? (_, _, _) async {},
  );

  Future<void> pumpScreen(WidgetTester tester, HealthService health) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SettingsHealthScreen(service: health)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('summarizes checks by truthful status category and progress', (
    tester,
  ) async {
    final health = service();
    await pumpScreen(tester, health);

    expect(find.textContaining('Available'), findsOneWidget);
    expect(find.textContaining('Needs attention'), findsOneWidget);
    expect(find.textContaining('Unavailable'), findsOneWidget);
    expect(find.textContaining('18 of 18 checks completed'), findsOneWidget);
    expect(find.textContaining('2 repairable'), findsOneWidget);
  });

  testWidgets('labels selected repair progress separately from repairability', (
    tester,
  ) async {
    final health = service();
    await pumpScreen(tester, health);

    expect(find.text('0 selected · 2 repairable'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(find.text('1 selected · 2 repairable'), findsOneWidget);
  });

  testWidgets('keeps successful repair distinct from failed repair', (
    tester,
  ) async {
    var repairRun = false;
    final success = service(
      pythonOk: () => repairRun,
      repairWorker: (_, _, _) async {
        repairRun = true;
      },
    );
    await success.repair((_) {}, targets: {'python'});
    expect(
      success.lastReport!.checks.singleWhere((c) => c.id == 'python').ok,
      isTrue,
    );

    final failure = service(
      repairWorker: (_, _, _) async =>
          throw StateError('signed verification failed'),
    );
    await expectLater(
      failure.repair((_) {}, targets: {'python'}),
      throwsA(isA<StateError>()),
    );
    expect(
      failure.lastReport!.checks.singleWhere((c) => c.id == 'python').ok,
      isFalse,
    );
  });
}
