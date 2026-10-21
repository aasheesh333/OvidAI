import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/plan_billing_page.dart';

const _plans = <V2Plan>[
  V2Plan(
    id: 'free',
    name: 'Free',
    tagline: 'For getting started',
    priceUsd: 0,
    priceInr: 0,
    priceUsdYearly: 0,
    priceInrYearly: 0,
    storageGb: 3,
    autoOnly: true,
    features: ['50M daily tokens', 'Community support'],
  ),
  V2Plan(
    id: 'go',
    name: 'Go',
    tagline: 'Great for everyday builders',
    priceUsd: 5,
    priceInr: 499,
    priceUsdYearly: 50,
    priceInrYearly: 4990,
    storageGb: 5,
    features: ['Ovid Flash 2.5 unlimited', 'Priority queue'],
  ),
  V2Plan(
    id: 'plus',
    name: 'Plus',
    tagline: 'Power tools for fast work',
    priceUsd: 18,
    priceInr: 1799,
    priceUsdYearly: 180,
    priceInrYearly: 17990,
    storageGb: 15,
    features: [
      'Ovid Pro 1.5 and Claude 3.7',
      '200M daily tokens',
      'Fastest speed',
    ],
    popular: true,
  ),
  V2Plan(
    id: 'pro',
    name: 'Pro',
    tagline: 'Heavy compute for teams',
    priceUsd: 99,
    priceInr: 9999,
    priceUsdYearly: 990,
    priceInrYearly: 99990,
    storageGb: 75,
    features: [
      'All advanced reasoning models',
      'Unlimited tokens',
      'Dedicated cloud agent sandbox',
    ],
  ),
];

const _history = <V2BillingHistoryEntry>[
  V2BillingHistoryEntry(
    id: 'inv_plus_09',
    title: 'Plus plan',
    dateLabel: 'Sep 18, 2026',
    amountLabel: r'$18.00',
  ),
  V2BillingHistoryEntry(
    id: 'inv_go_08',
    title: 'Go plan',
    dateLabel: 'Aug 18, 2026',
    amountLabel: r'$5.00',
  ),
];

V2PlanBillingData _billingData({
  V2PlanBillingStatus status = V2PlanBillingStatus.ready,
  V2Currency currency = V2Currency.usd,
  V2BillingPeriod period = V2BillingPeriod.monthly,
  String currentPlanId = 'free',
  List<V2Plan> plans = _plans,
  List<V2BillingHistoryEntry> history = const [],
  ValueChanged<V2Currency>? onCurrencyChanged,
  ValueChanged<V2BillingPeriod>? onPeriodChanged,
  ValueChanged<V2Plan>? onSelectPlan,
  VoidCallback? onUpgrade,
  VoidCallback? onRestorePurchases,
  ValueChanged<V2BillingHistoryEntry>? onHistoryTap,
  VoidCallback? onRetry,
}) {
  return V2PlanBillingData(
    status: status,
    currency: currency,
    period: period,
    currentPlanId: currentPlanId,
    plans: plans,
    history: history,
    onCurrencyChanged: onCurrencyChanged,
    onPeriodChanged: onPeriodChanged,
    onSelectPlan: onSelectPlan,
    onUpgrade: onUpgrade,
    onRestorePurchases: onRestorePurchases,
    onHistoryTap: onHistoryTap,
    onRetry: onRetry,
  );
}

Finder _inCard(String planId, String text) => find.descendant(
  of: find.byKey(ValueKey<String>('plan-card-$planId')),
  matching: find.text(text),
);

Finder _inTable(String text) => find.descendant(
  of: find.byKey(const ValueKey<String>('plan-compare-table')),
  matching: find.text(text),
);

Widget _app(ThemeData theme, V2PlanBillingData data) {
  return MaterialApp(
    theme: theme,
    home: PlanBillingPage(data: data),
  );
}

