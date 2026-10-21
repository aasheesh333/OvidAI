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
  V2UsageModel(
    id: 'gpt',
    name: 'GPT-4o / Mini',
    subtitle: 'OpenAI engines',
    percent: 12,
    tokensLabel: '1.5M tokens',
    tone: V2UsageTone.success,
  ),
  V2UsageModel(
    id: 'claude',
    name: 'Claude 3.7 Sonnet',
    subtitle: 'Anthropic engine',
    percent: 10,
    tokensLabel: '1.2M tokens',
    tone: V2UsageTone.warn,
  ),
];

V2UsageData _usageData({
  V2UsageStatus status = V2UsageStatus.ready,
  V2UsageRange range = V2UsageRange.today,
  String planId = 'free',
  List<V2UsageDay> days = _days,
  List<V2UsageModel> models = _models,
  String? selectedDayId = 'sun',
  String requestsLabel = '1,284',
  String imagesLabel = '86',
  String imagesDetail = 'image generations',
  String storageUsedLabel = '1.2 GB',
  String storageLimitLabel = '3 GB',
  double storageFraction = 0.4,
  String resetLabel = 'Resets in 6h 12m',
  String resetsAtLabel = 'Oct 22, 2026, 6:12 AM',
  ValueChanged<V2UsageRange>? onRangeChanged,
  ValueChanged<V2UsageDay>? onDaySelected,
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
    selectedDayId: selectedDayId,
    selectedDayLabel: 'Sun (Today): 12.4M tokens',
    models: models,
    range: range,
    requestsLabel: requestsLabel,
    imagesLabel: imagesLabel,
    imagesDetail: imagesDetail,
    storageUsedLabel: storageUsedLabel,
    storageLimitLabel: storageLimitLabel,
    storageFraction: storageFraction,
    onRangeChanged: onRangeChanged,
    onDaySelected: onDaySelected,
    onStartChat: onStartChat,
    onUpgrade: onUpgrade,
    onRetry: onRetry,
  );
}

