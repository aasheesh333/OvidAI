// PR-3b: destructive actions outside the chat screen confirm (or keep
// running) instead of acting on one tap.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(AppState.resetTestInstance);

  group('device health', () {
    HealthService service({
      Future<void> Function(
        Set<String>,
        HealthRepairCancellation,
        void Function(String),
      )?
      worker,
      bool pythonOk = false,
    }) => HealthService(
      installed: () async => true,
      exec: (args) async =>
          args.first == 'python' && !pythonOk ? (127, 'missing') : (0, 'ok'),
      workspace: () async {},
      providerConfigured: () => true,
      repairWorker: worker,
    );

    testWidgets('leaving during a repair asks and keeps the worker running', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final release = Completer<void>();
      HealthRepairCancellation? seen;
      final health = service(
        worker: (ids, cancellation, onLine) async {
          seen = cancellation;
          onLine('Installing python');
          await release.future;
        },
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: Aether.theme(),
          home: const Scaffold(body: Text('Settings home')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsHealthScreen(service: health),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final checkbox = find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'Select Python for repair',
        ),
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
      await tester.ensureVisible(find.text('Repair selected runtimes'));
      await tester.tap(find.text('Repair selected runtimes'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(health.repairing, isTrue);

      // The elapsed-time readout ticks every second while repairing, so the
      // tree never settles: pump frames explicitly.
      await navigator.currentState!.maybePop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Leave while repairing?'), findsOneWidget);
      await tester.tap(find.text('Keep running'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Settings home'), findsOneWidget);
      expect(find.byType(SettingsHealthScreen), findsNothing);
      // Leaving neither cancelled nor stopped the install.
      expect(health.repairing, isTrue);
      expect(seen?.isCancelled, isFalse);
      expect(health.repairLog, contains('Installing python'));

      release.complete();
      await tester.pumpAndSettle();
      health.dispose();
    });

    testWidgets('hard reset is blocked while a chat is running', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AppState.I.sessions.add(ChatSession(id: 'busy', title: 'B', model: 'm'));
      final run = AgentService.I.runBucketForTest('busy');
      run.activeRunId = 'run';
      addTearDown(() => AgentService.I.dropSessionRun('busy'));
      final health = service(worker: null, pythonOk: true);
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: SettingsHealthScreen(service: health)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Hard reset the sandbox'), 400);
      await tester.tap(find.text('Hard reset the sandbox'));
      await tester.pumpAndSettle();
      expect(find.text('Stop running chats first'), findsOneWidget);
      expect(find.text('Reset the sandbox?'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      run.activeRunId = null;
      await tester.tap(find.text('Hard reset the sandbox'));
      await tester.pumpAndSettle();
      expect(find.text('Reset the sandbox?'), findsOneWidget);
      expect(find.textContaining('Chat workspace folders'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      health.dispose();
    });
  });
}
