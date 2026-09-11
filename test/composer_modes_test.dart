import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    // The reminder tick runs forever; pause it so widget teardown is clean.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    // Built-ins register on first access to the agent service.
    expect(AgentService.I, isNotNull);
  });

  tearDown(() {
    workspaceChipOpenStudioForTest = null;
    studioFolderPickOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  group('composer modes', () {
    test('modeOptionsForPicker excludes Read-Only', () {
      final options = modeOptionsForPicker();
      expect(options, isNot(contains(AgentMode.safe)));
      expect(options, contains(AgentMode.auto));
      expect(options, contains(AgentMode.drive));
      expect(options, contains(AgentMode.studio));
      expect(options, contains(AgentMode.control));
      expect(options.length, AgentMode.values.length - 1);
    });

    test('/permission keeps read-only functional but unadvertised', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'perm', title: 'P', model: 'm', mode: 'auto');
      app.sessions.add(s);
      app.activeSessionId = s.id;

      final bad = await CommandService.I.execute('/permission bogus');
      expect(bad!.feedback, contains('Unknown preset'));
      expect(bad.feedback, isNot(contains('read-only')));

      final back = await CommandService.I.execute('/permission read-only');
      expect(back!.feedback, contains('Read-Only'));
      expect(s.mode, 'safe');
    });

    test('/preset plan sets plan mode + read-only and denies mutating tools',
        () async {
      final app = AppState.I;
      final s = ChatSession(id: 'plan', title: 'Plan', model: 'm', mode: 'auto');
      app.sessions.add(s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);

      final res = await CommandService.I.execute('/preset plan');
      expect(res!.feedback, contains('plan'));
      expect(s.presetId, 'plan');
      expect(s.planMode, isTrue);
      expect(AgentService.I.mode, AgentMode.safe);

      expect(
        await AgentService.I.dispatchForTest('file_write', {
          'path': 'a.dart',
          'content': 'x',
        }),
        contains('PLAN MODE ACTIVE'),
      );
      expect(
        await AgentService.I.dispatchForTest('run_shell', {
          'command': 'touch /tmp/x',
        }),
        contains('PLAN MODE ACTIVE'),
      );
    });

    test('switching to another preset clears plan mode and read-only',
        () async {
      final app = AppState.I;
      final s = ChatSession(id: 'plan2', title: 'P', model: 'm', mode: 'auto');
      app.sessions.add(s);
      app.activeSessionId = s.id;

      await CommandService.I.execute('/preset plan');
      expect(s.planMode, isTrue);
      expect(AgentService.I.mode, AgentMode.safe);

      await CommandService.I.execute('/preset standard');
      expect(s.presetId, 'standard');
      expect(s.planMode, isFalse);
      expect(AgentService.I.mode, AgentMode.auto);
    });
  });

  group('composer mode pickers (widget)', () {
    Future<void> pumpChat(WidgetTester tester) async {
      final app = AppState.I;
      final s = ChatSession(id: 'picker', title: 'Picker', model: 'm');
      app.sessions.add(s);
      app.activeSessionId = s.id;
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('mode chip sheet never offers Read-Only', (tester) async {
      await pumpChat(tester);

      await tester.tap(find.text('General'));
      await tester.pumpAndSettle();

      expect(find.text('Agent access mode'), findsOneWidget);
      expect(find.text('Read-Only'), findsNothing);
      expect(find.text('Full Access'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      expect(find.text('Control'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });

    testWidgets('/permission sheet never offers Read-Only', (tester) async {
      await pumpChat(tester);

      await tester.enterText(find.byType(TextField).first, '/permission');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Agent access mode'), findsOneWidget);
      expect(find.text('Read-Only'), findsNothing);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    });
  });

  group('workspace chip', () {
    testWidgets('opens Studio and never the in-chat folder picker',
        (tester) async {
      final app = AppState.I;
      final s = ChatSession(id: 'ws', title: 'WS', model: 'm');
      s.workspaceFolder = '/tmp/some-pinned-folder';
      app.sessions.add(s);
      app.activeSessionId = s.id;

      BuildContext? openedWith;
      workspaceChipOpenStudioForTest = (ctx) => openedWith = ctx;

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The chip shows the pinned folder read-only (basename only).
      expect(find.text('some-pinned-folder'), findsOneWidget);

      await tester.tap(find.text('some-pinned-folder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(openedWith, isNotNull, reason: 'chip must open Studio');
      expect(
        find.text('Working folder'),
        findsNothing,
        reason: 'the in-chat folder picker must be gone',
      );
    });
  });

  // ── C1: plan mode exit must release the plan-owned read-only mode ──────
  group('plan mode exit', () {
    ChatSession planSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: 'P', model: 'm', mode: 'auto');
      app.sessions.add(s);
      app.activeSessionId = s.id;
      return s;
    }

    test(
      'approving exit_plan_mode restores the pre-plan mode and allows mutating '
      'tools',
      () async {
        final s = planSession('plan-exit');
        AgentService.setRunSessionForTest(s.id);

        await CommandService.I.execute('/preset plan');
        expect(s.planMode, isTrue);
        expect(s.mode, 'safe');
        expect(s.planPreMode, 'auto');

        final planFuture = AgentService.I.dispatchForTest('exit_plan_mode', {
          'plan': 'Do the thing',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(AgentService.I.pendingApproval, isNotNull);
        AgentService.I.approve(true);
        expect(await planFuture, contains('approved'));

        expect(s.planMode, isFalse);
        expect(
          s.mode,
          'auto',
          reason: 'plan-owned read-only must be released on approval',
        );
        expect(s.planPreMode, isNull);

        // M4: a mutating tool is no longer blocked by the plan/read-only
        // gates. device_read is mutating and requires Control mode, so
        // reaching THAT denial proves both gates released.
        final res = await AgentService.I.dispatchForTest('device_read', {});
        expect(res, isNot(contains('PLAN MODE ACTIVE')));
        expect(res, isNot(contains('READ-ONLY MODE')));
        expect(res, contains('Control mode'));

        // And a mutating tool the released mode DOES allow actually runs:
        // file_write proceeds past both gates (it is never plan/read-only
        // refused after approval).
        final writeRes = await AgentService.I.dispatchForTest('file_write', {
          'path': 'plan-exec.txt',
          'content': 'executed',
        });
        expect(writeRes, isNot(contains('PLAN MODE ACTIVE')));
        expect(writeRes, isNot(contains('READ-ONLY MODE')));
      },
    );

    test('/plan off releases the plan-owned read-only mode', () async {
      final s = planSession('plan-off');
      await CommandService.I.execute('/preset plan');
      expect(s.mode, 'safe');

      final res = await CommandService.I.execute('/plan off');
      expect(res!.feedback, contains('Plan mode off'));
      expect(s.planMode, isFalse);
      expect(s.mode, 'auto');
      expect(s.planPreMode, isNull);
    });

    testWidgets('tapping the Plan chip releases the plan-owned read-only mode',
        (tester) async {
      final s = planSession('plan-chip');
      await CommandService.I.execute('/preset plan');
      expect(s.mode, 'safe');

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Plan'));
      await tester.pump();

      expect(s.planMode, isFalse);
      expect(s.mode, 'auto');
      expect(s.planPreMode, isNull);
    });

    test(
      'an independent /permission read-only session stays read-only',
      () async {
        final s = planSession('plan-independent-ro');
        await CommandService.I.execute('/permission read-only');
        expect(s.mode, 'safe');
        expect(s.planMode, isFalse);
        expect(s.planPreMode, isNull);

        // A plan cycle on a DIFFERENT session must not touch it.
        final other = planSession('plan-independent-other');
        await CommandService.I.execute('/preset plan');
        await CommandService.I.execute('/plan off');
        expect(other.mode, 'auto');

        expect(
          s.mode,
          'safe',
          reason: 'independent read-only (planMode=false) is untouched',
        );
        expect(s.planMode, isFalse);
        expect(s.planPreMode, isNull);
      },
    );

    // Entry-order regression: `/plan` sets planMode first, then
    // `/preset plan` introduces safe read-only. Ownership must still be
    // recorded so a plan exit releases it.
    test(
      '/plan then /preset plan then approve exit_plan_mode releases read-only',
      () async {
        final s = planSession('plan-order-approve');
        AgentService.setRunSessionForTest(s.id);

        await CommandService.I.execute('/plan');
        expect(s.planMode, isTrue);
        expect(s.mode, 'auto');

        await CommandService.I.execute('/preset plan');
        expect(s.planMode, isTrue);
        expect(s.mode, 'safe');
        expect(
          s.planPreMode,
          'auto',
          reason: 'ownership must be recorded even though planMode was set',
        );

        final planFuture = AgentService.I.dispatchForTest('exit_plan_mode', {
          'plan': 'Do it',
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(AgentService.I.pendingApproval, isNotNull);
        AgentService.I.approve(true);
        expect(await planFuture, contains('approved'));

        expect(s.planMode, isFalse);
        expect(s.mode, 'auto');
        expect(s.planPreMode, isNull);

        // A mutating tool is allowed again.
        final res = await AgentService.I.dispatchForTest('device_read', {});
        expect(res, isNot(contains('PLAN MODE ACTIVE')));
        expect(res, isNot(contains('READ-ONLY MODE')));
        expect(res, contains('Control mode'));
      },
    );

    test('/plan then /preset plan then /plan off releases read-only', () async {
      final s = planSession('plan-order-off');
      await CommandService.I.execute('/plan');
      await CommandService.I.execute('/preset plan');
      expect(s.mode, 'safe');
      expect(s.planPreMode, 'auto');

      await CommandService.I.execute('/plan off');
      expect(s.planMode, isFalse);
      expect(s.mode, 'auto');
      expect(s.planPreMode, isNull);
    });

    testWidgets(
        '/plan then /preset plan then tapping the Plan chip releases read-only',
        (tester) async {
      final s = planSession('plan-order-chip');
      await CommandService.I.execute('/plan');
      await CommandService.I.execute('/preset plan');
      expect(s.mode, 'safe');

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Plan'));
      await tester.pump();

      expect(s.planMode, isFalse);
      expect(s.mode, 'auto');
      expect(s.planPreMode, isNull);
    });

    // Upgrade regression: a session persisted by the round-1 bug
    // (planMode=true, mode=safe, planPreMode=null) must not stay locked
    // after a plan exit.
    test('legacy persisted plan session releases read-only on exit', () async {
      final app = AppState.I;
      final legacy = ChatSession.fromJson({
        'id': 'legacy-plan',
        'title': 'Legacy',
        'model': 'm',
        'mode': 'safe',
        'planMode': true,
      });
      expect(legacy.mode, 'safe');
      expect(legacy.planMode, isTrue);
      expect(legacy.planPreMode, isNull);
      app.sessions.add(legacy);
      app.activeSessionId = legacy.id;
      AgentService.setRunSessionForTest(legacy.id);

      await CommandService.I.execute('/plan off');

      expect(legacy.planMode, isFalse);
      expect(
        legacy.mode,
        'auto',
        reason: 'legacy plan-owned read-only must not stay locked',
      );
      expect(legacy.planPreMode, isNull);
    });

    // M1: a direct mode pick must clear planMode so picker state and the
    // enforcement gate agree.
    test('selecting a direct mode clears planMode and the plan gate', () async {
      final s = planSession('plan-direct-mode');
      await CommandService.I.execute('/preset plan');
      expect(s.planMode, isTrue);
      expect(s.mode, 'safe');

      AgentService.I.setMode(AgentMode.studio);

      expect(s.planMode, isFalse);
      expect(s.mode, 'studio');
      expect(s.planPreMode, isNull);
    });
  });

  // ── I1: folder change/clear lives in Studio ────────────────────────────
  group('studio workspace folder', () {
    Future<void> pumpStudio(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('changing the folder from Studio updates the session',
        (tester) async {
      final app = AppState.I;
      final s = ChatSession(id: 'studio-ws', title: 'S', model: 'm');
      app.sessions.add(s);
      app.activeSessionId = s.id;

      final picked = Directory.systemTemp.createTempSync('ovid-studio-folder');
      addTearDown(() {
        try {
          picked.deleteSync(recursive: true);
        } catch (_) {}
      });
      studioFolderPickOverrideForTest = picked.path;

      await pumpStudio(tester);
      await tester.tap(find.byTooltip('Working folder'));
      await tester.pumpAndSettle();

      expect(find.text('Working folder'), findsOneWidget);
      await tester.tap(find.text('Change folder'));
      await tester.pumpAndSettle();

      expect(s.workspaceFolder, picked.path);
    });

    testWidgets('clearing the folder from Studio updates the session',
        (tester) async {
      final app = AppState.I;
      final s = ChatSession(id: 'studio-clear', title: 'S', model: 'm');
      s.workspaceFolder = '/tmp/some-pinned-folder';
      app.sessions.add(s);
      app.activeSessionId = s.id;

      await pumpStudio(tester);
      await tester.tap(find.byTooltip('Working folder'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use session sandbox'));
      await tester.pumpAndSettle();

      expect(s.workspaceFolder, isNull);
    });
  });
}
