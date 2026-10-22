import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/queue_dock.dart';

Widget _app(Widget home, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

const _liveItems = <V2LiveChatItem>[
  V2LiveUserMessage(id: 'u1', text: 'Build a pricing page'),
  V2LiveAssistantMessage(id: 'a1', markdown: 'Working on it now.'),
];

/// The nearest circular Material behind the composer's stop icon.
Material _roundStopMaterial(WidgetTester tester) => tester.widget<Material>(
  find
      .ancestor(
        of: find.byIcon(Icons.stop_rounded),
        matching: find.byWidgetPredicate(
          (widget) => widget is Material && widget.shape is CircleBorder,
        ),
      )
      .first,
);

void main() {
  testWidgets('dock shows one line: count, send now and dismiss', (
    tester,
  ) async {
    var sentNow = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _app(
        V2QueueDock(
          count: 2,
          preview: 'Add a pricing page with a yearly toggle',
          onSendNow: () => sentNow++,
          onDismiss: () => dismissed++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('2 queued'), findsOneWidget);
    expect(
      find.text('Add a pricing page with a yearly toggle'),
      findsNothing,
      reason: 'the dock never draws a preview paragraph',
    );
    expect(find.text('Send now'), findsOneWidget);

    await tester.tap(find.text('Send now'));
    await tester.pump();
    expect(sentNow, 1);

    await tester.tap(find.bySemanticsLabel('Dismiss queued message'));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('dock uses the singular count for one queued message', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(const V2QueueDock(count: 1, preview: 'One more thing')),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('1 queued'), findsOneWidget);
    expect(find.text('2 queued'), findsNothing);
  });

  testWidgets('dock stays one line when the host has no preview text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        V2QueueDock(count: 1, preview: '', onSendNow: () {}, onDismiss: () {}),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('1 queued'), findsOneWidget);
    expect(find.text('Send now'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Send now')).dy,
      closeTo(tester.getTopLeft(find.text('1 queued')).dy, 8),
      reason: 'count and action share one line',
    );
  });

  testWidgets('chat page shows the dock above the composer and wires Stop', (
    tester,
  ) async {
    var stops = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            queuedCount: 1,
            queuedPreview: 'Use a warmer accent',
          ),
          onStop: () => stops++,
          onDismissQueued: () => dismissed++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(V2QueueDock), findsOneWidget);
    expect(find.text('Use a warmer accent'), findsNothing);
    expect(
      tester.getTopLeft(find.byType(V2QueueDock)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );

    // "Send now" is Stop: no separate callback is wired.
    await tester.tap(find.text('Send now'));
    await tester.pump();
    expect(stops, 1);

    await tester.tap(find.bySemanticsLabel('Dismiss queued message'));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('chat page prefers the explicit send-now callback', (
    tester,
  ) async {
    var stops = 0;
    var sentNow = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(queuedCount: 1, queuedPreview: 'Go ahead'),
          onStop: () => stops++,
          onSendQueuedNow: () => sentNow++,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Send now'));
    await tester.pump();
    expect(sentNow, 1);
    expect(stops, 0);
  });

  testWidgets('live chat shows the dock and wires send now and dismiss', (
    tester,
  ) async {
    var sentNow = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      _app(
        V2LiveChatPage(
          data: const V2LiveChatData(
            items: _liveItems,
            running: true,
            queuedCount: 2,
            queuedPreview: 'Then add testimonials',
          ),
          onSendQueuedNow: () => sentNow++,
          onDismissQueued: () => dismissed++,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(V2QueueDock), findsOneWidget);
    expect(find.text('2 queued'), findsOneWidget);
    expect(find.text('Then add testimonials'), findsNothing);
    expect(
      tester.getTopLeft(find.byType(V2QueueDock)).dy,
      lessThan(tester.getTopLeft(find.byType(TextField)).dy),
    );

    await tester.ensureVisible(find.text('Send now'));
    await tester.pump();
    await tester.tap(find.text('Send now'));
    await tester.pump();
    expect(sentNow, 1);

    await tester.tap(find.bySemanticsLabel('Dismiss queued message'));
    await tester.pump();
    expect(dismissed, 1);
  });

  testWidgets('dock actions meet the 48 dp target and are labelled', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        V2QueueDock(
          count: 3,
          preview: 'Keep going after this',
          onSendNow: () {},
          onDismiss: () {},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    for (final label in ['Send now', 'Dismiss queued message']) {
      final finder = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.label == label &&
            widget.properties.button == true,
      );
      expect(finder, findsOneWidget, reason: label);
      final size = tester.getSize(finder);
      expect(size.width, greaterThanOrEqualTo(48), reason: label);
      expect(size.height, greaterThanOrEqualTo(48), reason: label);
    }
  });

  testWidgets('queued dock lays out at 320 dp with 200 % text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const chatStates = <String, V2ChatPageData>{
      'empty': V2ChatPageData(queuedCount: 3, queuedPreview: 'First draft'),
      'running': V2ChatPageData(
        state: V2ChatState.running,
        queuedCount: 3,
        queuedPreview: 'First draft',
      ),
      'offline': V2ChatPageData(
        state: V2ChatState.offline,
        queuedCount: 3,
        queuedPreview: 'First draft',
      ),
    };
    const liveStates = <String, V2LiveChatData>{
      'content': V2LiveChatData(
        items: _liveItems,
        queuedCount: 3,
        queuedPreview: 'First draft',
      ),
      'running': V2LiveChatData(
        items: _liveItems,
        running: true,
        queuedCount: 3,
        queuedPreview: 'First draft',
      ),
    };

    for (final dark in [false, true]) {
      for (final entry in chatStates.entries) {
        await tester.pumpWidget(
          _app(
            V2ChatPage(
              data: entry.value,
              onStop: () {},
              onDismissQueued: () {},
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.takeException(),
          isNull,
          reason:
              'chat ${entry.key} overflowed at 320 dp / 200 % text '
              '(${dark ? 'dark' : 'light'})',
        );
        expect(find.byType(V2QueueDock), findsOneWidget);
      }
      for (final entry in liveStates.entries) {
        await tester.pumpWidget(
          _app(
            V2LiveChatPage(
              data: entry.value,
              onStop: () {},
              onDismissQueued: () {},
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          tester.takeException(),
          isNull,
          reason:
              'live ${entry.key} overflowed at 320 dp / 200 % text '
              '(${dark ? 'dark' : 'light'})',
        );
        expect(find.byType(V2QueueDock), findsOneWidget);
      }
    }
  });

  for (final dark in [false, true]) {
    testWidgets('stop turns red while running (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      final danger = dark ? OColors.dark.danger : OColors.light.danger;

      await tester.pumpWidget(
        _app(
          V2ChatPage(
            data: const V2ChatPageData(state: V2ChatState.running),
            onStop: () {},
          ),
          dark: dark,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(_roundStopMaterial(tester).color, danger);

      await tester.pumpWidget(
        _app(
          V2LiveChatPage(
            data: const V2LiveChatData(items: _liveItems, running: true),
            onStop: () {},
          ),
          dark: dark,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(_roundStopMaterial(tester).color, danger);
    });
  }
}
