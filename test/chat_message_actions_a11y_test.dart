import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState.I;
    final session = ChatSession(
      id: 'a11y',
      title: 'A11y',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', kind: MsgKind.text, content: 'hi'),
        Message(role: 'assistant', kind: MsgKind.text, content: 'hello'),
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

  testWidgets('message action targets are at least 48x48dp', (tester) async {
    await pump(tester);
    for (final tip in ['Copy', 'Good answer', 'Bad answer', 'More actions']) {
      final targets = find.byTooltip(tip);
      expect(targets, findsWidgets, reason: tip);
      for (final e in targets.evaluate()) {
        final size = (e.renderObject! as RenderBox).size;
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
    }
    // Branch moved into the overflow menu.
    expect(find.byTooltip('Branch into a new conversation'), findsNothing);
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Branch into a new conversation'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat header controls are >= 48dp and labelled', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    final header = find.byType(AppBar);
    final buttons = find.descendant(
      of: header,
      matching: find.byType(IconButton),
    );
    expect(buttons, findsWidgets);
    for (final e in buttons.evaluate()) {
      final size = (e.renderObject! as RenderBox).size;
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    final model = find.bySemanticsLabel(RegExp('Change model'));
    expect(model, findsOneWidget);
    expect(tester.getSize(model).height, greaterThanOrEqualTo(48));
    handle.dispose();
  });
}
