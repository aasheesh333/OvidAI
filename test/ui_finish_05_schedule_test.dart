// Finish-05 schedule layout coverage, migrated to the server-backed screen
// (P8 Task 14). Kept: responsive details, every server field, inline edit
// validation, error copy, and pause/resume/cancel mutations — all against a
// fake P4 gateway.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/schedule_fake.dart';

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

Future<FakeScheduleGateway> _mount(
  WidgetTester tester, {
  Size size = const Size(1024, 768),
  double scale = 1,
  bool dark = true,
  Map<String, dynamic>? schedule,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Aether.dark = dark;
  final fake = FakeScheduleGateway([
    schedule ??
        scheduleJson(
          title: 'Release operations',
          description: _description,
          trigger: {'kind': 'every', 'seconds': 3600},
          maxRetries: 2,
          nextRunAt: '2025-04-07T09:30:00.000Z',
          lastResult: lastResultJson(
            status: 'failed',
            message: 'Provider unavailable before execution; no external action taken.',
            ranLate: true,
            finishedAt: '2025-04-07T09:00:05.000Z',
          ),
        ),
  ]);
  ScheduleClient.installForTest(fake.client);
  await tester.pumpWidget(MaterialApp(
    theme: Aether.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: const RepaintBoundary(
      key: _captureKey,
      child: ScheduleScreen(sessionId: 's'),
    ),
  ));
  await _frames(tester);
  return fake;
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  // Text entry schedules a post-frame caret reveal. Let it finish before
  // scrolling to another control, otherwise it can undo ensureVisible.
  await _frames(tester);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 200);
    await _frames(tester);
  }
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
  late bool wasDark;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    wasDark = Aether.dark;
    ScheduleClient.timeZoneOverrideForTest = 'UTC';
    app = AppState.createForTest();
    app.sessions.add(ChatSession(
      id: 's', title: 'Release operations', model: 'm',
    ));
    app.activeSessionId = 's';
  });

  tearDown(() {
    ScheduleClient.timeZoneOverrideForTest = null;
    Aether.dark = wasDark;
    AppState.resetTestInstance();
  });

  // Catches truncation, fixed-width detail rows and incorrect result fields.
  for (final layout in [
    (size: const Size(360, 640), scale: 2.0, dark: true),
    (size: const Size(320, 640), scale: 1.0, dark: false),
    (size: const Size(1024, 768), scale: 1.0, dark: true),
  ]) {
    testWidgets('saved details readable at ${layout.size} ${layout.scale}x',
        (tester) async {
      await _mount(
        tester,
        size: layout.size,
        scale: layout.scale,
        dark: layout.dark,
      );
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
      for (final label in [
        'Scheduled',
        'Time zone',
        'Next run',
        'Last run',
        'Retries',
        'Last error',
        'Raw spec',
      ]) {
        await _reveal(tester, find.text(label));
      }
      expect(find.textContaining('Overdue by'), findsWidgets);
      expect(find.textContaining('UTC'), findsWidgets);
      expect(find.textContaining('failed ·'), findsWidgets);
      expect(find.textContaining('2025'), findsWidgets);
      expect(find.textContaining('Up to 2'), findsOneWidget);
      expect(find.textContaining('every=3600s'), findsOneWidget);
      expect(find.text('ran late'), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (layout.size.width == 1024 &&
          const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
        // Capture the actual expanded saved-task card with its persisted data.
        await Scrollable.ensureVisible(
          tester.element(find.text('Hide details')), alignment: 0.2,
        );
        await _frames(tester);
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
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

  testWidgets('daily trigger renders the server nextRunAt', (tester) async {
    await _mount(tester, schedule: scheduleJson(
      title: 'Morning brief',
      description: 'Summarise the inbox',
      trigger: {'kind': 'daily_at', 'time': '09:30', 'tz': 'America/New_York'},
      nextRunAt: '2032-06-15T13:30:00.000Z',
    ));
    expect(find.textContaining('Daily'), findsOneWidget);
    expect(find.textContaining('America/New_York'), findsOneWidget);
    expect(find.textContaining('2032'), findsWidgets);
  });

  testWidgets('paused and terminal tasks do not claim an automatic next run',
      (tester) async {
    final fake = await _mount(tester);
    final row = fake.byId('sc1')!;
    for (final status in ['paused', 'failed', 'completed', 'cancelled']) {
      row['status'] = status;
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleScreen(
            key: ValueKey(status),
            sessionId: 's',
          ),
        ),
      );
      await _frames(tester);
      expect(find.textContaining('Next in'), findsNothing);
      expect(find.textContaining('Overdue by'), findsNothing);
    }
    row['lastResult'] = null;
    await tester.pumpWidget(
      const MaterialApp(
        home: ScheduleScreen(key: ValueKey('no-result'), sessionId: 's'),
      ),
    );
    await _frames(tester);
    await tester.tap(find.text('Show details'));
    await _frames(tester);
    expect(find.text('Never run'), findsOneWidget);
    await _reveal(tester, find.byTooltip('Task actions'));
    await tester.tap(find.byTooltip('Task actions'));
    await _frames(tester);
    final edit = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('Edit'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(edit.enabled, isFalse);
  });

  testWidgets('edit sheet supports keyboard, recurrence and inline validation at 2x',
      (tester) async {
    final fake = await _mount(tester, size: const Size(360, 640), scale: 2);
    await _menu(tester, 'Edit');
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await _frames(tester);
    final time = find.byKey(const ValueKey('schedule-time'));
    await _reveal(tester, find.text('Daily'));
    await tester.tap(find.text('Daily'));
    await _frames(tester);
    await _reveal(tester, find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await _frames(tester);
    await _reveal(tester, time);
    await tester.enterText(time, '25:90');
    await _reveal(tester, find.text('Save'));
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(400));
    expect(tester.view.viewInsets.bottom, 240);
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(
      tester,
      find.text('Pick a time of day (HH:mm, 00:00 to 23:59).'),
    );
    expect(fake.patchCalls, 0);
    await _reveal(tester, time);
    await tester.enterText(time, '09:45');
    await _reveal(tester, find.text('Save'));
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(400));
    expect(tester.view.viewInsets.bottom, 240);
    await tester.tap(find.text('Save'));
    await _frames(tester);
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'daily_at',
      'time': '09:45',
      'tz': 'UTC',
    });
    // FE-017: only what changed is sent — the untouched description is not.
    expect(fake.lastPatchBody!.containsKey('description'), isFalse);
    expect(find.text('Edit schedule'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one-off rejects invalid calendar then persists exact offset instant',
      (tester) async {
    final fake = await _mount(tester, schedule: scheduleJson(
      title: 'Release operations',
      description: _description,
      trigger: {'kind': 'at', 'at': '2025-04-07T09:30:00.000Z'},
    ));
    await _menu(tester, 'Edit');
    await tester.tap(find.text('One-off'));
    await _frames(tester);
    await tester.tap(find.text('Advanced'));
    await _frames(tester);
    final time = find.byKey(const ValueKey('schedule-time'));
    await tester.enterText(time, '2032-02-30 09:00');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    expect(find.textContaining('Invalid calendar date/time'), findsOneWidget);
    expect(fake.patchCalls, 0);
    await _reveal(tester, time);
    await tester.enterText(time, '2032-06-15T09:45:30+05:30');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'at',
      'at': '2032-06-15T04:15:30.000Z',
    });
    expect(find.text('Edit schedule'), findsNothing);
  });

  testWidgets('service rejection remains inline without claiming saved',
      (tester) async {
    final fake = await _mount(tester);
    await _menu(tester, 'Edit');
    fake.failPatchStatus = 400;
    fake.failPatchMessage = 'Schedule is not editable.';
    // A real change: an untouched sheet closes without a PATCH (FE-017).
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'Renamed');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.text('Schedule is not editable.'));
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Edit schedule'), findsOneWidget);
    expect(fake.byId('sc1')!['status'], 'pending');
  });

  testWidgets('empty title and short interval are rejected, minimum saves',
      (tester) async {
    final fake = await _mount(tester, size: const Size(320, 640), dark: false);
    await _menu(tester, 'Edit');
    final title = find.byKey(const ValueKey('schedule-title'));
    final time = find.byKey(const ValueKey('schedule-time'));
    await tester.enterText(title, '   ');
    await _reveal(tester, find.text('Advanced'));
    await tester.tap(find.text('Advanced'));
    await _frames(tester);
    await _reveal(tester, time);
    expect(tester.widget<TextField>(time).keyboardType, TextInputType.number);
    await tester.enterText(time, '299');
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    await _reveal(tester, find.text('Enter a title.'));
    await _reveal(tester, find.text('The shortest interval is 5 minutes.'));
    expect(fake.patchCalls, 0);

    await _reveal(tester, title);
    await tester.enterText(title, 'Check release queue');
    await _reveal(tester, time);
    await tester.enterText(time, '300');
    await _reveal(tester, find.descendant(of: find.byType(AetherStepper), matching: find.byIcon(Icons.add)));
    await tester.tap(find.descendant(of: find.byType(AetherStepper), matching: find.byIcon(Icons.add)));
    await _reveal(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await _frames(tester);
    expect(fake.lastPatchBody!['trigger'], {
      'kind': 'every',
      'seconds': 300,
    });
    expect(fake.lastPatchBody!['maxRetries'], 3);
    expect(fake.lastPatchBody!['title'], 'Check release queue');
    expect(fake.lastPatchBody!.containsKey('description'), isFalse);
  });

  testWidgets('pause resume and cancel mutate the saved task', (tester) async {
    final fake = await _mount(tester, schedule: scheduleJson(
      title: 'Release operations',
      description: _description,
      status: 'pending',
    ));
    final row = fake.byId('sc1')!;

    for (final action in [
      (label: 'Pause', status: 'paused'),
      (label: 'Resume', status: 'pending'),
    ]) {
      await _reveal(tester, find.byTooltip('Task actions'));
      await tester.tap(find.byTooltip('Task actions'));
      await _frames(tester);
      await tester.tap(find.text(action.label));
      await _frames(tester);
      expect(row['status'], action.status);
      expect(find.text(scheduleStatusLabel(action.status)), findsOneWidget);
    }

    await _reveal(tester, find.byTooltip('Task actions'));
    await tester.tap(find.byTooltip('Task actions'));
    await _frames(tester);
    await tester.tap(find.text('Cancel task'));
    await _frames(tester);
    expect(find.text('Cancel this task?'), findsOneWidget);
    await tester.tap(find.text('Cancel task').last);
    await _frames(tester);
    expect(row['status'], 'cancelled');
    expect(find.text('Cancelled'), findsOneWidget);
  });
}
