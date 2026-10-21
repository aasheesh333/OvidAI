import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/revenuecat_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake RevenueCat SDK that reports a successful purchase of Ovid Plus.
class _PurchaseOkPlatform implements RevenueCatPlatform {
  const _PurchaseOkPlatform();

  @override
  Future<void> configure({
    required String apiKey,
    required String appUserId,
  }) async {}

  static const _products = <String, String>{
    'pkg_go': 'ovid_plus_monthly',
    'pkg_plus': 'ovid_pro_monthly',
    'pkg_max': 'ovid_max_monthly',
  };

  static const _tiers = <String, String>{
    'pkg_go': '3x',
    'pkg_plus': '7x',
    'pkg_max': '15x',
  };

  @override
  Future<List<RevenueCatPackage>> packages() async => [
    for (final entry in _products.entries)
      RevenueCatPackage(
        identifier: entry.key,
        productId: entry.value,
        title: entry.value,
        priceString: '\$18',
      ),
  ];

  @override
  Future<RevenueCatResult> purchasePackage(String identifier) async =>
      RevenueCatResult(ok: true, tier: _tiers[identifier] ?? '7x');

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

  setUp(() {
    paths = [];
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    resetConfirmedPlanTierForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 'billing-test-token';
    RevenueCatBilling.instanceForTest = RevenueCatBilling(
      platform: const _PurchaseOkPlatform(),
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
    OvidCloudService.httpClientFactoryForTest = () => MockClient((
      request,
    ) async {
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
    expect(
      find.textContaining('unlocks as soon as our server confirms'),
      findsOneWidget,
    );
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
}
