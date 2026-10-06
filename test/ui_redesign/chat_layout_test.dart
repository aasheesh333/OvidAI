import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_layout.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Smoke renders for the wave-2 Aether redesign of `chat_layout.dart`.
///
/// The pure [ChatLayout] width axis is pinned by `test/chat_layout_test.dart`
/// and the live chat surface by `test/chat_layout_widget_test.dart`; this
/// suite only covers the new Aether transcript primitives declared in
/// `lib/ui/chat_layout.dart`:
///
/// 1. Message rows render on [AetherSurface], keep the shared width axis
///    (user rows cap at `userBubbleMaxWidth` right-aligned, assistant rows
///    cap at `contentWidth` left-aligned), and surface status as
///    [AetherPill].
/// 2. Tool-call bubbles render as [AetherCard] with the tool state shown as
///    a trailing [AetherPill], and disclose their detail body on tap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRow(
    WidgetTester tester,
    Widget child, {
    double width = 1400,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  testWidgets('user message row renders on AetherSurface within the compact '
      'bubble cap, right-aligned', (tester) async {
    const layout = ChatLayout(viewportWidth: 1400);
    await pumpRow(
      tester,
      ChatMessageRow(
        layout: layout,
        isUser: true,
        bubbleKey: const ValueKey('chat-user-bubble-0'),
        child: Text('word ' * 80),
      ),
    );

    expect(find.byType(AetherSurface), findsOneWidget);
    final bubble = find.byKey(const ValueKey('chat-user-bubble-0'));
    expect(bubble, findsOneWidget);
    expect(
      tester.getSize(bubble).width,
      lessThanOrEqualTo(layout.userBubbleMaxWidth + 0.5),
    );
    // Right-aligned inside the row: bubble center is right of viewport center.
    expect(tester.getCenter(bubble).dx, greaterThan(700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('assistant message row caps at the content width, left-aligned',
      (tester) async {
    const layout = ChatLayout(viewportWidth: 1400);
    await pumpRow(
      tester,
      ChatMessageRow(
        layout: layout,
        isUser: false,
        child: Text('word ' * 200),
      ),
    );

    final surface = find.byType(AetherSurface);
    expect(surface, findsOneWidget);
    expect(
      tester.getSize(surface).width,
      lessThanOrEqualTo(layout.contentWidth + 0.5),
    );
    expect(tester.getCenter(surface).dx, lessThan(700));
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow viewport: user bubble shrinks with the axis', (
    tester,
  ) async {
    const layout = ChatLayout(viewportWidth: 400);
    await pumpRow(
      tester,
      ChatMessageRow(
        layout: layout,
        isUser: true,
        bubbleKey: const ValueKey('chat-user-bubble-0'),
        child: Text('word ' * 80),
      ),
      width: 400,
    );

    final bubble = find.byKey(const ValueKey('chat-user-bubble-0'));
    expect(bubble, findsOneWidget);
    expect(
      tester.getSize(bubble).width,
      lessThanOrEqualTo(layout.userBubbleMaxWidth + 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('message row status renders as an AetherPill', (tester) async {
    await pumpRow(
      tester,
      const ChatMessageRow(
        layout: ChatLayout(viewportWidth: 1400),
        isUser: false,
        statusLabel: 'Streaming',
        child: Text('partial answer'),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(AetherPill),
        matching: find.text('Streaming'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool call bubble renders an AetherCard with a status pill', (
    tester,
  ) async {
    await pumpRow(
      tester,
      const ChatToolCallCard(
        state: ChatToolState.running,
        title: 'Read',
        summary: 'lib/main.dart',
      ),
    );

    expect(find.byType(AetherCard), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('lib/main.dart'), findsOneWidget);
    final pill = tester.widget<AetherPill>(find.byType(AetherPill));
    expect(pill.label, 'Running');
    expect(pill.color, Aether.accent);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool call pill mirrors the tool state', (tester) async {
    await pumpRow(
      tester,
      const ChatToolCallCard(state: ChatToolState.error, title: 'Bash'),
    );

    final pill = tester.widget<AetherPill>(find.byType(AetherPill));
    expect(pill.label, 'Error');
    expect(pill.color, Aether.dangerC);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tool call card discloses its detail body on tap', (
    tester,
  ) async {
    await pumpRow(
      tester,
      const ChatToolCallCard(
        state: ChatToolState.done,
        title: 'Edit',
        detail: '+added line\n-removed line',
      ),
    );

    expect(find.text('+added line\n-removed line'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-tool-card-toggle')));
    await tester.pump();
    expect(find.text('+added line\n-removed line'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
