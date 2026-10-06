import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal usage snapshot the server would return for [tier].
Map<String, dynamic> _snapshot(String tier) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'daily_budget_usd': 45,
  'daily_spent_usd': 1,
  'daily_remaining_usd': 44,
  'budget_window': tier == 'free' ? '24h' : '30d',
  'remaining_pct': 0.5,
  'models': const [],
};

Future<void> _pumpBilling(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    const MaterialApp(home: BillingScreen()),
  );
  await tester.pumpAndSettle();
}

/// Flatten all visible [Text] widgets' data into one blob — useful for
/// asserting an absence of forbidden copy anywhere on the screen.
String _allVisibleText(WidgetTester tester) {
  final sb = StringBuffer();
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    final data = t.data;
    if (data != null) sb.write('$data ');
  }
  return sb.toString();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    // Default: user is on Free. Tests that need a different tier override
    // the client factory individually.
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(jsonEncode(_snapshot('free')), 200),
    );
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  testWidgets('renders four plan cards with INR prices and multipliers', (
    tester,
  ) async {
    await _pumpBilling(tester);

    // Scroll the whole list so every lazily-built card is materialised.
    for (final marker in [
      'Free',
      'Plus',
      '₹499',
      'Pro',
      '₹899',
      'Max',
      '₹1699',
      '×15',
    ]) {
      await tester.scrollUntilVisible(find.text(marker).first, 140);
      await tester.pump();
    }

    // All four plan names visible.
    expect(find.text('Free'), findsWidgets);
    expect(find.text('Plus'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Max'), findsOneWidget);

    // INR prices for paid plans; 'Free' label for the free tile.
    expect(find.text('₹499'), findsOneWidget);
    expect(find.text('₹899'), findsOneWidget);
    expect(find.text('₹1699'), findsOneWidget);

    // Multiplier chips.
    expect(find.text('×1'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    expect(find.text('×7'), findsOneWidget);
    expect(find.text('×15'), findsOneWidget);
  });

  testWidgets('current plan button is disabled with "Current plan" label', (
    tester,
  ) async {
    // User is on Plus (3x). The Plus card should show the disabled
    // "Current plan" button.
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(jsonEncode(_snapshot('3x')), 200),
    );
    await _pumpBilling(tester);

    // The header label and the disabled button both read "Current plan".
    expect(find.text('Current plan'), findsWidgets);

    // Locate the disabled FilledButton labelled "Current plan" and assert
    // it cannot be pressed.
    final btnFinder = find.widgetWithText(FilledButton, 'Current plan');
    expect(btnFinder, findsOneWidget);
    final btn = tester.widget<FilledButton>(btnFinder);
    expect(btn.onPressed, isNull);
  });

  testWidgets(
    'tapping a plan upgrade button routes through OvidCloudService.upgrade',
    (tester) async {
      var tier = 'free';
      var upgrades = 0;
      Map<String, dynamic>? upgradeBody;
      OvidCloudService.httpClientFactoryForTest = () => MockClient(
        (request) async {
          if (request.url.path == '/upgrade') {
            upgrades++;
            upgradeBody = jsonDecode(request.body) as Map<String, dynamic>;
            tier = (upgradeBody!['tier'] as String?) ?? tier;
            return http.Response(
              jsonEncode({'ok': true, 'tier': tier}),
              200,
            );
          }
          return http.Response(jsonEncode(_snapshot(tier)), 200);
        },
      );

      await _pumpBilling(tester);

      // Scroll the Plus button into view and tap it.
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('upgrade-3x')),
        150,
      );
      await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
      await tester.pumpAndSettle();

      // Confirm the "Pay now" sheet is open and tap it.
      final pay = find.widgetWithText(FilledButton, 'Pay now · ₹499');
      expect(pay, findsOneWidget);
      await tester.tap(pay);
      await tester.pumpAndSettle();

      // Upgrade API was invoked with the Plus tier identifier (3x), which is
      // the backend code for the Plus plan — preserving the existing wiring.
      expect(upgrades, 1);
      expect(upgradeBody, isNotNull);
      expect(upgradeBody!['tier'], '3x');
      // AppState records the newly confirmed tier.
      expect(AppState.I.ovidCloudTier, '3x');
    },
  );

  testWidgets('no USD text appears anywhere on the screen', (tester) async {
    // Try every tier so the renewal/footer/current-plan copy all render.
    for (final startTier in ['free', '3x', '7x', '15x']) {
      OvidCloudService.httpClientFactoryForTest = () => MockClient(
        (_) async => http.Response(jsonEncode(_snapshot(startTier)), 200),
      );
      await _pumpBilling(tester);
      final blob = _allVisibleText(tester);
      expect(
        blob.contains(r'$'),
        isFalse,
        reason: 'dollar sign leaked for tier=$startTier: $blob',
      );
      expect(
        RegExp(r'\bUSD\b', caseSensitive: false).hasMatch(blob),
        isFalse,
        reason: 'USD leaked for tier=$startTier: $blob',
      );
    }
  });
}
