import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _description = 'Review the staging deployment and inspect the error '
    'budget before preparing a release summary. Include all unresolved issues, '
    'the owners responsible for follow-up, and the complete rollback procedure. '
    'Do not publish until the release checks have been reviewed.';
const _captureKey = ValueKey('schedule-review-capture');

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(1024, 768),
  double scale = 1,
  bool dark = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Aether.dark = dark;
  await tester.pumpWidget(MaterialApp(
    theme: Aether.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const RepaintBoundary(
      key: _captureKey,
      child: ScheduleScreen(sessionId: 'finish-05'),
    ),
  ));
  await _frames(tester);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  // Text entry schedules a post-frame caret reveal. Let it finish before
  // scrolling to another control, otherwise it can undo ensureVisible.
  await _frames(tester);
  await tester.ensureVisible(finder);
  await _frames(tester);
  expect(finder.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

Future<void> _menu(WidgetTester tester, String choice) async {
  await _reveal(tester, find.byTooltip('Task actions'));
  await tester.tap(find.byTooltip('Task actions'));
  await _frames(tester);
  await tester.tap(find.text(choice));
  await _frames(tester);
}

void main() {
  late AppState app;
  late Map<String, dynamic> task;
  late bool wasDark;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    wasDark = Aether.dark;
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    AgentNotificationService.I.backgroundStopped = false;
    AgentNotificationService.I.backgroundConstraint = null;
    task = {
      'id': 'saved-task',
      'prompt': _description,
      'status': 'pending',
      'fireAt': '2025-04-07T09:30:00Z',
      'every': 3600,
      'timezone': 'fixed-instant',
      'maxRetries': 2,
      'attempt': 1,
      'lastStatus': 'failed',
      'startedAt': '2025-04-07T09:00:00Z',
      'finishedAt': '2025-04-07T09:00:05Z',
      'error': 'Provider unavailable before execution; no external action taken.',
    };
    app.sessions.add(ChatSession(
      id: 'finish-05', title: 'Release operations', model: 'm',
    )..schedules.add(task));
    app.activeSessionId = 'finish-05';
  });

  tearDown(() {
    AgentNotificationService.I.backgroundStopped = false;
    AgentNotificationService.I.backgroundConstraint = null;
    AgentService.I.schedules.stopped = false;
    Aether.dark = wasDark;
    AppState.resetTestInstance();
  });

  // Catches truncation, fixed-width detail rows and incorrect result field names.
  for (final layout in [
    (size: const Size(360, 640), scale: 2.0, dark: true),
    (size: const Size(320, 640), scale: 1.0, dark: false),
    (size: const Size(1024, 768), scale: 1.0, dark: true),
  ]) {
    testWidgets('saved details readable at ${layout.size} ${layout.scale}x',
        (tester) async {
      await _mount(tester, size: layout.size, scale: layout.scale, dark: layout.dark);
      await _reveal(tester, find.text('Show details'));
      await tester.tap(find.text('Show details'));
      await _frames(tester);
      final full = find.text(_description).last;
      final text = tester.widget<Text>(full);
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      // The description itself can be taller than the viewport at 2x. Scroll
      // to both ends rather than requiring its offscreen midpoint to hit-test.
      await tester.ensureVisible(full);
      await _frames(tester);
      await Scrollable.ensureVisible(tester.element(full), alignment: 1);
      await _frames(tester);
      for (final label in ['Scheduled', 'Time zone', 'Next run', 'Last run', 'Retries', 'Last error', 'Raw spec']) {
        await _reveal(tester, find.text(label));
      }
      expect(find.textContaining('Overdue by'), findsWidgets);
      expect(find.textContaining('UTC'), findsWidgets);
      expect(find.textContaining('failed ·'), findsOneWidget);
      expect(find.textContaining('2025'), findsWidgets);
      expect(find.textContaining('1/2'), findsOneWidget);
      expect(find.text(task['error'] as String), findsOneWidget);
      expect(find.textContaining('Every 1 h'), findsWidgets);
      expect(find.text('Never run'), findsNothing);
      expect(tester.takeException(), isNull);

      if (layout.size.width == 1024 &&
          const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
        // Capture the actual expanded saved-task card with its persisted data.
        await Scrollable.ensureVisible(
          tester.element(find.text('Hide details')), alignment: 0.2,
        );
        await _frames(tester);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          expect(data, isNotNull);
          await File('/tmp/opencode/ui-finish-05.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets('daily due follows local calendar, retry follows stored instant',
      (tester) async {
    task.addAll({
      'dailyAt': '09:30', 'every': null, 'localDate': '2032-06-15',
      'fireAt': '2031-04-07T01:00:00Z', 'attempt': 0,
    });
    await _mount(tester);
    expect(find.textContaining('Jun 15, 2032 at 9:30 AM'), findsOneWidget);
    expect(find.textContaining('device-local'), findsOneWidget);
    task['attempt'] = 1;
    app.refresh();
    await _frames(tester);
    expect(find.textContaining('2032'), findsNothing);
    expect(find.textContaining('2031'), findsOneWidget);
  });

  testWidgets('paused and terminal tasks do not claim an automatic next run',
      (tester) async {
    await _mount(tester);
    for (final status in ['paused', 'failed', 'completed', 'cancelled', 'running']) {
      task['status'] = status;
      app.refresh();
      await _frames(tester);
      expect(find.textContaining('Next in'), findsNothing);
      expect(find.textContaining('Overdue by'), findsNothing);
    }
    task.remove('lastStatus');
    task.remove('finishedAt');
    app.refresh();
    await tester.tap(find.text('Show details'));
    await _frames(tester);
    expect(find.text('No result recorded'), findsOneWidget);
    expect(find.text('Never run'), findsNothing);
    await _reveal(tester, find.byTooltip('Task actions'));
    await tester.tap(find.byTooltip('Task actions'));
    await _frames(tester);
    final edit = tester.widget<PopupMenuItem<String>>(
      find.ancestor(of: find.text('Edit'), matching: find.byType(PopupMenuItem<String>)),
    );
    expect(edit.enabled, isFalse);
    expect(find.text('Pause'), findsOneWidget);
  });

  testWidgets('edit sheet supports keyboard, recurrence and inline validation at 2x',
      (tester) async {
    await _mount(tester, size: const Size(360, 640), scale: 2);
    await _menu(tester, 'Edit');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await _frames(tester);
    final time = find.byKey(const ValueKey('schedule-time'));
    await _reveal(tester, find.text('Daily'));
    await tester.tap(find.text('Daily'));
    await _frames(tester);
    await _reveal(tester, time);
    await tester.enterText(time, '25:90');
    await _reveal(tester, find.text('Save'));
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(400));
    expect(tester.view.viewInsets.bottom, 240);
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.text('Use HH:mm, from 00:00 to 23:59.'));
    expect(task['every'], 3600);
    await _reveal(tester, time);
    await tester.enterText(time, '09:45');
    await _reveal(tester, find.text('Save'));
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(400));
    expect(tester.view.viewInsets.bottom, 240);
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await app.flushSessionPersistence();
    });
    await _frames(tester);
    expect(task['dailyAt'], '09:45');
    expect(task['every'], isNull);
    expect(task['timezone'], 'device-local');
    expect(task['prompt'], _description);
    await tester.runAsync(() async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('ovid_sessions')!
          .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
          .singleWhere((session) => session['id'] == 'finish-05');
      expect((saved['schedules'] as List).single['dailyAt'], '09:45');
    });
    expect(find.text('Edit schedule'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-off rejects invalid calendar then persists exact offset instant',
      (tester) async {
    await _mount(tester);
    await _menu(tester, 'Edit');
    await tester.tap(find.text('One-off'));
    await _frames(tester);
    final time = find.byKey(const ValueKey('schedule-time'));
    await tester.enterText(time, '2032-02-30 09:00');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    expect(find.textContaining('Invalid calendar date/time'), findsOneWidget);
    expect(task['fireAt'], '2025-04-07T09:30:00Z');
    await _reveal(tester, time);
    await tester.enterText(time, '2032-06-15T09:45:30+05:30');
    await _reveal(tester, find.text('Save'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await app.flushSessionPersistence();
    });
    await _frames(tester);
    expect(task['fireAt'], '2032-06-15T04:15:30.000Z');
    expect(task['dailyAt'], isNull);
    expect(task['every'], isNull);
    expect(find.text('Edit schedule'), findsNothing);
  });

  testWidgets('edit service rejection remains inline without claiming saved',
      (tester) async {
    await _mount(tester);
    await _menu(tester, 'Edit');
    task['status'] = 'running'; // Coordinator claimed it while the sheet was open.
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.textContaining('Pause the task before editing'));
    expect(find.text('Edit schedule'), findsOneWidget);
    expect(task['status'], 'running');
    expect(task['fireAt'], '2025-04-07T09:30:00Z');
  });

  testWidgets('storage failure keeps edits open and restores original schedule',
      (tester) async {
    await _mount(tester);
    await _menu(tester, 'Edit');
    final prompt = find.byKey(const ValueKey('schedule-prompt'));
    await tester.enterText(prompt, 'Unsaved change');
    await _reveal(tester, find.text('Save'));
    app.failNextSessionWriteForTest = true;
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.textContaining('Session storage unavailable'));
    expect(find.text('Edit schedule'), findsOneWidget);
    expect(task['prompt'], _description);
    expect(task['fireAt'], '2025-04-07T09:30:00Z');
    expect(tester.widget<TextField>(prompt).controller!.text, 'Unsaved change');
  });

  testWidgets('empty task and short interval are rejected, minimum interval saves',
      (tester) async {
    await _mount(tester, size: const Size(320, 640), dark: false);
    await _menu(tester, 'Edit');
    final prompt = find.byKey(const ValueKey('schedule-prompt'));
    final time = find.byKey(const ValueKey('schedule-time'));
    await tester.enterText(prompt, '   ');
    await _reveal(tester, time);
    expect(tester.widget<TextField>(time).keyboardType, TextInputType.number);
    await tester.enterText(time, '299');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.text('Enter a task description.'));
    await _reveal(tester, find.text('Enter a whole number of seconds, at least 300.'));
    expect(task['every'], 3600);
    await _reveal(tester, prompt);
    await tester.enterText(prompt, 'Check release queue');
    await _reveal(tester, time);
    await tester.enterText(time, '300');
    await _reveal(tester, find.byIcon(Icons.add));
    await tester.tap(find.byIcon(Icons.add));
    await _reveal(tester, find.text('Save'));
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      await app.flushSessionPersistence();
    });
    await _frames(tester);
    expect(task['every'], 300);
    expect(task['maxRetries'], 3);
    expect(task['prompt'], 'Check release queue');
    expect(DateTime.tryParse(task['fireAt'] as String), isNotNull);
  });

  testWidgets('pause resume and cancel mutate the saved task through real services',
      (tester) async {
    await _mount(tester);
    for (final action in [
      (label: 'Pause', status: 'paused'),
      (label: 'Resume', status: 'pending'),
      (label: 'Cancel', status: 'cancelled'),
    ]) {
      await _reveal(tester, find.byTooltip('Task actions'));
      await tester.tap(find.byTooltip('Task actions'));
      await _frames(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text(action.label));
        await app.flushSessionPersistence();
      });
      await _frames(tester);
      expect(task['status'], action.status);
      expect(find.text(action.status), findsOneWidget);
      expect(app.sessionById('finish-05')!.schedules.single['id'], 'saved-task');
    }
    await _reveal(tester, find.byTooltip('Task actions'));
    await tester.tap(find.byTooltip('Task actions'));
    await _frames(tester);
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
  });
}
