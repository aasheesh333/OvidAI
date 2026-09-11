import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_layout.dart';
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
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpChatAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState.I;
    final session = ChatSession(
      id: 'layout-session',
      title: 'Layout',
      model: 'm',
      mode: 'auto',
      messages: [
        // Long enough that the bubble wants to exceed its cap at both widths.
        Message(role: 'user', content: 'word ' * 80),
        Message(role: 'assistant', content: 'ok'),
      ],
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  for (final width in <double>[1400, 400]) {
    testWidgets('shared content axis at ${width.toInt()}px', (tester) async {
      await pumpChatAt(tester, width);
      final layout = ChatLayout(viewportWidth: width);

      // (a) The transcript column is capped to the content width and centered
      // in the pane, not left-aligned.
      final column = find.byKey(const ValueKey('chat-transcript-column'));
      expect(column, findsOneWidget);
      final columnRect = tester.getRect(column);
      expect(
        columnRect.width,
        moreOrLessEquals(layout.contentWidth, epsilon: 0.5),
      );
      expect(columnRect.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));

      // (b) The composer card is capped to the composer width.
      final composer = find.byKey(const ValueKey('chat-composer-card'));
      expect(composer, findsOneWidget);
      expect(
        tester.getSize(composer).width,
        moreOrLessEquals(layout.composerWidth, epsilon: 0.5),
      );

      // (c) User bubbles never exceed the compact user bubble width.
      final bubble = find.byKey(const ValueKey('chat-user-bubble-0'));
      expect(bubble, findsOneWidget);
      expect(
        tester.getSize(bubble).width,
        lessThanOrEqualTo(layout.userBubbleMaxWidth + 0.5),
      );
    });
  }
}
