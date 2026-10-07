import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ChatSession session(String state) => ChatSession(
        id: 'premium-$state',
        title: 'Premium agent',
        model: 'm',
        mode: 'auto',
        parentId: 'parent',
        agentState: state,
        agentContinuable: false,
      );

  Widget host(ChatSession child) {
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.sessions.addAll([
      ChatSession(id: 'parent', title: 'Parent', model: 'm', mode: 'auto'),
      child,
    ]);
    return MaterialApp(theme: Aether.theme(), home: SubagentScreen(sessionId: child.id));
  }

  testWidgets('terminal footer explains failed, stopped, and completed states',
      (tester) async {
    for (final entry in {
      'failed': 'This agent failed — read the transcript for details.',
      'stopped': 'This agent was stopped — no follow-ups were sent.',
      'completed': 'Completed execution record — read only.',
    }.entries) {
      await tester.pumpWidget(host(session(entry.key)));
      await tester.pump();
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets('latest control is explicit when transcript is scrolled away',
      (tester) async {
    final child = session('running');
    child.agentContinuable = true;
    child.messages.addAll(
      List.generate(30, (i) => Message(role: 'user', content: 'row $i')),
    );
    await tester.pumpWidget(host(child));
    await tester.pump();

    expect(find.byTooltip('Jump to latest'), findsNothing);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 500));
    await tester.pump();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);

    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsNothing);
  });
}
