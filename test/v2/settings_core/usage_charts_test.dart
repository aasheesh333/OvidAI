import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/usage_charts.dart';

const _tokens7 = <V2TokenChartPoint>[
  V2TokenChartPoint(
    id: 'mon',
    label: 'Mon',
    value: 8200000,
    valueLabel: '8.2M tokens',
  ),
  V2TokenChartPoint(
    id: 'tue',
    label: 'Tue',
    value: 14100000,
    valueLabel: '14.1M tokens',
  ),
  V2TokenChartPoint(
    id: 'wed',
    label: 'Wed',
    value: 6500000,
    valueLabel: '6.5M tokens',
  ),
  V2TokenChartPoint(
    id: 'thu',
    label: 'Thu',
    value: 11800000,
    valueLabel: '11.8M tokens',
  ),
  V2TokenChartPoint(
    id: 'fri',
    label: 'Fri',
    value: 16900000,
    valueLabel: '16.9M tokens',
  ),
  V2TokenChartPoint(
    id: 'sat',
    label: 'Sat',
    value: 4300000,
    valueLabel: '4.3M tokens',
  ),
  V2TokenChartPoint(
    id: 'sun',
    label: 'Sun',
    value: 12400000,
    valueLabel: '12.4M tokens',
  ),
];

const _models = <V2ModelShareSlice>[
  V2ModelShareSlice(
    id: 'auto',
    label: 'Auto',
    percent: 78,
    valueLabel: '9.6M tokens',
  ),
  V2ModelShareSlice(
    id: 'gpt',
    label: 'GPT',
    percent: 12,
    valueLabel: '1.5M tokens',
  ),
  V2ModelShareSlice(
    id: 'claude',
    label: 'Claude',
    percent: 10,
    valueLabel: '1.2M tokens',
  ),
];

const _images7 = <V2ImageUsagePoint>[
  V2ImageUsagePoint(id: 'mon', label: 'Mon', count: 8),
  V2ImageUsagePoint(id: 'tue', label: 'Tue', count: 12),
  V2ImageUsagePoint(id: 'wed', label: 'Wed', count: 9),
  V2ImageUsagePoint(id: 'thu', label: 'Thu', count: 14),
  V2ImageUsagePoint(id: 'fri', label: 'Fri', count: 21),
  V2ImageUsagePoint(id: 'sat', label: 'Sat', count: 7),
  V2ImageUsagePoint(id: 'sun', label: 'Sun', count: 15),
];

List<V2TokenChartPoint> _tokens30() => [
  for (var i = 0; i < 30; i++)
    V2TokenChartPoint(
      id: 'd${i + 1}',
      label: 'Day ${i + 1}',
      value: 1000000 + i * 100000,
    ),
];

