import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/paywall_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/purchase_banner.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  bool settle = true,
  V2PaywallData data = const V2PaywallData(),
  ValueChanged<String>? onPlanSelected,
  ValueChanged<V2Currency>? onCurrencyChanged,
  ValueChanged<String>? onStartTrial,
  VoidCallback? onComparePlans,
  VoidCallback? onRetry,
  VoidCallback? onManageSubscription,
  double width = 400,
  double textScale = 1,
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
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
        data: data,
        onPlanSelected: onPlanSelected,
        onCurrencyChanged: onCurrencyChanged,
        onStartTrial: onStartTrial,
        onComparePlans: onComparePlans,
        onRetry: onRetry,
        onManageSubscription: onManageSubscription,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets('paywall renders all three plans in USD in light', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Ovid Go'), findsOneWidget);
    expect(find.text('Ovid Plus'), findsOneWidget);
    expect(find.text('Ovid Pro'), findsOneWidget);
    expect(find.text('\$5'), findsOneWidget);
    expect(find.text('\$18'), findsOneWidget);
    expect(find.text('\$99'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.text('Start 7-day free trial'), findsOneWidget);
    expect(
      find.text('Cancel anytime. Billed securely through Google Play.'),
      findsOneWidget,
    );
    expect(find.text('Compare all plans'), findsOneWidget);
  });

  testWidgets('paywall renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Ovid Go'), findsOneWidget);
    expect(find.text('Ovid Plus'), findsOneWidget);
    expect(find.text('Ovid Pro'), findsOneWidget);
    expect(find.text('Start 7-day free trial'), findsOneWidget);
  });

  testWidgets('320 dp wide at 200 % text lays out without overflow', (
    tester,
  ) async {
    await _pump(tester, width: 320, textScale: 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid Go'), findsOneWidget);
    expect(find.text('Ovid Plus'), findsOneWidget);
    expect(find.text('Ovid Pro'), findsOneWidget);
    expect(find.text('Start 7-day free trial'), findsOneWidget);
    expect(find.text('Compare all plans'), findsOneWidget);

    // Scroll the whole body to force every off-screen section to lay out.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Compare all plans'), findsOneWidget);
  });

  testWidgets('320 dp wide at 200 % text renders in dark too', (tester) async {
    await _pump(tester, width: 320, textScale: 2, dark: true);

    expect(tester.takeException(), isNull);
    expect(find.text('Most popular'), findsOneWidget);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps every section visible', (tester) async {
    await _pump(tester, disableAnimations: true);

    expect(find.text('Do more with Ovid Plus'), findsOneWidget);
    expect(find.text('Most popular'), findsOneWidget);
    expect(find.text('Compare all plans'), findsOneWidget);
  });

  testWidgets('currency toggle swaps every price to INR', (tester) async {
    var currencyChanges = <V2Currency>[];
    await _pump(tester, onCurrencyChanged: currencyChanges.add);

    await tester.tap(find.byKey(const Key('paywall-currency-inr')));
    await tester.pumpAndSettle();

    expect(find.text('₹499'), findsOneWidget);
    expect(find.text('₹1,799'), findsOneWidget);
    expect(find.text('₹9,999'), findsOneWidget);
    expect(find.text('\$18'), findsNothing);
    expect(currencyChanges, [V2Currency.inr]);
  });

  testWidgets('selecting a plan and starting the trial calls back', (
    tester,
  ) async {
    String? selected;
    String? trialPlan;
    await _pump(
      tester,
      onPlanSelected: (id) => selected = id,
      onStartTrial: (id) => trialPlan = id,
    );

    await tester.ensureVisible(find.text('Ovid Go'));
    await tester.tap(find.text('Ovid Go'));
    await tester.pump();
    expect(selected, 'go');

    await tester.ensureVisible(find.byKey(const Key('paywall-trial')));
    await tester.tap(find.byKey(const Key('paywall-trial')));
    await tester.pump();
    expect(trialPlan, 'go');
  });

  testWidgets('compare all plans calls back', (tester) async {
    var taps = 0;
    await _pump(tester, onComparePlans: () => taps++);

    await tester.ensureVisible(find.text('Compare all plans'));
    await tester.tap(find.text('Compare all plans'));
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('loading shows skeletons and no trial button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const PaywallPage(data: V2PaywallData(loading: true)),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byKey(const Key('paywall-trial')), findsNothing);
  });

  testWidgets('purchasing state shows a spinner and disables the trial', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2PaywallData(purchasing: true),
      onStartTrial: (_) {},
      settle: false,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final trial = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(trial.onPressed, isNull);
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
    String? trialPlan;
    await _pump(
      tester,
      data: const V2PaywallData(error: 'Your last purchase did not finish.'),
      onRetry: () => retries++,
      onStartTrial: (id) => trialPlan = id,
    );

    expect(find.text('Ovid Plus'), findsOneWidget);
    expect(find.text('Your last purchase did not finish.'), findsOneWidget);

    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
    expect(trialPlan, isNull);
  });

  testWidgets('trial CTA is disabled when no purchase callback is wired', (
    tester,
  ) async {
    await _pump(tester);

    final trial = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const Key('paywall-trial')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(trial.onPressed, isNull);
  });

  testWidgets('test-mode note is shown when purchases are simulated', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: PaywallPage(
          data: const V2PaywallData(
            testModeNote: 'Test mode: purchases are simulated.',
          ),
          onStartTrial: (_) {},
        ),
      ),
    );
    expect(find.text('Test mode: purchases are simulated.'), findsOneWidget);
    // The legacy note is rendered by the shared purchase banner, not ad hoc.
    expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);
    expect(find.text('Test Store mode'), findsOneWidget);
  });

  testWidgets('currency tabs keep a 48 dp touch target', (tester) async {
    await _pump(tester);

    for (final key in const [
      Key('paywall-currency-usd'),
      Key('paywall-currency-inr'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(48), reason: '$key height');
      expect(size.width, greaterThanOrEqualTo(48), reason: '$key width');
    }
  });

  group('purchase banner', () {
    testWidgets('no banner is painted when no purchase status is given', (
      tester,
    ) async {
      await _pump(tester);

      expect(find.byKey(const Key('purchase-banner-card')), findsNothing);
    });

    testWidgets('test store status renders the banner and no retry', (
      tester,
    ) async {
      var retries = 0;
      await _pump(
        tester,
        data: const V2PaywallData(
          purchaseStatus: V2PurchaseBannerStatus.testStore,
        ),
        onRetry: () => retries++,
      );

      expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);
      expect(find.text('Test Store mode'), findsOneWidget);
      expect(find.text('Ovid Plus'), findsOneWidget);
      // Simulated purchases must not offer a retry that looks like a rebuy.
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
        data: const V2PaywallData(
          purchaseStatus: V2PurchaseBannerStatus.failed,
          purchaseDetail: 'Card declined (test card).',
        ),
        onRetry: () => retries++,
        onManageSubscription: () => managed++,
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

    testWidgets('pending status names the selected plan and offers no retry', (
      tester,
    ) async {
      await _pump(
        tester,
        data: const V2PaywallData(
          purchaseStatus: V2PurchaseBannerStatus.pending,
        ),
      );

      expect(find.text('Finishing your purchase'), findsOneWidget);
      expect(
        find.text(
          'Your Ovid Plus purchase is still being confirmed with the store. '
          'This can take a moment.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
    });

    testWidgets('restored status confirms the plan is active again', (
      tester,
    ) async {
      await _pump(
        tester,
        data: const V2PaywallData(
          purchaseStatus: V2PurchaseBannerStatus.restored,
        ),
      );

      expect(find.text('Purchase restored'), findsOneWidget);
      expect(
        find.text('Your Ovid Plus subscription is active again.'),
        findsOneWidget,
      );
    });

    testWidgets('banner survives 320 dp at 200 % text in dark', (tester) async {
      await _pump(
        tester,
        dark: true,
        width: 320,
        textScale: 2,
        data: const V2PaywallData(
          purchaseStatus: V2PurchaseBannerStatus.failed,
          purchaseDetail: 'The store did not confirm the purchase in time.',
        ),
        onRetry: () {},
        onManageSubscription: () {},
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
