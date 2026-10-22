import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/model_chip.dart';
import 'package:ovid_ai/ui/v2/chat/transcript_tiles.dart';

/// The chat surface's visual contract: the transcript is the screen.
///
/// These tests pin the *absence* of chrome — no avatars, no per-message
/// timestamps, no card around a plain assistant paragraph, no tinted thinking
/// icon — plus the exact top-bar control order. A redesign that re-introduces
/// chrome fails here before it reaches review.
Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

const _contractItems = <V2LiveChatItem>[
  V2LiveUserMessage(id: 'u1', text: 'Build a landing page', timeLabel: '10:24'),
  V2LiveThinking(
    id: 't1',
    label: 'Thought for a moment',
    details: <String>['Read the brief'],
  ),
  V2LiveTool(id: 'tool1', title: 'Writing index.html', status: 'ok', progress: 1),
  V2LiveAssistantMessage(id: 'a1', markdown: 'The page is ready.'),
];

Widget _wiredLive({V2LiveChatData data = const V2LiveChatData(
  sessionTitle: 'Landing page',
  items: _contractItems,
)}) =>
    V2LiveChatPage(
      data: data,
      onMenu: () {},
      onModelChipTap: () {},
      onStudio: () {},
      onBrowser: () {},
      onMore: () {},
      onSend: (_) {},
    );

/// Left-edge x of the first match, for ordering assertions.
double _x(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dx;

void main() {
  testWidgets('a message has no avatar, no timestamp, no tinted icon', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_wiredLive()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // No avatar widget anywhere in the transcript.
    expect(find.byType(CircleAvatar), findsNothing);
    // The per-message timestamp is never drawn.
    expect(find.text('10:24'), findsNothing);
    // Thinking is one muted line — no tinted icon in front of it.
    expect(find.byIcon(Icons.psychology_rounded), findsNothing);
    expect(find.text('Thought for a moment'), findsOneWidget);
    // No message carries a time caption.
    expect(find.byIcon(Icons.schedule_rounded), findsNothing);
  });

  testWidgets('a plain assistant paragraph has no card around it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: [
              V2LiveAssistantMessage(id: 'a1', markdown: 'A quiet reply.'),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final paragraph = find.textContaining('A quiet reply', findRichText: true);
    expect(paragraph, findsOneWidget);

    // Between the text and the transcript list there is no filled or bordered
    // surface: the answer sits directly on the page background.
    final chrome = <Widget>[];
    tester.element(paragraph).visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is ListView) return false; // stop at the transcript
      if (widget is Container && widget.decoration != null) chrome.add(widget);
      if (widget is OCard || widget is Card) chrome.add(widget);
      return true;
    });
    expect(chrome, isEmpty, reason: 'a plain paragraph wears no card');
  });

  testWidgets('the user bubble is a gentle surfaceAlt fill, nothing else', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_wiredLive()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final container = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Build a landing page'),
            matching: find.byType(Container),
          )
          .first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, OColors.light.surfaceAlt);
    expect(decoration.border, isNull, reason: 'no border on a bubble');
    expect(decoration.boxShadow, isNull, reason: 'no shadow on a bubble');
    expect(decoration.borderRadius, BorderRadius.circular(ORadius.l));
  });

  testWidgets('the live top bar keeps the exact control order', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_wiredLive()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final title = find.text('Landing page');
    expect(_x(tester, find.bySemanticsLabel('Open menu')),
        lessThan(_x(tester, find.byType(V2ModelChip))));
    expect(_x(tester, find.byType(V2ModelChip)), lessThan(_x(tester, title)));
    expect(_x(tester, title),
        lessThan(_x(tester, find.bySemanticsLabel('Open Studio'))));
    expect(_x(tester, find.bySemanticsLabel('Open Studio')),
        lessThan(_x(tester, find.bySemanticsLabel('Open Browser'))));
    expect(_x(tester, find.bySemanticsLabel('Open Browser')),
        lessThan(_x(tester, find.bySemanticsLabel('More options'))));

    // Nothing else: no hairline, no bell, no avatar in the bar.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
  });

  testWidgets('the chat top bar keeps the exact control order', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(),
          onMenu: () {},
          onModelChipTap: () {},
          onStudio: () {},
          onBrowser: () {},
          onMore: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final title = find.text('Ovid Si').first;
    expect(_x(tester, find.bySemanticsLabel('Open menu')),
        lessThan(_x(tester, find.byType(V2ModelChip))));
    expect(_x(tester, find.byType(V2ModelChip)), lessThan(_x(tester, title)));
    expect(_x(tester, title),
        lessThan(_x(tester, find.bySemanticsLabel('Open Studio'))));
    expect(_x(tester, find.bySemanticsLabel('Open Studio')),
        lessThan(_x(tester, find.bySemanticsLabel('Open Browser'))));
    expect(_x(tester, find.bySemanticsLabel('Open Browser')),
        lessThan(_x(tester, find.bySemanticsLabel('More options'))));
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(Divider)),
      findsNothing,
    );
  });

  testWidgets('thinking shimmers only while running', (tester) async {
    Widget tile({required bool running}) => _app(
          Scaffold(
            body: V2ThinkingTile(
              label: 'Thinking',
              details: const ['detail'],
              expanded: false,
              onToggle: () {},
              running: running,
            ),
          ),
        );

    await tester.pumpWidget(tile(running: true));
    await tester.pump();
    // A subtle sweep plays across the label while the thought is live.
    // Flat system: the running thought breathes opacity, no gradient shader.
    expect(find.byType(Opacity), findsWidgets);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, greaterThan(0));

    await tester.pumpWidget(tile(running: false));
    await tester.pump();
    // A finished thought is still text: no shimmer, no running animation.
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('a newly appended message fades in once, then is still', (
    tester,
  ) async {
    const first = V2LiveChatData(
      items: [V2LiveUserMessage(id: 'u1', text: 'Hi')],
    );
    const appended = V2LiveChatData(
      items: [
        V2LiveUserMessage(id: 'u1', text: 'Hi'),
        V2LiveAssistantMessage(id: 'a2', markdown: 'Fresh reply'),
      ],
    );

    await tester.pumpWidget(_app(const V2LiveChatPage(data: first)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(_app(const V2LiveChatPage(data: appended)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final reply = find.textContaining('Fresh reply', findRichText: true);
    expect(reply, findsOneWidget);
    final midFade = tester.widget<Opacity>(
      find.ancestor(of: reply, matching: find.byType(Opacity)).first,
    );
    expect(midFade.opacity, greaterThan(0));
    expect(midFade.opacity, lessThan(1), reason: 'the fade is ≤ 200 ms');

    // After the entrance the row is plain: no wrapper, no running animation.
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.ancestor(of: reply, matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(find.textContaining('Fresh reply', findRichText: true),
        findsOneWidget);
  });

  testWidgets('the chat empty state is the brand, one line and three chips', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const V2ChatPage(data: V2ChatPageData())));
    await tester.pump(const Duration(milliseconds: 400));

    // One greeting and three starting points. The wordmark lives in the top
    // bar only — repeating it in the body was the duplicate the minimal pass
    // removed. No paragraph, no icon circle.
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('What should we build?'), findsOneWidget);
    expect(find.byType(OChip), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    // Three rows, each with an arrow: the starting points are full-width
    // rows now, not floating chips that wrap on a narrow phone.
    expect(find.byIcon(Icons.arrow_forward_rounded), findsNWidgets(3));
  });
}