Widget _app(
  Widget child, {
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: (context, appChild) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: appChild!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.screen),
        child: child,
      ),
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _small(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('daily chart paints bars with the range switch, no labels', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const V2DailyTokensChart(points: _tokens7)));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('usage-chart-daily')),
      findsOneWidget,
    );
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);

    // No card chrome: no title, no total, no axis labels, no legend.
    expect(find.text('Daily tokens'), findsNothing);
    expect(find.text('Last 7 days'), findsNothing);
    expect(find.text('74.2M'), findsNothing);
    expect(find.text('tokens'), findsNothing);
    expect(find.text('Mon'), findsNothing);
    expect(find.text('Thu'), findsNothing);
    expect(find.text('Sun'), findsNothing);
    expect(find.byType(OCard), findsNothing);
  });

  testWidgets('range tabs report the selected window', (tester) async {
    _phone(tester);
    V2UsageChartRange? changed;
    await tester.pumpWidget(
      _app(
        V2DailyTokensChart(
          points: _tokens7,
          onRangeChanged: (value) => changed = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('30 days'));
    await tester.pump();

    expect(changed, V2UsageChartRange.thirtyDays);
  });

  testWidgets('daily chart summarises 30 days for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    await tester.pumpWidget(
      _app(
        V2DailyTokensChart(
          points: _tokens30(),
          range: V2UsageChartRange.thirtyDays,
          onRangeChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('usage-chart-daily')),
    );
    expect(node.label, contains('Daily tokens chart, last 30 days'));
    expect(node.label, contains('Peak Day 30'));
    expect(node.label, contains('Lowest Day 1'));
    // The axis labels are gone; the painted bars carry the semantics summary.
    expect(find.text('Day 1'), findsNothing);
    expect(find.text('Day 16'), findsNothing);
    expect(find.text('Day 30'), findsNothing);
    handle.dispose();
  });

  testWidgets('model share paints the split and keeps a readable legend', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    await tester.pumpWidget(_app(const V2ModelShareChart(slices: _models)));
    await tester.pumpAndSettle();

    expect(find.text('Usage by model'), findsOneWidget);
    expect(find.text('Share of tokens'), findsOneWidget);
    expect(find.text('3 models'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('78%'), findsOneWidget);
    expect(find.text('9.6M tokens'), findsOneWidget);
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('usage-chart-model-share')),
    );
    expect(node.label, 'Model share chart. Auto 78%, GPT 12%, Claude 10%.');
    handle.dispose();
  });

  testWidgets('image chart paints a line and announces its peak', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    await tester.pumpWidget(_app(const V2ImageUsageChart(points: _images7)));
    await tester.pumpAndSettle();

    expect(find.text('Images generated'), findsOneWidget);
    expect(find.text('Per day'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('images'), findsOneWidget);

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('usage-chart-images')),
    );
    expect(node.label, contains('Image usage chart, 7 days'));
    expect(node.label, contains('86 images total'));
    expect(node.label, contains('Peak Fri, 21 images'));
    handle.dispose();
  });

  testWidgets('every chart has an empty state with a next action', (
    tester,
  ) async {
    _phone(tester);
    var started = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            V2DailyTokensChart(onStartChat: () => started++),
            V2ModelShareChart(onStartChat: () => started++),
            V2ImageUsageChart(onStartChat: () => started++),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No token activity yet'), findsOneWidget);
    expect(find.text('No model use yet'), findsOneWidget);
    expect(find.text('No images yet'), findsOneWidget);
    expect(find.text('Start a chat'), findsNWidgets(3));

    for (var i = 0; i < 3; i++) {
      final button = find.text('Start a chat').at(i);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }
    expect(started, 3);
  });

  testWidgets('error state retries and loading shows the skeleton', (
    tester,
  ) async {
    _phone(tester);
    var retried = 0;
    await tester.pumpWidget(
      _app(
        V2ImageUsageChart(
          status: V2UsageChartStatus.error,
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('We could not load your image usage.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retried, 1);

    await tester.pumpWidget(
      _app(const V2DailyTokensChart(status: V2UsageChartStatus.loading)),
    );
    await tester.pump();
    expect(find.byType(OSkeleton), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('usage-chart-daily')),
      findsNothing,
    );
  });

  testWidgets('explicit empty status wins over stale points', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const V2DailyTokensChart(
          points: _tokens7,
          status: V2UsageChartStatus.empty,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No token activity yet'), findsOneWidget);
    expect(find.text('74.2M'), findsNothing);
  });

  testWidgets('range tabs are 48 dp buttons and announce disabled state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phone(tester);

    await tester.pumpWidget(
      _app(V2DailyTokensChart(points: _tokens7, onRangeChanged: (_) {})),
    );
    await tester.pumpAndSettle();

    final tab = tester.getSemantics(find.text('7 days'));
    expect(tab.label, 'Last 7 days');
    expect(tab.rect.height, greaterThanOrEqualTo(48));
    expect(
      tab,
      isSemantics(
        label: 'Last 7 days',
        hasTapAction: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );

    await tester.pumpWidget(_app(const V2DailyTokensChart(points: _tokens7)));
    await tester.pumpAndSettle();

    final disabled = tester.getSemantics(find.text('30 days'));
    expect(disabled.label, 'Last 30 days');
    expect(
      disabled,
      isSemantics(
        label: 'Last 30 days',
        hasTapAction: false,
        hasEnabledState: true,
        isEnabled: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('charts stay inside 320 dp at 200 % text in light and dark', (
    tester,
  ) async {
    _small(tester);
    final charts = Column(
      children: [
        V2DailyTokensChart(points: _tokens7, onRangeChanged: (_) {}),
        const V2ModelShareChart(slices: _models),
        const V2ImageUsageChart(points: _images7),
      ],
    );

    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _app(charts, theme: theme, textScaler: const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The daily chart keeps only its range switch; the other two charts
      // keep their headers because they render standalone in previews.
      expect(find.text('Daily tokens'), findsNothing);
      expect(find.text('Usage by model'), findsOneWidget);
      expect(find.text('Images generated'), findsOneWidget);
      expect(find.text('7 days'), findsOneWidget);
    }
  });

  testWidgets('empty charts also fit 320 dp at 200 % text', (tester) async {
    _small(tester);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            V2DailyTokensChart(onStartChat: () {}),
            V2ModelShareChart(onStartChat: () {}),
            V2ImageUsageChart(onStartChat: () {}),
          ],
        ),
        textScaler: const TextScaler.linear(2),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No token activity yet'), findsOneWidget);
    expect(find.text('No model use yet'), findsOneWidget);
    expect(find.text('No images yet'), findsOneWidget);
  });

  testWidgets('wide cards keep the range switch inline', (tester) async {
    await tester.pumpWidget(
      _app(V2DailyTokensChart(points: _tokens7, onRangeChanged: (_) {})),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
  });

  testWidgets('an empty chart labels the action that is actually wired', (
    tester,
  ) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(V2DailyTokensChart(onRetry: () => retried++)),
    );
    await tester.pumpAndSettle();

    // No chat callback: the button must say what it does.
    expect(find.text('Start a chat'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retried, 1);

    await tester.pumpWidget(
      _app(V2DailyTokensChart(onStartChat: () {})),
    );
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Start a chat'), findsOneWidget);
  });
}
