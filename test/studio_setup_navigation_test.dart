import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Completer<void> installBarrier;
  late StudioSetupCoordinator coordinator;
  late SetupPhaseCallback progress;
  late int installs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    AppState.resetTestInstance();
    AppState.createForTest();
    installs = 0;
    coordinator = StudioSetupCoordinator(
      checkExisting: () async => false,
      install: (onPhase, full) async {
        expect(full, isTrue);
        installs++;
        progress = onPhase;
        onPhase(7, .4, 'Downloading runtime packages');
        await installBarrier.future;
      },
      verifyCore: () async => true,
      verifyRuntimes: () async => true,
    );
    StudioSetupCoordinator.overrideForTest = coordinator;
  });

  tearDown(() {
    StudioSetupCoordinator.overrideForTest = null;
    coordinator.dispose();
    AppState.resetTestInstance();
  });

  Future<void> launcher(WidgetTester tester) async {
    // Create the barrier in the widget test's fake-async zone, so pump drains
    // its completion callbacks rather than waiting on the outer test zone.
    installBarrier = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const TextField(
                  decoration: InputDecoration(labelText: 'Chat message'),
                ),
                TextButton(
                  onPressed: () => openStudio(context),
                  child: const Text('Studio'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Studio'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('declining setup never starts a job or records completion', (
    tester,
  ) async {
    await launcher(tester);
    expect(installs, 0);
    expect(find.text('Install sandbox'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Still chatting');
    expect(find.text('Still chatting'), findsOneWidget);
    expect(installs, 0);
    expect(AppState.I.studioFirstOpenDone, isFalse);
  });

  testWidgets(
    'Back permits chat; reopen attaches to the same job and live log',
    (tester) async {
      await launcher(tester);
      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      expect(installs, 1);
      expect(find.text('Downloading runtime packages'), findsOneWidget);
      final startedAt = coordinator.startedAt;

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SandboxSetupScreen), findsNothing);
      await tester.enterText(find.byType(TextField), 'Chat while setup runs');
      expect(find.text('Chat while setup runs'), findsOneWidget);
      progress(8, .6, 'Verifying Python');
      await tester.pump();
      await tester.tap(find.text('Studio'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Verifying Python'), findsOneWidget);
      expect(find.text('Downloading runtime packages'), findsOneWidget);
      expect(find.text('Install sandbox'), findsNothing);
      expect(coordinator.startedAt, startedAt);
      expect(installs, 1);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      installBarrier.complete();
      await tester.pump();
      expect(coordinator.status, StudioSetupStatus.ready);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SandboxSetupScreen), findsNothing);
      expect(find.text('Chat while setup runs'), findsOneWidget);
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(AppState.I.sandboxInstalled, isTrue);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.done);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'studio_first_open_done',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('foreground completion waits for explicit Open Studio', (
    tester,
  ) async {
    await launcher(tester);
    await tester.tap(find.text('Install sandbox'));
    await tester.pump();
    expect(installs, 1);
    installBarrier.complete();
    await tester.pump();
    expect(coordinator.status, StudioSetupStatus.ready);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(SandboxSetupScreen), findsOneWidget);
    expect(find.text('Sandbox ready'), findsOneWidget);
    expect(find.text('Open Studio'), findsOneWidget);
    expect(AppState.I.studioFirstOpenDone, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failure after disposal is retained on reopening, without auto retry',
    (tester) async {
      await launcher(tester);
      await tester.tap(find.text('Install sandbox'));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      installBarrier.completeError(StateError('Download interrupted'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Studio'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Download interrupted'), findsOneWidget);
      expect(find.text('Retry install'), findsOneWidget);
      expect(installs, 1);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completed Health core-only job still asks approval for full Studio setup',
    (tester) async {
      coordinator.dispose();
      coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        verifyCore: () async => true,
      );
      StudioSetupCoordinator.overrideForTest = coordinator;
      await coordinator.start(coreOnly: true);
      await launcher(tester);
      expect(find.text('Install sandbox'), findsOneWidget);
      expect(find.text('Sandbox ready'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('partial runtime setup is honest and retry stays runtime-only', (
    tester,
  ) async {
    coordinator.dispose();
    var runtimeReady = false;
    var repairs = 0;
    coordinator = StudioSetupCoordinator(
      checkExisting: () async => true,
      install: (_, _) async => fail('existing core must not be replaced'),
      installRuntimes: (_) async {
        repairs++;
        return runtimeReady;
      },
      verifyCore: () async => true,
      verifyRuntimes: () async => runtimeReady,
    );
    StudioSetupCoordinator.overrideForTest = coordinator;
    await launcher(tester);
    await tester.tap(find.text('Install sandbox'));
    await tester.pumpAndSettle();
    expect(find.text('Sandbox core ready'), findsOneWidget);
    expect(find.text('Sandbox ready'), findsNothing);
    expect(find.text('RUNTIMES INCOMPLETE'), findsOneWidget);
    expect(AppState.I.studioFirstOpenDone, isFalse);
    runtimeReady = true;
    await tester.tap(find.text('Retry runtime setup'));
    await tester.pumpAndSettle();
    expect(find.text('Sandbox ready'), findsOneWidget);
    expect(repairs, 1); // Second attempt verifies the now-ready toolchain.
    expect(AppState.I.studioFirstOpenDone, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'previously completed wiped-core reinstall stays gated after relaunch when runtimes fail',
    (tester) async {
      await AppState.I.setStudioFirstOpenDone(true);
      coordinator.dispose();
      coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async {},
        verifyCore: () async => true,
        verifyRuntimes: () async => false,
      );
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.partial);

      // Fresh app/job state, same persisted preferences: the historical success
      // must not route past setup merely because the core now exists.
      coordinator.dispose();
      coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        install: (_, _) async => fail('relaunch must wait for approval'),
      );
      StudioSetupCoordinator.overrideForTest = coordinator;
      AppState.resetTestInstance();
      AppState.createForTest();
      await AppState.I.loadStudioFirstOpenFlag();
      await launcher(tester);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(find.byType(SandboxSetupScreen), findsOneWidget);
      expect(find.text('Install sandbox'), findsOneWidget);
      expect(coordinator.status, StudioSetupStatus.idle);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
