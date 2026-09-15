import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Agent response styling: the model may use font-color markup for
/// emphasis and it must render in color — while unknown/bogus values fall
/// back to plain body text (never crash, never raw-tag leak as styling).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  bool spanHasColor(InlineSpan span, Color color, String text) {
    if (span is TextSpan) {
      if ((span.text ?? '').contains(text) && span.style?.color == color) {
        return true;
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        if (spanHasColor(child, color, text)) return true;
      }
    }
    return false;
  }

  // SelectableText renders EditableText (not RichText) — cover both.
  bool hasColoredText(Widget w, Color color, String text) {
    if (w is RichText) return spanHasColor(w.text, color, text);
    if (w is EditableText) {
      return w.controller.text.contains(text) && w.style.color == color;
    }
    return false;
  }

  Future<void> pumpTranscript(WidgetTester tester, String answer) async {
    final s = ChatSession(
      id: 'color-1',
      title: 'Color',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', content: 'hi'),
        Message(role: 'assistant', content: answer),
      ],
    );
    app.sessions.add(s);
    app.activeSessionId = s.id;
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('font color renders in color', (tester) async {
    await pumpTranscript(tester, 'Watch <font color="red">alert</font> out');

    expect(
      find.byWidgetPredicate((w) => hasColoredText(w, Colors.red, 'alert')),
      findsOneWidget,
    );
  });

  testWidgets('unknown color falls back to plain text', (tester) async {
    await pumpTranscript(
      tester,
      'Watch <font color="notacolor">alert</font> out',
    );

    // No red span anywhere; the words still render.
    expect(
      find.byWidgetPredicate((w) => hasColoredText(w, Colors.red, 'alert')),
      findsNothing,
    );
    expect(find.textContaining('alert'), findsWidgets);
  });

  test('color names and hex resolve, garbage does not', () {
    expect(ovidFontColor('red'), Colors.red);
    expect(ovidFontColor('RED'), Colors.red);
    expect(ovidFontColor('  green  '), Colors.green);
    expect(ovidFontColor('#ff0000'), const Color(0xFFFF0000));
    expect(ovidFontColor('#f00'), const Color(0xFFFF0000));
    expect(ovidFontColor('notacolor'), isNull);
    expect(ovidFontColor(''), isNull);
    expect(ovidFontColor(null), isNull);
    expect(ovidFontColor('red; background:evil'), isNull);
  });
}
