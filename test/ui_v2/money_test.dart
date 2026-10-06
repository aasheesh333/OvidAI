import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/plan_identity.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/money_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal usage snapshot the server would return for [tier].
Map<String, dynamic> _snapshot(
  String tier, {
  double? remaining = 0.42,
  List<Map<String, dynamic>> models = const [],
}) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'daily_budget_usd': 45,
  'daily_spent_usd': 1,
  'daily_remaining_usd': 44,
  'budget_window': tier == 'free' ? '24h' : '30d',
  'remaining_pct': ?remaining,
  'models': models,
};

/// v2 Money surface contract ("Account & billing"):
///
/// * [PlanIdentity] is the single tier→identity source: FREE/PLUS/PRO/MAX,
///   ×1/×3/×7/×15, ₹0/₹499/₹899/₹1699 — INR only, never USD.
/// * The Overview hero renders the plan pill, the remaining percentage with
///   a progress bar, a refresh action, and the next-plan CTA.
/// * Tabs switch between Overview, Usage, and Plans; the Plans tab holds the
///   four INR plan cards.
/// * The receipt panel shows one state display and ONE context action
///   (Recover when the receipt is confirmed, otherwise Check status).
/// * Empty and error states stay clean at 360×640 @2× in light and dark.
///
/// All pumps are bounded; real async boundaries (receipt journal) run inside
/// `tester.runAsync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response(jsonEncode(_snapshot('free')), 200));
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    Aether.dark = true;
  });

  // -------------------------------------------------------------------------
  // Helpers — bounded pumps only.
  // -------------------------------------------------------------------------

  void setView(WidgetTester tester) {
    // The v2 money contract viewport: 360×640 logical at 2× DPR.
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(720, 1280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpMoney(
    WidgetTester tester, {
    MoneyTab initialTab = MoneyTab.overview,
    bool dark = false,
  }) async {
    Aether.dark = dark;
    setView(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: MoneyScreen(initialTab: initialTab),
      ),
    );
    await tester.pump();
  }

  /// Bounded settle: a fixed number of 50ms frames — covers sheet (≈250ms)
  /// and route animations without an unbounded pumpAndSettle.
  Future<void> frames(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  String visibleText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .join(' ');

  void expectInrOnly(WidgetTester tester) {
    expect(
      visibleText(tester),
      isNot(matches(RegExp(r'\$|USD', caseSensitive: false))),
    );
  }

  // -------------------------------------------------------------------------
  // PlanIdentity — the single plan-identity source.
  // -------------------------------------------------------------------------

  test('plan identity maps every tier to name, multiplier, and INR price', () {
    final expected = {
      'free': ('FREE', '×1', 0, 'Free'),
      '3x': ('PLUS', '×3', 499, '₹499'),
      '7x': ('PRO', '×7', 899, '₹899'),
      '15x': ('MAX', '×15', 1699, '₹1699'),
    };
    expect(PlanIdentity.all.map((p) => p.tier), expected.keys);
    for (final entry in expected.entries) {
      final plan = PlanIdentity.forTier(entry.key);
      expect(plan, isNotNull, reason: entry.key);
      expect(plan!.name, entry.value.$1, reason: entry.key);
      expect(plan.multiplierLabel, entry.value.$2, reason: entry.key);
      expect(plan.priceInr, entry.value.$3, reason: entry.key);
      expect(plan.priceLabel, entry.value.$4, reason: entry.key);
      // INR only: the price label is either 'Free' or carries the rupee sign.
      expect(
        plan.priceLabel == 'Free' || plan.priceLabel.startsWith('₹'),
        isTrue,
        reason: entry.key,
      );
    }
    expect(PlanIdentity.forTier('future-tier'), isNull);
    expect(PlanIdentity.forTier(''), isNull);

    // Multipliers over the Free base.
    expect(PlanIdentity.forTier('free')!.multiplier, 1);
    expect(PlanIdentity.forTier('3x')!.multiplier, 3);
    expect(PlanIdentity.forTier('7x')!.multiplier, 7);
    expect(PlanIdentity.forTier('15x')!.multiplier, 15);

    // Pill labels honour the paid flag and never invent one.
    expect(PlanIdentity.pillLabel('free', isPaid: false), 'FREE');
    expect(PlanIdentity.pillLabel('free', isPaid: true), 'FREE');
    expect(PlanIdentity.pillLabel('3x', isPaid: false), 'FREE');
    expect(PlanIdentity.pillLabel('3x', isPaid: true), 'PLUS');
    expect(PlanIdentity.pillLabel('7x', isPaid: true), 'PRO');
    expect(PlanIdentity.pillLabel('15x', isPaid: true), 'MAX');
    expect(PlanIdentity.pillLabel('', isPaid: false), 'FREE');
    expect(PlanIdentity.pillLabel('future-tier', isPaid: true), 'UNKNOWN');

    // Next-plan ladder.
    expect(PlanIdentity.nextAfter('free')!.tier, '3x');
    expect(PlanIdentity.nextAfter('3x')!.tier, '7x');
    expect(PlanIdentity.nextAfter('7x')!.tier, '15x');
    expect(PlanIdentity.nextAfter('15x'), isNull);
    expect(PlanIdentity.nextAfter('future-tier'), isNull);
  });

  // -------------------------------------------------------------------------
  // Overview hero.
  // -------------------------------------------------------------------------

  testWidgets('hero renders remaining percent, pill, bar, and refreshes', (
    tester,
  ) async {
    var fetches = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      fetches++;
      return http.Response(jsonEncode(_snapshot('3x')), 200);
    });
    await pumpMoney(tester);
    await frames(tester);

    // Pill + remaining percentage + progress bar from the server snapshot.
    expect(find.text('PLUS'), findsOneWidget);
    expect(find.text('42% remaining'), findsOneWidget);
    final bars = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bars.map((b) => b.value), [0.42]);
    expect(fetches, 1);

    // Explicit refresh re-fetches the allowance (past the store cooldown).
    await tester.tap(find.byTooltip('Refresh allowance'));
    await tester.pump(const Duration(seconds: 3));
    await frames(tester);
    expect(fetches, greaterThanOrEqualTo(2));
    expect(find.text('42% remaining'), findsOneWidget);
    expectInrOnly(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hero next-plan CTA opens checkout and pays through upgrade', (
    tester,
  ) async {
    var tier = 'free';
    var upgrades = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((
      request,
    ) async {
      if (request.url.path == '/upgrade') {
        upgrades++;
        tier = (jsonDecode(request.body) as Map<String, dynamic>)['tier']
            as String;
        return http.Response(jsonEncode({'ok': true, 'tier': tier}), 200);
      }
      if (request.url.path.endsWith('/models')) {
        return http.Response('{"data":[{"id":"ovid-base"}]}', 200);
      }
      return http.Response(jsonEncode(_snapshot(tier)), 200);
    });
    await pumpMoney(tester);
    await frames(tester);

    expect(find.text('FREE'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('upgrade-header')));
    await frames(tester);

    // Checkout sheet quotes the next plan in INR and pays via the service.
    expect(find.text('Upgrade to Plus'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Pay now · ₹499'));
    await frames(tester, 14);
    expect(upgrades, 1);
    expect(app.ovidCloudTier, '3x');
    expect(find.text('You are now on the Plus plan.'), findsOneWidget);
    expect(find.text('PLUS'), findsOneWidget);
    expectInrOnly(tester);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // Tabs.
  // -------------------------------------------------------------------------

  testWidgets('tabs switch between overview, usage, and plans', (tester) async {
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(
        jsonEncode(
          _snapshot(
            '15x',
            remaining: 0.37,
            models: const [
              {'model': 'ovid-pro-1', 'remaining_pct': 0.23},
            ],
          ),
        ),
        200,
      ),
    );
    await pumpMoney(tester);
    await frames(tester);

    // Overview: hero with plan pill and remaining percentage.
    expect(find.text('MAX'), findsOneWidget);
    expect(find.text('37% remaining'), findsOneWidget);

    // Plans: the four cards, current plan marked, no hero percentage.
    await tester.tap(find.text('Plans'));
    await frames(tester);
    expect(find.text('37% remaining'), findsNothing);
    expect(find.text('₹1699'), findsOneWidget);
    expect(find.text('×15'), findsOneWidget);
    expect(find.text('Current plan'), findsOneWidget);

    // Usage: per-model remaining, BYOK empty state, image receipts.
    await tester.tap(find.text('Usage'));
    await frames(tester);
    expect(find.text('23% remaining'), findsOneWidget);
    expect(find.text('No usage yet'), findsOneWidget);
    expect(find.text('Image receipts'), findsOneWidget);

    // Back to Overview: the hero returns.
    await tester.tap(find.text('Overview'));
    await frames(tester);
    expect(find.text('MAX'), findsOneWidget);
    expect(find.text('37% remaining'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plans tab renders four cards with INR prices and multipliers', (
    tester,
  ) async {
    await pumpMoney(tester, initialTab: MoneyTab.plans);
    await frames(tester);

    for (final marker in ['₹499', '₹899', '₹1699', '×15']) {
      await tester.ensureVisible(find.text(marker));
      await tester.pump();
    }
    // Prices (INR only) and multiplier chips.
    expect(find.text('Free'), findsWidgets);
    expect(find.text('₹499'), findsOneWidget);
    expect(find.text('₹899'), findsOneWidget);
    expect(find.text('₹1699'), findsOneWidget);
    expect(find.text('×1'), findsOneWidget);
    expect(find.text('×3'), findsOneWidget);
    expect(find.text('×7'), findsOneWidget);
    expect(find.text('×15'), findsOneWidget);

    // The free plan is current: its action is disabled.
    final current = find.widgetWithText(FilledButton, 'Current plan');
    expect(current, findsOneWidget);
    expect(tester.widget<FilledButton>(current).onPressed, isNull);

    expectInrOnly(tester);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // Receipt panel — one state display, one context action.
  // -------------------------------------------------------------------------

  testWidgets('receipt panel shows one context action per record', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final store = ImageReceiptStore(
        preferences: SharedPreferences.getInstance,
      );
      const fingerprint =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      // The journal allows only one unresolved request per account, so the
      // confirmed record is settled BEFORE the pending one is reserved.
      const confirmedIdentity = ImageRequestRecord(
        accountId: 'alice',
        requestId: 'request-confirmed-1',
        fingerprint: fingerprint,
      );
      await store.reserve(
        confirmedIdentity,
        isCurrent: () => true,
        canSubmit: () => true,
      );
      final receipt = ImageReceipt.parse({
        'account_id': 'alice',
        'request_id': 'request-confirmed-1',
        'fingerprint': fingerprint,
        'state': 'confirmed',
        'charged': '0.0370370367037037036703703703670',
      });
      await store.update(
        confirmedIdentity.withReceipt(receipt),
        isCurrent: () => true,
      );
      await store.reserve(
        const ImageRequestRecord(
          accountId: 'alice',
          requestId: 'request-pending-1',
          fingerprint: fingerprint,
        ),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((_) async => http.Response('{}', 404)),
      )..bindAccount('alice');
      await studio.loadReceipts();

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImageReceiptPanel(
                studio: studio,
                headers: () async => const {'Authorization': 'Bearer fixture'},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // One state display each: the pill, with no duplicated 'Status:' line.
      expect(find.text('PENDING'), findsOneWidget);
      expect(find.text('CONFIRMED'), findsOneWidget);
      expect(find.textContaining('Status:'), findsNothing);

      // ONE context action per record: recovery only when the receipt is
      // confirmed; a read-only status check otherwise.
      expect(find.text('Recover image'), findsOneWidget);
      expect(find.text('Check status'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // -------------------------------------------------------------------------
  // Empty and error states — 360×640 @2×, light and dark.
  // -------------------------------------------------------------------------

  for (final dark in [false, true]) {
    testWidgets('error state refreshes cleanly (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      var fail = true;
      OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
        if (fail) return http.Response('down', 503);
        return http.Response(jsonEncode(_snapshot('7x', remaining: 0.55)), 200);
      });
      await pumpMoney(tester, dark: dark);
      await frames(tester);

      // Clean error state: no invented percentage, retry offered.
      expect(find.text('PRO'), findsNothing);
      expect(find.text('Usage unavailable'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pump(const Duration(seconds: 3));
      await frames(tester);
      expect(find.text('55% remaining'), findsOneWidget);
      expect(find.text('PRO'), findsOneWidget);
      expectInrOnly(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('empty usage and receipts stay calm (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      await pumpMoney(tester, initialTab: MoneyTab.usage, dark: dark);
      await frames(tester);

      // No BYOK usage and no account receipts: designed empty states, no
      // exceptions, and nothing leaks a currency other than INR.
      expect(find.text('No usage yet'), findsOneWidget);
      // The empty-state icon (the segmented control reuses it for Usage).
      expect(find.byIcon(Icons.query_stats), findsWidgets);
      await tester.ensureVisible(
        find.text('No loaded image receipts for this account.'),
      );
      expect(
        find.text('No loaded image receipts for this account.'),
        findsOneWidget,
      );
      expect(find.text('Check status'), findsNothing);
      expect(find.text('Recover image'), findsNothing);
      expectInrOnly(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
