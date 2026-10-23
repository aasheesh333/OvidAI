import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/plans_client.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/paywall_page.dart';

/// The gateway's real shape (`GET /cloud/v1/plans`, camelCase). No row carries
/// a yearly price because no server table contains one. The Pro row
/// deliberately carries `null` for every product limit: a plan the product
/// table does not describe has unknown limits, not zero limits.
List<CloudPlan> _serverPlans() => [
  CloudPlan.tryParse({
    'id': 'free',
    'tier': 'free',
    'name': 'Ovid Free',
    'priceUsd': 0,
    'priceInr': 0,
    'manualModels': false,
    'storageGb': 3,
    'customConnectors': 0,
    'projectFiles': 80,
    'uploads': {'count': 50, 'windowHours': 24},
  })!,
  CloudPlan.tryParse({
    'id': 'go',
    'tier': 'go',
    'name': 'Ovid Go',
    'priceUsd': 5,
    'priceInr': 499,
    'manualModels': false,
    'storageGb': 5,
    'customConnectors': 5,
    'projectFiles': 100,
    'uploads': {'count': 80, 'windowHours': 3},
  })!,
  CloudPlan.tryParse({
    'id': 'plus',
    'tier': 'plus',
    'name': 'Ovid Plus',
    'priceUsd': 18,
    'priceInr': 1799,
    'manualModels': true,
    'storageGb': 15,
    'customConnectors': 20,
    'projectFiles': 150,
    'uploads': {'count': 80, 'windowHours': 3},
  })!,
  CloudPlan.tryParse({
    'id': 'pro',
    'tier': 'pro',
    'name': 'Ovid Pro',
    'priceUsd': 99,
    'priceInr': null,
    'manualModels': null,
    'storageGb': null,
    'customConnectors': null,
    'projectFiles': null,
    'uploads': null,
  })!,
];

V2PaywallData _serverData({
  String selectedPlanId = 'plus',
  V2Currency currency = V2Currency.usd,
  V2PaywallPeriod period = V2PaywallPeriod.monthly,
}) => V2PaywallData(
  plans: [for (final plan in _serverPlans()) V2PlanOption.fromServer(plan)],
  selectedPlanId: selectedPlanId,
  currency: currency,
  period: period,
  trialDays: 7,
);

