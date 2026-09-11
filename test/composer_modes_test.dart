import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

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
}
