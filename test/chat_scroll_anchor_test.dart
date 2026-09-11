import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

Message _msg(
  String content, {
  String role = 'user',
  MsgKind kind = MsgKind.text,
  bool thinking = false,
}) => Message(role: role, kind: kind, content: content, thinking: thinking);

const _listKey = ValueKey('chat-transcript-list');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpSession(
    WidgetTester tester,
    List<Message> messages,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState.I;
    final session = ChatSession(
      id: 'anchor-session',
      title: 'Anchor',
      model: 'm',
      mode: 'auto',
      messages: messages,
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  ScrollPosition transcriptPosition(WidgetTester tester) {
    final scrollable = find
        .descendant(of: find.byKey(_listKey), matching: find.byType(Scrollable))
        .first;
    return tester.state<ScrollableState>(scrollable).position;
  }

  testWidgets(
    'paging older items keeps the previously top item at its offset',
    (tester) async {
      // 44 messages with a 40-item page. The four OLDEST (the page that gets
      // prepended) are tall; the visible tail is short. A maxScrollExtent
      // delta extrapolated from the built tail badly overshoots once those
      // tall rows are prepended, so the previously top row is pushed out of
      // the viewport. Keyed anchoring restores it to its captured offset.
      final messages = <Message>[
        for (var i = 0; i < 4; i++) _msg('TALL$i ${'x' * 300}'),
        for (var i = 4; i < 44; i++) _msg('m$i'),
      ];
      await pumpSession(tester, messages);

      final position = transcriptPosition(tester);
      final listTop = tester.getTopLeft(find.byKey(_listKey)).dy;

      // Reach the top: this triggers paging (prepend TALL0..TALL3). Before
      // the page, the top visible row is TALL4.
      position.jumpTo(0);
      await tester.pump();
      // The pager captures the anchor after the new scroll offset lays out,
      // then grows the window and restores on the following frame.
      await tester.pump();
      // The restore jump itself lays out on the next frame.
      await tester.pump();

      // TALL4 is the row that was at the top when paging began; m5 sits just
      // below it. If the prepend is mis-compensated, both are pushed out of
      // the built range; keyed anchoring keeps them on screen.
      final anchorNeighbor = find.text('m5');
      expect(
        anchorNeighbor,
        findsOneWidget,
        reason: 'the rows around the anchor must stay built after the prepend',
      );
      final top = tester.getTopLeft(anchorNeighbor).dy;
      expect(
        top,
        greaterThanOrEqualTo(listTop - 2),
        reason: 'the anchored row must not be pushed above the viewport',
      );
      expect(top, lessThanOrEqualTo(listTop + 400));
    },
  );

  testWidgets(
    'a new streaming item does not force-scroll when scrolled up',
    (tester) async {
      await pumpSession(tester, List.generate(20, (i) => _msg('m$i')));

      final position = transcriptPosition(tester);
      // Scroll up off the bottom (positive dy reveals older content).
      await tester.drag(find.byKey(_listKey), const Offset(0, 300));
      await tester.pump();
      final scrolledUp = position.pixels;
      expect(
        scrolledUp,
        lessThan(position.maxScrollExtent - 24),
        reason: 'precondition: the user is scrolled up',
      );

      // A new streaming item arrives while the user is reading history.
      final app = AppState.I;
      final live = _msg('streamed', role: 'assistant');
      app.activeSession!.messages.add(live);
      AgentService.I.setActiveRunForTest(app.activeSession!.id, 'run-live');
      app.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        position.pixels,
        moreOrLessEquals(scrolledUp, epsilon: 1),
        reason: 'a streaming append must not yank a scrolled-up user to the '
            'bottom',
      );

      AgentService.I.setActiveRunForTest(app.activeSession!.id, null);
    },
  );

  testWidgets('auto-follow scrolls to the bottom when already there', (
    tester,
  ) async {
    await pumpSession(tester, List.generate(20, (i) => _msg('m$i')));

    final position = transcriptPosition(tester);
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
      reason: 'precondition: the user is at the bottom',
    );

    final app = AppState.I;
    app.activeSession!.messages.add(_msg('newest', role: 'assistant'));
    app.refresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
      reason: 'a new tip item should keep an at-bottom user pinned',
    );
  });
}
