import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/health_screen.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium `health_screen` + `settings_health_screen` redesign contract
/// (wave 2 UI).
///
/// Pins the public widgets the redesign owes callers:
///   * [AetherSectionTitle] eyebrow 'RUNTIME HEALTH' on each surface.
///   * [AetherCard]s stacked per runtime check and per service.
///   * [AetherStatusDot]s to show working/warn/danger.
///   * Overall score summary at the top.
///   * Repair/Retry wiring preserved through the [HealthService] seams.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  HealthService buildService({
    bool installed = true,
    bool anyFail = true,
    bool providerOk = true,
    HealthRepairWorker? worker,
  }) {
    return HealthService(
      installed: () async => installed,
      exec: (args) async {
        if (!anyFail) return (0, 'ok');
        if (args.first == 'apt' ||
            args.first == 'python' ||
            args.first == 'node') {
          return (127, 'not found');
        }
        return (0, 'ok');
      },
      workspace: () async {},
      providerConfigured: () => providerOk,
      repairWorker: worker,
    );
  }

  group('HealthScreen', () {
    testWidgets('renders overall summary, runtime section, and check cards', (
      tester,
    ) async {
      final health = buildService(anyFail: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: HealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('RUNTIME HEALTH'), findsOneWidget);
      expect(find.text('Overall health'), findsOneWidget);
      expect(find.byType(AetherCard), findsWidgets);
      expect(find.byType(AetherStatusDot), findsWidgets);
    });

    testWidgets('shows a service card with status dot and Retry ghost button',
        (tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final health = buildService(anyFail: false);

      AppState.I.updateServiceStatus(
        'plugin:example',
        ServiceHealth.failed,
        detail: 'not reachable',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: HealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SERVICES'), findsOneWidget);
      expect(find.text('plugin:example'), findsOneWidget);
      // Ghost Retry button rendered for the failed service row.
      expect(find.widgetWithText(TextButton, 'Retry'), findsWidgets);
    });

    testWidgets('offers a Repair primary button when checks are repairable',
        (tester) async {
      final health = buildService(
        anyFail: true,
        worker: (targets, cancellation, onLine) async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: HealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Repair available'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Repair'), findsOneWidget);
    });

    testWidgets('diagnostics card exposes re-run and hard reset actions',
        (tester) async {
      final health = buildService(anyFail: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: HealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Hard reset the sandbox'),
        300,
      );
      expect(find.text('Re-run checks'), findsOneWidget);
      expect(find.text('Hard reset the sandbox'), findsOneWidget);
    });
  });

  group('SettingsHealthScreen', () {
    testWidgets('renders runtime health section with Aether primitives',
        (tester) async {
      final health = buildService(anyFail: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('RUNTIME HEALTH'), findsOneWidget);
      expect(find.text('Overall health'), findsOneWidget);
      expect(find.byType(AetherCard), findsWidgets);
      expect(find.byType(AetherStatusDot), findsWidgets);
    });

    testWidgets('surfaces the no-worker explainer when repair is unbound',
        (tester) async {
      final health = buildService(worker: null);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Targeted repair unavailable'),
        findsOneWidget,
      );
      expect(find.text('Repair selected runtimes'), findsNothing);
    });

    testWidgets('wires selected targets through HealthService.repair',
        (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Set<String>? seenTargets;
      final completer = Completer<void>();
      final health = buildService(
        worker: (targets, cancellation, onLine) async {
          seenTargets = targets;
          onLine('installing…');
          completer.complete();
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Repair selected runtimes'));
      await tester.pumpAndSettle();

      await completer.future;
      expect(seenTargets, isNotNull);
      expect(seenTargets, isNotEmpty);
    });

    testWidgets('re-run checks ghost action re-invokes HealthService.runChecks',
        (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var checks = 0;
      final health = HealthService(
        installed: () async {
          checks++;
          return true;
        },
        exec: (_) async => (0, 'ok'),
        workspace: () async {},
        providerConfigured: () => true,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();
      final before = checks;

      await tester.tap(find.text('Re-run checks'));
      await tester.pumpAndSettle();

      expect(checks, greaterThan(before));
    });
  });
}
