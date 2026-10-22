import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/usage_charts.dart';
import 'package:ovid_ai/ui/v2/settings/usage_page.dart';

const _days = <V2UsageDay>[
  V2UsageDay(
    id: 'mon',
    label: 'Mon',
    fraction: 0.52,
    valueLabel: '8.2M tokens',
  ),
  V2UsageDay(
    id: 'tue',
    label: 'Tue',
    fraction: 0.75,
    valueLabel: '14.1M tokens',
  ),
  V2UsageDay(
    id: 'wed',
    label: 'Wed',
    fraction: 0.40,
    valueLabel: '6.5M tokens',
  ),
  V2UsageDay(
    id: 'thu',
    label: 'Thu',
    fraction: 0.64,
    valueLabel: '11.8M tokens',
  ),
  V2UsageDay(
    id: 'fri',
    label: 'Fri',
    fraction: 0.88,
    valueLabel: '16.9M tokens',
  ),
  V2UsageDay(
    id: 'sat',
    label: 'Sat',
    fraction: 0.28,
    valueLabel: '4.3M tokens',
  ),
  V2UsageDay(
    id: 'sun',
    label: 'Sun',
    fraction: 0.68,
    valueLabel: '12.4M tokens',
  ),
];

const _models = <V2UsageModel>[
  V2UsageModel(
    id: 'auto',
    name: 'Auto',
    subtitle: 'Default smart router',
    percent: 78,
    tokensLabel: '9.6M tokens',
  ),
];

V2UsageData _usageData({
  V2UsageStatus status = V2UsageStatus.ready,
  V2UsageRange range = V2UsageRange.today,
  String planId = 'free',
  List<V2UsageDay> days = _days,
  List<V2UsageModel> models = _models,
  String resetLabel = 'Resets in 6h 12m',
  String resetsAtLabel = 'Oct 22, 2026, 6:12 AM',
  ValueChanged<V2UsageRange>? onRangeChanged,
  VoidCallback? onStartChat,
  VoidCallback? onUpgrade,
  VoidCallback? onRetry,
}) {
  return V2UsageData(
    status: status,
    planId: planId,
    dailyUsedLabel: '12.4M',
    dailyLimitLabel: '50M',
    dailyFraction: 0.248,
    resetLabel: resetLabel,
    resetsAtLabel: resetsAtLabel,
    monthlyUsedLabel: '1.02B',
    monthlyLimitLabel: '1.5B',
    monthlyFraction: 0.68,
    monthlyPercentLabel: '68%',
    billingNote: 'Billing cycle ends in 18 days',
    days: days,
    selectedDayId: 'sun',
    selectedDayLabel: 'Sun (Today): 12.4M tokens',
    models: models,
    range: range,
    requestsLabel: '1,284',
    imagesLabel: '86',
    storageUsedLabel: '1.2 GB',
    storageLimitLabel: '3 GB',
    storageFraction: 0.4,
    onRangeChanged: onRangeChanged,
    onStartChat: onStartChat,
    onUpgrade: onUpgrade,
    onRetry: onRetry,
  );
}

Widget _app(ThemeData theme, V2UsageData data, {DateTime Function()? clock}) {
  return MaterialApp(
    theme: theme,
    home: UsagePage(data: data, clock: clock),
  );
}

Widget _scaledApp(ThemeData theme, V2UsageData data, double scale) {
  return MaterialApp(
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: UsagePage(data: data),
  );
}

