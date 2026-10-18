// Task 17 pin: tool cards are rendered from cloud event `toolName`s, with NO
// local MCP/plugin runtime present. `mcp__*` names arrive via P3 events and
// must keep mapping to the plug glyph, title, and status badge after the local
// runtimes and plugin screens are deleted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/widgets/chat_tool_visuals.dart';

void main() {
  group('cloud tool card visuals are runtime-free', () {
    test('mcp__ tool names map to the MCP family and plug glyph', () {
      final m = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'mcp__github__list',
        toolTitle: 'GitHub · list repos',
        toolState: 'ok',
      );

      expect(chatToolFamily(m.toolName!), 'mcp');
      expect(chatToolIcon(m.toolName!), Icons.power_outlined);
    });

    testWidgets('a plain cloud tool Message renders its title and state', (
      tester,
    ) async {
      final m = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'mcp__github__list',
        toolTitle: 'GitHub · list repos',
        toolState: 'ok',
      );

      // The same primitives _ToolCard uses: family glyph + title + badge.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Icon(
                  chatToolIcon(m.toolName!),
                  key: ValueKey('chat-tool-icon-${chatToolFamily(m.toolName!)}'),
                ),
                Text(m.toolTitle ?? m.toolName ?? 'tool'),
                ToolStatusBadge(state: m.toolState),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('chat-tool-icon-mcp')), findsOneWidget);
      expect(find.text('GitHub · list repos'), findsOneWidget);
      expect(find.byType(ToolStatusBadge), findsOneWidget);
    });
  });
}
