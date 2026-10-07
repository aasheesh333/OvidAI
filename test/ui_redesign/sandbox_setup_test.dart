import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium `sandbox_setup` redesign contract (wave 2 UI).
///
/// Smoke-render pins for the Aether-primitive reskin while proving the
/// preserved flows still wire to [StudioSetupCoordinator] verbatim:
///   * Approval view in an [AetherCard]; 'Install sandbox' starts the job.
///   * Progress view: one [AetherCard] per setup step with an
///     [AetherStatusDot] + step name + 'Repair' [AetherGhostButton]
///     (disabled while running), plus the overall [LinearProgressIndicator].
///   * Error view: failed-step Repair re-runs the preserved install flow.
///   * Done view: [AetherPill] tags + 'Open Studio' CTA.
///   * Gate mode: auto-starts the 7-step core-only install, no approval.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudioSetupCoordinator coordinator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() {
    StudioSetupCoordinator.overrideForTest = null;
    coordinator.dispose();
    AppState.resetTestInstance();
  });

  StudioSetupCoordinator useCoordinator({
    required Future<void> Function(SetupPhaseCallback, bool) install,
    Future<bool> Function()? checkExisting,
    Future<bool> Function(SetupPhaseCallback)? installRuntimes,
    Future<bool> Function()? verifyCore,
    Future<bool> Function()? verifyRuntimes,
  }) {
    coordinator = StudioSetupCoordinator(
      checkExisting: checkExisting ?? () async => false,
      install: install,
      installRuntimes: installRuntimes ?? (_) async => true,
      verifyCore: verifyCore ?? () async => true,
      verifyRuntimes: verifyRuntimes ?? () async => true,
    );
    StudioSetupCoordinator.overrideForTest = coordinator;
    return coordinator;
  }

  Widget host({bool gateMode = false}) {
    return MaterialApp(
      theme: Aether.theme(),
      home: SandboxSetupScreen(gateMode: gateMode),
    );
  }

  /// Tall viewport so every lazily-built step card in the scroll views is
  /// laid out and findable (same pattern as the health redesign tests).
  void tallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'approval view renders an AetherCard and Install sandbox starts the job',
    (tester) async {
      tallViewport(tester);
      final barrier = Completer<void>();
      var installs = 0;
      useCoordinator(
        install: (_, _) async {
          installs++;
          await barrier.future;
        },
      );

      await tester.pumpWidget(host());
      await tester.pump();

      expect(find.text('Set up Studio'), findsOneWidget);
      expect(find.byType(AetherCard), findsOneWidget);
      expect(
        find.widgetWithText(AetherPrimaryButton, 'Install sandbox'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherGhostButton, 'Not now'),
        findsOneWidget,
      );

      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      // Approval flow preserved: the coordinator job is now running.
      expect(coordinator.status, StudioSetupStatus.running);
      expect(installs, 1);

      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Sandbox ready'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'progress view renders one AetherCard per step with status dot, Repair '
    'ghost button and overall linear progress',
    (tester) async {
      tallViewport(tester);
      final barrier = Completer<void>();
      useCoordinator(
        install: (onPhase, full) async {
          onPhase(0, 0, 'Checking device…');
          onPhase(1, 1, 'Bootstrap located ✓');
          onPhase(2, .2, 'Extracting payload (real log line)');
          await barrier.future;
        },
      );

      await tester.pumpWidget(host());
      await tester.pump();
      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      await tester.pump();

      // Every step name renders on its own card (the active name also shows
      // in the overall progress card header).
      const steps = [
        'Checking device',
        'Locating bundled bootstrap',
        'Extracting sandbox payload',
        'Setting exec bits',
        'Linking tool aliases',
        'Configuring prefix',
        'Verifying native exec',
        'Installing Node.js runtime',
        'Installing Python runtime',
      ];
      for (final step in steps) {
        expect(find.text(step), findsWidgets, reason: step);
      }

      // 1 overall progress card + 9 step cards, 9 status dots.
      expect(find.byType(AetherCard), findsNWidgets(10));
      expect(find.byType(AetherStatusDot), findsNWidgets(9));

      // Overall linear progress tracks the real phase/phaseProgress.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(2.2 / 9, 1e-9),
      );
      expect(find.text('24.4%'), findsOneWidget);
      expect(find.text('Step 3 of 9'), findsOneWidget);

      // One Repair ghost per step, disabled while the job runs.
      final repairs = tester
          .widgetList<AetherGhostButton>(
            find.widgetWithText(AetherGhostButton, 'Repair'),
          )
          .toList();
      expect(repairs.length, 9);
      expect(repairs.every((b) => b.onPressed == null), isTrue);

      // The live log terminal is preserved beneath the step cards.
      expect(find.text('SANDBOX SETUP LOG — LIVE'), findsOneWidget);
      expect(find.text('Extracting payload (real log line)'), findsOneWidget);

      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Sandbox ready'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'error view renders enabled per-step Repair ghosts that re-run the '
    'preserved install flow',
    (tester) async {
      tallViewport(tester);
      var installs = 0;
      var fail = true;
      useCoordinator(
        install: (_, _) async {
          installs++;
          if (fail) throw StateError('simulated kernel check failure');
        },
      );

      await tester.pumpWidget(host());
      await tester.pump();
      await tester.tap(find.text('Install sandbox'));
      await tester.pumpAndSettle();

      expect(find.text('Install interrupted'), findsOneWidget);
      expect(
        find.textContaining('simulated kernel check failure'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherPrimaryButton, 'Retry install'),
        findsOneWidget,
      );

      // Failed at phase 0: all nine step cards offer an enabled Repair.
      final repairs = find.widgetWithText(AetherGhostButton, 'Repair');
      expect(repairs, findsNWidgets(9));
      expect(
        tester
            .widgetList<AetherGhostButton>(repairs)
            .every((b) => b.onPressed != null),
        isTrue,
      );

      fail = false;
      await tester.tap(repairs.first);
      await tester.pump();
      // Repair re-invokes the same install entry point (kernel checks and
      // verification re-run inside the coordinator, unchanged).
      expect(installs, 2);
      await tester.pumpAndSettle();
      expect(find.text('Sandbox ready'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'done view renders AetherPill tags and the Open Studio CTA',
    (tester) async {
      tallViewport(tester);
      useCoordinator(install: (_, _) async {});

      await tester.pumpWidget(host());
      await tester.pump();
      await tester.tap(find.text('Install sandbox'));
      await tester.pumpAndSettle();

      expect(find.text('Sandbox ready'), findsOneWidget);
      expect(find.byType(AetherCard), findsWidgets);
      expect(
        find.widgetWithText(AetherPill, 'NATIVE BIONIC'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherPill, 'RUNTIMES VERIFIED'),
        findsOneWidget,
      );
      expect(find.widgetWithText(AetherPill, 'NO ROOT'), findsOneWidget);
      expect(
        find.widgetWithText(AetherPrimaryButton, 'Open Studio'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(AetherGhostButton, 'Back to chat'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'gate mode auto-starts the 7-step core-only install without approval',
    (tester) async {
      tallViewport(tester);
      final barrier = Completer<void>();
      var installs = 0;
      bool? sawFull;
      useCoordinator(
        install: (_, full) async {
          installs++;
          sawFull = full;
          await barrier.future;
        },
      );

      await tester.pumpWidget(host(gateMode: true));
      await tester.pump();
      await tester.pump();

      expect(find.text('Setting up Ovid Si — one time'), findsOneWidget);
      expect(find.text('Install sandbox'), findsNothing);
      expect(coordinator.status, StudioSetupStatus.running);
      expect(installs, 1);
      // Core-only job: runtimes are excluded, kernel checks stay.
      expect(sawFull, isFalse);
      expect(
        find.widgetWithText(AetherGhostButton, 'Repair'),
        findsNWidgets(7),
      );
      expect(find.text('Verifying native exec'), findsWidgets);
      expect(find.text('Installing Node.js runtime'), findsNothing);

      // Dispose before completing so the gate hand-off timer never fires;
      // _runInstall's mounted guard swallows the late completion.
      await tester.pumpWidget(const SizedBox());
      barrier.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
