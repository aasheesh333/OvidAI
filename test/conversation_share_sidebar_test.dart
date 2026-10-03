import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/sidebar.dart';

void main() {
  testWidgets(
    'session menu shares selected row without switching active chat',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      AgentNotificationService.I.resetForTest();
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
      addTearDown(() {
        AgentNotificationService.I.resetForTest();
        AppState.resetTestInstance();
      });
      app.sessions
        ..clear()
        ..addAll([
          ChatSession(
            id: 'a',
            title: 'First chat',
            model: 'model',
            messages: [Message(role: 'user', content: 'First preview')],
          ),
          ChatSession(
            id: 'b',
            title: 'Second chat',
            model: 'model',
            messages: [Message(role: 'user', content: 'Second preview')],
          ),
        ]);
      app.activeSessionId = 'a';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: SessionsSidebar(isDrawer: false)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Session actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share conversation'));
      await tester.pumpAndSettle();
      expect(find.text('Second preview'), findsOneWidget);
      expect(find.text('First preview'), findsNothing);
      expect(app.activeSessionId, 'a');
      expect(tester.takeException(), isNull);
    },
  );
}
