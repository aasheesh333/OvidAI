// PR-3b: the chat screen never silently loses typed text, history, queued
// messages or goals.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = find.byKey(const ValueKey('chat-composer'));
  late ChatSession a;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.providers
      ..clear()
      ..add(
        ProviderConfig(
          id: 'p',
          name: 'Provider',
          description: '',
          baseUrl: 'https://example.test/v1',
          apiKey: 'key',
          models: ['m'],
        ),
      );
    a = ChatSession(
      id: 'safety-a',
      title: 'A',
      model: 'm',
      providerId: 'p',
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    app.sessions
      ..clear()
      ..add(a);
    app.activeSessionId = a.id;
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    AgentService.I.pendingApproval = null;
  });

  tearDown(() {
    AgentService.llmOnceForTest = null;
    AgentService.I.runBucketForTest(a.id).activeRunId = null;
    AgentService.I.pendingApproval = null;
    AgentService.I.clearQueueForTest();
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
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

  Future<void> expireSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('draft survives recreating ChatScreen after process death', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.enterText(composer, 'A long prompt I typed carefully');
    // Debounced write.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox());
    // Process death: every in-memory draft is gone, preferences remain.
    ComposerDraftStore.I.resetForTest();
    expect(
      (await SharedPreferences.getInstance()).getString(
        ComposerDraftStore.prefsKey,
      ),
      contains('A long prompt I typed carefully'),
    );
    await pumpChat(tester);
    await tester.pump();
    expect(draft(tester), 'A long prompt I typed carefully');
  });

  testWidgets('Regenerate removes tool and reasoning rows of the first try', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'user', content: 'Question'),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'bash',
          content: 'first attempt tool output',
          toolState: 'ok',
        ),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          content: 'first attempt reasoning',
        ),
        Message(role: 'assistant', content: 'First answer'),
      ]);
    List<Map<String, dynamic>>? sent;
    AgentService.llmOnceForTest = (p, msgs, session, includeTools) async {
      sent ??= List.of(msgs);
      AgentService.I.streamToBubbleForTest(session, 'Second answer');
      return {
        'role': 'assistant',
        'content': 'Second answer',
        'finish_reason': 'stop',
      };
    };
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Regenerate'));
    await tester.pump();
    // Truncated to [user] before the new attempt starts.
    expect(a.messages.first.content, 'Question');
    expect(
      a.messages.where(
        (m) =>
            m.content.contains('first attempt') || m.content == 'First answer',
      ),
      isEmpty,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      a.messages.where((m) => m.content.contains('first attempt')),
      isEmpty,
    );
    expect(a.messages.where((m) => m.role == 'user'), hasLength(1));
    if (sent != null) {
      expect(sent.toString(), isNot(contains('first attempt')));
    }
  });

  testWidgets('Regenerate explains why it cannot run', (tester) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'user', content: 'Question'),
        Message(role: 'assistant', content: 'Answer'),
      ]);
    AppState.I.providers.single.models = ['other-model'];
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Regenerate'));
    await tester.pump();
    expect(find.textContaining('no longer available'), findsOneWidget);
    expect(a.messages, hasLength(2));
    await expireSnackBars(tester);
  });

  testWidgets('edit dialog states how many later messages it removes', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'user', content: 'First'),
        Message(role: 'assistant', content: 'One'),
        Message(role: 'user', content: 'Second'),
        Message(role: 'assistant', content: 'Two'),
      ]);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit & resend').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This removes the 3 messages after it'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Edit & remove 3'));
    await tester.pumpAndSettle();
    expect(a.messages, isEmpty);
    expect(draft(tester), 'First');

    // Undo restores the transcript and takes the staged edit back.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(a.messages.map((m) => m.content), ['First', 'One', 'Second', 'Two']);
    expect(draft(tester), isEmpty);
    await expireSnackBars(tester);
  });

  testWidgets('Delete message (formerly Revert) offers Undo', (tester) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'assistant', content: 'Hello'),
        Message(role: 'user', content: 'Oops'),
      ]);
    await pumpChat(tester);
    expect(find.byTooltip('Revert'), findsNothing);
    await tester.tap(find.byTooltip('Delete message'));
    await tester.pumpAndSettle();
    expect(a.messages.map((m) => m.content), ['Hello']);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(a.messages.map((m) => m.content), ['Hello', 'Oops']);
    await expireSnackBars(tester);
  });

  testWidgets('pending approval disables Attach and the mic', (tester) async {
    AgentService.I.pendingApproval = ApprovalRequest(
      tool: 'bash',
      summary: 'Run',
      detail: 'ls',
    );
    await pumpChat(tester);
    tester.widget<TextField>(composer).controller!.text = 'My draft';
    await tester.pump();
    final attach = tester.widget<AetherGhostButton>(
      find.byWidgetPredicate(
        (w) => w is AetherGhostButton && w.label == 'Attach',
      ),
    );
    expect(attach.onPressed, isNull);
    final mic = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.mic_none),
    );
    expect(mic.onPressed, isNull);
    expect(draft(tester), 'My draft');
  });

  testWidgets('refused Generate image keeps the draft', (tester) async {
    a.messages.clear();
    // No usable model: the send path refuses with a snack bar.
    AppState.I.providers.single.models = ['other-model'];
    await pumpChat(tester);
    await tester.enterText(composer, 'My unrelated draft');
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate image'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'a mountain',
    );
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(draft(tester), 'My unrelated draft');
    expect(a.messages, isEmpty);
    await expireSnackBars(tester);
  });

  testWidgets('queue Clear all can be undone with the same ids', (
    tester,
  ) async {
    final run = AgentService.I.runBucketForTest(a.id);
    run.activeRunId = 'busy';
    for (final text in ['one', 'two', 'three']) {
      AgentService.I.enqueueMessage(text, sessionId: a.id);
    }
    final ids = AgentService.I.queuedMessageIdsFor(a.id);
    expect(ids, hasLength(3));
    await pumpChat(tester);
    await tester.tap(find.text('Clear all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(AgentService.I.queuedMessagesFor(a.id), isEmpty);
    expect(find.text('Cleared 3 queued messages'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(AgentService.I.queuedMessagesFor(a.id), ['one', 'two', 'three']);
    expect(AgentService.I.queuedMessageIdsFor(a.id), ids);
    await expireSnackBars(tester);
  });

  testWidgets('complete goal renders nothing; Clear removes the bar', (
    tester,
  ) async {
    a.goal = {'objective': 'Ship it', 'status': 'complete', 'round': 3};
    await pumpChat(tester);
    expect(find.text('Ship it'), findsNothing);

    a.goal = {'objective': 'Ship it', 'status': 'active', 'round': 1};
    AppState.I.refresh();
    await tester.pump();
    expect(find.text('Ship it'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear goal'));
    await tester.pumpAndSettle();
    expect(a.goal, isNull);
    expect(find.text('Ship it'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(a.goal?['objective'], 'Ship it');
    expect(find.text('Ship it'), findsOneWidget);
    await expireSnackBars(tester);
  });
}
