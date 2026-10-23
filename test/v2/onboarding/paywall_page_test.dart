import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/paywall_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/purchase_banner.dart';

/// A server-shaped plan table: the values `GET /cloud/v1/plans` sends. No row
/// has a yearly price because the server table has none.
const _plans = <V2PlanOption>[
  V2PlanOption(
    id: 'free',
    name: 'Ovid Free',
    priceUsd: 0,
    priceInr: 0,
    storageGb: 3,
    autoOnly: true,
    features: ['3 GB storage', 'No custom connectors', 'Manual models locked'],
  ),
  V2PlanOption(
    id: 'go',
    name: 'Ovid Go',
    priceUsd: 5,
    priceInr: 499,
    storageGb: 5,
    autoOnly: true,
    features: ['5 GB storage', '5 custom connectors', 'Manual models locked'],
  ),
  V2PlanOption(
    id: 'plus',
    name: 'Ovid Plus',
    priceUsd: 18,
    priceInr: 1799,
    storageGb: 15,
    autoOnly: false,
    features: ['15 GB storage', '20 custom connectors', 'Manual models'],
  ),
  V2PlanOption(
    id: 'pro',
    name: 'Ovid Pro',
    priceUsd: 99,
    priceInr: 9999,
    storageGb: 75,
    autoOnly: false,
    features: ['75 GB storage', '20 custom connectors', 'Manual models'],
  ),
];

