import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/runs/timeline.dart';

const _items = <V2TimelineItem>[
  V2TimelineItem(
    id: 'plan',
    title: 'Read your message',
    description: 'Parsed the request and picked a plan.',
    timeLabel: '10:41',
    durationLabel: '0.2s',
    status: V2TimelineStatus.success,
    icon: Icons.chat_bubble_outline_rounded,
  ),
  V2TimelineItem(
    id: 'search',
    title: 'Searched the web',
    description: 'Opened four pages about layout.',
    timeLabel: '10:42',
    durationLabel: '4.8s',
    status: V2TimelineStatus.running,
    icon: Icons.travel_explore_rounded,
    expandedDetail: 'Read four pages and kept the two that matched.',
  ),
  V2TimelineItem(
    id: 'write',
    title: 'Wrote portfolio-index.html',
    timeLabel: '10:43',
    durationLabel: '54.2s',
    status: V2TimelineStatus.danger,
    statusLabel: 'Stopped',
    icon: Icons.terminal_rounded,
  ),
  V2TimelineItem(
    id: 'preview',
    title: 'Ran the live preview',
    timeLabel: '10:44',
    durationLabel: '12.0s',
    status: V2TimelineStatus.warning,
    icon: Icons.desktop_windows_rounded,
  ),
];

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.l),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
  // Let the capped stagger finish so no entrance animation hides a row.
  await tester.pump(const Duration(milliseconds: 900));
}

/// Pumps at 320 dp wide with 200 % text, the smallest supported combination.
Future<void> _pumpNarrow(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      builder: (context, navigator) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: navigator!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.l),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

/// Text that paints past the left or right edge of the screen.
List<String> _offScreenText(WidgetTester tester) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final off = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (rect.left < -0.5 || rect.right > width + 0.5) {
      off.add('"${(element.widget as Text).data}" $rect');
    }
  }
  return off;
}

void main() {
  testWidgets('renders time labels, descriptions, statuses and durations', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, const V2Timeline(items: _items), theme);

      expect(find.text('Read your message'), findsOneWidget);
      expect(find.text('Searched the web'), findsOneWidget);
      expect(find.text('Wrote portfolio-index.html'), findsOneWidget);
      expect(find.text('Ran the live preview'), findsOneWidget);
      expect(find.text('10:41'), findsOneWidget);
      expect(find.text('10:44'), findsOneWidget);
      expect(find.text('0.2s'), findsOneWidget);
      expect(find.text('54.2s'), findsOneWidget);
      expect(
        find.text('Parsed the request and picked a plan.'),
        findsOneWidget,
      );
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('Needs attention'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('nodes take the theme colour for their status', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, const V2Timeline(items: _items), theme);
      final c = theme.extension<OColors>()!;

      Icon node(String id) =>
          tester.widget<Icon>(find.byKey(ValueKey('v2-timeline-node-$id')));

      expect(node('plan').color, c.success);
      expect(node('search').color, c.accent);
      expect(node('write').color, c.danger);
      expect(node('preview').color, c.warn);
    }
  });

  testWidgets('draws a connector between rows but not after the last', (
    tester,
  ) async {
    await _pump(tester, const V2Timeline(items: _items), OTheme.light());

    for (final id in ['plan', 'search', 'write']) {
      final connector = find.byKey(ValueKey('v2-timeline-connector-$id'));
      expect(connector, findsOneWidget);
      expect(tester.getSize(connector).height, greaterThan(0));
    }
    expect(
      find.byKey(const ValueKey('v2-timeline-connector-preview')),
      findsNothing,
    );
  });

  testWidgets('expandable row shows and hides its detail', (tester) async {
    final changes = <(String, bool)>[];
    await _pump(
      tester,
      V2Timeline(
        items: _items,
        onExpandedChanged: (id, expanded) => changes.add((id, expanded)),
      ),
      OTheme.light(),
    );

    const detail = 'Read four pages and kept the two that matched.';
    expect(find.text(detail), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(find.text(detail), findsOneWidget);
    expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(find.text(detail), findsNothing);
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    expect(changes, [('search', true), ('search', false)]);
  });

  testWidgets('initiallyExpanded opens the detail on first paint', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2Timeline(
        items: [
          V2TimelineItem(
            id: 'open',
            title: 'Step',
            expandedDetail: 'Already visible.',
            initiallyExpanded: true,
          ),
        ],
      ),
      OTheme.light(),
    );

    expect(find.text('Already visible.'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget);
  });

  testWidgets('footer content renders under the row', (tester) async {
    await _pump(
      tester,
      const V2Timeline(
        items: [
          V2TimelineItem(
            id: 'file',
            title: 'Wrote the page',
            footer: Text('portfolio-index.html'),
          ),
        ],
      ),
      OTheme.light(),
    );

    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('row taps carry the item id', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      V2Timeline(items: _items, onItemTap: opened.add),
      OTheme.light(),
    );

    await tester.tap(find.text('Read your message'));
    await tester.pump();
    expect(opened, ['plan']);

    // An expandable row both toggles and reports the tap.
    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(opened, ['plan', 'search']);
    expect(
      find.text('Read four pages and kept the two that matched.'),
      findsOneWidget,
    );
  });

  testWidgets('screen readers get time, title, status and expansion state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(
      tester,
      const V2Timeline(items: _items, semanticLabel: 'Execution trajectory'),
      OTheme.light(),
    );

    expect(find.bySemanticsLabel('Execution trajectory'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        '10:41, Read your message, Completed, 0.2s. '
        'Parsed the request and picked a plan',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        '10:42, Searched the web, Running, 4.8s. '
        'Opened four pages about layout. Show details',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        '10:43, Wrote portfolio-index.html, Stopped, 54.2s',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(
      find.bySemanticsLabel(
        '10:42, Searched the web, Running, 4.8s. '
        'Opened four pages about layout. '
        'Read four pages and kept the two that matched. Hide details',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('lays out at 320 dp with 200 % text without clipping', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      const V2Timeline(
        items: [
          ..._items,
          V2TimelineItem(
            id: 'long',
            title:
                'Compared three component libraries and wrote a summary for '
                'the main agent',
            description:
                'This description is long enough to wrap over several lines '
                'at the smallest supported width.',
            timeLabel: '10:45',
            durationLabel: '1m 02s',
            status: V2TimelineStatus.warning,
            statusLabel: 'Needs a decision',
          ),
        ],
      ),
    );

    final ctx = tester.element(find.text('Read your message'));
    expect(MediaQuery.textScalerOf(ctx).scale(12), 24);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pump();

    expect(find.text('Needs a decision'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(_offScreenText(tester), isEmpty);
  });

  testWidgets('an empty timeline renders nothing', (tester) async {
    await _pump(tester, const V2Timeline(items: []), OTheme.light());

    expect(find.byType(V2Timeline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves every row visible', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(OSpace.l),
            child: V2Timeline(items: _items),
          ),
        ),
      ),
    );
    await tester.pump();

    for (final item in _items) {
      expect(find.text(item.title), findsOneWidget);
    }
  });
}
