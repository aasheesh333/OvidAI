import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/shell.dart';
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
    SandboxService.execCheckedOverrideForTest = null;
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
      // The raw exception is never the headline (F-171): human copy first,
      // the original line only behind Details.
      expect(
        find.textContaining('Sandbox setup did not finish'),
        findsOneWidget,
      );
      expect(
        find.textContaining('simulated kernel check failure'),
        findsNothing,
      );
      await tester.ensureVisible(find.text('Details'));
      await tester.tap(find.text('Details'));
      await tester.pump();
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
    'runtime phase advancement never verifies failed Node and partial stops activity',
    (tester) async {
      tallViewport(tester);
      final barrier = Completer<void>();
      useCoordinator(
        install: (onPhase, _) async {
          onPhase(7, .7, 'node ................ ⚠ not installed (offline?)');
          onPhase(8, 1, 'python .............. ⚠ not installed');
          onPhase(8, 1, 'git ...............  ⚠ exec failed');
          await barrier.future;
        },
        verifyRuntimes: () async => false,
      );
      await tester.pumpWidget(host());
      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      Finder step(String name) => find.ancestor(
        of: find.text(name),
        matching: find.byType(AetherCard),
      ).first;
      expect(
        find.descendant(
          of: step('Installing Node.js runtime'),
          matching: find.text('Needs attention'),
        ),
        findsOneWidget,
      );
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Sandbox core ready'), findsOneWidget);
      for (final name in [
        'Installing Node.js runtime',
        'Installing Python runtime',
        'Git',
      ]) {
        expect(
          find.descendant(of: step(name), matching: find.text('Needs attention')),
          findsOneWidget,
        );
      }
      expect(find.text('In progress'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widgetList<AetherStatusDot>(find.byType(AetherStatusDot))
            .every((dot) => !dot.pulsing),
        isTrue,
      );
      expect(AppState.I.sandboxInstalled, isTrue);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.failed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Git failure at Python phase does not fail verified Python or native core',
    (tester) async {
      tallViewport(tester);
      SandboxService.execCheckedOverrideForTest = (args, env) async =>
          args.last == 'git --version' ? (127, 'not installed') : (0, 'version');
      coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (onPhase, _) async {
          onPhase(8, 1, 'git ...............  ⚠ exec failed');
        },
      );
      StudioSetupCoordinator.overrideForTest = coordinator;
      await tester.pumpWidget(host());
      await tester.tap(find.text('Install sandbox'));
      await tester.pumpAndSettle();
      for (final name in [
        'Installing Node.js runtime',
        'Installing Python runtime',
        'Verifying native exec',
      ]) {
        final card = find.ancestor(
          of: find.text(name),
          matching: find.byType(AetherCard),
        ).first;
        expect(
          find.descendant(of: card, matching: find.text('Verified')),
          findsOneWidget,
        );
      }
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('In progress'), findsNothing);
      expect(find.text('SANDBOX SETUP LOG — LIVE'), findsNothing);
      expect(find.text('SANDBOX SETUP LOG'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'phase completion without runtime evidence remains unverified',
    (tester) async {
      tallViewport(tester);
      final barrier = Completer<void>();
      useCoordinator(
        install: (onPhase, _) async {
          onPhase(8, 1, 'Runtime install returned');
          await barrier.future;
        },
        verifyRuntimes: () async => false,
      );
      await tester.pumpWidget(host());
      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      final nodeCard = find.ancestor(
        of: find.text('Installing Node.js runtime'),
        matching: find.byType(AetherCard),
      ).first;
      expect(
        find.descendant(of: nodeCard, matching: find.text('Not verified')),
        findsOneWidget,
      );
      barrier.complete();
      await tester.pumpAndSettle();
      expect(find.text('Not verified'), findsNWidgets(4));
      expect(find.text('Needs attention'), findsNothing);
      expect(find.text('In progress'), findsNothing);
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
        find.widgetWithText(AetherPill, 'TERMUX · PROOT'),
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
  testWidgets(
    'gate mode failure is not a dead end: Continue to chat hands off to '
    'OvidShell (F-176)',
    (tester) async {
      tallViewport(tester);
      useCoordinator(
        install: (_, _) async => throw StateError('corrupt bundled asset'),
      );
      await tester.pumpWidget(host(gateMode: true));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Install interrupted'), findsOneWidget);
      expect(find.text('Retry install'), findsOneWidget);
      expect(find.text('Copy log'), findsOneWidget);
      final cont = find.text('Continue to chat without sandbox');
      expect(cont, findsOneWidget);
      await tester.ensureVisible(cont);
      await tester.tap(cont);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(OvidShell), findsOneWidget);
      expect(AppState.I.sandboxSkipped, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('errno = 28 shows storage copy, never FileSystemException text', (
    tester,
  ) async {
    tallViewport(tester);
    useCoordinator(
      install: (_, _) async => throw const FileSystemException(
        'Cannot create file',
        '/data/user/0/x/usr/bin/node',
        OSError('No space left on device', 28),
      ),
    );
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.text('Install sandbox'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not enough storage'), findsOneWidget);
    expect(find.textContaining('FileSystemException'), findsNothing);
    expect(find.textContaining('errno'), findsNothing);
  });
}
