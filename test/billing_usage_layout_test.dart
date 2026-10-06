import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> snapshot(String tier, {double? remaining = 0.37}) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'daily_budget_usd': 45,
  'daily_spent_usd': 1,
  'daily_remaining_usd': 44,
  'budget_window': tier == 'free' ? '24h' : '30d',
  'remaining_pct': ?remaining,
  'models': [
    {
      'model': 'ovid-pro-1',
      'output_cost_per_token': 0.000075,
      'remaining_pct': ?remaining,
    },
  ],
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(jsonEncode(snapshot('15x')), 200),
    );
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Future<void> pump(WidgetTester tester, Widget screen, double width) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.3)),
          child: child!,
        ),
        home: screen,
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectNoInternalCopy(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .join(' ');
    expect(
      text,
      isNot(
        matches(
          RegExp(
            r'\$|USD|daily|24h|monthly pool|Est\. cost|≈ COST',
            caseSensitive: false,
          ),
        ),
      ),
    );
  }

  for (final width in [320.0, 360.0, 390.0, 411.0]) {
    testWidgets('billing and checkout fit ${width}dp at 1.3x', (tester) async {
      await pump(tester, const BillingScreen(), width);
      expect(tester.takeException(), isNull);
      expect(find.text('37% remaining'), findsOneWidget);
      for (final price in ['₹499', '₹899', '₹1699']) {
        await tester.scrollUntilVisible(find.text(price), 150);
        expectNoInternalCopy(tester);
        expect(tester.takeException(), isNull);
      }
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('upgrade-3x')),
        -150,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('upgrade-3x')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('upgrade-3x')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pay now · ₹'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expectNoInternalCopy(tester);
    });

    testWidgets('usage fits ${width}dp at 1.3x', (tester) async {
      await pump(tester, const UsageScreen(), width);
      expect(find.text('37% remaining'), findsWidgets);
      expectNoInternalCopy(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('account actions fit ${width}dp at 1.3x', (tester) async {
      await pump(tester, const AuthScreen(), width);
      await tester.scrollUntilVisible(
        find.text('Existing account help'),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Phone'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Forgot password'), findsNothing);
      expect(find.text('Sign in with email'), findsNothing);
      await tester.tap(find.text('Existing account help'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('identity-verified account recovery'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final tier in ['free', '15x']) {
    for (final remaining in [0.0, 1.0]) {
      testWidgets(
        '$tier shows server remaining $remaining without a reset claim',
        (tester) async {
          OvidCloudService.httpClientFactoryForTest = () => MockClient(
            (_) async => http.Response(
              jsonEncode(snapshot(tier, remaining: remaining)),
              200,
            ),
          );
          await pump(tester, const UsageScreen(), 320);
          expect(
            find.text('${(remaining * 100).round()}% remaining'),
            findsWidgets,
          );
          for (final bar in tester.widgetList<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          )) {
            expect(bar.value, remaining);
          }
          expectNoInternalCopy(tester);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets('$tier missing usage does not invent a percentage', (
      tester,
    ) async {
      OvidCloudService.httpClientFactoryForTest = () => MockClient(
        (_) async =>
            http.Response(jsonEncode(snapshot(tier, remaining: null)), 200),
      );
      await pump(tester, const UsageScreen(), 320);
      expect(find.text('Usage unavailable'), findsWidgets);
      expect(find.textContaining('%'), findsNothing);
      expectNoInternalCopy(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'provider detail keeps token counts and hides model costs at 320dp',
    (tester) async {
      final provider = ProviderUsage(
        providerId: 'custom',
        providerName: 'Custom provider with a long name',
        tier: 'BYOK',
        icon: Icons.cloud,
        color: Colors.blue,
        requests: 10000,
        tokensIn: 1234567,
        tokensOut: 7654321,
        models: [('custom-model-with-a-long-name', 10000, 8888888)],
        costUsd: 99,
        hasPricedModel: true,
      );
      await pump(tester, ProviderUsageScreen(provider: provider), 320);
      await tester.scrollUntilVisible(
        find.text('custom-model-with-a-long-name'),
        150,
      );
      expectNoInternalCopy(tester);
      expect(tester.takeException(), isNull);
    },
  );

  for (final success in [true, false]) {
    testWidgets(
      'Pay now ${success ? 'refreshes the plan' : 'handles rejection'} and prevents duplicate requests',
      (tester) async {
        var tier = 'free';
        var upgrades = 0;
        final reply = Completer<http.Response>();
        OvidCloudService.httpClientFactoryForTest = () =>
            MockClient((request) async {
              if (request.url.path == '/upgrade') {
                upgrades++;
                expect(jsonDecode(request.body), {'tier': '3x'});
                return reply.future;
              }
              return http.Response(jsonEncode(snapshot(tier)), 200);
            });
        await pump(tester, const BillingScreen(), 320);
        await tester.scrollUntilVisible(find.text('Upgrade').first, 150);
        await tester.tap(find.text('Upgrade').first);
        await tester.pumpAndSettle();
        final pay = find.widgetWithText(FilledButton, 'Pay now · ₹499');
        await tester.tap(pay);
        await tester.pump();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
          isNull,
        );
        expect(upgrades, 1);
        if (success) tier = '3x';
        reply.complete(
          http.Response(
            jsonEncode({'ok': success, 'tier': tier}),
            success ? 200 : 403,
          ),
        );
        await tester.pumpAndSettle();
        expect(AppState.I.ovidCloudTier, tier);
        expect(
          find.text(
            success
                ? 'You are now on the Plus plan.'
                : 'Could not complete the upgrade. Try again.',
          ),
          findsOneWidget,
        );
        await tester.drag(find.byType(ListView), const Offset(0, 1500));
        await tester.pumpAndSettle();
        expect(find.text(success ? 'PLUS' : 'FREE'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
