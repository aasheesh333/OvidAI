import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat/docks.dart';
import 'package:ovid_ai/ui/chat_layout.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

/// Render contract for the v2-03 chat split: the screen assembled from
/// `chat/transcript.dart`, `chat/composer.dart`, `chat/docks.dart` and
/// `chat/sheets.dart` behaves exactly like the old god-file at phone and
/// desktop sizes — transcript rows, composer Send/Queue/Stop, the two-dock
/// cap with the activity overflow, and the consolidated metrics sheet.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final composer = find.byKey(const ValueKey('chat-composer'));
  late ChatSession session;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    // The reminder tick runs forever; pause it so widget teardown is clean.
    AgentService.I.debugPauseScheduleTimerForTest(true);
    session = ChatSession(
      id: 'split-session',
      title: 'Split',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', content: 'Build a chat split'),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          content: 'Thinking about the split',
        ),
        Message(role: 'assistant', content: 'First answer'),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'read_file',
          toolTitle: 'Read',
          toolSummary: 'lib/ui/chat_screen.dart',
          toolDetail: 'file contents',
          toolState: 'ok',
        ),
        Message(role: 'assistant', content: 'Second answer'),
      ],
    );
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    AgentService.I.pendingApproval = null;
    // Run buckets persist across tests on the service singleton; reset the
    // fake busy/stop state each test installs.
    final bucket = AgentService.I.runBucketForTest(session.id);
    bucket.activeRunId = null;
    bucket.cancelRequested = false;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    required Size physicalSize,
    double devicePixelRatio = 1.0,
  }) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  String draft(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!.text;

  testWidgets('360x640 @2x: transcript rows and composer render without '
      'overflow', (tester) async {
    await pumpChat(
      tester,
      physicalSize: const Size(720, 1280),
      devicePixelRatio: 2.0,
    );

    // Transcript rows: user bubble, reasoning disclosure, tool card, answers.
    expect(find.byKey(const ValueKey('chat-user-bubble-0')), findsOneWidget);
    expect(find.text('Build a chat split'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-reasoning-summary')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('chat-tool-summary')), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Second answer'), findsOneWidget);

    // Composer renders on the shared axis at the narrow size.
    expect(find.byKey(const ValueKey('chat-composer-card')), findsOneWidget);
    expect(composer, findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('1024 wide: transcript column and composer share the axis '
      'without overflow', (tester) async {
    await pumpChat(tester, physicalSize: const Size(1024, 800));
    const layout = ChatLayout(viewportWidth: 1024);

    final column = find.byKey(const ValueKey('chat-transcript-column'));
    expect(column, findsOneWidget);
    final columnRect = tester.getRect(column);
    expect(
      columnRect.width,
      moreOrLessEquals(layout.contentWidth, epsilon: 0.5),
    );
    expect(columnRect.center.dx, moreOrLessEquals(512, epsilon: 0.5));

    final card = find.byKey(const ValueKey('chat-composer-card'));
    expect(
      tester.getSize(card).width,
      moreOrLessEquals(layout.composerWidth, epsilon: 0.5),
    );

    final bubble = find.byKey(const ValueKey('chat-user-bubble-0'));
    expect(
      tester.getSize(bubble).width,
      lessThanOrEqualTo(layout.userBubbleMaxWidth + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer Send runs a slash command and clears the draft', (
    tester,
  ) async {
    CommandService.I.register(
      AgentCommand(
        name: 'splitrun',
        description: 'Run',
        handler: (_) async => const CommandResult(),
      ),
    );
    await pumpChat(tester, physicalSize: const Size(700, 1200));
    await tester.enterText(composer, '/splitrun');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(draft(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer Queue while busy stages the draft instead of '
      'sending', (tester) async {
    AgentService.I.runBucketForTest(session.id).activeRunId = 'split-busy';
    await pumpChat(tester, physicalSize: const Size(700, 1200));
    await tester.enterText(composer, 'Queued work');
    await tester.pump();
    await tester.tap(find.byTooltip('Add to queue'));
    await tester.pump();
    expect(AgentService.I.queuedMessagesFor(session.id), ['Queued work']);
    expect(draft(tester), isEmpty);
    // The busy session must not have appended a user message.
    expect(session.messages.where((m) => m.role == 'user'), hasLength(1));
    expect(tester.takeException(), isNull);
    // Release the fake run so no run watchdog timer outlives the test, and
    // reset the notification debounce the live bucket armed (the invariant
    // check runs before tearDown).
    AgentService.I.runBucketForTest(session.id).activeRunId = null;
    AgentNotificationService.I.resetForTest();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('composer Stop latches the session run', (tester) async {
    AgentService.I.runBucketForTest(session.id).activeRunId = 'split-busy';
    await pumpChat(tester, physicalSize: const Size(700, 1200));
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pump();
    expect(
      AgentService.I.runBucketForTest(session.id).cancelRequested,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('docks cap at two and overflow into the activity dock', (
    tester,
  ) async {
    session.goal = {'objective': 'Ship the split', 'status': 'active', 'round': 2};
    session.todos.addAll([
      {'status': 'in_progress', 'content': 'Task A'},
      {'status': 'pending', 'content': 'Task B'},
    ]);
    session.analytics.turns = 3;
    session.analytics.inputTokens = 8200;
    session.analytics.outputTokens = 1400;
    AgentService.I.enqueueMessage('Queued one', sessionId: session.id);

    await pumpChat(tester, physicalSize: const Size(700, 1200));

    // Four docks active: the queue stays pinned, the goal fills the one
    // free slot, todo + stats fold into the single activity dock.
    expect(find.byType(ChatDockCard), findsWidgets);
    expect(find.text('Ship the split'), findsOneWidget);
    expect(find.text('1 queued message'), findsOneWidget);
    expect(find.byTooltip('Edit in composer'), findsOneWidget);
    expect(find.text('Activity · 2'), findsOneWidget);
    expect(find.text('Tasks · 0/2 done'), findsNothing);
    expect(find.textContaining('3 turns'), findsNothing);
    expect(tester.takeException(), isNull);

    // Expanding the activity dock reveals the overflowed docks.
    await tester.tap(find.byKey(const ValueKey('chat-activity-dock-toggle')));
    await tester.pump();
    expect(find.text('Tasks · 0/2 done'), findsOneWidget);
    expect(find.textContaining('3 turns'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two or fewer docks render uncapped', (tester) async {
    session.goal = {'objective': 'Ship the split', 'status': 'active', 'round': 2};
    await pumpChat(tester, physicalSize: const Size(700, 1200));
    expect(find.text('Ship the split'), findsOneWidget);
    expect(find.textContaining('Activity ·'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('metrics sheet opens from the stats line', (tester) async {
    session.analytics.turns = 3;
    session.analytics.inputTokens = 8200;
    session.analytics.outputTokens = 1400;
    await pumpChat(tester, physicalSize: const Size(700, 1200));
    expect(find.textContaining('3 turns'), findsOneWidget);

    await tester.tap(find.textContaining('3 turns'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The consolidated sheet: context breakdown + turn analytics in one.
    expect(find.text('Session metrics'), findsOneWidget);
    expect(find.text('Context'), findsWidgets);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Input'), findsOneWidget);
    expect(find.text('8.2K tok'), findsWidgets);
    expect(
      find.text('Compaction triggers automatically near the window limit.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    Navigator.of(tester.element(find.text('Session metrics'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Session metrics'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
