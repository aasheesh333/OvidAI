// V2 UI — Activity hub widget tests.
//
// The Activity hub consolidates the per-session operational views into one
// tabbed screen: Jobs (background jobs) / Agents (subagents) / Schedules /
// Events (trajectory ledger). These tests pin the hub contract:
//   * tabs switch via the AetherSegmentedControl,
//   * exactly one status strip is visible on every tab (no stacked banners),
//   * jobs render with a status pill and one clear kill action,
//   * schedule cards show recurrence + next run + one action menu,
//   * events render from the ledger with a details disclosure,
//   * calm empty states at 360×640 @2× in light and dark.
//
// Uses the same test seams as the ui_redesign suites (AppState.createForTest,
// AgentService.runBucketForTest / debugPauseScheduleTimerForTest,
// SessionLedger.rootOverrideForTest). Ledger reads use real files + isolates,
// so Events-tab flows run inside tester.runAsync with bounded pump loops —
// the pulsing status dot rules out pumpAndSettle.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/activity_screen.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late Directory ledgerRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    AgentNotificationService.I.backgroundStopped = false;
    AgentNotificationService.I.backgroundConstraint = null;
    ledgerRoot = await Directory.systemTemp.createTemp('v2-activity-');
    SessionLedger.rootOverrideForTest = ledgerRoot;
    app.sessions.add(ChatSession(id: 's', title: 'My work', model: 'm'));
    app.activeSessionId = 's';
  });

  tearDown(() async {
    for (final sid in SessionLedger.I.sinkOpensForTest.keys.toList()) {
      await SessionLedger.I.close(sid);
    }
    SessionLedger.rootOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentService.I.schedules.stopped = false;
    AgentNotificationService.I.resetForTest();
    Aether.dark = true;
    AppState.resetTestInstance();
    try {
      ledgerRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHub(WidgetTester tester, {Key? key}) async {
    await tester.pumpWidget(
      MaterialApp(
        key: key,
        theme: Aether.theme(),
        home: const ActivityScreen(sessionId: 's'),
      ),
    );
    await tester.pump();
  }

  // The status strip's pulsing dot is a repeating animation, so pumpAndSettle
  // would spin forever. Advance by bounded durations instead.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
  }

  // Called inside runAsync: ledger reads use real files and worker isolates,
  // which advancing the widget test's fake clock cannot complete. The bound
  // only guards against hangs; the wait is condition-based.
  Future<void> pumpUntilLedgerReady(WidgetTester tester) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'Events tab must leave loading once real IO completes',
    );
  }

  testWidgets(
    'tabs switch between Jobs, Agents, Schedules and Events with exactly one '
    'status strip on every tab',
    (tester) async {
      await pumpHub(tester);

      // Default tab is Jobs.
      expect(find.text('No background jobs'), findsOneWidget);
      expect(find.text('Background execution active'), findsOneWidget);

      await tester.tap(find.text('Schedules'));
      await settle(tester);
      expect(find.text('No scheduled tasks'), findsOneWidget);
      // One strip — the hub's own; the schedules tab does not stack its banner.
      expect(find.text('Background execution active'), findsOneWidget);

      await tester.tap(find.text('Agents'));
      await settle(tester);
      expect(find.text('No subagents yet'), findsOneWidget);
      expect(find.text('Background execution active'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('Events'));
        await tester.pump();
        await pumpUntilLedgerReady(tester);
      });
      expect(find.text('No ledger records yet'), findsOneWidget);
      expect(find.text('Background execution active'), findsOneWidget);

      await tester.tap(find.text('Jobs'));
      await settle(tester);
      expect(find.text('No background jobs'), findsOneWidget);
      expect(find.text('Background execution active'), findsOneWidget);
    },
  );

  testWidgets(
    'jobs tab renders jobs with status pills and one clear kill action',
    (tester) async {
      final bucket = AgentService.I.runBucketForTest('s');
      bucket.jobs[1] =
          BgJob(id: 1, name: 'dev server', command: 'python -m http.server')
            ..started = true;
      bucket.jobs[2] = BgJob(id: 2, name: 'build', command: 'make')
        ..started = true
        ..finished = true
        ..exitCode = 0;
      addTearDown(() => AgentService.I.dropSessionRun('s'));

      await pumpHub(tester);

      expect(find.text('#1 dev server'), findsOneWidget);
      expect(find.text('#2 build'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'running'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'done'), findsOneWidget);
      expect(find.textContaining('chars output'), findsNWidgets(2));

      // One clear action: Kill only for the running job.
      expect(find.byKey(const ValueKey('activity-job-kill-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-job-kill-2')), findsNothing);

      // The status strip summarizes the live work.
      expect(find.text('1 job'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('activity-job-kill-1')));
      await settle(tester);

      expect(bucket.jobs[1]!.state, 'stopping');
      expect(find.widgetWithText(AetherPill, 'stopping'), findsOneWidget);
      expect(find.byKey(const ValueKey('activity-job-kill-1')), findsNothing);
    },
  );

  testWidgets(
    'schedules tab renders a card with status pill, recurrence, next run and '
    'one action menu',
    (tester) async {
      final s = app.sessionById('s')!;
      final future = DateTime.now().toUtc().add(const Duration(hours: 2));
      s.schedules.add({
        'id': 'a',
        'prompt': 'Review PR queue',
        'status': 'pending',
        'fireAt': future.toIso8601String(),
        'dailyAt': '09:30',
        'maxRetries': 1,
        'attempt': 0,
      });

      await pumpHub(tester);
      await tester.tap(find.text('Schedules'));
      await settle(tester);

      expect(find.widgetWithText(AetherPill, 'pending'), findsOneWidget);
      expect(find.text('Review PR queue'), findsOneWidget);
      expect(find.textContaining('Daily'), findsOneWidget);
      expect(find.textContaining('09:30'), findsOneWidget);
      expect(find.textContaining('Next in'), findsOneWidget);
      // One clear action affordance per card.
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      // The strip summarizes the pending task without stacking a banner.
      expect(find.text('1 task'), findsOneWidget);
      expect(find.text('Background execution active'), findsOneWidget);
    },
  );

  testWidgets(
    'events tab renders ledger events and opens the details disclosure',
    (tester) async {
      await tester.runAsync(() async {
        await SessionLedger.I.append('s', 'turn_start', {'turn': 1, 'msgs': 3});
        await SessionLedger.I.append('s', 'tool_end', {
          'tool': 'read_file',
          'ms': 42,
          'ok': true,
        });

        await pumpHub(tester);
        await tester.tap(find.text('Events'));
        await tester.pump();
        await pumpUntilLedgerReady(tester);
      });

      expect(find.text('#1 · Turn start (turn 1)'), findsOneWidget);
      expect(find.text('#2 · Tool done: read_file'), findsOneWidget);
      expect(find.text('42ms · ok'), findsOneWidget);

      // Details stay behind a disclosure, not as raw rows.
      await tester.tap(find.text('View details').first);
      await settle(tester);
      expect(find.textContaining('"kind": "turn_start"'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await settle(tester);
      expect(find.textContaining('"kind": "turn_start"'), findsNothing);
    },
  );

  testWidgets(
    'agents tab lists subagents with status pill and opens the slim '
    'transcript view',
    (tester) async {
      app.sessions.add(
        ChatSession(
          id: 'c1',
          title: 'Scout',
          model: 'm',
          mode: 'auto',
          parentId: 's',
          agentLabel: 'Scout',
          agentState: 'running',
          agentContinuable: true,
        ),
      );
      AgentService.I.runBucketForTest('c1').activeRunId = 'r-1';
      addTearDown(() => AgentService.I.dropSessionRun('c1'));

      await pumpHub(tester);
      await tester.tap(find.text('Agents'));
      await settle(tester);

      expect(find.text('Scout'), findsOneWidget);
      expect(find.widgetWithText(AetherPill, 'running'), findsOneWidget);
      expect(find.byKey(const ValueKey('subagent-stop-c1')), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);

      // Tapping the card opens the child's transcript (SubagentScreen).
      await tester.tap(find.text('Scout'));
      await settle(tester);
      expect(find.byType(SubagentScreen), findsOneWidget);
    },
  );

  testWidgets(
    'empty states render at 360x640 @2x in light and dark',
    (tester) async {
      tester.view.physicalSize = const Size(720, 1280);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final dark in [true, false]) {
        Aether.dark = dark;
        await tester.runAsync(() async {
          // A fresh key per theme: pumpWidget would otherwise reuse the
          // ActivityScreen State and reopen on the previous iteration's tab.
          await pumpHub(tester, key: ValueKey('activity-hub-$dark'));
          expect(find.text('No background jobs'), findsOneWidget);
          expect(find.byKey(const ValueKey('activity-jobs-empty')),
              findsOneWidget);

          await tester.tap(find.text('Schedules'));
          await settle(tester);
          expect(find.text('No scheduled tasks'), findsOneWidget);

          await tester.tap(find.text('Agents'));
          await settle(tester);
          expect(find.byKey(const ValueKey('subagent-catalog-empty')),
              findsOneWidget);
          expect(find.text('No subagents yet'), findsOneWidget);

          await tester.tap(find.text('Events'));
          await tester.pump();
          await pumpUntilLedgerReady(tester);
          expect(find.byKey(const ValueKey('trajectory-empty')), findsOneWidget);
          expect(find.text('No ledger records yet'), findsOneWidget);
        });
      }
    },
  );
}
