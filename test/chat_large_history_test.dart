import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/transcript_model.dart';

Message _msg(
  String content, {
  String role = 'user',
  MsgKind kind = MsgKind.text,
  bool thinking = false,
}) => Message(role: role, kind: kind, content: content, thinking: thinking);

Message _tool(String content) =>
    _msg(content, role: 'assistant', kind: MsgKind.tool);

Message _answer(String content) =>
    _msg(content, role: 'assistant', kind: MsgKind.text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('windowForBounded', () {
    setUp(resetTranscriptFoldStats);

    test('folds only a bounded tail and reports the hidden message count', () {
      final messages = List.generate(5000, (i) => _msg('m$i'));
      final w = windowForBounded(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      expect(w.visible.length, 40);
      expect((w.visible.last as SingleItem).m.content, 'm4999');
      expect((w.visible.first as SingleItem).m.content, 'm4960');
      expect(w.hasEarlier, isTrue);
      expect(w.hiddenMessages, 4960);
      // The fold touched only the tail, not the whole history.
      expect(transcriptFoldedMessages, lessThan(1000));
    });

    test('visible matches the tail of the full fold', () {
      final messages = List.generate(500, (i) => _msg('m$i'));
      final full = foldMessages(messages, showReasoning: false);
      final w = windowForBounded(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      expect(w.visible.length, 40);
      for (var i = 0; i < 40; i++) {
        final expected = full[full.length - 40 + i];
        final actual = w.visible[i];
        expect(actual.runtimeType, expected.runtimeType);
        if (actual is SingleItem && expected is SingleItem) {
          expect(actual.m.content, expected.m.content);
          expect(actual.index, expected.index);
        }
      }
    });

    test('does not split a foldable run that straddles the window start', () {
      final messages = <Message>[
        _msg('u0'),
        _tool('a'),
        _tool('b'),
        _tool('c'),
        _answer('done'),
      ];
      final w = windowForBounded(
        messages,
        pageSize: 2,
        visibleCount: 2,
        showReasoning: false,
      );
      // The tail is [folded a,b,c] + [answer]; the run is not split.
      expect(w.visible.length, 2);
      expect(w.visible.first, isA<FoldedGroup>());
      final group = w.visible.first as FoldedGroup;
      expect(group.msgs.map((m) => m.content), ['a', 'b', 'c']);
      expect(group.indices, [1, 2, 3]);
      expect(w.visible.last, isA<SingleItem>());
      expect((w.visible.last as SingleItem).m.content, 'done');
    });

    test('returns everything when the window covers the history', () {
      final messages = List.generate(10, (i) => _msg('m$i'));
      final w = windowForBounded(
        messages,
        pageSize: 40,
        visibleCount: 40,
        showReasoning: false,
      );
      expect(w.visible.length, 10);
      expect(w.hasEarlier, isFalse);
      expect(w.hiddenMessages, 0);
    });
  });

  group('ChatScreen large history', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AgentNotificationService.I.resetForTest();
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      app.seenWelcomeVersion = AppState.welcomeVersion;
      AgentService.I.debugPauseScheduleTimerForTest(true);
      app.sessions.clear();
      app.activeSessionId = null;
      resetTranscriptFoldStats();
    });

    tearDown(() {
      AgentNotificationService.I.resetForTest();
      AppState.resetTestInstance();
    });

    Future<void> pumpChat(WidgetTester tester, int count) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final app = AppState.I;
      final session = ChatSession(
        id: 'large-history',
        title: 'Large history',
        model: 'm',
        mode: 'auto',
        messages: List.generate(count, (i) => _msg('m$i')),
      );
      app.sessions.add(session);
      app.activeSessionId = session.id;

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('opens a 5,000-message session with a bounded fold', (
      tester,
    ) async {
      await pumpChat(tester, 5000);

      // The tail of the history is what renders.
      expect(find.text('m4999'), findsOneWidget);
      // Bounded fold: nowhere near the 5,000 messages in the session.
      expect(transcriptFoldedMessages, lessThan(1000));
      expect(transcriptFoldInvocations, lessThan(10));

      // Scrolling to the top reveals the earlier-history affordance, proving
      // the window is a tail slice rather than the whole session.
      await tester.drag(
        find.byKey(const ValueKey('chat-transcript-list')),
        const Offset(0, 5000),
      );
      await tester.pump();
      expect(find.textContaining('earlier'), findsOneWidget);
    });

    testWidgets('streaming token appends do not re-fold the transcript', (
      tester,
    ) async {
      await pumpChat(tester, 5000);

      final app = AppState.I;
      final session = app.activeSession!;
      // Simulate the live streaming bubble appearing.
      final live = Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        content: '',
        thinking: true,
      );
      session.messages.add(live);
      app.refresh();
      await tester.pump();
      live.thinking = false;
      app.refresh();
      await tester.pump();

      final baseline = transcriptFoldedMessages;
      final baselineCalls = transcriptFoldInvocations;
      for (var i = 0; i < 60; i++) {
        live.content = 'token $i ';
        app.refresh();
        await tester.pump();
      }
      expect(
        transcriptFoldedMessages,
        baseline,
        reason: 'streaming tokens must not re-fold the transcript window',
      );
      expect(transcriptFoldInvocations, baselineCalls);
    });
  });
}
