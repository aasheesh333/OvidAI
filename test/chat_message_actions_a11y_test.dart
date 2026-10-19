import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
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
        // Server-stored rows (UUID ids): history actions address them.
        Message(
          role: 'user',
          kind: MsgKind.text,
          content: 'hi',
          privateSyncId: '0199aaaa-0000-7000-8000-000000000001',
        ),
        Message(
          role: 'assistant',
          kind: MsgKind.text,
          content: 'hello',
          privateSyncId: '0199aaaa-0000-7000-8000-000000000002',
        ),
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
    // CH-029: no thumbs on cloud rows (no server feedback route).
    expect(find.byTooltip('Good answer'), findsNothing);
    for (final tip in ['Copy', 'Report']) {
      final targets = find.byTooltip(tip);
      expect(targets, findsWidgets, reason: tip);
      for (final e in targets.evaluate()) {
        final size = (e.renderObject! as RenderBox).size;
        expect(size.width, greaterThanOrEqualTo(48), reason: tip);
        expect(size.height, greaterThanOrEqualTo(48), reason: tip);
      }
    }
    // R4: no apparently-active destructive history controls until the
    // server can atomically change history alongside sends on other devices.
    for (final tip in ['Edit & resend', 'Regenerate', 'More actions', 'Branch into a new chat']) {
      expect(find.byTooltip(tip), findsNothing);
    }
    expect(find.textContaining('Your chat is kept unchanged.'), findsOneWidget);
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
