import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerAllNativePlugins();
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    NativePluginRegistry.I.clearForTest();
    AppState.resetTestInstance();
  });

  test('Screen Awareness capability is registered and handles read_screen', () async {
    expect(NativePluginRegistry.I.has('Screen Awareness'), isTrue);
    final cap = NativePluginRegistry.I.capabilityFor('Screen Awareness')!;
    expect(cap.tools.map((t) => t.name), contains('read_screen'));

    // Calling tool without live accessibility service returns honest message
    final result = await cap.callTool('read_screen', {'full': false});
    expect(
      result.contains('screen') || result.contains('Accessibility'),
      isTrue,
    );
  });

  testWidgets('_ModelCompareView renders model choices and displays selected response', (tester) async {
    const content = '''
## GPT-4o
This is response from GPT-4o with details.

## Claude-3-5
This is response from Claude with other details.
''';

    final session = ChatSession(
      id: 'test_compare_session',
      title: 'Compare',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', content: 'compare models'),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'plugin__multi_model_compare__compare',
          toolState: 'ok',
          toolTitle: 'Multi-Model Compare',
          toolSummary: 'compare 2 models',
          toolDetail: content,
        ),
        Message(role: 'assistant', kind: MsgKind.text, content: 'done comparison'),
      ],
    );
    AppState.I.sessions.add(session);
    AppState.I.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Tap on the tool card to expand the detail body
    final toolSummary = find.byKey(const ValueKey('chat-tool-summary'));
    expect(toolSummary, findsOneWidget);
    await tester.tap(toolSummary);
    await tester.pumpAndSettle();

    // Verify model tabs rendered as ChoiceChips
    expect(find.text('GPT-4o'), findsOneWidget);
    expect(find.text('Claude-3-5'), findsOneWidget);
    expect(find.textContaining('This is response from GPT-4o'), findsOneWidget);

    // Switch to Claude-3-5 tab
    await tester.tap(find.text('Claude-3-5'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This is response from Claude'), findsOneWidget);
  });

  testWidgets('_ColorPaletteView renders swatches for detected hex codes', (tester) async {
    const content = 'Palette generated: Primary #FF5733, Secondary #33FF57, Accent #3357FF.';

    final session = ChatSession(
      id: 'test_palette_session',
      title: 'Palette',
      model: 'm',
      mode: 'auto',
      messages: [
        Message(role: 'user', content: 'generate colors'),
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'plugin__color_palette_gen__from_hex',
          toolState: 'ok',
          toolTitle: 'Color Palette Gen',
          toolSummary: 'generate hex',
          toolDetail: content,
        ),
        Message(role: 'assistant', kind: MsgKind.text, content: 'done colors'),
      ],
    );
    AppState.I.sessions.add(session);
    AppState.I.activeSessionId = session.id;

    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: ChatScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Expand tool card
    final toolSummary = find.byKey(const ValueKey('chat-tool-summary'));
    expect(toolSummary, findsOneWidget);
    await tester.tap(toolSummary);
    await tester.pumpAndSettle();

    // Verify Palette Swatches title and hex chips exist
    expect(find.text('Palette Swatches'), findsOneWidget);
    expect(find.text('#FF5733'), findsOneWidget);
    expect(find.text('#33FF57'), findsOneWidget);
    expect(find.text('#3357FF'), findsOneWidget);
  });
}
