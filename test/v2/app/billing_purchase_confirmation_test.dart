import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/revenuecat_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake RevenueCat SDK that reports a successful purchase.
class _PurchaseOkPlatform implements RevenueCatPlatform {
  _PurchaseOkPlatform({this.offered = monthly});

  static const monthly = <RevenueCatPackage>[
    RevenueCatPackage(
      identifier: 'pkg_go',
      productId: 'ovid_plus_monthly',
      title: 'ovid_plus_monthly',
      priceString: r'$5',
    ),
    RevenueCatPackage(
      identifier: 'pkg_plus',
      productId: 'ovid_pro_monthly',
      title: 'ovid_pro_monthly',
      priceString: r'$18',
    ),
    RevenueCatPackage(
      identifier: 'pkg_max',
      productId: 'ovid_max_monthly',
      title: 'ovid_max_monthly',
      priceString: r'$99',
    ),
  ];

  static const yearly = <RevenueCatPackage>[
    RevenueCatPackage(
      identifier: 'pkg_go_yearly',
      productId: 'ovid_plus_yearly',
      title: 'ovid_plus_yearly',
      priceString: r'$50',
    ),
    RevenueCatPackage(
      identifier: 'pkg_plus_yearly',
      productId: 'ovid_pro_yearly',
      title: 'ovid_pro_yearly',
      priceString: r'$180',
    ),
    RevenueCatPackage(
      identifier: 'pkg_max_yearly',
      productId: 'ovid_max_yearly',
      title: 'ovid_max_yearly',
      priceString: r'$990',
    ),
  ];

  final List<RevenueCatPackage> offered;

  /// Package identifiers the SDK was asked to buy.
  final purchased = <String>[];

  static const _tiers = <String, String>{
    'pkg_go': '3x',
    'pkg_plus': '7x',
    'pkg_max': '15x',
    'pkg_go_yearly': '3x',
    'pkg_plus_yearly': '7x',
    'pkg_max_yearly': '15x',
  };

  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {}

  @override
  Future<List<RevenueCatPackage>> packages() async => offered;

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async {
    purchased.add(identifier);
    return RevenueCatResult(ok: true, tier: _tiers[identifier] ?? '7x');
  }

  @override
  Future<RevenueCatResult> restore() async =>
      const RevenueCatResult(ok: true, tier: '7x');

  @override
  Future<RevenueCatResult> customerInfo() async =>
      const RevenueCatResult(ok: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> paths;
  late _PurchaseOkPlatform platform;

  setUp(() {
    paths = [];
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    resetConfirmedPlanTierForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 'billing-test-token';
    platform = _PurchaseOkPlatform();
    RevenueCatBilling.instanceForTest = RevenueCatBilling(
      platform: platform,
      uid: () => 'u1',
      config: const RevenueCatConfig(apiKey: 'goog_test_key'),
    );
  });

  tearDown(() {
    RevenueCatBilling.instanceForTest = null;
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    resetConfirmedPlanTierForTest();
    AppState.resetTestInstance();
  });

  void serve(String tier) {
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(
            jsonEncode({
              'tier': tier,
              'is_paid': tier != 'free',
              'remaining_pct': 0.5,
              'models': const <String>[],
            }),
            200,
          );
        });
  }

  Future<BuildContext> mount(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('a store success does not unlock before the server agrees', (
    tester,
  ) async {
    serve('free');
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    await actions.buyPlan(context, '7x');
    await tester.pump();

    expect(paths.where((p) => p == '/usage'), isNotEmpty);
    expect(AppState.I.ovidCloudTier, 'free');
    expect(isServerConfirmed('7x'), isFalse);
    expect(find.textContaining('unlocks after confirmation'), findsOneWidget);
    // Cancel the store's timers before the widget test checks for leaks.
    usage.release();
  });

  testWidgets('the server tier, not the purchased one, is applied', (
    tester,
  ) async {
    serve('7x');
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    // Buying 15x while the server still reports 7x: the server wins.
    await actions.buyPlan(context, '15x');
    await tester.pump();

    expect(AppState.I.ovidCloudTier, '7x');
    expect(isServerConfirmed('7x'), isTrue);
    expect(isServerConfirmed('15x'), isFalse);
    expect(find.text('Plan updated.'), findsOneWidget);
    usage.release();
  });

  testWidgets('a cached paid tier is cleared when the server says free', (
    tester,
  ) async {
    // The stale SharedPreferences value: a paid plan with no server backing.
    AppState.I.setOvidCloudTier('7x');
    expect(isServerConfirmed('7x'), isFalse);
    serve('free');
    final usage = CloudUsageStore.acquire(AppState.I);
    V2SettingsActions(usage);
    await mount(tester);
    await tester.pump();
    await tester.pump();

    expect(AppState.I.ovidCloudTier, 'free');
    expect(isServerConfirmed('7x'), isFalse);
    usage.release();
  });

  testWidgets('a yearly selection buys the yearly package', (tester) async {
    final yearlyPlatform = _PurchaseOkPlatform(
      offered: [..._PurchaseOkPlatform.monthly, ..._PurchaseOkPlatform.yearly],
    );
    RevenueCatBilling.instanceForTest = RevenueCatBilling(
      platform: yearlyPlatform,
      uid: () => 'u1',
      config: const RevenueCatConfig(apiKey: 'goog_test_key'),
    );
    serve('7x');
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    await actions.buyPlan(context, '7x', period: OvidBillingPeriod.yearly);
    await tester.pump();

    expect(yearlyPlatform.purchased, ['pkg_plus_yearly']);
    expect(AppState.I.ovidCloudTier, '7x');
    usage.release();
  });

  testWidgets('a missing yearly package does not buy the monthly one', (
    tester,
  ) async {
    // The setUp platform offers monthly packages only.
    serve('7x');
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    await actions.buyPlan(context, '7x', period: OvidBillingPeriod.yearly);
    await tester.pump();

    expect(platform.purchased, isEmpty, reason: 'no monthly fallback');
    expect(
      find.textContaining('Yearly billing is not available'),
      findsOneWidget,
    );
    expect(AppState.I.ovidCloudTier, 'free');
    expect(isServerConfirmed('7x'), isFalse);
    usage.release();
  });
}
