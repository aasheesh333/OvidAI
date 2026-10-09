import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatSession session;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.skillCatalogInputsForTest = (_) async => SkillCatalogInputs();
    session = ChatSession(
      id: 'dock-attachment-regression',
      title: 'Chat',
      model: 'm',
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    AgentService.I.pendingApproval = null;
  });

  tearDown(() {
    AgentService.I.pendingApproval = null;
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    AgentNotificationService.I.resetForTest();
    AgentService.skillCatalogInputsForTest = null;
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(700, 900),
    double scale = 1,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  ApprovalRequest questions(int count) => ApprovalRequest(
    tool: 'ask_user_question',
    summary: 'Choose',
    detail: '',
    questions: [
      for (var i = 0; i < count; i++)
        UserQuestion(
          id: 'q$i',
          question: 'Question $i?',
          options: [QuestionOption(label: 'Choice $i')],
        ),
    ],
  );

  testWidgets('short questions show answer action without scrolling', (
    tester,
  ) async {
    AgentService.I.pendingApproval = questions(2);
    await pumpChat(tester);
    expect(find.text('Question 0?').hitTestable(), findsOneWidget);
    expect(find.text('Question 1?').hitTestable(), findsOneWidget);
    expect(find.text('Answer').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'three queued messages use available height without clipping actions',
    (tester) async {
      for (var i = 0; i < 3; i++) {
        AgentService.I.enqueueMessage(
          'Queued message $i',
          sessionId: session.id,
        );
      }
      await pumpChat(tester);
      expect(find.text('Queued message 2').hitTestable(), findsOneWidget);
      expect(
        find.byTooltip('Edit in composer').hitTestable(),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final switchSession in [false, true]) {
    testWidgets(
      'queue acceptance preserves ${switchSession ? 'another session files' : 'files staged during notification'}',
      (tester) async {
        final agent = AgentService.I;
        final app = AppState.I;
        final other = ChatSession(id: 'next-draft', title: 'Next', model: 'm');
        app.sessions.add(other);
        agent.runBucketForTest(session.id).activeRunId = 'busy';
        addTearDown(
          () => agent.runBucketForTest(session.id).activeRunId = null,
        );
        agent.pendingAttachments.add((
          name: 'sent.txt',
          path: '/sent.txt',
          size: 1,
        ));
        final originalPending = agent.pendingAttachments;
        await pumpChat(tester);
        final composer = find.byKey(const ValueKey('chat-composer'));
        await tester.enterText(composer, 'Queue files');
        await tester.pump();
        var notified = false;
        void stageNextDraft() {
          if (notified || agent.queuedMessagesFor(session.id).isEmpty) return;
          notified = true;
          if (switchSession) app.selectSession(other.id);
          agent.pendingAttachments.add((
            name: 'next.txt',
            path: '/next.txt',
            size: 2,
          ));
        }

        agent.addListener(stageNextDraft);
        await tester.tap(find.byTooltip('Add to queue'));
        agent.removeListener(stageNextDraft);
        await tester.pump();
        expect(agent.queuedMessagesFor(session.id), ['Queue files']);
        expect(agent.pendingAttachments.map((a) => a.path), ['/next.txt']);
        expect(originalPending.any((a) => a.path == '/sent.txt'), isFalse);
        expect(tester.takeException(), isNull);
        app.activeSessionId = session.id;
        agent.clearQueueForTest();
        agent.runBucketForTest(session.id).activeRunId = null;
        AgentNotificationService.I.resetForTest();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('refused queue admission retains the draft and attachments', (
    tester,
  ) async {
    final agent = AgentService.I;
    final run = agent.runBucketForTest(session.id)..activeRunId = 'busy';
    agent.pendingAttachments.add((
      name: 'keep.txt',
      path: '/keep.txt',
      size: 1,
    ));
    await pumpChat(tester);
    final composer = find.byKey(const ValueKey('chat-composer'));
    await tester.enterText(composer, 'Keep draft');
    await tester.pump();
    // Exercise the service's real stale-generation admission refusal.
    agent.setRunCtxForTest(run, session, run.runEpoch - 1);
    await tester.tap(find.byTooltip('Add to queue'));
    agent.clearRunCtxForTest();
    await tester.pump();
    expect(agent.queuedMessagesFor(session.id), isEmpty);
    expect(agent.pendingAttachments.single.path, '/keep.txt');
    expect(tester.widget<TextField>(composer).controller!.text, 'Keep draft');
    run.activeRunId = null;
    AgentNotificationService.I.resetForTest();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'accepted direct submit keeps its attachment after cancellation',
    (tester) async {
      final agent = AgentService.I;
      final app = AppState.I;
      final provider = ProviderConfig(
        id: 'direct-submit-fixture',
        name: 'Direct submit fixture',
        description: 'Provider used by the direct-submit regression.',
        baseUrl: 'https://example.test',
        apiKey: 'test-key',
        models: ['m'],
      );
      app.providers.add(provider);
      session.providerId = provider.id;

      final requestStarted = Completer<void>();
      final releaseRequest = Completer<Map<String, dynamic>?>();
      AgentService.llmOnceForTest = (p, messages, running, tools) async {
        requestStarted.complete();
        return releaseRequest.future;
      };
      addTearDown(() {
        AgentService.llmOnceForTest = null;
        if (!releaseRequest.isCompleted) {
          releaseRequest.complete({
            'role': 'assistant',
            'content': 'cancelled',
            'finish_reason': 'stop',
          });
        }
      });

      agent.pendingAttachments.add((
        name: 'accepted.txt',
        path: '/accepted.txt',
        size: 1,
      ));
      await pumpChat(tester);
      final composer = find.byKey(const ValueKey('chat-composer'));
      await tester.enterText(composer, 'Send this');
      await tester.pump();

      await tester.tap(find.byTooltip('Send'));
      for (var i = 0; i < 100 && !requestStarted.isCompleted; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(requestStarted.isCompleted, isTrue,
          reason: 'The admitted run must reach the mocked LLM request');
      expect(session.messages.last.content, 'Send this');
      expect(session.messages.last.attachments.single.path, '/accepted.txt');
      expect(agent.pendingAttachments, isEmpty);

      agent.stopRequested(sessionId: session.id);
      releaseRequest.complete({
        'role': 'assistant',
        'content': 'cancelled',
        'finish_reason': 'stop',
      });
      await tester.pump();

      expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
      expect(session.messages.last.attachments.single.path, '/accepted.txt');
      expect(agent.pendingAttachments, isEmpty);
      expect(tester.takeException(), isNull);

      // Drain the run's unwind and the 600ms notification debounce its
      // `think` emissions armed (AgentNotificationService.agentWorking).
      // Binding invariants run BEFORE tearDowns, so a fake Timer left by
      // the cancelled run fails the test even though tearDown resets the
      // service. The run-end idle pass cancels the debounce; if the run
      // is still unwinding, elapsing past the debounce window fires it
      // instead (its platform invoke is swallowed in tests).
      for (var i = 0; i < 10 && agent.busyFor(session.id); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 700));
    },
  );

  for (final size in [const Size(320, 900), const Size(1400, 900)]) {
    testWidgets(
      'long filenames stay compact and last of 20 files is removable at $size',
      (tester) async {
        final names = [
          for (var i = 0; i < 20; i++) '${'long-name-' * 20}$i.txt',
        ];
        AgentService.I.pendingAttachments.addAll([
          for (var i = 0; i < 20; i++)
            (name: names[i], path: '/workspace/$i.txt', size: 20000),
        ]);
        await pumpChat(tester, size: size);
        final firstName = find.text(names.first);
        final remove = find.byTooltip('Remove attachment ${names.first}');
        // File identity is bounded independently of the width of the chat pane.
        expect(tester.getSize(firstName).width, lessThanOrEqualTo(200));
        expect(tester.getSize(remove).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
        final scroll = find.byKey(
          const ValueKey('composer-attachments-scroll'),
        );
        expect(tester.getSize(scroll).height, lessThanOrEqualTo(132));
        final scrollable = find.descendant(
          of: scroll,
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byTooltip('Remove attachment ${names.last}'),
          100,
          scrollable: scrollable,
        );
        await tester.tap(find.byTooltip('Remove attachment ${names.last}'));
        await tester.pump();
        expect(AgentService.I.pendingAttachments, hasLength(19));
        expect(
          AgentService.I.pendingAttachments.any(
            (a) => a.path == '/workspace/19.txt',
          ),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'long questions remain scrollable with a short enlarged viewport',
    (tester) async {
      AgentService.I.pendingApproval = questions(12);
      await pumpChat(tester, size: const Size(400, 500), scale: 1.5);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('chat-composer-card')).hitTestable(),
        findsOneWidget,
      );
      // One dock scroll surface must reach the final question and its action.
      final dockScroll = find
          .ancestor(
            of: find.text('Questions from the AI'),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Answer'),
        150,
        scrollable: dockScroll,
      );
      expect(find.text('Answer').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'questions and 20 attachments keep composer reachable above keyboard',
    (tester) async {
      AgentService.I.pendingApproval = questions(12);
      AgentService.I.pendingAttachments.addAll([
        for (var i = 0; i < 20; i++)
          (name: 'attachment-$i.txt', path: '/$i.txt', size: 1),
      ]);
      await pumpChat(
        tester,
        size: const Size(360, 640),
        scale: 2,
        keyboard: 280,
      );
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('chat-composer-card'));
      expect(tester.getRect(card).bottom, lessThanOrEqualTo(360));
      expect(find.byTooltip('Attach').hitTestable(), findsOneWidget);
    },
  );
}
