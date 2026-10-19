import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/widgets/external_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_platform.dart';

Map<String, dynamic> _usage({
  String tier = 'free',
  String? expires,
  bool? autoRenews,
  List<Map<String, Object>>? plans,
}) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'remaining_pct': .5,
  'models': const [],
  'billing_enabled': true,
  'plan_expires_at': ?expires,
  'plan_auto_renews': ?autoRenews,
  'plans': ?plans,
};

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeBillingPlatform store;
  late PlayBillingService billing;
  late Map<String, dynamic> usage;
  late List<Uri> launched;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    OvidCloudService.I.resetUpgradeAvailabilityForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 'billing-test-token';
    usage = _usage();
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response('{"data":[{"id":"ovid-base"}]}', 200);
          }
          return http.Response(jsonEncode(usage), 200);
        });
    store = FakeBillingPlatform();
    billing = fakeBillingService(store);
    launched = [];
    externalLinkLauncherForTest = (uri) async {
      launched.add(uri);
      return true;
    };
  });

  tearDown(() {
    externalLinkLauncherForTest = null;
    billing.dispose();
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AppState.resetTestInstance();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(540, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: BillingScreen(allowTestUpgrade: false, billing: billing),
      ),
    );
    await _frames(tester);
  }

  testWidgets('Play prices are localised with period and clear terms', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('€4.99 / month'), findsNWidgets(3));
    expect(find.textContaining('₹'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
    await _frames(tester);
    final terms = tester.widget<Text>(
      find.byKey(const ValueKey('billing-terms')),
    );
    expect(terms.data, contains('€4.99 / month'));
    expect(terms.data, contains('Renews automatically'));
    expect(terms.data, contains('cancel anytime'));
    final sheet = find.byType(BottomSheet);
    expect(
      find.descendant(of: sheet, matching: find.text('Terms')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sheet, matching: find.text('Privacy')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: sheet,
        matching: find.text('Subscribe · €4.99 / month'),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Play purchase is verified, then acknowledged and confirmed', (
    tester,
  ) async {
    store.autoResult = PurchaseStatus.purchased;
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('billing-pay-now')));
    await _frames(tester);
    expect(store.bought.single.product, kOvidPlayProducts['3x']);
    expect(store.completed, hasLength(1));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('You are now on the Starter plan.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('sheet cannot be dismissed while busy; failure stays inline', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('upgrade-7x')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('billing-pay-now')));
    await _frames(tester);
    // Busy: back and scrim taps are ignored.
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await _frames(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );
    // The user closes Google Play's sheet.
    store.controller.add([
      purchase(kOvidPlayProducts['7x']!, PurchaseStatus.canceled),
    ]);
    await _frames(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(
      find.text('Purchase cancelled. Nothing was charged.'),
      findsOneWidget,
    );
    final retry = find.byKey(const ValueKey('billing-pay-now'));
    expect(
      find.descendant(of: retry, matching: find.text('Retry')),
      findsOneWidget,
    );
    expect(store.completed, isEmpty);
    // Not busy any more: back closes the sheet.
    await tester.binding.handlePopRoute();
    await _frames(tester);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending payment is explained without a retry', (tester) async {
    store.autoResult = PurchaseStatus.pending;
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('billing-pay-now')));
    await _frames(tester);
    expect(find.textContaining('Payment pending'), findsOneWidget);
    expect(find.byKey(const ValueKey('billing-pay-now')), findsNothing);
    expect(find.byKey(const ValueKey('billing-sheet-close')), findsOneWidget);
    expect(store.completed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('paid Play plan shows renewal, manage and Play downgrades', (
    tester,
  ) async {
    usage = _usage(
      tier: '7x',
      expires: '2026-11-11T08:00:00Z',
      autoRenews: true,
    );
    await mount(tester);
    expect(find.text('Renews on Nov 11, 2026'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manage-3x')),
        matching: find.text('Change in Google Play'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('manage-free')),
        matching: find.text('Cancel in Google Play'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('upgrade-3x')), findsNothing);
    expect(find.byKey(const ValueKey('upgrade-15x')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('billing-manage')));
    await _frames(tester);
    expect(launched.single.host, 'play.google.com');
    expect(launched.single.path, '/store/account/subscriptions');
    expect(launched.single.queryParameters['sku'], kOvidPlayProducts['7x']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelled plan shows its end date', (tester) async {
    usage = _usage(
      tier: '3x',
      expires: '2026-11-11T08:00:00Z',
      autoRenews: false,
    );
    await mount(tester);
    expect(find.text('Ends on Nov 11, 2026'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('server feature lists replace multiplier-only copy', (
    tester,
  ) async {
    usage = _usage(
      plans: [
        {
          'tier': '3x',
          'features': ['About 900 messages a month', 'Image generation'],
        },
      ],
    );
    await mount(tester);
    final plus = find.byKey(const ValueKey('plan-3x'));
    expect(
      find.descendant(
        of: plus,
        matching: find.text('About 900 messages a month'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: plus, matching: find.text('Image generation')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('restore purchases reports what it found', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('billing-restore')));
    await _frames(tester);
    expect(
      find.text('No active subscription found for this Google account.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('every plan-change result has distinct copy', () {
    final copy = {
      for (final result in UpgradeResult.values)
        upgradeResultMessage(result, planTitle: 'Plus'),
    };
    expect(copy, hasLength(UpgradeResult.values.length));
    expect(upgradeResultRetryable(UpgradeResult.notAvailable), isFalse);
    expect(upgradeResultRetryable(UpgradeResult.pending), isFalse);
    expect(upgradeResultRetryable(UpgradeResult.offline), isTrue);
  });
}
