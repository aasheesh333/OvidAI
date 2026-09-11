import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

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

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final app = AppState.I;
    final session = ChatSession(
      id: 'disclosure-session',
      title: 'Disclosure',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', content: 'hi'),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          content: 'REASONING_BODY_TOKEN',
        ),
        Message(role: 'assistant', kind: MsgKind.text, content: 'answer one'),
        Message(role: 'user', content: 'go'),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'search',
          toolTitle: 'Search docs',
          toolSummary: 'query terms',
          toolDetail: 'DETAIL_BODY_TOKEN',
          toolState: 'ok',
        ),
        Message(role: 'assistant', kind: MsgKind.text, content: 'answer two'),
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

  const reasoningRoot = ValueKey('chat-reasoning-disclosure');
  const reasoningSummary = ValueKey('chat-reasoning-summary');
  const reasoningBody = ValueKey('chat-reasoning-body');
  const reasoningTitle = ValueKey('chat-reasoning-title');
  const reasoningChevron = ValueKey('chat-reasoning-chevron');
  const toolRoot = ValueKey('chat-tool-disclosure');
  const toolSummary = ValueKey('chat-tool-summary');
  const toolBody = ValueKey('chat-tool-body');
  const toolTitle = ValueKey('chat-tool-title');
  const toolChevron = ValueKey('chat-tool-chevron');

  testWidgets('reasoning and tool disclosures are collapsed by default', (
    tester,
  ) async {
    await pumpChat(tester);

    expect(find.byKey(reasoningRoot), findsOneWidget);
    expect(find.byKey(toolRoot), findsOneWidget);

    // The collapsed summaries are visible...
    expect(find.byKey(reasoningSummary), findsOneWidget);
    expect(find.byKey(toolSummary), findsOneWidget);
    // ...and the bodies are not.
    expect(find.byKey(reasoningBody), findsNothing);
    expect(find.byKey(toolBody), findsNothing);

    // The chevrons point at rest.
    expect(
      tester.widget<AnimatedRotation>(find.byKey(reasoningChevron)).turns,
      0.0,
    );
    expect(
      tester.widget<AnimatedRotation>(find.byKey(toolChevron)).turns,
      0.0,
    );
  });

  testWidgets('collapsed summaries carry no heavy border or background', (
    tester,
  ) async {
    await pumpChat(tester);

    for (final key in <ValueKey<String>>[reasoningRoot, toolRoot]) {
      final container = tester.widget<Container>(find.byKey(key));
      final decoration = container.decoration;
      if (decoration is BoxDecoration) {
        expect(
          decoration.border,
          isNull,
          reason: 'collapsed summary must not draw a border',
        );
        expect(
          decoration.color,
          anyOf(isNull, const Color(0x00000000)),
          reason: 'collapsed summary must not paint a background',
        );
      }
    }
  });

  testWidgets('collapsed summary titles truncate to one line', (tester) async {
    await pumpChat(tester);

    for (final key in <ValueKey<String>>[reasoningTitle, toolTitle]) {
      final text = tester.widget<Text>(find.byKey(key));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
  });

  testWidgets('reasoning disclosure expands on tap and collapses again', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byKey(reasoningSummary));
    await tester.pumpAndSettle();
    expect(find.byKey(reasoningBody), findsOneWidget);
    expect(
      tester.widget<AnimatedRotation>(find.byKey(reasoningChevron)).turns,
      0.5,
    );

    await tester.tap(find.byKey(reasoningSummary));
    await tester.pumpAndSettle();
    expect(find.byKey(reasoningBody), findsNothing);
    expect(
      tester.widget<AnimatedRotation>(find.byKey(reasoningChevron)).turns,
      0.0,
    );
  });

  testWidgets('tool disclosure expands on tap and collapses again', (
    tester,
  ) async {
    await pumpChat(tester);

    await tester.tap(find.byKey(toolSummary));
    await tester.pumpAndSettle();
    expect(find.byKey(toolBody), findsOneWidget);
    expect(
      tester.widget<AnimatedRotation>(find.byKey(toolChevron)).turns,
      0.5,
    );

    await tester.tap(find.byKey(toolSummary));
    await tester.pumpAndSettle();
    expect(find.byKey(toolBody), findsNothing);
    expect(
      tester.widget<AnimatedRotation>(find.byKey(toolChevron)).turns,
      0.0,
    );
  });
}
