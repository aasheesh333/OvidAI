import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

/// Issue 5: the queued-message box used to pin every row to 48px
/// (`_QueueAction`'s fixed-height SizedBox) and truncate text to 2 lines.
/// Rows now size to their text, and the rows region scrolls inside ~38%
/// of the available height so a long queue cannot push the composer
/// off-screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  int sessionSeq = 0;

  Future<String> pumpChatWithQueue(
    WidgetTester tester,
    List<String> queued,
  ) async {
    sessionSeq++;
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState.I;
    final session = ChatSession(
      id: 'queue-dock-session-$sessionSeq',
      title: 'Queue dock',
      model: 'm',
      mode: 'auto',
      messages: [Message(role: 'user', content: 'hi')],
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    for (final text in queued) {
      AgentService.I.enqueueMessage(text, sessionId: session.id);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return session.id;
  }

  testWidgets('queue rows are not pinned to a fixed height', (tester) async {
    const longText =
        'first queued message with enough words to wrap onto several lines '
        'when the row is allowed to grow instead of being truncated';
    await pumpChatWithQueue(tester, [longText, 'second']);

    // The row text renders with no line cap — rows grow with content.
    final textWidget = tester.widget<Text>(find.text(longText));
    expect(
      textWidget.maxLines,
      isNull,
      reason: 'queue text must not be truncated to 2 lines',
    );

    // The row actions keep a 48dp-wide tap target but no fixed height.
    final actionBox = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byTooltip(
              'Quick send: stop current run and send this now',
            ),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(actionBox.width, 48);
    expect(
      actionBox.height,
      isNull,
      reason: '_QueueAction must not pin the row height',
    );
  });

  testWidgets('long queue scrolls inside a capped region', (tester) async {
    final queued = List.generate(
      12,
      (i) => 'queued message number $i with a fairly long body of text',
    );
    await pumpChatWithQueue(tester, queued);

    // Header still renders.
    expect(find.text('12 queued messages'), findsOneWidget);

    // The rows region is scrollable...
    final scroller = find.descendant(
      of: find.text('12 queued messages'),
      matching: find.byType(SingleChildScrollView),
    );
    // ...find it via the queued text instead: the rows must live under a
    // SingleChildScrollView.
    final rowsScroller = find.ancestor(
      of: find.text(queued.first),
      matching: find.byType(SingleChildScrollView),
    );
    expect(rowsScroller, findsOneWidget);
    expect(scroller, findsNothing);

    // ...and that scrollable is capped to a fraction of the 900px viewport.
    final caps = find
        .ancestor(
          of: find.text(queued.first),
          matching: find.byType(ConstrainedBox),
        )
        .evaluate()
        .map((e) => e.widget as ConstrainedBox)
        .where((b) => b.constraints.maxHeight.isFinite)
        .toList();
    expect(caps, isNotEmpty, reason: 'rows need a finite maxHeight cap');
    for (final cap in caps) {
      expect(
        cap.constraints.maxHeight,
        lessThan(900),
        reason: 'cap must be a fraction of the viewport, not the full height',
      );
      expect(cap.constraints.maxHeight, greaterThan(0));
    }
  });
}
