import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/message_blocks.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_tiles.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_page.dart';

/// Performance regression guards for the live transcript.
///
/// These count mounted widgets rather than wall-clock time so they stay
/// deterministic on CI. A `ListView` with `children:` mounts every row; the
/// lazy builder must keep the count bounded no matter how long the history is.

Widget _app(Widget home) => MaterialApp(theme: OTheme.light(), home: home);

List<V2LiveChatItem> _thinkingItems(int count) => [
  for (var i = 0; i < count; i++)
    V2LiveThinking(id: 't$i', label: 'Step $i', details: const ['detail']),
];

void main() {
  testWidgets('long transcript mounts a bounded number of rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<int> mounted(int count) async {
      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: V2LiveChatData(items: _thinkingItems(count)),
          ),
        ),
      );
      await tester.pump();
      return find.byType(V2ThinkingTile).evaluate().length;
    }

    final short = await mounted(20);
    final long = await mounted(1000);

    // The 1,000-row history must not mount ~1,000 tiles.
    expect(long, lessThan(60));
    // And the mounted count must not grow with the history length.
    expect(long, lessThanOrEqualTo(short + 4));
  });

  testWidgets('typing in the composer does not rebuild the transcript', (
    tester,
  ) async {
    String? draft;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: V2LiveChatData(items: _thinkingItems(12)),
          onDraftChanged: (value) => draft = value,
        ),
      ),
    );
    await tester.pump();

    final before = tester.widget<V2ThinkingTile>(
      find.byType(V2ThinkingTile).first,
    );

    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();

    final after = tester.widget<V2ThinkingTile>(
      find.byType(V2ThinkingTile).first,
    );

    // Same widget instance: the page did not rebuild its transcript for a
    // keystroke. The send button still updates from the controller itself.
    expect(identical(before, after), isTrue);
    expect(draft, 'hello world');
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send')),
      isSemantics(label: 'Send', isButton: true, isEnabled: true),
    );
  });

  testWidgets('expanding one row keeps the mounted set bounded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(V2LiveChatPage(data: V2LiveChatData(items: _thinkingItems(500)))),
    );
    await tester.pump();

    final before = tester
        .widgetList<V2ThinkingTile>(find.byType(V2ThinkingTile))
        .toList();

    await tester.tap(find.text('Step 0'));
    await tester.pump();

    final after = tester
        .widgetList<V2ThinkingTile>(find.byType(V2ThinkingTile))
        .toList();

    // Only the visible window is built, before and after the expansion.
    expect(before.length, lessThan(60));
    expect(after.length, lessThan(60));
    // The tapped row shows its details; the rest stay collapsed.
    expect(find.text('detail'), findsOneWidget);
  });

  testWidgets('long schedule list mounts only the visible cards', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: V2SchedulesData(
            schedules: [
              for (var i = 0; i < 300; i++)
                V2ScheduleItem(
                  id: 's$i',
                  title: 'Schedule $i',
                  description: 'Runs every day',
                  rule: 'Every day at 9:00 AM',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final mounted = find.byType(Switch).evaluate().length;
    expect(mounted, greaterThan(0));
    expect(mounted, lessThan(60));
  });

  testWidgets('long artifact library mounts only the visible rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: V2ArtifactsData(
            artifacts: [
              for (var i = 0; i < 400; i++)
                V2ArtifactItem(
                  id: 'a$i',
                  name: 'file-$i.png',
                  kind: V2ArtifactKind.image,
                  createdAt: DateTime(2026, 5, 18),
                  sizeLabel: '10 KB',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final rows = find.byType(IntrinsicHeight).evaluate().length;
    expect(rows, greaterThan(0));
    expect(rows, lessThan(30));
  });

  test('unchanged markdown is parsed once and reused', () {
    const markdown = '## Heading\n\nSome **bold** text with `code`.\n\n- a\n- b';
    final first = parseV2MessageBlocksCached(markdown);
    final second = parseV2MessageBlocksCached(markdown);
    expect(identical(first, second), isTrue);
    expect(first.length, greaterThan(0));
  });

  testWidgets('changing one row does not re-parse the other messages', (
    tester,
  ) async {
    var parses = 0;
    v2MessageParseObserver = (_) => parses++;
    addTearDown(() => v2MessageParseObserver = null);

    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              const V2LiveThinking(
                id: 'think',
                label: 'Step 0',
                details: ['detail'],
              ),
              for (var i = 0; i < 20; i++)
                V2LiveAssistantMessage(
                  id: 'a$i',
                  markdown: 'Message $i with **bold** and `code`.',
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final initial = parses;
    expect(initial, greaterThan(0));

    // Expanding the thinking row rebuilds the visible rows; their markdown is
    // unchanged, so no message is parsed again.
    await tester.tap(find.text('Step 0'));
    await tester.pump();
    expect(parses, initial);
  });
}
