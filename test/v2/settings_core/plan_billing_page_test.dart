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
    currentPlanId: 'free',
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
    expect(find.text('Free'), findsOneWidget);
    expect(find.text(r'$0'), findsOneWidget);
    expect(find.text('Go'), findsOneWidget);
    expect(find.text(r'$5'), findsOneWidget);
    expect(find.text('Plus'), findsOneWidget);
    expect(find.text(r'$18'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text(r'$99'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
    expect(find.text('3 GB storage'), findsOneWidget);
    expect(find.text('5 GB storage'), findsOneWidget);
    expect(find.text('15 GB storage'), findsOneWidget);
    expect(find.text('75 GB storage'), findsOneWidget);
    expect(find.text('Auto only'), findsOneWidget);
    expect(find.text('PAYMENT HISTORY'), findsOneWidget);
    expect(find.text('No payments yet'), findsOneWidget);
    expect(find.text('Restore purchases'), findsOneWidget);
    expect(find.textContaining('Google Play'), findsOneWidget);
  });

  testWidgets('renders correctly in dark', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.dark(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.text(r'$18'), findsOneWidget);
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

    expect(find.text(r'$5'), findsOneWidget);
    await tester.tap(find.text('INR (₹)'));
    await tester.pumpAndSettle();

    expect(changes, [V2Currency.inr]);
    expect(find.text('₹0'), findsOneWidget);
    expect(find.text('₹499'), findsOneWidget);
    expect(find.text('₹1,799'), findsOneWidget);
    expect(find.text('₹9,999'), findsOneWidget);
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

    expect(find.text(r'$5'), findsOneWidget);
    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();

    expect(changes, [V2BillingPeriod.yearly]);
    expect(find.text(r'$50'), findsOneWidget);
    expect(find.text(r'$180'), findsOneWidget);
    expect(find.text(r'$990'), findsOneWidget);
    expect(find.text('/ year'), findsNWidgets(4));
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
    for (final label in ['Free', 'Go', 'Plus', 'Pro']) {
      expect(find.text(label), findsOneWidget, reason: '$label stays visible');
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
