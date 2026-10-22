import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/runs/timeline.dart';

import '_harness.dart';

const _items = [
  V2TimelineItem(
    id: 'read',
    title: 'Read your message',
    description: 'Parsed the request and picked a plan.',
    timeLabel: '10:41',
    durationLabel: '0.2s',
    status: V2TimelineStatus.success,
  ),
  V2TimelineItem(
    id: 'search',
    title: 'Searched the web',
    description: 'Read four pages and kept two.',
    timeLabel: '10:41',
    durationLabel: '54.2s',
    status: V2TimelineStatus.running,
    expandedDetail: 'Kept the two pages that matched.',
  ),
  V2TimelineItem(
    id: 'preview',
    title: 'Ran the live preview',
    durationLabel: '12s',
    status: V2TimelineStatus.warning,
    statusLabel: 'Stopped',
  ),
];

void main() {
  testWidgets('renders one line per item with its duration', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: V2Timeline(items: _items),
        ),
        dark: dark,
      );

      for (final item in _items) {
        expect(find.text(item.title), findsOneWidget);
        expect(find.text(item.durationLabel!), findsOneWidget);
        expect(
          find.byKey(ValueKey('v2-timeline-node-${item.id}')),
          findsOneWidget,
        );
      }

      // Descriptions, expansion and footers are not part of a minimal row.
      expect(
        find.text('Parsed the request and picked a plan.'),
        findsNothing,
      );
      expect(find.text('Kept the two pages that matched.'), findsNothing);
      expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
      expect(find.byIcon(Icons.expand_less_rounded), findsNothing);
    }
  });

  testWidgets('a row reports taps with its id', (tester) async {
    String? tapped;
    await pumpAt(
      tester,
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: V2Timeline(
          items: _items,
          onItemTap: (id) => tapped = id,
        ),
      ),
    );

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(tapped, 'search');
  });

  testWidgets('the semantic label reads time, title, status and duration', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: V2Timeline(items: _items, semanticLabel: 'Execution trajectory'),
      ),
    );

    expect(find.bySemanticsLabel('Execution trajectory'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        '10:41, Searched the web, Running, 54.2s',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Ran the live preview, Stopped, 12s',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('an empty timeline renders nothing', (tester) async {
    await pumpAt(tester, const V2Timeline(items: []));
    expect(find.byType(V2Timeline), findsOneWidget);
    expect(find.text('Read your message'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: V2Timeline(items: _items),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Ran the live preview'), findsOneWidget);
    }
  });
}
