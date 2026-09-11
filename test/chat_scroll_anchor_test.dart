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
    transcriptAnchorFallbackObserver = null;
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

  // 44 messages with a 40-item page. Indices 0..3 are the page that gets
  // prepended (tall, so a maxScrollExtent delta extrapolated from the short
  // tail badly overshoots); index 4 is the top visible row before paging
  // (ANCHOR); 5..43 are the short tail.
  List<Message> anchoredMessages() => <Message>[
    for (var i = 0; i < 4; i++) _msg('TALL$i ${'x' * 300}'),
    _msg('ANCHOR'),
    for (var i = 5; i < 44; i++) _msg('m$i'),
  ];

  testWidgets(
    'paging older items restores the anchored row to its exact offset',
    (tester) async {
      await pumpSession(tester, anchoredMessages());

      final position = transcriptPosition(tester);

      // Reach the top: this triggers paging (prepend TALL0..TALL3). Before the
      // page, the top visible row is ANCHOR (index 4).
      position.jumpTo(0);
      await tester.pump(); // lays out at the top; pager captures the anchor
      expect(find.text('ANCHOR'), findsOneWidget);
      final before = tester.getTopLeft(find.text('ANCHOR')).dy;

      // The pager grows the window and restores on the following frame; the
      // restore jump lays out one frame after that.
      await tester.pump();
      await tester.pump();

      expect(find.text('ANCHOR'), findsOneWidget);
      final after = tester.getTopLeft(find.text('ANCHOR')).dy;
      expect(
        after,
        moreOrLessEquals(before, epsilon: 1),
        reason: 'the anchored row must keep the exact offset it had before '
            'the prepend (was $before, now $after)',
      );
    },
  );

  testWidgets(
    'a huge prepend uses the coarse extent jump then re-anchors exactly',
    (tester) async {
      var fallbacks = 0;
      transcriptAnchorFallbackObserver = () => fallbacks++;
      // 80 uniform messages: paging prepends 40 rows, pushing the previously
      // top row (m40) well beyond the viewport + cache. The keyed lookup
      // misses, so the extent-delta fallback runs, then the retry re-anchors.
      await pumpSession(tester, List.generate(80, (i) => _msg('m$i')));

      final position = transcriptPosition(tester);
      position.jumpTo(0);
      await tester.pump(); // lays out at the top; pager captures the anchor
      expect(find.text('m40'), findsOneWidget);
      final before = tester.getTopLeft(find.text('m40')).dy;

      // The pager grows the window, the fallback jump lays out, then the
      // retry jump lays out.
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // The 40 prepended rows total more than the viewport + cache, so the
      // keyed row is not built on the first restore and the extent-delta
      // fallback runs; the retry then re-anchors exactly.
      expect(
        fallbacks,
        greaterThan(0),
        reason: 'the huge prepend must exercise the extent-delta fallback',
      );
      expect(find.text('m40'), findsOneWidget);
      final after = tester.getTopLeft(find.text('m40')).dy;
      expect(after, moreOrLessEquals(before, epsilon: 1));
    },
  );

  testWidgets(
    'streaming tokens keep an at-bottom user pinned to the newest content',
    (tester) async {
      await pumpSession(tester, List.generate(20, (i) => _msg('m$i')));

      final position = transcriptPosition(tester);
      expect(
        position.pixels,
        moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
        reason: 'precondition: the user is at the bottom',
      );

      // Start a live run: a streaming assistant message mutates IN PLACE, so
      // the folded window key/count never changes even though the rendered
      // height grows every token.
      final app = AppState.I;
      final live = _msg('', role: 'assistant', thinking: true);
      app.activeSession!.messages.add(live);
      AgentService.I.setActiveRunForTest(app.activeSession!.id, 'run-live');
      app.refresh();
      await tester.pump();

      for (var i = 0; i < 40; i++) {
        // Grow the bubble by a line per token so the rendered height — not
        // just the key/count — changes every frame.
        live.content = '${live.content}token $i\n';
        app.refresh();
        await tester.pump();
      }

      // The newest token is on screen and the viewport is pinned to the
      // bottom despite the tip's key/count being unchanged.
      expect(find.textContaining('token 39'), findsOneWidget);
      expect(
        position.pixels,
        moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
        reason: 'an at-bottom user must keep following a live in-place stream',
      );

      AgentService.I.setActiveRunForTest(app.activeSession!.id, null);
    },
  );

  testWidgets(
    'streaming tokens do not force-scroll a scrolled-up user',
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

      // A live run streams multiple tokens while the user reads history.
      final app = AppState.I;
      final live = _msg('', role: 'assistant', thinking: true);
      app.activeSession!.messages.add(live);
      AgentService.I.setActiveRunForTest(app.activeSession!.id, 'run-live');
      app.refresh();
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        live.content = '${live.content}token $i\n';
        app.refresh();
        await tester.pump();
      }

      expect(
        position.pixels,
        moreOrLessEquals(scrolledUp, epsilon: 1),
        reason: 'a streaming append must not yank a scrolled-up user to the '
            'bottom',
      );

      AgentService.I.setActiveRunForTest(app.activeSession!.id, null);
    },
  );

  testWidgets('a new tip item keeps an at-bottom user pinned', (tester) async {
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
