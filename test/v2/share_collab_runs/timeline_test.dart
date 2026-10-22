import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
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
    details: [
      V2TimelineDetail(label: 'Tool', value: 'web_search', mono: true),
      V2TimelineDetail(
        label: 'Result',
        value: 'Kept the two pages that matched.',
      ),
    ],
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
  testWidgets('renders one row per item with description and duration', (
    tester,
  ) async {
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
        if (item.description != null) {
          expect(find.text(item.description!), findsOneWidget);
        }
      }

      // Only the row that carries detail offers an expansion control.
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(find.text('web_search'), findsNothing);
      expect(find.text('Kept the two pages that matched.'), findsNothing);
    }
  });

  testWidgets('expands real detail and reports both states', (tester) async {
    final changes = <bool>[];
    await pumpAt(
      tester,
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: V2Timeline(
          items: _items,
          onExpandedChanged: (_, expanded) => changes.add(expanded),
        ),
      ),
    );

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(find.text('web_search'), findsOneWidget);
    expect(find.text('Kept the two pages that matched.'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(changes, [true]);

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('web_search'), findsNothing);
    expect(changes, [true, false]);
  });

  testWidgets('a row without detail is not expandable', (tester) async {
    var taps = 0;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: V2Timeline(
          items: const [V2TimelineItem(id: 'plain', title: 'Run finished')],
          onItemTap: (_) => taps++,
        ),
      ),
    );

    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    final data = tester
        .getSemantics(find.bySemanticsLabel(RegExp('Step 1 of 1')))
        .getSemanticsData();
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.flagsCollection.isExpanded, Tristate.none);

    await tester.tap(find.text('Run finished'));
    await tester.pump();
    expect(taps, 1);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    handle.dispose();
  });

  testWidgets(
    'the semantic label reads position, time, title, status, duration',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: V2Timeline(
            items: _items,
            semanticLabel: 'Execution trajectory',
          ),
        ),
      );

      expect(find.bySemanticsLabel('Execution trajectory'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Step 1 of 3, 10:41, Read your message, Completed, 0.2s',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Step 2 of 3, 10:41, Searched the web, Running, 54.2s',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Step 3 of 3, Ran the live preview, Stopped, 12s',
        ),
        findsOneWidget,
      );
      handle.dispose();
    },
  );

  testWidgets('expansion is announced as expanded', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: V2Timeline(items: _items),
      ),
    );

    final row = find.bySemanticsLabel(
      RegExp('Step 2 of 3, 10:41, Searched the web'),
    );
    expect(
      tester.getSemantics(row).getSemanticsData().flagsCollection.isExpanded,
      Tristate.isFalse,
    );
    await tester.tap(row);
    await tester.pump();

    final expanded = tester.getSemantics(row).getSemanticsData();
    expect(expanded.flagsCollection.isExpanded, Tristate.isTrue);
    expect(expanded.hint, 'Hide details');
    handle.dispose();
  });

  testWidgets(
    'a failure is marked on its own row and the error is shown once',
    (tester) async {
      const error = 'Permission denied writing the file.';
      const failed = [
        V2TimelineItem(
          id: 'failed',
          title: 'Wrote portfolio-index.html',
          durationLabel: '1m 12s',
          status: V2TimelineStatus.danger,
          errorMessage: error,
          details: [
            V2TimelineDetail(label: 'Result', value: 'Write rejected.'),
          ],
        ),
      ];
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: V2Timeline(items: failed),
        ),
      );

      expect(find.text(error), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Step 1 of 1.*$error')),
        findsOneWidget,
      );

      await tester.tap(find.text('Wrote portfolio-index.html'));
      await tester.pump();
      expect(find.text('Write rejected.'), findsOneWidget);
      expect(find.text(error), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets('only a running row animates', (tester) async {
    var items = _items;
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: V2Timeline(items: items),
          );
        },
      ),
    );

    expect(find.byType(OPulse), findsOneWidget);
    expect(
      find.byKey(const ValueKey('v2-timeline-node-search')),
      findsOneWidget,
    );

    setHost(() {
      items = [
        for (final item in _items)
          V2TimelineItem(
            id: item.id,
            title: item.title,
            description: item.description,
            timeLabel: item.timeLabel,
            durationLabel: item.durationLabel,
            status: V2TimelineStatus.success,
            details: item.details,
          ),
      ];
    });
    await tester.pump();
    expect(find.byType(OPulse), findsNothing);
  });

  testWidgets('an empty timeline renders nothing', (tester) async {
    await pumpAt(tester, const V2Timeline(items: []));
    expect(find.byType(V2Timeline), findsOneWidget);
    expect(find.text('Read your message'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text with a long tool name', (
    tester,
  ) async {
    const long = V2TimelineItem(
      id: 'long',
      title: 'run_shell_with_a_very_long_tool_name_that_must_not_clip',
      description:
          'A long description that has to wrap or ellipsize without overflow.',
      durationLabel: '1m 12s',
      status: V2TimelineStatus.success,
      details: [
        V2TimelineDetail(
          label: 'Tool',
          value: 'run_shell_with_a_very_long_tool_name_that_must_not_clip',
          mono: true,
        ),
      ],
    );
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        SingleChildScrollView(
          key: ValueKey<String>('long-$dark'),
          padding: const EdgeInsets.all(16),
          child: const V2Timeline(items: [long]),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(long.title));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text(long.title), findsWidgets);
    }
  });
}