void _phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('renders all four plans in light', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('ACCOUNT TIER'), findsOneWidget);
    expect(find.text('Current plan'), findsOneWidget);
    expect(_inCard('free', 'Free'), findsOneWidget);
    expect(_inCard('free', r'$0'), findsOneWidget);
    expect(_inCard('go', 'Go'), findsOneWidget);
    expect(_inCard('go', r'$5'), findsOneWidget);
    expect(_inCard('plus', 'Plus'), findsOneWidget);
    expect(_inCard('plus', r'$18'), findsOneWidget);
    expect(_inCard('pro', 'Pro'), findsOneWidget);
    expect(_inCard('pro', r'$99'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    expect(_inCard('free', '3 GB'), findsOneWidget);
    expect(_inCard('go', '5 GB'), findsOneWidget);
    expect(_inCard('plus', '15 GB'), findsOneWidget);
    expect(_inCard('pro', '75 GB'), findsOneWidget);
    expect(find.text('Auto only'), findsNWidgets(4));
    expect(find.text('PAYMENT HISTORY'), findsOneWidget);
    expect(find.text('No payments yet'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
    expect(find.textContaining('Google Play'), findsOneWidget);
  });

  testWidgets('every plan card shows the exact limits from the plan table', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    const expected = <String, List<String>>{
      'free': [
        '3 GB',
        '50 files / day',
        '80 files max / project',
        'Auto only',
        '1× auto',
      ],
      'go': [
        '5 GB',
        '80 files / 3 h',
        '100 files max / project',
        'Auto only',
        '1.5× auto',
      ],
      'plus': [
        '15 GB',
        '80 files / 3 h',
        '150 files max / project',
        'Auto + manual models',
        '5× auto',
      ],
      'pro': [
        '75 GB',
        '80 files / 3 h',
        '250 files max / project',
        'Auto + manual models',
        '20× auto',
      ],
    };

    for (final entry in expected.entries) {
      for (final text in entry.value) {
        expect(
          _inCard(entry.key, text),
          findsOneWidget,
          reason: '${entry.key} should show "$text"',
        );
      }
    }
  });

  testWidgets('plan limits table compares all four plans and gates models', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('PLAN LIMITS'), findsOneWidget);
    expect(_inTable('Go'), findsOneWidget);
    expect(_inTable('Plus'), findsOneWidget);
    expect(_inTable('Pro'), findsOneWidget);

    for (final text in [
      'Storage',
      'Files / day',
      'Files / project',
      'Model access',
      'Auto multiplier',
      'Custom connectors',
      'Token caps',
      'Price',
    ]) {
      expect(_inTable(text), findsOneWidget, reason: 'row $text');
    }

    expect(_inTable('100 max'), findsOneWidget);
    expect(_inTable('150 max'), findsOneWidget);
    expect(_inTable('250 max'), findsOneWidget);
    expect(_inTable('Auto + manual'), findsNWidgets(2));
    expect(_inTable('1.5×'), findsOneWidget);
    expect(_inTable('5×'), findsOneWidget);
    expect(_inTable('20×'), findsOneWidget);
    expect(_inTable('75M / 24 h'), findsOneWidget);
    expect(_inTable('1.5B / 30 d'), findsOneWidget);

    expect(find.text('Auto mode only'), findsOneWidget);
    expect(
      find.textContaining('Manual models unlock with Plus or Pro'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the comparison column follows the current plan and file windows',
    (tester) async {
      _phoneSize(tester);
      await tester.pumpWidget(
        _app(OTheme.light(), _billingData(currentPlanId: 'go')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('plan-compare-current-go')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('plan-compare-header-go')),
        findsOneWidget,
      );
      // Free is 50/day; the three paid plans normalise 80 every 3 h to 640/day.
      expect(_inTable('50 / day'), findsOneWidget);
      expect(_inTable('640 / day'), findsNWidgets(3));
      expect(_inTable('80 / 3 h'), findsNWidgets(3));
    },
  );

  testWidgets('the current plan badge follows the current plan id', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(OTheme.light(), _billingData(currentPlanId: 'plus')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current plan'), findsOneWidget);
    expect(_inCard('plus', 'Current plan'), findsOneWidget);
    expect(_inCard('plus', '15 GB'), findsOneWidget);
    expect(find.text('Select Plus'), findsNothing);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(_inCard('plus', r'$18'), findsOneWidget);
    expect(_inTable(r'$18'), findsOneWidget);
  });

  testWidgets('empty state retry fires', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(
          status: V2PlanBillingStatus.empty,
          plans: const [],
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No plans to show'), findsOneWidget);
    await tester.tap(find.text('Check plans again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('selecting Go calls the injected callback', (tester) async {
    V2Plan? selected;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(onSelectPlan: (plan) => selected = plan),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Select Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select Go'));
    await tester.pump();

    expect(selected?.id, 'go');
  });

  testWidgets('currency toggle updates the prices', (tester) async {
    final changes = <V2Currency>[];
    var currency = V2Currency.usd;
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return PlanBillingPage(
              data: _billingData(
                currency: currency,
                onCurrencyChanged: (value) {
                  changes.add(value);
                  setState(() => currency = value);
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inCard('go', r'$5'), findsOneWidget);
    await tester.tap(find.text('INR (₹)'));
    await tester.pumpAndSettle();

    expect(changes, [V2Currency.inr]);
    for (final entry in const {
      'free': '₹0',
      'go': '₹499',
      'plus': '₹1,799',
      'pro': '₹9,999',
    }.entries) {
      expect(
        _inCard(entry.key, entry.value),
        findsOneWidget,
        reason: '${entry.key} card',
      );
      expect(
        _inTable(entry.value),
        findsOneWidget,
        reason: '${entry.key} comparison column',
      );
    }
  });

  testWidgets('billing period toggle updates the prices', (tester) async {
    final changes = <V2BillingPeriod>[];
    var period = V2BillingPeriod.monthly;
    late StateSetter setState;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: StatefulBuilder(
          builder: (context, setter) {
            setState = setter;
            return PlanBillingPage(
              data: _billingData(
                period: period,
                onPeriodChanged: (value) {
                  changes.add(value);
                  setState(() => period = value);
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_inCard('go', r'$5'), findsOneWidget);
    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();

    expect(changes, [V2BillingPeriod.yearly]);
    for (final entry in const {
      'go': r'$50',
      'plus': r'$180',
      'pro': r'$990',
    }.entries) {
      expect(_inCard(entry.key, entry.value), findsOneWidget);
      expect(_inTable(entry.value), findsOneWidget);
    }
    expect(_inCard('go', '/ year'), findsOneWidget);
    expect(_inTable('/ year'), findsNWidgets(4));
  });

  testWidgets('payment history renders and rows call the callback', (
    tester,
  ) async {
    V2BillingHistoryEntry? tapped;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(
          history: _history,
          onHistoryTap: (entry) => tapped = entry,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 payments'), findsOneWidget);
    expect(find.text('Plus plan'), findsOneWidget);
    expect(find.text(r'$18.00'), findsOneWidget);

    await tester.ensureVisible(find.text('Plus plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plus plan'));
    await tester.pump();

    expect(tapped?.id, 'inv_plus_09');
  });

  testWidgets('restore purchases calls the injected callback', (tester) async {
    var restored = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _billingData(onRestorePurchases: () => restored++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore purchases'));
    await tester.pump();

    expect(restored, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(
          status: V2PlanBillingStatus.error,
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, 1);
  });

  testWidgets('empty history offers a next action that fires', (tester) async {
    var upgrades = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _billingData(onUpgrade: () => upgrades++)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('See plans'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See plans'));
    await tester.pump();

    expect(upgrades, 1);
  });

  testWidgets('toggles are 48 dp and announce selection', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(onCurrencyChanged: (_) {}, onPeriodChanged: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['Monthly', 'Yearly', r'USD ($)', 'INR (₹)']) {
      final target = find.ancestor(
        of: find.text(label),
        matching: find.byType(OPressable),
      );
      expect(target, findsOneWidget, reason: '$label has a tap target');
      expect(
        tester.getSize(target).height,
        greaterThanOrEqualTo(48),
        reason: '$label is at least 48 dp tall',
      );
    }

    final monthly = tester
        .getSemantics(find.text('Monthly'))
        .getSemanticsData()
        .flagsCollection;
    final yearly = tester
        .getSemantics(find.text('Yearly'))
        .getSemanticsData()
        .flagsCollection;
    expect(monthly.isSelected, Tristate.isTrue);
    expect(yearly.isSelected, Tristate.isFalse);
  });

  testWidgets('toggles announce the disabled state without callbacks', (
    tester,
  ) async {
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    final monthly = tester
        .getSemantics(find.text('Monthly'))
        .getSemanticsData()
        .flagsCollection;
    expect(monthly.isEnabled, Tristate.isFalse);
  });

  testWidgets('reduced motion keeps every plan and the history', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: PlanBillingPage(data: _billingData(history: _history)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnimatedOpacity), findsNothing);
    for (final entry in const {
      'free': 'Free',
      'go': 'Go',
      'plus': 'Plus',
      'pro': 'Pro',
    }.entries) {
      expect(
        _inCard(entry.key, entry.value),
        findsOneWidget,
        reason: '${entry.value} stays visible',
      );
    }
    expect(find.text('Plus plan'), findsOneWidget);
  });

  testWidgets('320 dp at 200 % text lays out every state', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in V2PlanBillingStatus.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: PlanBillingPage(
              data: _billingData(
                status: status,
                plans: status == V2PlanBillingStatus.ready ? _plans : const [],
                history: status == V2PlanBillingStatus.ready
                    ? _history
                    : const [],
                onCurrencyChanged: (_) {},
                onPeriodChanged: (_) {},
                onSelectPlan: (_) {},
                onUpgrade: () {},
                onRestorePurchases: () {},
                onHistoryTap: (_) {},
                onRetry: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull, reason: 'state $status overflows');
    }
  });

  testWidgets('320 dp at 200 % text renders the content in dark too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: PlanBillingPage(
            data: _billingData(
              history: _history,
              onCurrencyChanged: (_) {},
              onPeriodChanged: (_) {},
              onSelectPlan: (_) {},
              onUpgrade: () {},
              onRestorePurchases: () {},
              onHistoryTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('Current plan'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
  });
}
