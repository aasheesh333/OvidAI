import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ChatSession session;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
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
    CloudAgentFacade.I.clearAttachment();
    CloudAgentFacade.I.clearQueueForTest();
    CloudAgentFacade.I.pendingApprovalForTest = null;
  });

  tearDown(() {
    CloudAgentFacade.I.setActiveRunForTest(session.id, null);
    CloudAgentFacade.I.pendingApprovalForTest = null;
    CloudAgentFacade.I.clearAttachment();
    CloudAgentFacade.I.clearQueueForTest();
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
    CloudAgentFacade.I.pendingApprovalForTest = questions(2);
    await pumpChat(tester);
    expect(find.text('Question 0?').hitTestable(), findsOneWidget);
    expect(find.text('Question 1?').hitTestable(), findsOneWidget);
    expect(find.text('Answer').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'three queued messages use available height without clipping actions',
    (tester) async {
      CloudAgentFacade.I.setActiveRunForTest(session.id, 'busy');
      for (var i = 0; i < 3; i++) {
        CloudAgentFacade.I.enqueueMessage(
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

  for (final size in [const Size(320, 900), const Size(1400, 900)]) {
    testWidgets(
      'long filenames stay compact and last of 20 files is removable at $size',
      (tester) async {
        final names = [
          for (var i = 0; i < 20; i++) '${'long-name-' * 20}$i.txt',
        ];
        for (var i = 0; i < 20; i++) {
          CloudAgentFacade.I.stageAttachmentForTest(
            session.id,
            name: names[i],
            path: '/workspace/$i.txt',
            size: 20000,
          );
        }
        await pumpChat(tester, size: size);
        // The name is shortened in the middle and keeps its extension.
        final firstName = find
            .descendant(
              of: find.byKey(const ValueKey('composer-attachments-scroll')),
              matching: find.textContaining('\u2026'),
            )
            .first;
        expect(tester.widget<Text>(firstName).data, endsWith('0.txt'));
        final remove = find.byTooltip('Remove attachment ${names.first}');
        // File identity is bounded independently of the width of the chat pane.
        expect(tester.getSize(firstName).width, lessThanOrEqualTo(200));
        expect(tester.getSize(remove).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
        final scroll = find.byKey(
          const ValueKey('composer-attachments-scroll'),
        );
        expect(tester.getSize(scroll).height, lessThanOrEqualTo(72));
        final scrollable = find.descendant(
          of: scroll,
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(
          find.byTooltip('Remove attachment ${names.last}'),
          100,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Remove attachment ${names.last}'));
        await tester.pump();
        expect(CloudAgentFacade.I.pendingAttachments, hasLength(19));
        expect(
          CloudAgentFacade.I.pendingAttachments.any(
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
      CloudAgentFacade.I.pendingApprovalForTest = questions(12);
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
      CloudAgentFacade.I.pendingApprovalForTest = questions(12);
      for (var i = 0; i < 20; i++) {
        CloudAgentFacade.I.stageAttachmentForTest(
          session.id,
          name: 'attachment-$i.txt',
          path: '/$i.txt',
          size: 1,
        );
      }
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
