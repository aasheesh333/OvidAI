import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:ovid_ai/ui/startup_progress_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Lightweight startup task used to seed the coordinator with a single
/// running item so the Aether polish on [StartupProgressPanel] has
/// something to render.
final class _PendingTask implements StartupTask {
  _PendingTask(this.id, this.label, this._gate);
  @override
  final String id;
  @override
  final String label;
  @override
  StartupItemKind get kind => StartupItemKind.plugin;
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  StartupDisable? get onDisable => null;
  final Completer<StartupItemStatus> _gate;
  @override
  Future<StartupItemStatus> run() => _gate.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AppState.I.sessions.clear();
    AppState.I.activeSessionId = null;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpSidebar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: SessionsSidebar(isDrawer: false)),
      ),
    );
    await tester.pump();
  }

  group('SessionsSidebar — Aether polish', () {
    testWidgets('renders Aether primary CTA, brand and SESSIONS header', (
      tester,
    ) async {
      await pumpSidebar(tester);

      // Brand wordmark still named "Ovid".
      expect(find.text('Ovid'), findsOneWidget);

      // "New session" preserved as the AetherPrimaryButton label.
      expect(find.text('New session'), findsOneWidget);
      expect(find.byType(AetherPrimaryButton), findsOneWidget);

      // Section header text is intact.
      expect(find.text('SESSIONS'), findsOneWidget);

      // Profile avatar is in the gradient header (the ProfileAvatar widget
      // itself, not an arbitrary Image, so the fallback path is covered).
      expect(find.byType(ProfileAvatar), findsOneWidget);

      // Gradient header primitive is present.
      expect(find.byType(AetherGradientHeader), findsOneWidget);

      // Plan pill renders (free by default).
      expect(find.byType(AetherPill), findsOneWidget);
      expect(find.text('Free plan'), findsOneWidget);
    });

    testWidgets('new session CTA tap creates a session via AppState', (
      tester,
    ) async {
      await pumpSidebar(tester);
      final before = AppState.I.sessions.length;
      await tester.tap(find.text('New session'));
      await tester.pumpAndSettle();
      expect(AppState.I.sessions.length, greaterThan(before));
    });

    testWidgets('footer surfaces Schedule, Trajectory and Settings', (
      tester,
    ) async {
      await pumpSidebar(tester);
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Trajectory — event ledger'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });
  });

  group('StartupProgressPanel — Aether polish', () {
    testWidgets('wraps expanded rows in an AetherCard with step header', (
      tester,
    ) async {
      final gate = Completer<StartupItemStatus>();
      final coord = StartupCoordinator.forTest(
        deadline: const Duration(seconds: 120),
      );
      unawaited(
        coord.start([
          _PendingTask('task.a', 'Mounting workspace runtime', gate),
        ]),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: StartupProgressPanel(coordinator: coord),
            ),
          ),
        ),
      );
      await tester.pump();

      // Progress bar + toggle present.
      expect(
        find.byKey(const ValueKey('startup-progress-bar')),
        findsOneWidget,
      );
      expect(find.text('Finishing setup · 0 of 1'), findsOneWidget);

      // Expand the panel — the AetherCard polish wraps the rows.
      await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
      await tester.pump();

      expect(find.byType(AetherCard), findsOneWidget);
      // Step label (the running task's label) renders at the top of
      // the card, and the row below renders it again.
      expect(find.text('Mounting workspace runtime'), findsWidgets);

      gate.complete(
        StartupItemStatus.ready(
          'task.a',
          StartupItemKind.plugin,
          'Mounting workspace runtime',
        ),
      );
      await tester.pump();
      await tester.pump();
    });
  });
}
