import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/shared_conversation_screen.dart';

void main() {
  testWidgets('500 long shared messages build only the visible cards', (
    tester,
  ) async {
    final snapshot = ConversationSnapshot.fromJson('session', [
      for (var i = 0; i < 500; i++)
        SharedMessage(
          i.isEven ? 'user' : 'assistant',
          'Message $i ${'word ' * 3990}',
        ),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: SharedConversationScreen(
          token: 'token',
          loadSnapshot: (_) async => snapshot,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Read only'), findsOneWidget);
    expect(find.textContaining('Message 0 '), findsOneWidget);
    final built = find.byType(SharedMessageBubble).evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(10), reason: 'lazy list, not 500 eager bubbles');
    expect(find.textContaining('Message 499 '), findsNothing);

    // The Continue action is pinned (F-182); the last message is reachable.
    expect(find.text('Continue this chat in Ovid'), findsOneWidget);
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    for (var i = 0; i < 20; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      if (find.textContaining('Message 499 ').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('Message 499 '), findsOneWidget);
  });
}