void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('one hero number, one chart, one range switch', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('Tokens today'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    expect(find.text('of 50M tokens'), findsOneWidget);
    expect(find.text('Resets in 6h 12m'), findsOneWidget);
    expect(find.byType(OProgressBar), findsOneWidget);

    // One chart, one range switch. No chart title, no axis labels, no legend.
    expect(find.byType(V2DailyTokensChart), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    expect(find.text('Activity'), findsNothing);
    expect(find.text('Mon'), findsNothing);
    expect(find.text('Sun'), findsNothing);

    // The multi-card dashboard is gone.
    expect(find.text('TOKENS TODAY'), findsNothing);
    expect(find.text('Monthly quota'), findsNothing);
    expect(find.text('THIS MONTH AT A GLANCE'), findsNothing);
    expect(find.text('Requests'), findsNothing);
    expect(find.text('Usage by model'), findsNothing);
    expect(find.byType(V2ModelShareChart), findsNothing);
    expect(find.byType(V2ImageUsageChart), findsNothing);
    expect(find.textContaining('Free and Go use Auto'), findsNothing);
    expect(find.text('Upgrade plan'), findsNothing);
  });

  testWidgets('monthly total comes from the ledger, missing is a dash', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('This month: 1.02B of 1.5B'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          planId: 'free',
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          days: _days,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The monthly cap still comes from the plan table, but the unknown used
    // value is a dash, never a fabricated zero.
    expect(find.text('This month: — of 1.5B'), findsOneWidget);
  });

  testWidgets('an unknown daily count paints no progress and no zero', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          planId: 'free',
          monthlyUsedLabel: '1.02B',
          monthlyLimitLabel: '1.5B',
          days: _days,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('—'), findsOneWidget);
    expect(find.byType(OProgressBar), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('This month: 1.02B of 1.5B'), findsOneWidget);
  });

  testWidgets('the reset countdown ticks and stops at the window', (
    tester,
  ) async {
    _phoneSize(tester);
    final start = DateTime(2026, 10, 22, 12);
    var now = start;

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          planId: 'free',
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          resetsAt: start.add(const Duration(minutes: 2)),
          days: _days,
        ),
        clock: () => now,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Resets in 2 m'), findsOneWidget);

    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Resets in 1 m'), findsOneWidget);

    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Resets now'), findsOneWidget);
  });

  testWidgets('an empty window still offers the 7/30 switch', (tester) async {
    _phoneSize(tester);
    final ranges = <V2UsageRange>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          planId: 'free',
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          monthlyUsedLabel: '1.02B',
          days: const [],
          onRangeChanged: ranges.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No token activity yet'), findsOneWidget);
    await tester.tap(find.text('30 days'));
    await tester.pump();

    expect(ranges, [V2UsageRange.thirtyDays]);
  });

  testWidgets('a day without a real count is not invented', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          planId: 'free',
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          days: const [V2UsageDay(id: 'mon', label: 'Mon', fraction: 0.5)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<V2DailyTokensChart>(
      find.byType(V2DailyTokensChart),
    );
    expect(chart.points.single.value, 0);
    expect(find.text('No token activity yet'), findsOneWidget);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    expect(find.byType(V2DailyTokensChart), findsOneWidget);
  });

  testWidgets('empty state action fires', (tester) async {
    var started = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _usageData(status: V2UsageStatus.empty, onStartChat: () => started++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No usage yet'), findsOneWidget);
    await tester.tap(find.text('Start a chat'));
    await tester.pump();

    expect(started, 1);
  });

  testWidgets('upgrade is the single header action', (tester) async {
    var upgraded = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onUpgrade: () => upgraded++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('usage-upgrade')));
    await tester.pump();

    expect(upgraded, 1);
  });

  testWidgets('daily token chart maps the page day list and range', (
    tester,
  ) async {
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    final chart = tester.widget<V2DailyTokensChart>(
      find.byType(V2DailyTokensChart),
    );
    expect(chart.range, V2UsageChartRange.sevenDays);
    expect(chart.points.map((point) => point.id), [
      'mon',
      'tue',
      'wed',
      'thu',
      'fri',
      'sat',
      'sun',
    ]);
    expect(chart.points.first.value, closeTo(8.2 * 1000000, 1));
    expect(chart.points.last.value, closeTo(12.4 * 1000000, 1));
    expect(chart.points.last.valueLabel, '12.4M tokens');
  });

  testWidgets('range tabs call the injected callback', (tester) async {
    final ranges = <V2UsageRange>[];
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onRangeChanged: ranges.add)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('7 days'));
    await tester.pump();

    expect(ranges, [V2UsageRange.sevenDays]);
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _usageData(status: V2UsageStatus.error, onRetry: () => retried++),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    _size(tester, const Size(320, 640));

    await tester.pumpWidget(
      _scaledApp(OTheme.light(), _usageData(onUpgrade: () {}), 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('Tokens today'), findsOneWidget);
    expect(find.byType(V2DailyTokensChart), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200% text in dark too', (tester) async {
    _size(tester, const Size(320, 640));

    await tester.pumpWidget(
      _scaledApp(OTheme.dark(), _usageData(planId: 'pro', onUpgrade: () {}), 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Usage'), findsOneWidget);
  });

  testWidgets('the caps follow the authoritative plan table', (tester) async {
    _phoneSize(tester);
    const caps = <String, String>{
      'free': '50M',
      'go': '75M',
      'plus': '250M',
      'pro': '1B',
    };

    for (final entry in caps.entries) {
      await tester.pumpWidget(
        _app(
          OTheme.light(),
          V2UsageData(
            planId: entry.key,
            dailyUsedLabel: '12.4M',
            dailyFraction: 0.1,
            days: _days,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('of ${entry.value} tokens'),
        findsOneWidget,
        reason: '${entry.key} cap',
      );
    }
  });

  testWidgets('the reset countdown is derived from the real window', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          resetsAt: DateTime.now().add(const Duration(hours: 6, minutes: 12)),
          days: _days,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Resets in 6 h'), findsOneWidget);
  });

  testWidgets('missing usage renders an honest empty state, not zeros', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), const V2UsageData()));
    await tester.pumpAndSettle();

    expect(find.text('No usage yet'), findsOneWidget);
    expect(find.text('Tokens today'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('0 GB'), findsNothing);
  });

  testWidgets('the empty state only offers a wired action', (tester) async {
    _phoneSize(tester);
    var retried = 0;
    await tester.pumpWidget(_app(OTheme.light(), const V2UsageData()));
    await tester.pumpAndSettle();
    expect(find.text('Start a chat'), findsNothing);
    expect(find.text('Try again'), findsNothing);

    await tester.pumpWidget(
      _app(OTheme.light(), V2UsageData(onRetry: () => retried++)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start a chat'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('chart tabs announce their state', (tester) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);

    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onRangeChanged: (_) {})),
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
    handle.dispose();
  });

  testWidgets('paints every band width in both themes and text scales', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      for (final scale in [1.0, 2.0]) {
        for (final width in [320.0, 360.0, 412.0, 600.0, 1024.0, 1280.0]) {
          _size(tester, Size(width, 900));
          await tester.pumpWidget(
            _scaledApp(
              theme,
              _usageData(onRangeChanged: (_) {}, onUpgrade: () {}),
              scale,
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: '${width}dp at ${scale}x',
          );
          expect(find.text('Tokens today'), findsOneWidget);
          expect(find.byType(V2DailyTokensChart), findsOneWidget);
        }
      }
    }
  });

  testWidgets('600 dp centres the hero and the chart at 640', (tester) async {
    _size(tester, const Size(800, 1000));
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    // One hero, one chart, one range switch.
    expect(find.text('Tokens today'), findsOneWidget);
    expect(find.byType(V2DailyTokensChart), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    // The multi-card dashboard stays deleted at tablet widths.
    expect(find.text('Usage by model'), findsNothing);
    expect(find.text('Images generated'), findsNothing);
    expect(find.text('Monthly quota'), findsNothing);

    final chart = tester.getSize(find.byType(V2DailyTokensChart));
    expect(chart.width, lessThanOrEqualTo(640 - 48));
    final left = tester.getTopLeft(find.text('Tokens today')).dx;
    expect(left, greaterThan(40));
  });

  testWidgets('900 dp caps the content at 720 and centres it', (tester) async {
    _size(tester, const Size(1200, 1000));
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.byType(V2DailyTokensChart), findsOneWidget);
    expect(find.text('Tokens today'), findsOneWidget);

    final chart = tester.getSize(find.byType(V2DailyTokensChart));
    expect(chart.width, lessThanOrEqualTo(720 - 48));
    final left = tester.getTopLeft(find.text('Tokens today')).dx;
    final right = tester.getTopRight(find.byType(V2DailyTokensChart)).dx;
    expect(left, closeTo(1200 - right, 1));
  });
}
