import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sidebar.dart';

/// Worker D regression tests — sidebar bug-hunt fixes:
///  1. Swipe-to-delete now asks for confirmation (was: instant, irreversible
///     delete with no dialog, unlike the delete button).
///  2. The search field's clear (X) button now clears the visible text too
///     (was: only the filter state reset, stale text stayed in the field).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The app theme uses the bundled Inter font; the test VM has no Inter
  // installed, so without this the fallback font's wider glyphs overflow
  // tight rows (e.g. the Trajectory row) and fail layout.
  setUpAll(() async {
    final bytes = await File('assets/fonts/Inter.ttf').readAsBytes();
    await (FontLoader(
      'Inter',
    )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    final app = AppState.I;
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession addSession(String id, String title) {
    final app = AppState.I;
    final s = ChatSession(
      id: id,
      title: title,
      model: 'm',
      mode: 'auto',
      messages: [Message(role: 'user', content: 'hi')],
    );
    app.sessions.add(s);
    app.activeSessionId = id;
    return s;
  }

  Future<void> pumpSidebar(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
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

  testWidgets('search clear button empties the text field', (tester) async {
    addSession('s1', 'Flutter chat');
    await pumpSidebar(tester);

    final field = find.byWidgetPredicate(
      (w) => w is TextField && (w.decoration?.hintText == 'Search sessions'),
    );
    expect(field, findsOneWidget);

    await tester.enterText(field, 'zzz-no-match');
    await tester.pump();
    // Filter applied: nothing matches.
    expect(find.textContaining('No sessions match'), findsOneWidget);

    // Tap the X clear button.
    final clear = find.byIcon(Icons.close);
    expect(clear, findsOneWidget);
    await tester.tap(clear);
    await tester.pump();

    // The field text itself is gone (not just the filter state)…
    final tf = tester.widget<TextField>(field);
    expect(tf.controller!.text, isEmpty);
    // …and the session list is visible again.
    expect(find.text('Flutter chat'), findsOneWidget);
  });

  testWidgets('swipe delete shows a confirmation dialog', (tester) async {
    addSession('s1', 'Keep me');
    await pumpSidebar(tester);
    expect(find.text('Keep me'), findsOneWidget);

    await tester.fling(
      find.byKey(const ValueKey('s1')),
      const Offset(-400, 0),
      800,
    );
    await tester.pump();

    // Confirmation appears instead of an instant delete.
    expect(find.text('Delete Keep me?'), findsOneWidget);
    expect(
      AppState.I.sessions.any((s) => s.id == 's1'),
      isTrue,
      reason: 'session must survive until the dialog is confirmed',
    );
  });

  testWidgets('cancel keeps the session, delete removes it', (tester) async {
    addSession('s1', 'Cancel me');
    await pumpSidebar(tester);

    Future<void> swipeAndPump() async {
      await tester.fling(
        find.byKey(const ValueKey('s1')),
        const Offset(-400, 0),
        800,
      );
      await tester.pump();
      expect(find.text('Delete Cancel me?'), findsOneWidget);
    }

    // Cancel path.
    await swipeAndPump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(AppState.I.sessions.any((s) => s.id == 's1'), isTrue);

    // Confirm path.
    await swipeAndPump();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(AppState.I.sessions.any((s) => s.id == 's1'), isFalse);
  });
}
