import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
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
      'Ovid Pro 1.5 and the model',
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
  ValueChanged<V2PlanPurchase>? onPurchase,
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
    onPurchase: onPurchase,
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

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test(
    'model access matches the real Auto-only gate (free/go vs plus/pro)',
    () {
      // The shell gate is `autoOnly = tier == 'free' || tier == '3x'`
      // (v2_app_shell.dart). Server tier ids must resolve the same way here.
      for (final tier in ['free', '3x']) {
        final limits = V2PlanLimits.forIdOrFree(tier);
        expect(limits.manualModels, isFalse, reason: '$tier is Auto only');
        expect(limits.modelAccessLabel, 'Auto only');
      }
      for (final tier in ['7x', '15x']) {
        final limits = V2PlanLimits.forIdOrFree(tier);
        expect(limits.manualModels, isTrue, reason: '$tier allows manual');
        expect(limits.modelAccessLabel, 'Auto + manual models');
      }
    },
  );

  testWidgets('one header and four cards: name, price, one line, one CTA', (
    tester,
  ) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    // Exactly one title, in the header. No body heading repeats it.
    expect(find.text('Plan & billing'), findsOneWidget);
    expect(find.text('ACCOUNT TIER'), findsNothing);

    for (final entry in const {
      'free': ('Free', r'$0'),
      'go': ('Go', r'$5'),
      'plus': ('Plus', r'$18'),
      'pro': ('Pro', r'$99'),
    }.entries) {
      expect(_inCard(entry.key, entry.value.$1), findsOneWidget);
      expect(_inCard(entry.key, entry.value.$2), findsOneWidget);
    }

    // One line per card: the tagline, never a feature bullet list.
    expect(_inCard('plus', 'Power tools for fast work'), findsOneWidget);
    expect(_inCard('plus', 'Fastest speed'), findsNothing);
    expect(_inCard('plus', '200M daily tokens'), findsNothing);
    expect(find.text('Most popular'), findsNothing);

    // The long limit rows moved to the comparison table.
    for (final text in [
      '3 GB',
      '50 files / day',
      '80 files max / project',
      '1× auto',
    ]) {
      expect(_inCard('free', text), findsNothing, reason: text);
    }

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Yearly'), findsOneWidget);
  });

  testWidgets('the comparison table keeps every plan limit', (tester) async {
    _phoneSize(tester);
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('PLAN LIMITS'), findsOneWidget);
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
    expect(_inTable('3 GB'), findsOneWidget);
    expect(_inTable('75 GB'), findsOneWidget);
    expect(_inTable('50 / day'), findsOneWidget);
    expect(_inTable('640 / day'), findsNWidgets(3));
    expect(_inTable('1.5×'), findsOneWidget);
    expect(_inTable('75M / 24 h'), findsOneWidget);
  });

  testWidgets('the current plan is marked and its CTA is disabled', (
    tester,
  ) async {
    _phoneSize(tester);
    final purchases = <V2PlanPurchase>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(currentPlanId: 'plus', onPurchase: purchases.add),
      ),
    );
    await tester.pumpAndSettle();

    final cta = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('plan-cta-plus')),
    );
    expect(cta.label, 'Current plan');
    expect(cta.onPressed, isNull);
    expect(find.text('Current plan'), findsOneWidget);
    expect(find.text('Select Plus'), findsNothing);
    expect(purchases, isEmpty);

    // The current card carries the 2 dp accent edge.
    final card = tester.widget<Container>(
      find.byKey(const ValueKey<String>('plan-card-plus')),
    );
    final border = (card.decoration! as BoxDecoration).border! as Border;
    expect(border.top.width, 2);
    // Another card keeps the hairline edge.
    final other = tester.widget<Container>(
      find.byKey(const ValueKey<String>('plan-card-go')),
    );
    final otherBorder = (other.decoration! as BoxDecoration).border! as Border;
    expect(otherBorder.top.width, 1);
  });

  testWidgets('each plan CTA buys that plan with its own store product', (
    tester,
  ) async {
    _phoneSize(tester);
    final purchases = <V2PlanPurchase>[];
    await tester.pumpWidget(
      _app(OTheme.light(), _billingData(onPurchase: purchases.add)),
    );
    await tester.pumpAndSettle();

    for (final entry in const {
      'go': ('3x', 'ovid_plus_monthly'),
      'plus': ('7x', 'ovid_pro_monthly'),
      'pro': ('15x', 'ovid_max_monthly'),
    }.entries) {
      await tester.ensureVisible(
        find.byKey(ValueKey<String>('plan-cta-${entry.key}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<String>('plan-cta-${entry.key}')));
      await tester.pump();

      final purchase = purchases.last;
      expect(purchase.planId, entry.key);
      expect(purchase.tier, entry.value.$1, reason: '${entry.key} tier');
      expect(
        purchase.productId,
        entry.value.$2,
        reason: '${entry.key} product',
      );
      expect(purchase.period, V2BillingPeriod.monthly);
    }
    expect(purchases, hasLength(3));
  });

  testWidgets('a period with no product disables the CTA with a reason', (
    tester,
  ) async {
    _phoneSize(tester);
    final purchases = <V2PlanPurchase>[];
    const unsold = V2Plan(
      id: 'team',
      name: 'Team',
      tagline: 'For bigger teams',
      priceUsd: 30,
      priceInr: 2999,
      storageGb: 20,
    );
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(plans: [unsold], onPurchase: purchases.add),
      ),
    );
    await tester.pumpAndSettle();

    final cta = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('plan-cta-team')),
    );
    expect(cta.onPressed, isNull);
    expect(cta.label, 'Not available');
    expect(
      find.text('Team is not sold with monthly billing right now.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('plan-unavailable-team')), findsOneWidget);
    expect(purchases, isEmpty);
  });

  testWidgets('the Free card is a Play management action, not a purchase', (
    tester,
  ) async {
    final purchases = <V2PlanPurchase>[];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(currentPlanId: 'go', onPurchase: purchases.add),
      ),
    );
    await tester.pumpAndSettle();

    final cta = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('plan-cta-free')),
    );
    expect(cta.label, 'Manage in Google Play');
    await tester.tap(find.byKey(const ValueKey<String>('plan-cta-free')));
    await tester.pump();

    expect(purchases.single.planId, 'free');
    expect(purchases.single.tier, 'free');
    expect(purchases.single.productId, isNull);
  });

  testWidgets('the billing period toggle changes price and product', (
    tester,
  ) async {
    final purchases = <V2PlanPurchase>[];
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
                onPurchase: purchases.add,
                onPeriodChanged: (value) => setState(() => period = value),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();

    expect(_inCard('go', r'$50'), findsOneWidget);
    expect(_inCard('go', '/ year'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('plan-cta-go')));
    await tester.pump();

    expect(purchases.single.period, V2BillingPeriod.yearly);
    expect(purchases.single.productId, 'ovid_plus_yearly');
  });

  testWidgets('server tier ids resolve to the same card and product', (
    tester,
  ) async {
    final purchases = <V2PlanPurchase>[];
    final serverPlans = [
      for (final plan in _plans)
        V2Plan(
          id: plan.id == 'go'
              ? '3x'
              : plan.id == 'plus'
              ? '7x'
              : plan.id == 'pro'
              ? '15x'
              : plan.id,
          name: plan.name,
          tagline: plan.tagline,
          priceUsd: plan.priceUsd,
          priceInr: plan.priceInr,
          storageGb: plan.storageGb,
        ),
    ];
    await tester.pumpWidget(
      _app(
        OTheme.light(),
        _billingData(
          currentPlanId: 'free',
          plans: serverPlans,
          onPurchase: purchases.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('plan-cta-3x')));
    await tester.pump();

    expect(purchases.single.planId, 'go');
    expect(purchases.single.tier, '3x');
    expect(purchases.single.productId, 'ovid_plus_monthly');
  });

  testWidgets('currency toggle updates the cards and the table', (
    tester,
  ) async {
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
      expect(_inCard(entry.key, entry.value), findsOneWidget);
      expect(_inTable(entry.value), findsOneWidget);
    }
  });

  testWidgets('payment history renders rows and calls the callback', (
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

    expect(find.text('PAYMENT HISTORY'), findsOneWidget);
    expect(find.text('Plus plan'), findsOneWidget);
    expect(find.text(r'$18.00'), findsOneWidget);
    // The count and the "See plans" secondary action are gone.
    expect(find.text('2 payments'), findsNothing);
    expect(find.text('See plans'), findsNothing);

    await tester.ensureVisible(find.text('Plus plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plus plan'));
    await tester.pump();

    expect(tapped?.id, 'inv_plus_09');
  });

  testWidgets('an empty history is a single line, not a card with an action', (
    tester,
  ) async {
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.text('No payments yet'), findsOneWidget);
    expect(find.text('See plans'), findsNothing);
    expect(find.textContaining('receipts will appear'), findsNothing);
  });

  testWidgets('restore purchases is the header action', (tester) async {
    var restored = 0;
    await tester.pumpWidget(
      _app(OTheme.light(), _billingData(onRestorePurchases: () => restored++)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restore purchases'), findsNothing);
    await tester.tap(find.byKey(const ValueKey<String>('restore-purchases')));
    await tester.pump();

    expect(restored, 1);
  });

  testWidgets('no explanatory paragraphs survive on the page', (tester) async {
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Subscriptions renew'), findsNothing);
    expect(find.text('Auto mode only'), findsNothing);
    expect(find.textContaining('Instant activation'), findsNothing);
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

  testWidgets('320 dp at 200 % text lays out every state', (tester) async {
    _size(tester, const Size(320, 640));

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
                onPurchase: (_) {},
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

  testWidgets('600 dp centres the cards in a two-column grid', (tester) async {
    _size(tester, const Size(800, 1000));
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    // Four cards, one CTA each, and no feature bullet list on the card.
    for (final id in const ['free', 'go', 'plus', 'pro']) {
      expect(find.byKey(ValueKey('plan-card-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('plan-cta-$id')), findsOneWidget);
    }
    expect(find.byType(OButton), findsNWidgets(4));
    // The detail lives in the compare table.
    expect(find.text('Storage'), findsOneWidget);
    expect(find.text('Files / day'), findsOneWidget);
    expect(find.text('Token caps'), findsOneWidget);

    final free = tester.getSize(find.byKey(const ValueKey('plan-card-free')));
    final go = tester.getSize(find.byKey(const ValueKey('plan-card-go')));
    expect(free.width, closeTo(go.width, 0.5));
    expect(free.width, lessThan(320));
    // Same row: the second card starts to the right of the first.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('plan-card-go'))).dy,
      closeTo(
        tester.getTopLeft(find.byKey(const ValueKey('plan-card-free'))).dy,
        0.5,
      ),
    );
    // Content is capped at 640 dp and centred.
    final table = tester.getSize(
      find.byKey(const ValueKey('plan-compare-table')),
    );
    expect(table.width, lessThanOrEqualTo(640));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('plan-card-free'))).dx,
      greaterThan(80),
    );
  });

  testWidgets('900 dp caps the content at 720 and stays centred', (
    tester,
  ) async {
    _size(tester, const Size(1200, 1000));
    await tester.pumpWidget(_app(OTheme.light(), _billingData()));
    await tester.pumpAndSettle();

    final table = tester.getSize(
      find.byKey(const ValueKey('plan-compare-table')),
    );
    expect(table.width, lessThanOrEqualTo(720));
    expect(table.width, greaterThan(600));

    final card = tester
        .getTopLeft(find.byKey(const ValueKey('plan-card-free')))
        .dx;
    final right = tester
        .getTopRight(find.byKey(const ValueKey('plan-card-pro')))
        .dx;
    // Left and right margins match: the block is centred.
    expect(card, closeTo(1200 - right, 1));
    // Still four cards with one action each, never a stretched single card.
    for (final id in const ['free', 'go', 'plus', 'pro']) {
      expect(find.byKey(ValueKey('plan-card-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('plan-cta-$id')), findsOneWidget);
    }
  });
}