V2PaywallData _data({
  List<V2PlanOption> plans = _plans,
  String selectedPlanId = 'plus',
  V2Currency currency = V2Currency.usd,
  V2PaywallPeriod period = V2PaywallPeriod.monthly,
  String? currentPlanId,
  bool loading = false,
  bool purchasing = false,
  String? error,
  V2PurchaseBannerStatus? purchaseStatus,
  String? purchaseDetail,
  String? testModeNote,
  String? checkoutBlockedReason,
  int trialDays = 7,
}) => V2PaywallData(
  plans: plans,
  selectedPlanId: selectedPlanId,
  currency: currency,
  period: period,
  currentPlanId: currentPlanId,
  loading: loading,
  purchasing: purchasing,
  error: error,
  purchaseStatus: purchaseStatus,
  purchaseDetail: purchaseDetail,
  testModeNote: testModeNote,
  checkoutBlockedReason: checkoutBlockedReason,
  trialDays: trialDays,
);

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  bool settle = true,
  V2PaywallData? data,
  ValueChanged<String>? onPlanSelected,
  ValueChanged<V2Currency>? onCurrencyChanged,
  ValueChanged<V2PaywallPeriod>? onPeriodChanged,
  Future<void> Function(V2PaywallPurchase)? onPurchase,
  ValueChanged<String>? onStartTrial,
  VoidCallback? onContinueFree,
  VoidCallback? onRetry,
  Future<V2PaywallRestoreResult> Function()? onRestorePurchases,
  VoidCallback? onManageSubscription,
  VoidCallback? onClose,
  double width = 400,
  double height = 800,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: PaywallPage(
        data: data ?? _data(),
        onPlanSelected: onPlanSelected,
        onCurrencyChanged: onCurrencyChanged,
        onPeriodChanged: onPeriodChanged,
        onPurchase: onPurchase,
        onStartTrial: onStartTrial,
        onContinueFree: onContinueFree,
        onRetry: onRetry,
        onRestorePurchases: onRestorePurchases,
        onManageSubscription: onManageSubscription,
        onClose: onClose,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Finder _cta(String id) => find.byKey(Key('paywall-cta-$id'));

Future<void> _tapCta(WidgetTester tester, String id) async {
  await tester.ensureVisible(_cta(id));
  await tester.tap(_cta(id));
  await tester.pumpAndSettle();
}

Future<void> _tapPeriod(WidgetTester tester, String period) async {
  final toggle = find.byKey(Key('paywall-period-$period'));
  await tester.ensureVisible(toggle);
  await tester.pumpAndSettle();
  await tester.tap(toggle);
  await tester.pumpAndSettle();
}

SemanticsData _semantics(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

int _words(String value) =>
    value.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

bool _isHorizontalScroll(Widget widget) =>
    widget is SingleChildScrollView &&
    widget.scrollDirection == Axis.horizontal;

void main() {
  group('prices', () {
    testWidgets('monthly prices are exact in USD and INR', (tester) async {
      await _pump(tester, onPurchase: (_) async {});

      expect(find.text('Ovid Free'), findsOneWidget);
      expect(find.text('Ovid Go'), findsOneWidget);
      expect(find.text('Ovid Plus'), findsOneWidget);
      expect(find.text('Ovid Pro'), findsOneWidget);
      expect(find.text(r'$0'), findsOneWidget);
      expect(find.text(r'$5'), findsOneWidget);
      expect(find.text(r'$18'), findsOneWidget);
      expect(find.text(r'$99'), findsOneWidget);
      expect(find.text('/ month'), findsNWidgets(3));
      expect(find.text('forever'), findsOneWidget);
      expect(find.text('Start free trial'), findsOneWidget);

      await tester.tap(find.byKey(const Key('paywall-currency-inr')));
      await tester.pumpAndSettle();

      expect(find.text('₹0'), findsOneWidget);
      expect(find.text('₹499'), findsOneWidget);
      expect(find.text('₹1,799'), findsOneWidget);
      expect(find.text('₹9,999'), findsOneWidget);
      expect(find.text(r'$18'), findsNothing);
    });

    testWidgets('yearly has no server price: a dash, never an amount', (
      tester,
    ) async {
      await _pump(tester, onPurchase: (_) async {});

      await _tapPeriod(tester, 'yearly');

      // The server table has no yearly column. Every paid card says so and
      // disables its CTA; Free is a real zero labelled "forever".
      expect(find.text('/ year'), findsNWidgets(3));
      expect(find.text('forever'), findsOneWidget);
      expect(
        find.text('No yearly price for this plan.'),
        findsAtLeastNWidgets(3),
      );
      for (final invented in [
        r'$50',
        r'$180',
        r'$990',
        r'$60',
        r'$216',
        r'$1,188',
        '₹4,990',
        '₹17,990',
        '₹99,990',
      ]) {
        expect(find.text(invented), findsNothing, reason: invented);
      }

      await tester.tap(find.byKey(const Key('paywall-currency-inr')));
      await tester.pumpAndSettle();
      expect(find.text('₹4,990'), findsNothing);
      expect(find.text('₹17,990'), findsNothing);
      expect(find.text('₹99,990'), findsNothing);
    });

    test('no server plan carries a yearly amount', () {
      for (final plan in _plans) {
        // Free is a real zero, not a yearly price.
        if (plan.isFree) continue;
        for (final currency in V2Currency.values) {
          expect(
            plan.amountFor(currency, V2PaywallPeriod.yearly),
            isNull,
            reason: '${plan.id} ${currency.name} yearly',
          );
        }
      }
    });

    test('a missing yearly price resolves to null, not monthly × 12', () {
      const plan = V2PlanOption(
        id: 'go',
        name: 'Ovid Go',
        priceUsd: 5,
        priceInr: 499,
        storageGb: 5,
        autoOnly: true,
      );
      expect(plan.amountFor(V2Currency.usd, V2PaywallPeriod.yearly), isNull);
      expect(plan.hasPrice(V2Currency.inr, V2PaywallPeriod.yearly), isFalse);
      expect(plan.priceFor(V2Currency.usd, V2PaywallPeriod.yearly), '—');
    });
  });

  group('plan gating', () {
    testWidgets('Free and Go say they are Auto-only on the card', (
      tester,
    ) async {
      await _pump(tester, onPurchase: (_) async {});

      expect(find.text('Auto only'), findsNWidgets(2));
      expect(find.text('Auto + manual'), findsNWidgets(2));
      expect(find.byKey(const Key('plan-access-free')), findsOneWidget);
      expect(find.byKey(const Key('plan-access-go')), findsOneWidget);
      // The limit is stated on the card, not only implied by the pill.
      expect(find.text('Manual models locked'), findsNWidgets(2));
    });

    test('every card stays inside the copy budget', () {
      final data = _data();
      for (final plan in data.plans) {
        expect(plan.features.length, lessThanOrEqualTo(3), reason: plan.id);
        for (final feature in plan.features) {
          expect(
            _words(feature),
            lessThanOrEqualTo(4),
            reason: '${plan.id}: "$feature"',
          );
        }
        expect(_words(plan.name), lessThanOrEqualTo(3), reason: plan.id);
        expect(_words(plan.modelAccessLabel), lessThanOrEqualTo(3));
      }
    });
  });

  group('buy path', () {
    testWidgets('monthly purchase carries the matching product id', (
      tester,
    ) async {
      final purchases = <V2PaywallPurchase>[];
      await _pump(
        tester,
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await _tapCta(tester, 'plus');
      await _tapCta(tester, 'go');
      await _tapCta(tester, 'pro');

      expect([for (final p in purchases) p.planId], ['plus', 'go', 'pro']);
      expect([for (final p in purchases) p.tier], ['7x', '3x', '15x']);
      expect(
        [for (final p in purchases) p.productId],
        ['ovid_pro_monthly', 'ovid_plus_monthly', 'ovid_max_monthly'],
      );
      expect([
        for (final p in purchases) p.period,
      ], everyElement(V2PaywallPeriod.monthly));
    });

    testWidgets('yearly purchase carries the yearly product id', (
      tester,
    ) async {
      final purchases = <V2PaywallPurchase>[];
      // A host that has a real yearly source supplies it explicitly. The
      // server table has no yearly price, so the paywall never derives one.
      const yearlyData = V2PaywallData(
        trialDays: 7,
        plans: [
          V2PlanOption(
            id: 'free',
            name: 'Ovid Free',
            priceUsd: 0,
            priceInr: 0,
            storageGb: 3,
            autoOnly: true,
          ),
          V2PlanOption(
            id: 'go',
            name: 'Ovid Go',
            priceUsd: 5,
            priceInr: 499,
            priceUsdYearly: 50,
            priceInrYearly: 4990,
            storageGb: 5,
            autoOnly: true,
          ),
          V2PlanOption(
            id: 'plus',
            name: 'Ovid Plus',
            priceUsd: 18,
            priceInr: 1799,
            priceUsdYearly: 180,
            priceInrYearly: 17990,
            storageGb: 15,
          ),
          V2PlanOption(
            id: 'pro',
            name: 'Ovid Pro',
            priceUsd: 99,
            priceInr: 9999,
            priceUsdYearly: 990,
            priceInrYearly: 99990,
            storageGb: 75,
          ),
        ],
      );
      await _pump(
        tester,
        data: yearlyData,
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await _tapPeriod(tester, 'yearly');
      await _tapCta(tester, 'go');
      await _tapCta(tester, 'plus');
      await _tapCta(tester, 'pro');

      expect(
        [for (final p in purchases) p.productId],
        ['ovid_plus_yearly', 'ovid_pro_yearly', 'ovid_max_yearly'],
      );
      expect([
        for (final p in purchases) p.period,
      ], everyElement(V2PaywallPeriod.yearly));
    });

    testWidgets('a period without a product is unavailable and does nothing', (
      tester,
    ) async {
      final purchases = <V2PaywallPurchase>[];
      const data = V2PaywallData(
        selectedPlanId: 'team',
        trialDays: 7,
        plans: [
          V2PlanOption(
            id: 'team',
            name: 'Ovid Team',
            priceUsd: 30,
            priceInr: 2999,
            priceUsdYearly: 300,
            priceInrYearly: 29990,
            storageGb: 20,
            features: ['20 GB storage'],
          ),
        ],
      );
      await _pump(
        tester,
        data: data,
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await _tapPeriod(tester, 'yearly');

      expect(find.text('Not available'), findsNWidgets(2));
      expect(find.text('Yearly is not sold for this plan.'), findsNWidgets(2));
      final cta = tester.widget<OButton>(_cta('team'));
      expect(cta.onPressed, isNull);

      await tester.tap(_cta('team'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(purchases, isEmpty);
    });

    testWidgets('a period without a price is unavailable and does nothing', (
      tester,
    ) async {
      final purchases = <V2PaywallPurchase>[];
      const data = V2PaywallData(
        selectedPlanId: 'go',
        plans: [
          V2PlanOption(
            id: 'go',
            name: 'Ovid Go',
            priceUsd: 5,
            priceInr: 499,
            storageGb: 5,
            autoOnly: true,
            features: ['5 GB storage'],
          ),
        ],
      );
      await _pump(
        tester,
        data: data,
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await _tapPeriod(tester, 'yearly');

      expect(find.text('Not available'), findsNWidgets(2));
      expect(find.text('No yearly price for this plan.'), findsNWidgets(2));
      expect(tester.widget<OButton>(_cta('go')).onPressed, isNull);
      await tester.tap(_cta('go'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(purchases, isEmpty);
    });

    testWidgets('the Free card continues without buying anything', (
      tester,
    ) async {
      var freeContinues = 0;
      final purchases = <V2PaywallPurchase>[];
      await _pump(
        tester,
        onContinueFree: () => freeContinues++,
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await _tapCta(tester, 'free');

      expect(freeContinues, 1);
      expect(purchases, isEmpty);
    });

    testWidgets('the footer buys the selected plan', (tester) async {
      final purchases = <V2PaywallPurchase>[];
      await _pump(
        tester,
        data: _data(trialDays: 0),
        onPurchase: (purchase) async => purchases.add(purchase),
      );

      await tester.ensureVisible(find.text('Ovid Go'));
      await tester.tap(find.text('Ovid Go'));
      await tester.pumpAndSettle();
      expect(find.text('Subscribe'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('paywall-trial')));
      await tester.tap(find.byKey(const Key('paywall-trial')));
      await tester.pumpAndSettle();

      expect(purchases, hasLength(1));
      expect(purchases.single.planId, 'go');
      expect(purchases.single.productId, 'ovid_plus_monthly');
    });

    testWidgets('legacy callback is monthly-only and never buys yearly', (
      tester,
    ) async {
      final trials = <String>[];
      await _pump(tester, onStartTrial: trials.add);

      await _tapCta(tester, 'go');
      expect(trials, ['go']);

      await _tapPeriod(tester, 'yearly');
      expect(tester.widget<OButton>(_cta('go')).onPressed, isNull);
      await tester.tap(_cta('go'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(trials, ['go']);
      // The server table has no yearly price, so the yearly CTA is disabled
      // before the legacy callback is ever considered.
      expect(find.text('No yearly price for this plan.'), findsWidgets);
    });
  });

  group('restore', () {
    testWidgets('restored reports the real outcome', (tester) async {
      var restores = 0;
      await _pump(
        tester,
        onRestorePurchases: () async {
          restores++;
          return V2PaywallRestoreResult.restored;
        },
      );

      await tester.ensureVisible(find.byKey(const Key('paywall-restore')));
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pumpAndSettle();

      expect(restores, 1);
      expect(find.text('Purchase restored'), findsOneWidget);
      expect(find.text('Your subscription is active again.'), findsOneWidget);
      expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
    });

    testWidgets('nothing found is reported as nothing, not a failure', (
      tester,
    ) async {
      await _pump(
        tester,
        onRestorePurchases: () async => V2PaywallRestoreResult.nothingToRestore,
      );

      await tester.ensureVisible(find.byKey(const Key('paywall-restore')));
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pumpAndSettle();

      expect(find.text('No purchase found'), findsOneWidget);
      expect(
        find.text('No active subscription is linked to this account.'),
        findsOneWidget,
      );
      expect(find.text('Purchase restored'), findsNothing);
      expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
    });

    testWidgets('a failed restore retries the restore, not a purchase', (
      tester,
    ) async {
      var restores = 0;
      var purchases = 0;
      await _pump(
        tester,
        onPurchase: (_) async => purchases++,
        onRestorePurchases: () async {
          restores++;
          return V2PaywallRestoreResult.failed;
        },
      );

      await tester.ensureVisible(find.byKey(const Key('paywall-restore')));
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pumpAndSettle();

      expect(find.text('Purchase did not finish'), findsOneWidget);
      expect(find.text('The restore did not finish.'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('purchase-banner-retry')),
      );
      await tester.tap(find.byKey(const Key('purchase-banner-retry')));
      await tester.pumpAndSettle();

      expect(restores, 2);
      expect(purchases, 0);
    });

    testWidgets('a thrown restore is reported as failed', (tester) async {
      await _pump(
        tester,
        onRestorePurchases: () async => throw StateError('store offline'),
      );

      await tester.ensureVisible(find.byKey(const Key('paywall-restore')));
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pumpAndSettle();

      expect(find.text('Purchase did not finish'), findsOneWidget);
      expect(find.text('The restore did not finish.'), findsOneWidget);
    });

    testWidgets('restore is in flight once and cannot be tapped twice', (
      tester,
    ) async {
      var restores = 0;
      final completer = Completer<V2PaywallRestoreResult>();
      await _pump(
        tester,
        onRestorePurchases: () {
          restores++;
          return completer.future;
        },
      );

      await tester.ensureVisible(find.byKey(const Key('paywall-restore')));
      await tester.tap(find.byKey(const Key('paywall-restore')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(
        find.byKey(const Key('paywall-restore')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(restores, 1);

      completer.complete(V2PaywallRestoreResult.restored);
      await tester.pumpAndSettle();
      expect(find.text('Purchase restored'), findsOneWidget);
    });

    testWidgets('restore is present but disabled with no service', (
      tester,
    ) async {
      await _pump(tester);

      final restore = tester.widget<OButton>(
        find.byKey(const Key('paywall-restore')),
      );
      expect(restore.onPressed, isNull);
      final flags = _semantics(
        tester,
        find.byKey(const Key('paywall-restore')),
      ).flagsCollection;
      expect(flags.isEnabled, Tristate.isFalse);
    });
  });

  group('states', () {
    testWidgets('loading shows skeletons and no footer or restore', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const PaywallPage(data: V2PaywallData(loading: true)),
        ),
      );
      await tester.pump();

      expect(find.byType(OSkeletonList), findsOneWidget);
      expect(find.byKey(const Key('paywall-trial')), findsNothing);
      expect(find.byKey(const Key('paywall-restore')), findsNothing);
    });

    testWidgets('purchasing disables every buy control and never double taps', (
      tester,
    ) async {
      var purchases = 0;
      final completer = Completer<void>();
      await _pump(
        tester,
        data: _data(),
        onPurchase: (_) {
          purchases++;
          return completer.future;
        },
        settle: false,
      );

      await tester.ensureVisible(_cta('plus'));
      await tester.tap(_cta('plus'));
      await tester.pump();
      expect(purchases, 1);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(tester.widget<OButton>(_cta('plus')).onPressed, isNull);
      expect(tester.widget<OButton>(_cta('go')).onPressed, isNull);
      expect(
        _semantics(tester, _cta('plus')).label,
        contains('purchase in progress'),
      );

      await tester.tap(_cta('plus'), warnIfMissed: false);
      await tester.pump();
      expect(purchases, 1);

      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('host purchasing state disables the footer and cards', (
      tester,
    ) async {
      await _pump(
        tester,
        data: _data(purchasing: true),
        onPurchase: (_) async {},
        settle: false,
      );

      expect(find.byType(CircularProgressIndicator), findsWidgets);
      final footer = tester.widget<OButton>(
        find.byKey(const Key('paywall-trial')),
      );
      expect(footer.onPressed, isNull);
      expect(tester.widget<OButton>(_cta('plus')).onPressed, isNull);
    });

    testWidgets('empty plans state offers a retry', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        data: const V2PaywallData(plans: []),
        onRetry: () => retries++,
      );

      expect(find.text('No plans right now'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('error state explains the problem and retries', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        data: const V2PaywallData(
          plans: [],
          error: 'We could not load plans. Check your connection.',
        ),
        onRetry: () => retries++,
      );

      expect(
        find.text('We could not load plans. Check your connection.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retries, 1);
    });

    testWidgets('inline error keeps the plans and retries without buying', (
      tester,
    ) async {
      var retries = 0;
      var purchases = 0;
      await _pump(
        tester,
        data: _data(error: 'Your last purchase did not finish.'),
        onRetry: () => retries++,
        onPurchase: (_) async => purchases++,
      );

      expect(find.text('Ovid Plus'), findsOneWidget);
      expect(find.text('Your last purchase did not finish.'), findsOneWidget);

      await tester.ensureVisible(find.text('Try again'));
      await tester.tap(find.text('Try again'));
      await tester.pump();

      expect(retries, 1);
      expect(purchases, 0);
    });

    testWidgets('already subscribed turns the CTA into Manage', (tester) async {
      var managed = 0;
      var purchases = 0;
      await _pump(
        tester,
        data: _data(currentPlanId: '7x'),
        onManageSubscription: () => managed++,
        onPurchase: (_) async => purchases++,
      );

      final footer = tester.widget<OButton>(
        find.byKey(const Key('paywall-trial')),
      );
      expect(footer.label, 'Manage');
      await tester.tap(find.byKey(const Key('paywall-trial')));
      await tester.pump();
      expect(managed, 1);

      expect(tester.widget<OButton>(_cta('plus')).label, 'Current plan');
      expect(tester.widget<OButton>(_cta('plus')).onPressed, isNull);
      expect(tester.widget<OButton>(_cta('go')).label, 'Manage');
      expect(tester.widget<OButton>(_cta('go')).onPressed, isNotNull);
      expect(purchases, 0);

      await tester.ensureVisible(_cta('go'));
      await tester.tap(_cta('go'));
      await tester.pump();
      expect(managed, 2);
    });

    testWidgets('no purchase callback leaves the CTA disabled', (tester) async {
      await _pump(tester);

      final footer = tester.widget<OButton>(
        find.byKey(const Key('paywall-trial')),
      );
      expect(footer.onPressed, isNull);
      expect(tester.widget<OButton>(_cta('plus')).onPressed, isNull);
    });
  });

  group('semantics', () {
    testWidgets('each card is a group with name, price, period and CTA', (
      tester,
    ) async {
      await _pump(tester, data: _data(trialDays: 0), onPurchase: (_) async {});

      final group = _semantics(
        tester,
        find.byKey(const Key('paywall-plan-plus')),
      );
      expect(group.label, contains('Ovid Plus'));
      expect(group.label, contains(r'$18'));
      expect(group.label, contains('per month'));
      expect(group.label, contains('Auto + manual'));
      expect(group.flagsCollection.isSelected, Tristate.isTrue);

      final cta = _semantics(tester, _cta('plus'));
      expect(cta.label, contains('Choose Plus'));
      expect(cta.label, contains('Ovid Plus'));
      expect(cta.label, contains(r'$18'));
      expect(cta.label, contains('per month'));
      expect(cta.flagsCollection.isEnabled, Tristate.isTrue);
      expect(cta.flagsCollection.isButton, isTrue);
    });

    testWidgets('a disabled CTA announces the reason', (tester) async {
      const real = V2PaywallData(
        selectedPlanId: 'team',
        plans: [
          V2PlanOption(
            id: 'team',
            name: 'Ovid Team',
            priceUsd: 30,
            priceInr: 2999,
            priceUsdYearly: 300,
            priceInrYearly: 29990,
            storageGb: 20,
          ),
        ],
      );
      await _pump(tester, data: real, onPurchase: (_) async {});
      await _tapPeriod(tester, 'yearly');

      final cta = _semantics(tester, _cta('team'));
      expect(cta.flagsCollection.isEnabled, Tristate.isFalse);
      expect(cta.label, contains('Not available'));
      expect(cta.label, contains('Yearly is not sold for this plan.'));
    });

    testWidgets('toggles announce selection and mutual exclusion', (
      tester,
    ) async {
      await _pump(tester, onPurchase: (_) async {});

      final yearly = _semantics(
        tester,
        find.byKey(const Key('paywall-period-yearly')),
      );
      expect(yearly.flagsCollection.isSelected, Tristate.isFalse);
      expect(yearly.flagsCollection.isInMutuallyExclusiveGroup, isTrue);

      final monthly = _semantics(
        tester,
        find.byKey(const Key('paywall-period-monthly')),
      );
      expect(monthly.flagsCollection.isSelected, Tristate.isTrue);
      expect(monthly.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
    });
  });

  group('responsive', () {
    testWidgets('cards are one column on a phone and two on a tablet', (
      tester,
    ) async {
      await _pump(tester, width: 320, height: 900, onPurchase: (_) async {});
      final phoneFree = tester.getRect(
        find.byKey(const Key('paywall-plan-free')),
      );
      final phoneGo = tester.getRect(find.byKey(const Key('paywall-plan-go')));
      expect(phoneFree.left, phoneGo.left);
      expect(phoneFree.top, lessThan(phoneGo.top));

      await _pump(tester, width: 600, height: 900, onPurchase: (_) async {});
      final tabletFree = tester.getRect(
        find.byKey(const Key('paywall-plan-free')),
      );
      final tabletGo = tester.getRect(find.byKey(const Key('paywall-plan-go')));
      expect(tabletFree.top, tabletGo.top);
      expect(tabletFree.left, lessThan(tabletGo.left));
    });

    testWidgets('every supported width and text scale survives both themes', (
      tester,
    ) async {
      for (final width in const [320.0, 600.0, 900.0, 1280.0]) {
        for (final scale in const [1.0, 2.0]) {
          for (final dark in const [false, true]) {
            await _pump(
              tester,
              width: width,
              textScale: scale,
              dark: dark,
              onPurchase: (_) async {},
              onRestorePurchases: () async =>
                  V2PaywallRestoreResult.nothingToRestore,
            );

            expect(
              tester.takeException(),
              isNull,
              reason: '$width dp / ${scale}x / ${dark ? 'dark' : 'light'}',
            );
            expect(
              find.byWidgetPredicate(_isHorizontalScroll),
              findsNothing,
              reason: '$width dp must not scroll horizontally',
            );

            await tester.drag(
              find.byType(SingleChildScrollView),
              const Offset(0, -4000),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$width dp / ${scale}x scrolled',
            );
            expect(find.byKey(const Key('paywall-trial')), findsOneWidget);
          }
        }
      }
    });

    testWidgets('content stays inside the 640/720 caps', (tester) async {
      for (final width in const [600.0, 900.0, 1280.0]) {
        await _pump(tester, width: width, onPurchase: (_) async {});
        final free = tester.getRect(find.byKey(const Key('paywall-plan-free')));
        final pro = tester.getRect(find.byKey(const Key('paywall-plan-pro')));
        final gridWidth = pro.right - free.left;
        expect(gridWidth, lessThanOrEqualTo(720), reason: '$width dp');
        if (width >= 900) {
          expect(gridWidth, lessThanOrEqualTo(640 + 0.5), reason: '$width dp');
        }
      }
    });

    testWidgets('every action keeps a 48 dp touch target', (tester) async {
      await _pump(
        tester,
        width: 320,
        textScale: 2,
        onPurchase: (_) async {},
        onRestorePurchases: () async => V2PaywallRestoreResult.restored,
      );

      for (final key in const [
        Key('paywall-period-monthly'),
        Key('paywall-period-yearly'),
        Key('paywall-currency-usd'),
        Key('paywall-currency-inr'),
        Key('paywall-cta-free'),
        Key('paywall-cta-plus'),
        Key('paywall-restore'),
        Key('paywall-trial'),
      ]) {
        await tester.ensureVisible(find.byKey(key));
        await tester.pumpAndSettle();
        final size = tester.getSize(find.byKey(key));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key height');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$key width');
      }
    });
  });

  testWidgets('reduced motion keeps every section visible', (tester) async {
    await _pump(tester, disableAnimations: true, onPurchase: (_) async {});

    expect(find.text('Upgrade'), findsOneWidget);
    expect(find.text('Ovid Plus'), findsOneWidget);
    expect(find.byKey(const Key('paywall-trial')), findsOneWidget);
  });

  testWidgets('test-mode note is shown when purchases are simulated', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: PaywallPage(
          data: _data(testModeNote: 'Test mode: purchases are simulated.'),
          onPurchase: (_) async {},
        ),
      ),
    );
    expect(find.text('Test mode: purchases are simulated.'), findsOneWidget);
    // The legacy note is rendered by the shared purchase banner, not ad hoc.
    expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);
    expect(find.text('Test Store mode'), findsOneWidget);
  });

  group('purchase banner', () {
    testWidgets('no banner is painted when no purchase status is given', (
      tester,
    ) async {
      await _pump(tester, onPurchase: (_) async {});
      expect(find.byKey(const Key('purchase-banner-card')), findsNothing);
    });

    testWidgets('test store status renders the banner and no retry', (
      tester,
    ) async {
      var retries = 0;
      await _pump(
        tester,
        data: _data(purchaseStatus: V2PurchaseBannerStatus.testStore),
        onRetry: () => retries++,
        onPurchase: (_) async {},
      );

      expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);
      expect(find.text('Test Store mode'), findsOneWidget);
      expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
      expect(retries, 0);
    });

    testWidgets('failed status retries and opens subscription management', (
      tester,
    ) async {
      var retries = 0;
      var managed = 0;
      await _pump(
        tester,
        data: _data(
          purchaseStatus: V2PurchaseBannerStatus.failed,
          purchaseDetail: 'Card declined (test card).',
        ),
        onRetry: () => retries++,
        onManageSubscription: () => managed++,
        onPurchase: (_) async {},
      );

      expect(find.text('Purchase did not finish'), findsOneWidget);
      expect(find.text('Card declined (test card).'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('purchase-banner-retry')),
      );
      await tester.tap(find.byKey(const Key('purchase-banner-retry')));
      await tester.pump();
      expect(retries, 1);

      await tester.ensureVisible(
        find.byKey(const Key('purchase-banner-manage')),
      );
      await tester.tap(find.byKey(const Key('purchase-banner-manage')));
      await tester.pump();
      expect(managed, 1);
    });

    testWidgets('nothing-to-restore status is a real, non-error answer', (
      tester,
    ) async {
      await _pump(
        tester,
        data: _data(purchaseStatus: V2PurchaseBannerStatus.nothingToRestore),
        onPurchase: (_) async {},
      );

      expect(find.text('No purchase found'), findsOneWidget);
      expect(
        find.text('No active subscription is linked to this account.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
    });

    testWidgets('banner survives 320 dp at 200 % text in dark', (tester) async {
      await _pump(
        tester,
        dark: true,
        width: 320,
        textScale: 2,
        data: _data(
          purchaseStatus: V2PurchaseBannerStatus.failed,
          purchaseDetail: 'The store did not confirm the purchase in time.',
        ),
        onRetry: () {},
        onManageSubscription: () {},
        onPurchase: (_) async {},
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
