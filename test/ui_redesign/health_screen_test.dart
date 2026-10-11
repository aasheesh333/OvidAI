import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium Device health redesign contract (wave 2 UI). The legacy
/// `HealthScreen` was retired (F-154); its Services section and Hard reset
/// now live in [SettingsHealthScreen], so both groups pump that screen.
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

  group('SettingsHealthScreen (ported legacy sections)', () {
    testWidgets('renders overall summary, runtime section, and check cards', (
      tester,
    ) async {
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

    testWidgets('shows a service card with status dot and Retry ghost button', (
      tester,
    ) async {
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
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SERVICES'), findsOneWidget);
      expect(find.text('plugin:example'), findsOneWidget);
      // Ghost Retry button rendered for the failed service row.
      expect(find.widgetWithText(TextButton, 'Retry'), findsWidgets);
    });

    testWidgets('labels each check with a status word', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final health = buildService(anyFail: true, providerOk: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      // apt, python, `python -m pip`, node.
      expect(find.text('Missing'), findsNWidgets(4));
      expect(find.text('Available'), findsWidgets);
      expect(find.text('Missing configuration'), findsOneWidget);
    });

    testWidgets(
      'no sandbox collapses runtime checks into one Install sandbox CTA',
      (tester) async {
        tester.view.physicalSize = const Size(900, 3200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var installs = 0;
        var providers = 0;
        final health = buildService(installed: false, providerOk: false);
        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: SettingsHealthScreen(
              service: health,
              onInstallSandbox: () => installs++,
              onOpenProviders: () => providers++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Sandbox not installed'), findsOneWidget);
        expect(find.text('Install sandbox'), findsOneWidget);
        // The 16 dependent cards ("open Studio" each) are not rendered.
        expect(find.textContaining('Open Studio to install'), findsNothing);
        expect(find.text('Python'), findsNothing);
        await tester.tap(find.text('Install sandbox'));
        expect(installs, 1);

        // The failing provider check gets its own action.
        expect(find.text('AI provider configuration'), findsOneWidget);
        await tester.tap(find.text('Open Providers'));
        expect(providers, 1);
      },
    );

    testWidgets('services section and hard reset are present', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AppState.I.updateServiceStatus(
        'mcp:example',
        ServiceHealth.working,
        detail: 'connected',
      );
      final health = buildService(anyFail: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SERVICES'), findsOneWidget);
      expect(find.text('mcp:example'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Hard reset the sandbox'), findsOneWidget);
      await tester.tap(find.text('Hard reset the sandbox'));
      await tester.pumpAndSettle();
      expect(find.text('Reset the sandbox?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Resetting sandbox…'), findsNothing);
    });

    test('legacy health_screen.dart is deleted', () {
      expect(File('lib/ui/health_screen.dart').existsSync(), isFalse);
    });

    testWidgets('diagnostics card exposes re-run and hard reset actions', (
      tester,
    ) async {
      final health = buildService(anyFail: false);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Hard reset the sandbox'), 300);
      expect(find.text('Re-run checks'), findsOneWidget);
      expect(find.text('Hard reset the sandbox'), findsOneWidget);
    });
  });

  group('SettingsHealthScreen', () {
    testWidgets('renders runtime health section with Aether primitives', (
      tester,
    ) async {
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

    testWidgets('surfaces the no-worker explainer when repair is unbound', (
      tester,
    ) async {
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

    testWidgets('wires selected targets through HealthService.repair', (
      tester,
    ) async {
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

    testWidgets(
      're-run checks ghost action re-invokes HealthService.runChecks',
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
      },
    );
  });
}
