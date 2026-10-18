import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/play_billing.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_billing_platform.dart';

Map<String, dynamic> _usage({bool? billingEnabled}) => {
  'tier': 'free',
  'is_paid': false,
  'remaining_pct': .5,
  'models': const [],
  'billing_enabled': ?billingEnabled,
};

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _mount(
  WidgetTester tester, {
  bool? allowTestUpgrade,
  PlayBillingService? billing,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(540, 2400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: BillingScreen(allowTestUpgrade: allowTestUpgrade, billing: billing),
    ),
  );
  await _frames(tester);
}

void main() {
  late List<String> requests;
  setUp(() {
    requests = [];
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    OvidCloudService.I.resetUpgradeAvailabilityForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 'billing-test-token';
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    OvidCloudService.I.resetUpgradeAvailabilityForTest();
    AppState.resetTestInstance();
  });

  void serve({bool? billingEnabled}) {
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path == '/upgrade') {
            return http.Response('{"detail":"test upgrade is disabled"}', 403);
          }
          if (request.url.path.endsWith('/models')) {
            return http.Response('{"data":[{"id":"ovid-base"}]}', 200);
          }
          return http.Response(
            jsonEncode(_usage(billingEnabled: billingEnabled)),
            200,
          );
        });
  }

  testWidgets('without a billing backend no purchase CTA is offered', (
    tester,
  ) async {
    serve();
    await _mount(tester, allowTestUpgrade: false);
    expect(find.byKey(const ValueKey('upgrade-header')), findsNothing);
    expect(
      find.byKey(const ValueKey('paid-plans-coming-soon')),
      findsOneWidget,
    );
    for (final tier in ['3x', '7x', '15x']) {
      expect(find.byKey(ValueKey('upgrade-$tier')), findsNothing);
      expect(find.byKey(ValueKey('coming-soon-$tier')), findsOneWidget);
    }
    expect(find.textContaining('Pay now'), findsNothing);
    expect(find.textContaining('nothing can be purchased yet'), findsOneWidget);
    expect(requests, isNot(contains('/upgrade')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('server billing_enabled offers Google Play plans', (
    tester,
  ) async {
    serve(billingEnabled: true);
    final billing = fakeBillingService(FakeBillingPlatform());
    addTearDown(billing.dispose);
    await _mount(tester, allowTestUpgrade: false, billing: billing);
    expect(find.byKey(const ValueKey('upgrade-header')), findsOneWidget);
    expect(find.byKey(const ValueKey('upgrade-3x')), findsOneWidget);
    expect(find.byKey(const ValueKey('paid-plans-coming-soon')), findsNothing);
    expect(find.byKey(const ValueKey('billing-restore')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('billing_enabled without Google Play explains why', (
    tester,
  ) async {
    serve(billingEnabled: true);
    final billing = fakeBillingService(
      FakeBillingPlatform(storeAvailable: false),
    );
    addTearDown(billing.dispose);
    await _mount(tester, allowTestUpgrade: false, billing: billing);
    expect(find.byKey(const ValueKey('upgrade-3x')), findsNothing);
    expect(find.textContaining('need Google Play'), findsOneWidget);
    expect(requests, isNot(contains('/upgrade')));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a 403 "disabled" upgrade is explained and hides the CTAs', (
    tester,
  ) async {
    serve();
    await _mount(tester, allowTestUpgrade: true);
    await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('billing-pay-now')));
    await _frames(tester);
    expect(requests.where((path) => path == '/upgrade'), hasLength(1));
    expect(OvidCloudService.I.upgradeDisabledByServer, isTrue);
    // The sheet stays open with the reason and no Retry (F-201/F-202).
    expect(
      find.text('Paid plans are not available yet. Nothing was charged.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('billing-pay-now')), findsNothing);
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('billing-sheet-close')));
    await _frames(tester);
    expect(find.byKey(const ValueKey('upgrade-3x')), findsNothing);
    expect(find.byKey(const ValueKey('coming-soon-3x')), findsOneWidget);
    expect(AppState.I.ovidCloudTier, 'free');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
