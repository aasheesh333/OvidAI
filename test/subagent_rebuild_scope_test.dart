import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';

/// F-033: the subagent screen and its transcript ignore notifications that
/// do not concern the child session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(AppState.resetTestInstance);

  Future<ChatSession> pumpChild(WidgetTester tester) async {
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    final child = ChatSession(
      id: 'scope-child',
      title: 'Child agent',
      model: 'm',
      mode: 'auto',
      parentId: 'scope-parent',
      agentState: 'completed',
      agentContinuable: false,
      messages: [
        for (var i = 0; i < 20; i++)
          Message(role: i.isEven ? 'user' : 'assistant', content: 'row $i'),
      ],
    );
    app.sessions.addAll([
      ChatSession(
        id: 'scope-parent',
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      ),
      ChatSession(id: 'scope-other', title: 'Other', model: 'm', mode: 'auto'),
      child,
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: SubagentScreen(sessionId: child.id),
      ),
    );
    await tester.pump();
    return child;
  }

  testWidgets('50 notifies for another session rebuild no transcript', (
    tester,
  ) async {
    final child = await pumpChild(tester);
    ChatTranscript.debugBuildCount = 0;

    for (var i = 0; i < 50; i++) {
      AgentService.I.refreshNow();
      AgentService.I.debugTickLiveBubbleForTest('scope-other');
      await tester.pump();
    }
    expect(ChatTranscript.debugBuildCount, 0);

    // The child's own stream does repaint it.
    child.messages.last.content += ' more';
    AgentService.I.debugTickLiveBubbleForTest(child.id);
    await tester.pump();
    expect(ChatTranscript.debugBuildCount, 1);

    // A new row rebuilds the screen (status strip row count) once.
    child.messages.add(Message(role: 'assistant', content: 'new row'));
    AgentService.I.refreshNow();
    await tester.pump();
    expect(find.textContaining('21 rows'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
