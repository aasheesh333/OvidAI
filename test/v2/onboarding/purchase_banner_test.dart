import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/onboarding/purchase_banner.dart';

const _testStore = V2PurchaseBannerData(
  status: V2PurchaseBannerStatus.testStore,
);

Future<void> _pump(
  WidgetTester tester, {
  V2PurchaseBannerData data = _testStore,
  VoidCallback? onRetry,
  VoidCallback? onManageSubscription,
  bool dark = false,
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
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(OSpace.screen),
          child: V2PurchaseBanner(
            data: data,
            onRetry: onRetry,
            onManageSubscription: onManageSubscription,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('test store banner explains simulated purchases', (tester) async {
    var managed = 0;
    await _pump(tester, onManageSubscription: () => managed++);

    expect(find.text('Test Store mode'), findsOneWidget);
    expect(
      find.text(
        'Purchases here are simulated. No card is charged and no real '
        'subscription starts.',
      ),
      findsOneWidget,
    );
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);

    final status = tester
        .getSemantics(find.byKey(const Key('purchase-banner-status')))
        .getSemanticsData();
    expect(status.flagsCollection.isLiveRegion, isFalse);
    expect(status.label, contains('Test Store mode'));

    await tester.tap(find.byKey(const Key('purchase-banner-manage')));
    await tester.pump();
    expect(managed, 1);
  });

  testWidgets('test store banner renders in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Test Store mode'), findsOneWidget);
    expect(find.byKey(const Key('purchase-banner-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending banner names the plan and never offers a retry', (
    tester,
  ) async {
    var retries = 0;
    var managed = 0;
    await _pump(
      tester,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.pending,
        planName: 'Ovid Plus',
      ),
      onRetry: () => retries++,
      onManageSubscription: () => managed++,
    );

    expect(find.text('Finishing your purchase'), findsOneWidget);
    expect(
      find.text(
        'Your Ovid Plus purchase is still being confirmed with the store. '
        'This can take a moment.',
      ),
      findsOneWidget,
    );
    // Retrying a purchase the store is still processing could charge twice.
    expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);

    final flags = tester
        .getSemantics(find.byKey(const Key('purchase-banner-status')))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isLiveRegion, isTrue);

    await tester.tap(find.byKey(const Key('purchase-banner-manage')));
    await tester.pump();
    expect(managed, 1);
    expect(retries, 0);
  });

  testWidgets('failed banner shows the reason and both recovery actions', (
    tester,
  ) async {
    var retries = 0;
    var managed = 0;
    await _pump(
      tester,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.failed,
        planName: 'Ovid Plus',
        detail: 'Card declined by the store.',
      ),
      onRetry: () => retries++,
      onManageSubscription: () => managed++,
    );

    expect(find.text('Purchase did not finish'), findsOneWidget);
    expect(
      find.text(
        'We could not confirm your purchase. Try again, or manage your '
        'subscription in the store.',
      ),
      findsOneWidget,
    );
    expect(find.text('Card declined by the store.'), findsOneWidget);

    final status = tester
        .getSemantics(find.byKey(const Key('purchase-banner-status')))
        .getSemanticsData();
    expect(status.flagsCollection.isLiveRegion, isTrue);
    expect(status.label, contains('Card declined by the store.'));

    await tester.tap(find.byKey(const Key('purchase-banner-retry')));
    await tester.pump();
    expect(retries, 1);

    await tester.tap(find.byKey(const Key('purchase-banner-manage')));
    await tester.pump();
    expect(managed, 1);
  });

  testWidgets('failed banner announces a disabled retry when unwired', (
    tester,
  ) async {
    await _pump(
      tester,
      data: const V2PurchaseBannerData(status: V2PurchaseBannerStatus.failed),
      onManageSubscription: () {},
    );

    final retry = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const Key('purchase-banner-retry')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(retry.onPressed, isNull);

    final flags = tester
        .getSemantics(find.byKey(const Key('purchase-banner-retry')))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isEnabled, Tristate.isFalse);

    await tester.tap(find.byKey(const Key('purchase-banner-retry')));
    await tester.pump();
    expect(find.text('Purchase did not finish'), findsOneWidget);
  });

  testWidgets('restored banner confirms the plan and offers management', (
    tester,
  ) async {
    var managed = 0;
    await _pump(
      tester,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.restored,
        planName: 'Ovid Go',
      ),
      onManageSubscription: () => managed++,
    );

    expect(find.text('Purchase restored'), findsOneWidget);
    expect(
      find.text('Your Ovid Go subscription is active again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);

    final flags = tester
        .getSemantics(find.byKey(const Key('purchase-banner-status')))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isLiveRegion, isTrue);

    await tester.tap(find.byKey(const Key('purchase-banner-manage')));
    await tester.pump();
    expect(managed, 1);
  });

  testWidgets('nothing-to-restore is a real answer, not a failure', (
    tester,
  ) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.nothingToRestore,
      ),
      onRetry: () => retries++,
    );

    expect(find.text('No purchase found'), findsOneWidget);
    expect(
      find.text('No active subscription is linked to this account.'),
      findsOneWidget,
    );
    // Nothing failed, so there is nothing to retry.
    expect(find.byKey(const Key('purchase-banner-retry')), findsNothing);
    expect(find.text('Purchase did not finish'), findsNothing);

    final flags = tester
        .getSemantics(find.byKey(const Key('purchase-banner-status')))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isLiveRegion, isTrue);
    expect(retries, 0);
  });

  testWidgets('hidden status renders nothing', (tester) async {
    await _pump(tester, data: const V2PurchaseBannerData());

    expect(find.byKey(const Key('purchase-banner-card')), findsNothing);
    expect(find.byType(OButton), findsNothing);
    expect(find.text('Test Store mode'), findsNothing);
  });

  testWidgets('failed banner fits 320 dp at 200 % text in light', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 320,
      textScale: 2,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.failed,
        planName: 'Ovid Plus',
        detail:
            'The store could not confirm the payment. Check your card and '
            'try again.',
      ),
      onRetry: () {},
      onManageSubscription: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Purchase did not finish'), findsOneWidget);

    for (final key in const [
      Key('purchase-banner-retry'),
      Key('purchase-banner-manage'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(48), reason: '$key height');
      expect(size.width, greaterThanOrEqualTo(48), reason: '$key width');
    }

    await tester.ensureVisible(find.byKey(const Key('purchase-banner-manage')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending banner fits 320 dp at 200 % text in dark', (
    tester,
  ) async {
    await _pump(
      tester,
      dark: true,
      width: 320,
      textScale: 2,
      data: const V2PurchaseBannerData(
        status: V2PurchaseBannerStatus.pending,
        planName: 'Ovid Plus',
      ),
      onManageSubscription: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Finishing your purchase'), findsOneWidget);
    expect(find.text('Manage subscription'), findsOneWidget);
  });

  testWidgets('reduced motion still renders the banner', (tester) async {
    await _pump(
      tester,
      disableAnimations: true,
      data: const V2PurchaseBannerData(status: V2PurchaseBannerStatus.failed),
      onRetry: () {},
    );

    expect(find.text('Purchase did not finish'), findsOneWidget);
    expect(find.byKey(const Key('purchase-banner-retry')), findsOneWidget);
  });

  testWidgets('actions keep 48 dp touch targets', (tester) async {
    await _pump(
      tester,
      data: const V2PurchaseBannerData(status: V2PurchaseBannerStatus.failed),
      onRetry: () {},
      onManageSubscription: () {},
    );

    for (final key in const [
      Key('purchase-banner-retry'),
      Key('purchase-banner-manage'),
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.height, greaterThanOrEqualTo(48), reason: '$key height');
      expect(size.width, greaterThanOrEqualTo(48), reason: '$key width');
    }
  });
}
