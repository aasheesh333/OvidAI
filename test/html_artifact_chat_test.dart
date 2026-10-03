import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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

  testWidgets(
    'restored artifact routes into chat without executing markdown or plugin text',
    (tester) async {
      final artifact = HtmlArtifact.create('owner', {
        'title': 'Saved counter',
        'html': '<button>0</button>',
      });
      final app = AppState.I;
      app.sessions.add(
        ChatSession(
          id: 'owner',
          title: 'Artifacts',
          model: 'm',
          mode: 'auto',
          messages: [
            Message(
              role: 'assistant',
              content: '<button>markdown is inert</button>',
            ),
            Message(
              role: 'assistant',
              kind: MsgKind.tool,
              toolName: 'plugin__markdown_editor__render_html',
              toolState: 'ok',
              toolDetail: '<script>plugin text is inert</script>',
            ),
            Message.fromJson(
              Message(
                role: 'assistant',
                kind: MsgKind.htmlArtifact,
                content: 'Interactive artifact: Saved counter',
                htmlArtifact: artifact,
              ).toJson(),
            ),
          ],
        ),
      );
      app.activeSessionId = 'owner';
      // TickerMode pauses the actual platform view; routing/layout are real.
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const TickerMode(enabled: false, child: ChatScreen()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(HtmlArtifactView), findsOneWidget);
      expect(find.text('Saved counter'), findsOneWidget);
      expect(find.byType(AndroidView), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('existing generated image records keep their local path', () {
    final restored = Message.fromJson({
      'role': 'assistant',
      'kind': 'imageGen',
      'content': 'Saved picture',
      'imagePath': '/session/old-image.jpg',
    });
    expect(restored.kind, MsgKind.imageGen);
    expect(restored.toJson()['imagePath'], '/session/old-image.jpg');
    expect(restored.htmlArtifact, isNull);
  });
}
