import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
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
  List<V2UsageDay> days = _days,
  List<V2UsageModel> models = _models,
  String? selectedDayId = 'sun',
  String requestsLabel = '1,284',
  String imagesLabel = '86',
  String storageUsedLabel = '1.2 GB',
  String storageLimitLabel = '3 GB',
  double storageFraction = 0.4,
  ValueChanged<V2UsageRange>? onRangeChanged,
  ValueChanged<V2UsageDay>? onDaySelected,
  VoidCallback? onStartChat,
  VoidCallback? onUpgrade,
  VoidCallback? onRetry,
}) {
  return V2UsageData(
    status: status,
    dailyUsedLabel: '12.4M',
    dailyLimitLabel: '50M',
    dailyFraction: 0.248,
    resetLabel: 'Resets in 6h 12m',
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
    expect(find.text('Monthly quota'), findsOneWidget);
    expect(find.text('1.02B used'), findsOneWidget);
    expect(find.text('1.5B limit'), findsOneWidget);
    expect(find.text('68%'), findsOneWidget);
    expect(find.text('THIS MONTH AT A GLANCE'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('1,284'), findsOneWidget);
    expect(find.text('86'), findsOneWidget);
    expect(find.text('1.2 GB'), findsOneWidget);
    expect(find.text('of 3 GB'), findsOneWidget);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('30 days'), findsOneWidget);
    expect(find.text('USAGE BY MODEL'), findsOneWidget);
    expect(find.text('3 models active'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
    expect(find.text('Upgraded models appear when active.'), findsOneWidget);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _usageData()));
    await tester.pumpAndSettle();

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('12.4M'), findsOneWidget);
    expect(find.text('Claude 3.7 Sonnet'), findsOneWidget);
    expect(find.text('USAGE BY MODEL'), findsOneWidget);
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

  testWidgets('tapping a bar reports the selected day', (tester) async {
    V2UsageDay? selected;
    await tester.pumpWidget(
      _app(OTheme.light(), _usageData(onDaySelected: (day) => selected = day)),
    );
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey<String>('usage-day-mon'));
    await tester.ensureVisible(bar);
    await tester.pumpAndSettle();
    await tester.tap(bar);
    await tester.pump();

    expect(selected?.id, 'mon');
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
    expect(find.text('Free plan uses Auto only.'), findsOneWidget);
    expect(find.text('Upgrade plan'), findsOneWidget);
  });

  testWidgets('tabs and bars announce labels, targets and disabled state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _phoneSize(tester);

    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _usageData(onRangeChanged: (_) {}, onDaySelected: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    final tab = tester.getSemantics(find.text('7 days'));
    expect(tab.label, '7 days');
    expect(tab.rect.height, greaterThanOrEqualTo(48));
    expect(
      tab,
      isSemantics(
        label: '7 days',
        hasTapAction: true,
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasSelectedState: true,
      ),
    );

    final bar = tester.getSemantics(
      find.byKey(const ValueKey<String>('usage-day-mon')),
    );
    expect(bar.label, 'Mon, 8.2M tokens');
    expect(bar.rect.width, greaterThanOrEqualTo(48));
    expect(bar.rect.height, greaterThanOrEqualTo(48));

    // With no callbacks wired the same controls report a disabled state.
    await tester.pumpWidget(_app(OTheme.light(), _usageData()));
    await tester.pumpAndSettle();

    final disabledTab = tester.getSemantics(find.text('7 days'));
    expect(disabledTab.label, '7 days');
    expect(
      disabledTab,
      isSemantics(
        label: '7 days',
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
