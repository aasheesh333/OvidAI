import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/ui/collab_session_screen.dart';
import 'package:ovid_ai/ui/content_report_sheet.dart';
import 'package:ovid_ai/ui/shared_conversation_screen.dart';

/// Integration: the Play UGC report entry points (release/play-compliance
/// audit §6) are wired into the session-link viewer and live sessions.
void main() {
  testWidgets('a shared conversation offers Report and opens the sheet', (
    tester,
  ) async {
    final snapshot = ConversationSnapshot.fromJson('session', [
      SharedMessage('user', 'hello'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: SharedConversationScreen(
          token: 'token',
          loadSnapshot: (_) async => snapshot,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byTooltip('Report'));
    await tester.pumpAndSettle();
    expect(find.byType(ContentReportForm), findsOneWidget);
  });

  testWidgets('only other people\'s collab messages can be reported', (
    tester,
  ) async {
    var reported = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CollabMessageBubble(
                message: const CollaborationMessage(
                  sequence: 1,
                  clientEventId: 'a',
                  author: 'p-bob',
                  createdAt: '2026-10-10T00:00:00.000Z',
                  text: 'Hi',
                  role: MessageRole.user,
                ),
                authorName: 'Bob',
                mine: false,
                onReport: () => reported++,
              ),
              const CollabMessageBubble(
                message: CollaborationMessage(
                  sequence: 2,
                  clientEventId: 'b',
                  author: 'p-me',
                  createdAt: '2026-10-10T00:00:00.000Z',
                  text: 'Mine',
                  role: MessageRole.user,
                ),
                authorName: 'Me',
                mine: true,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byTooltip('Report message'), findsOneWidget);
    await tester.tap(find.byTooltip('Report message'));
    expect(reported, 1);
  });
}
