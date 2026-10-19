// SH-006 / SH-021 / EM-015: the Plans screen renders the server's live plan
// table and current plan, with honest copy when nothing can be bought here.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _plan(
  String tier,
  String id,
  String name,
  num price,
  num mult,
) => {
  'tier': tier,
  'id': id,
  'name': name,
  'price_usd': price,
  'mult': mult,
  'window': '24h',
  'features': ['About ${mult}x the Free allowance'],
  'product_id': tier == 'free' ? null : 'ovid_${id}_monthly',
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    OvidPlanCatalog.resetForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 't';
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    OvidPlanCatalog.resetForTest();
    AppState.resetTestInstance();
  });

  testWidgets('an admin-renamed plan table is what the screen shows', (
    tester,
  ) async {
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tier': '3x',
          'plan': 'basic',
          'plan_name': 'Basic',
          'is_paid': true,
          'remaining_fraction': .4,
          'resets_at': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 3, minutes: 30))
              .toIso8601String(),
          'models': const [],
          'billing_enabled': false,
          'plans': [
            _plan('free', 'free', 'Free', 0, 1),
            _plan('3x', 'basic', 'Basic', 7, 4),
            _plan('7x', 'team', 'Team', 30, 30),
          ],
        }),
        200,
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 2600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: BillingScreen(allowTestUpgrade: false)),
    );
    await tester.pumpAndSettle();

    expect(find.text('BASIC'), findsOneWidget, reason: 'current plan pill');
    expect(find.text('Team'), findsOneWidget);
    expect(find.text('×4'), findsOneWidget);
    expect(find.text('US\$7 / month'), findsOneWidget);
    expect(find.text('US\$30 / month'), findsOneWidget);
    // Localised reset, never raw ISO (SH-016).
    expect(find.textContaining('Resets in 3 h'), findsOneWidget);
    // Not purchasable here: said in text, no disabled fake button (R4).
    expect(find.byKey(const ValueKey('not-purchasable-7x')), findsOneWidget);
    expect(find.textContaining('Coming soon'), findsNothing);
    expect(find.byKey(const ValueKey('paid-plans-unavailable')), findsOneWidget);
    // The shared catalog now speaks the server's names (sidebar, account).
    expect(ovidPlanName('7x'), 'Team');
    expect(ovidPlanMultiplier('3x'), 4);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a 401 never shows a raw status code (EM-015)', (tester) async {
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response('{"detail":"x"}', 401));
    await tester.pumpWidget(
      const MaterialApp(home: BillingScreen(allowTestUpgrade: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('(401)'), findsNothing);
    expect(find.textContaining('UNKNOWN'), findsNothing);
    expect(find.textContaining("couldn't load your plan"), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