Future<void> _pump(
  WidgetTester tester,
  V2PaywallData data, {
  Future<void> Function(V2PaywallPurchase)? onPurchase,
  VoidCallback? onRetry,
}) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: PaywallPage(data: data, onPurchase: onPurchase, onRetry: onRetry),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('V2PlanOption.fromServer', () {
    test('carries the server name, price and limits', () {
      final go = V2PlanOption.fromServer(
        _serverPlans().firstWhere((plan) => plan.id == 'go'),
      );

      expect(go.id, 'go');
      expect(go.name, 'Ovid Go');
      expect(go.priceUsd, 5);
      expect(go.priceInr, 499);
      expect(go.storageGb, 5);
      expect(go.autoOnly, isTrue);
      expect(go.modelAccessLabel, 'Auto only');
      expect(go.features, contains('5 GB storage'));
      expect(go.features, contains('5 custom connectors'));
      expect(go.features, contains('Manual models locked'));
    });

    test('never carries the retired token claim', () {
      for (final plan in _serverPlans()) {
        final option = V2PlanOption.fromServer(plan);
        for (final feature in option.features) {
          expect(
            feature.toLowerCase(),
            isNot(contains('token')),
            reason: plan.id,
          );
        }
      }
    });

    test('no server yearly price is invented', () {
      for (final plan in _serverPlans()) {
        final option = V2PlanOption.fromServer(plan);
        // Free is a real zero that the card labels "forever"; it is not a
        // yearly price. Every paid plan has no yearly amount at all.
        if (option.isFree) continue;
        expect(
          option.amountFor(V2Currency.usd, V2PaywallPeriod.yearly),
          isNull,
          reason: plan.id,
        );
        expect(
          option.amountFor(V2Currency.inr, V2PaywallPeriod.yearly),
          isNull,
          reason: plan.id,
        );
      }
    });

    test('a null limit renders —, never 0', () {
      final pro = V2PlanOption.fromServer(
        _serverPlans().firstWhere((plan) => plan.id == 'pro'),
      );

      expect(pro.priceInr, isNull);
      expect(pro.storageGb, isNull);
      expect(pro.autoOnly, isNull);
      expect(pro.priceFor(V2Currency.inr), '—');
      expect(pro.modelAccessLabel, '—');
      expect(pro.features, contains('Storage: —'));
      expect(pro.features, contains('Connectors: —'));
      expect(pro.features, contains('Models: —'));
      expect(pro.features.join(' '), isNot(contains('0 GB')));
    });

    test('an unknown tier is Unknown and never Free', () {
      const unnamed = CloudPlan(
        id: 'team',
        tier: 'team',
        name: '',
        priceUsd: 30,
        priceInr: 2999,
      );
      final option = V2PlanOption.fromServer(unnamed);

      expect(option.canonicalId, 'team');
      expect(option.isFree, isFalse);
      expect(option.name, 'Unknown');

      const named = CloudPlan(
        id: 'team',
        tier: 'team',
        name: 'Team',
        priceUsd: 30,
        priceInr: 2999,
      );
      final namedOption = V2PlanOption.fromServer(named);
      expect(namedOption.canonicalId, 'team');
      expect(namedOption.isFree, isFalse);
      expect(namedOption.name, 'Team');
    });
  });

  group('paywall from the server table', () {
    testWidgets('shows the server monthly prices and no token claim', (
      tester,
    ) async {
      await _pump(tester, _serverData(), onPurchase: (_) async {});

      expect(find.text('Ovid Free'), findsOneWidget);
      expect(find.text('Ovid Go'), findsOneWidget);
      expect(find.text('Ovid Plus'), findsOneWidget);
      expect(find.text('Ovid Pro'), findsOneWidget);
      expect(find.text(r'$5'), findsOneWidget);
      expect(find.text(r'$18'), findsOneWidget);
      expect(find.text(r'$99'), findsOneWidget);
      expect(find.text('50M tokens a day'), findsNothing);
      expect(find.textContaining('token'), findsNothing);
    });

    testWidgets('yearly has no server price: —, never an invented amount', (
      tester,
    ) async {
      await _pump(tester, _serverData(), onPurchase: (_) async {});

      await tester.tap(find.byKey(const Key('paywall-period-yearly')));
      await tester.pumpAndSettle();

      // Three paid cards show a dash where the price would be.
      for (final id in const ['go', 'plus', 'pro']) {
        expect(
          find.descendant(
            of: find.byKey(Key('paywall-plan-$id')),
            matching: find.text('—'),
          ),
          findsWidgets,
          reason: id,
        );
      }
      for (final invented in [
        r'$50',
        r'$180',
        r'$990',
        '₹4,990',
        '₹17,990',
        '₹99,990',
      ]) {
        expect(find.text(invented), findsNothing, reason: invented);
      }
      // One per paid card, plus the footer for the selected card.
      expect(
        find.text('No yearly price for this plan.'),
        findsAtLeastNWidgets(3),
      );
      expect(
        tester
            .widget<OButton>(find.byKey(const Key('paywall-cta-plus')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('a null limit is a dash on the card', (tester) async {
      await _pump(tester, _serverData(), onPurchase: (_) async {});

      expect(find.text('Storage: —'), findsOneWidget);
      expect(find.text('Connectors: —'), findsOneWidget);
      expect(find.text('Models: —'), findsOneWidget);
      expect(find.text('0 GB storage'), findsNothing);
    });
  });

  group('unreachable server', () {
    testWidgets('says so instead of showing a hardcoded table', (tester) async {
      var retries = 0;
      await _pump(
        tester,
        const V2PaywallData(
          plans: [],
          error:
              'We could not load plans. Check your connection and try again.',
        ),
        onRetry: () => retries++,
      );

      expect(find.text('Plans did not load'), findsOneWidget);
      expect(
        find.text(
          'We could not load plans. Check your connection and try again.',
        ),
        findsOneWidget,
      );
      expect(find.text('Ovid Free'), findsNothing);
      expect(find.text(r'$5'), findsNothing);
      expect(find.text('50M tokens a day'), findsNothing);
      // The primary action is hidden: there is no plan to buy.
      expect(find.byKey(const Key('paywall-trial')), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(retries, 1);
    });
  });
}