Widget _app(ThemeData theme, V2UsageData data) {
  return MaterialApp(
    theme: theme,
    home: UsagePage(data: data),
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

void main() {
  testWidgets('renders the daily ring and monthly quota in light', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('TOKENS TODAY'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    expect(find.text('of 50M tokens used'), findsOneWidget);
    expect(find.text('Resets in 6h 12m'), findsOneWidget);
    expect(find.text('Resets at Oct 22, 2026, 6:12 AM'), findsOneWidget);
    expect(find.text('Daily cap 50,000,000 tokens / 24 h'), findsOneWidget);
    expect(find.text('Monthly quota'), findsOneWidget);
    expect(find.text('1.02B used'), findsOneWidget);
    expect(find.text('1.5B limit'), findsOneWidget);
    expect(find.text('68%'), findsOneWidget);
    expect(
      find.text('Monthly cap 1,500,000,000 tokens / 30 days'),
      findsOneWidget,
    );
    expect(find.text('1× Free auto allowance · Auto only'), findsOneWidget);
    expect(find.text('THIS MONTH AT A GLANCE'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('1,284'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('image generations'), findsOneWidget);
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('of 3 GB'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    expect(find.byType(V2DailyTokensChart), findsOneWidget);
    expect(find.byType(V2ModelShareChart), findsOneWidget);
    expect(find.byType(V2ImageUsageChart), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('usage-chart-daily')),
      findsOneWidget,
    );
    expect(find.text('Usage by model'), findsOneWidget);
    expect(find.text('3 models'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Free and Go use Auto mode only.'), findsOneWidget);
    expect(find.text('Manual models unlock with Plus or Pro.'), findsOneWidget);
    expect(find.byType(OProgressBar), findsNWidgets(3));
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    expect(find.text('Claude 3.7 Sonnet'), findsOneWidget);
    expect(find.text('Usage by model'), findsOneWidget);
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

  testWidgets('upgrade CTA calls the injected callback', (tester) async {
    var upgraded = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onUpgrade: () => upgraded++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Upgrade plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upgrade plan'));
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

  testWidgets('model and image charts map the page data', (tester) async {
    final days = [
      for (var index = 0; index < 3; index++)
        V2UsageDay(
          id: 'day-$index',
          label: 'Day $index',
          fraction: 0.4 + index * 0.2,
          valueLabel: '${index + 1}M tokens',
          imageCount: index * 2,
        ),
    ];
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(days: days, models: _models)),
    );
    await tester.pumpAndSettle();

    final modelChart = tester.widget<V2ModelShareChart>(
      find.byType(V2ModelShareChart),
    );
    expect(modelChart.slices.map((slice) => slice.id), [
      'auto',
      'gpt',
      'claude',
    ]);
    expect(modelChart.slices.first.percent, 78.0);
    expect(modelChart.slices.first.valueLabel, '9.6M tokens');
    expect(
      find.byKey(const ValueKey<String>('usage-chart-model-share')),
      findsOneWidget,
    );

    final imageChart = tester.widget<V2ImageUsageChart>(
      find.byType(V2ImageUsageChart),
    );
    expect(imageChart.points.map((point) => point.count), [0, 2, 4]);
    expect(imageChart.points.last.label, 'Day 2');
    expect(find.text('6'), findsWidgets);
    expect(find.text('images'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('usage-chart-images')),
      findsOneWidget,
    );
  });

  testWidgets('range tabs call the injected callback', (tester) async {
    final ranges = <V2UsageRange>[];
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onRangeChanged: ranges.add)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('7 days'));
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
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _scaledApp(OTheme.light(), _usageData(onUpgrade: () {}), 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('TOKENS TODAY'), findsOneWidget);
    expect(find.text('Monthly quota'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Free and Go use Auto mode only.'), findsOneWidget);
    expect(find.text('Upgrade plan'), findsOneWidget);
    expect(find.text('Daily cap 50,000,000 tokens / 24 h'), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200% text in dark too', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _scaledApp(
        OTheme.dark(),
        _usageData(
          planId: 'pro',
          models: [
            ..._models,
            const V2UsageModel(
              id: 'custom-llama',
              name: 'Llama 3.3 70B',
              subtitle: 'Custom provider',
              providerLabel: 'Ollama',
              percent: 8,
              tokensLabel: '0.9M tokens',
              isCustomProvider: true,
            ),
          ],
          onUpgrade: () {},
        ),
        2,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Llama 3.3 70B'), findsOneWidget);
    expect(find.text('Includes 1 custom provider model.'), findsOneWidget);
    expect(find.text('0.9M tokens'), findsOneWidget);
    expect(
      find.text('Monthly cap 30,000,000,000 tokens / 30 days'),
      findsOneWidget,
    );
  });

  testWidgets('daily and monthly caps follow the authoritative plan table', (
    tester,
  ) async {
    _phoneSize(tester);
    const caps = <String, (String, String)>{
      'free': ('50,000,000', '1,500,000,000'),
      'go': ('75,000,000', '2,250,000,000'),
      'plus': ('250,000,000', '7,500,000,000'),
      'pro': ('1,000,000,000', '30,000,000,000'),
    };

    for (final entry in caps.entries) {
      await tester.pumpWidget(
        _app(OTheme.light(), _usageData(planId: entry.key)),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Daily cap ${entry.value.$1} tokens / 24 h'),
        findsOneWidget,
        reason: '${entry.key} daily cap',
      );
      expect(
        find.text('Monthly cap ${entry.value.$2} tokens / 30 days'),
        findsOneWidget,
        reason: '${entry.key} monthly cap',
      );
    }
  });

  testWidgets('infers paid caps from the storage limit when planId is absent', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2UsageData(
          storageLimitLabel: '15 GB',
          dailyUsedLabel: '1M',
          dailyLimitLabel: '250M',
          monthlyUsedLabel: '1B',
          monthlyLimitLabel: '7.5B',
          monthlyPercentLabel: '13%',
          billingNote: 'Billed through Google Play.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Daily cap 250,000,000 tokens / 24 h'), findsOneWidget);
    expect(
      find.text('Monthly cap 7,500,000,000 tokens / 30 days'),
      findsOneWidget,
    );
    expect(
      find.text('5× Free auto allowance · Auto + manual models'),
      findsOneWidget,
    );
  });

  testWidgets('per-model breakdown includes custom providers and images', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _usageData(
          models: const [
            ..._models,
            V2UsageModel(
              id: 'custom-llama',
              name: 'Llama 3.3 70B',
              subtitle: 'Custom provider',
              providerLabel: 'Ollama',
              percent: 8,
              tokensLabel: '0.9M tokens',
              isCustomProvider: true,
            ),
            V2UsageModel(
              id: 'custom-qwen',
              name: 'Qwen 3 Coder',
              subtitle: 'Custom provider',
              providerLabel: 'OpenRouter',
              percent: 4,
              tokensLabel: '0.4M tokens',
              isCustomProvider: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('5 models'), findsOneWidget);
    expect(find.text('Includes 2 custom provider models.'), findsOneWidget);
    expect(find.text('Llama 3.3 70B'), findsOneWidget);
    expect(find.text('Qwen 3 Coder'), findsOneWidget);
    expect(find.text('0.9M tokens'), findsOneWidget);
    expect(find.text('0.4M tokens'), findsOneWidget);
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('image generations'), findsOneWidget);
  });

  testWidgets('the reset countdown is derived from the real window', (
    tester,
  ) async {
    _phoneSize(tester);
    final windowEnd = DateTime.now().add(
      const Duration(hours: 6, minutes: 12),
    );
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          resetsAt: windowEnd,
          resetsAtLabel: 'Oct 22, 2026, 6:12 AM',
          monthlyUsedLabel: '1.02B',
          monthlyLimitLabel: '1.5B',
          monthlyPercentLabel: '68%',
          requestsLabel: '12',
          imagesLabel: '1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Derived from the instant, not from a caller-supplied frozen string.
    expect(find.textContaining('Resets in 6 h'), findsOneWidget);
    expect(find.text('Resets in 6h 12m'), findsNothing);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.248,
          resetsAt: DateTime.now().add(
            const Duration(hours: 2, minutes: 30),
          ),
          monthlyUsedLabel: '1.02B',
          monthlyLimitLabel: '1.5B',
          monthlyPercentLabel: '68%',
          requestsLabel: '12',
          imagesLabel: '1',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Resets in 2 h'), findsOneWidget);
  });

  testWidgets('missing usage renders an honest empty state, not zeros', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), const V2UsageData()));
    await tester.pumpAndSettle();

    expect(find.text('No usage yet'), findsOneWidget);
    expect(find.text('TOKENS TODAY'), findsNothing);
    expect(find.text('0'), findsNothing);
    expect(find.text('0 GB'), findsNothing);
    expect(find.text('0 of 50,000,000 tokens used today'), findsNothing);
  });

  testWidgets('unknown monthly and storage values are shown as unknown', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2UsageData(
          dailyUsedLabel: '12.4M',
          dailyLimitLabel: '50M',
          dailyFraction: 0.2,
          // The server reported today but not the monthly ledger or storage.
          monthlyPercentLabel: '',
          requestsLabel: '',
          imagesLabel: '',
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One per unknown stat: monthly percentage, requests, images, storage.
    expect(find.text(V2UsageData.unknownLabel), findsNWidgets(4));
    expect(find.text('0 GB'), findsNothing);
    expect(find.text('0%'), findsNothing);
    expect(find.text('Not tracked yet'), findsOneWidget);
  });

  testWidgets('the empty state only offers a wired action', (tester) async {
    _phoneSize(tester);
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        const V2UsageData(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start a chat'), findsNothing);
    expect(find.text('Try again'), findsNothing);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        V2UsageData(onRetry: () => retried++),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Start a chat'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retried, 1);
  });

  testWidgets('a known image count without a daily series says so', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _usageData(imagesLabel: '3', days: const []),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Daily image history is not available'), findsOneWidget);
    expect(find.text('No images yet'), findsNothing);
  });

  testWidgets('chart tabs and summaries announce their state', (tester) async {
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

    final chart = tester.getSemantics(
      find.byKey(const ValueKey<String>('usage-chart-daily')),
    );
    expect(chart.label, contains('Daily tokens chart'));
    expect(chart.label, contains('74.2M tokens total'));
    expect(chart.label, contains('Peak Fri, 16.9M tokens'));

    // With no callbacks wired the range switch reports a disabled state.
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    final disabledTab = tester.getSemantics(find.text('30 days'));
    expect(disabledTab.label, 'Last 30 days');
    expect(
      disabledTab,
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
}
