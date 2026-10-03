import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudioSetupCoordinator coordinator;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions
      ..clear()
      ..add(
        ChatSession(
          id: 'setup-retry',
          title: 'Setup retry',
          model: 'm',
          messages: [
            Message(role: 'assistant', content: 'Chat stays available'),
          ],
        ),
      );
    app.activeSessionId = 'setup-retry';
    SandboxService.I.resetCheckExistingForTest();
    coordinator = StudioSetupCoordinator();
    StudioSetupCoordinator.overrideForTest = coordinator;
  });

  tearDown(() {
    StudioSetupCoordinator.overrideForTest = null;
    coordinator.dispose();
    SandboxService.execCheckedOverrideForTest = null;
    SandboxService.I.resetCheckExistingForTest();
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'partial setup -> Back -> banner Retry -> reopen joins verified setup job',
    (tester) async {
      final repairBarrier = Completer<void>();
      var coreExists = false;
      var executable = false;
      var installs = 0;
      var repairs = 0;
      // The old generic path's command-v probe succeeds, but execution (including
      // npx/uvx) must still pass before Studio setup may record completion.
      SandboxService.execCheckedOverrideForTest = (args, env) async =>
          args.last.contains('node --version') && !executable
          ? (1, 'Runtime cannot execute')
          : (0, 'ok');
      coordinator.dispose();
      coordinator = StudioSetupCoordinator(
        checkExisting: () async => coreExists,
        install: (_, _) async {
          installs++;
          coreExists = true;
        },
        installRuntimes: (onPhase) async {
          repairs++;
          onPhase(7, .4, 'Repairing Studio runtime tools');
          await repairBarrier.future;
          executable = true;
          return true;
        },
      );
      StudioSetupCoordinator.overrideForTest = coordinator;
      await pumpChat(tester);
      await tester.tap(find.byTooltip('Studio — code & terminal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install sandbox'));
      await tester.pumpAndSettle();
      expect(find.text('Sandbox core ready'), findsOneWidget);
      expect(AppState.I.studioFirstOpenDone, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SandboxSetupScreen), findsNothing);
      expect(find.text('Background setup needs attention'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pump();
      expect(coordinator.status, StudioSetupStatus.running);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.running);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(repairs, 1);

      await tester.tap(find.byTooltip('Studio — code & terminal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Repairing Studio runtime tools'), findsOneWidget);
      expect(find.text('Install sandbox'), findsNothing);
      expect(installs, 1);
      expect(repairs, 1);
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      repairBarrier.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SandboxSetupScreen), findsNothing);
      expect(find.text('Chat stays available'), findsOneWidget);
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.done);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'studio_first_open_done',
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('generic runtime banner retry does not approve Studio setup', (
    tester,
  ) async {
    var probes = 0;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      probes++;
      return (0, 'present');
    };
    AppState.I.sandboxInstalled = true;
    AppState.I.runtimeInstallState = RuntimeInstallState.failed;
    await pumpChat(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(probes, greaterThan(0));
    expect(AppState.I.runtimeInstallState, RuntimeInstallState.done);
    expect(coordinator.status, StudioSetupStatus.idle);
    expect(AppState.I.studioFirstOpenDone, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
