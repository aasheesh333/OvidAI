import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/money_screen.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2 providers polish contract:
///
/// * Calm managed Ovid Cloud tile — plan pill + 'Manage plan' → Money.
/// * BYOK cards show exactly one status pill, the model count, and the two
///   primary actions ('Fetch models', 'API key'); edit/remove live in the
///   overflow menu.
/// * The API-key sheet uses the unified [AetherSecretField] (never-echo
///   obscure + reveal toggle) and writes/clears through secure storage only.
/// * Designed empty state when no BYOK providers remain.
/// * Layout holds at 360×640 @2× and caps its reading width on wide screens.
///
/// All pumps are bounded; real async boundaries (secure-storage read-back)
/// run inside `tester.runAsync`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    // MoneyScreen (pushed by 'Manage plan') fetches the usage snapshot —
    // keep it off the real network, mirroring billing_screen_test.
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(
        jsonEncode({
          'tier': 'free',
          'is_paid': false,
          'daily_budget_usd': 45,
          'daily_spent_usd': 0,
          'daily_remaining_usd': 45,
          'budget_window': '24h',
          'remaining_pct': 1,
          'models': const [],
        }),
        200,
      ),
    );
  });

  tearDown(() {
    removeCustomProviderForTest = null;
    fetchProviderModelsForTest = null;
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AppState.resetTestInstance();
  });

  setUpAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDownAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  // -------------------------------------------------------------------------
  // Helpers — bounded pumps only.
  // -------------------------------------------------------------------------

  void setView(WidgetTester tester, {required Size logical, double dpr = 1}) {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = logical * dpr;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpProviders(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
    await tester.pump();
  }

  /// Bounded settle: a fixed number of 50ms frames — covers sheet (≈250ms)
  /// and route (≈300ms) animations without an unbounded pumpAndSettle.
  Future<void> frames(WidgetTester tester, [int count = 10]) async {
    for (var i = 0; i < count; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Secure-storage settle. AppState is constructed in setUp — outside the
  /// test's fake zone — so the credential-write chain only advances on real
  /// event-loop turns, never during fake-zone pumps. A single bounded
  /// runAsync turn flushes it; frames then process the sheet's pop.
  Future<void> settleStorage(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await frames(tester);
  }

  ProviderConfig addCustomProvider({
    String id = 'custom-acme',
    String name = 'Acme Models',
    List<String>? models,
    bool isFree = false,
  }) {
    final provider = ProviderConfig(
      id: id,
      name: name,
      description: 'Test provider',
      baseUrl: 'https://models.acme.test/v1',
      custom: true,
      isFree: isFree,
      models: models,
    );
    app.providers.add(provider);
    return provider;
  }

  void removeAllByok() {
    // Keep only the managed Ovid Cloud row; everything else (seeded
    // built-ins + any custom row) is a BYOK provider by this screen's
    // definition, so dropping them exercises the empty-state branch.
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
  }

  Finder pillWith(String label) => find.byWidgetPredicate(
    (w) => w is AetherPill && w.label == label,
  );

  // -------------------------------------------------------------------------
  // Ovid Cloud managed tile.
  // -------------------------------------------------------------------------

  testWidgets('Ovid Cloud tile renders plan pill and manage action', (
    tester,
  ) async {
    removeAllByok();
    await pumpProviders(tester);

    expect(find.text('Ovid Cloud'), findsOneWidget);
    expect(pillWith('FREE'), findsOneWidget);
    expect(find.text('Manage plan'), findsOneWidget);
  });

  testWidgets('Manage plan opens MoneyScreen', (tester) async {
    setView(tester, logical: const Size(360, 640), dpr: 2);
    removeAllByok();
    await pumpProviders(tester);

    await tester.tap(find.text('Manage plan'));
    await frames(tester);

    expect(find.byType(MoneyScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // -------------------------------------------------------------------------
  // BYOK card — one status pill + model count + actions.
  // -------------------------------------------------------------------------

  testWidgets('BYOK card shows one status pill, model count, and actions', (
    tester,
  ) async {
    removeAllByok();
    final provider = addCustomProvider(models: ['acme-chat', 'acme-reasoner']);
    await pumpProviders(tester);

    final card = find.byKey(ValueKey(provider.id));
    expect(card, findsOneWidget);
    // Exactly one status pill on the card.
    expect(
      find.descendant(of: card, matching: find.byType(AetherPill)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: pillWith('NO KEY')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('2 models')),
      findsOneWidget,
    );
    // Primary actions + overflow.
    expect(find.widgetWithText(TextButton, 'Fetch models'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'API key'), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.byTooltip('More actions')),
      findsOneWidget,
    );
    // Model chips are preserved.
    expect(find.text('acme-chat'), findsOneWidget);
  });

  testWidgets('Status pill reflects connection state', (tester) async {
    removeAllByok();
    final plain = addCustomProvider();
    addCustomProvider(
      id: 'custom-free',
      name: 'Freebie',
      isFree: true,
    );
    await pumpProviders(tester);

    expect(pillWith('NO KEY'), findsOneWidget);
    expect(pillWith('NEEDS KEY'), findsOneWidget);
    expect(pillWith('CONNECTED'), findsNothing);

    // Saving a key flips the pill to CONNECTED.
    plain.apiKey = 'sk-live-abc123';
    app.refresh();
    await tester.pump();

    expect(pillWith('CONNECTED'), findsOneWidget);
    expect(pillWith('NO KEY'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // API key sheet — unified secret field, secure save/clear.
  // -------------------------------------------------------------------------

  testWidgets('API key sheet saves and clears through secure storage', (
    tester,
  ) async {
    removeAllByok();
    final provider = addCustomProvider();
    await pumpProviders(tester);

    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await frames(tester);

    // Unified secret field (AetherSecretField): never-echo — the field stays
    // obscured at all times; the toggle reveals via a non-semantic overlay.
    final field = find.byType(TextField).last;
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(find.byTooltip('Show API key'), findsOneWidget);

    await tester.enterText(field, '  sk-live-abc123\n');
    await tester.tap(find.byTooltip('Show API key'));
    await tester.pump();
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    expect(find.byTooltip('Hide API key'), findsOneWidget);
    expect(find.textContaining('sk-live-abc123'), findsWidgets);
    await tester.tap(find.byTooltip('Hide API key'));
    await tester.pump();
    expect(find.byTooltip('Show API key'), findsOneWidget);

    // Save — pasted whitespace is stripped before it reaches storage.
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await settleStorage(tester);

    expect(provider.apiKey, 'sk-live-abc123');
    expect(provider.hasKey, isTrue);
    final stored = await tester.runAsync(
      () => const FlutterSecureStorage().read(
        key: 'ovid_provider_key_${provider.id}',
      ),
    );
    expect(stored, 'sk-live-abc123');

    // Clear — the stored secret is deleted from secure storage.
    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await frames(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await settleStorage(tester);

    expect(provider.apiKey, isEmpty);
    expect(provider.hasKey, isFalse);
    final cleared = await tester.runAsync(
      () => const FlutterSecureStorage().read(
        key: 'ovid_provider_key_${provider.id}',
      ),
    );
    expect(cleared, isNull);
  });

  // -------------------------------------------------------------------------
  // Fetch models.
  // -------------------------------------------------------------------------

  testWidgets('Fetch models round-trips through the provider seam', (
    tester,
  ) async {
    removeAllByok();
    final provider = addCustomProvider();
    final seen = <String>[];
    fetchProviderModelsForTest = (p) async {
      seen.add(p.id);
      p.models
        ..clear()
        ..addAll(['acme-chat', 'acme-reasoner']);
      return null;
    };
    await pumpProviders(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Fetch models'));
    await frames(tester);

    expect(seen, [provider.id]);
    expect(provider.models, ['acme-chat', 'acme-reasoner']);
    expect(find.text('2 models fetched ✓'), findsOneWidget);
    expect(find.text('acme-chat'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Empty state.
  // -------------------------------------------------------------------------

  testWidgets('Designed empty state renders with add action', (tester) async {
    removeAllByok();
    await pumpProviders(tester);

    expect(find.byType(AetherEmptyState), findsOneWidget);
    expect(find.text('No providers yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add provider'));
    await frames(tester);
    expect(find.text('Add custom provider'), findsOneWidget);
  });

  testWidgets('Empty state disappears once a BYOK provider exists', (
    tester,
  ) async {
    removeAllByok();
    addCustomProvider();
    await pumpProviders(tester);

    expect(find.byType(AetherEmptyState), findsNothing);
    expect(find.text('Acme Models'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Geometry — 360×640 @2× and wide.
  // -------------------------------------------------------------------------

  testWidgets('360x640 @2x renders without overflow', (tester) async {
    setView(tester, logical: const Size(360, 640), dpr: 2);
    removeAllByok();
    addCustomProvider(
      name: 'Research team international inference gateway',
      models: List.generate(8, (i) => 'acme-model-$i'),
    );
    await pumpProviders(tester);
    await frames(tester, 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid Cloud'), findsOneWidget);
    expect(find.text('Research team international inference gateway'),
        findsOneWidget);
    // 8 models → 6 chips + a '+2 more' overflow badge.
    expect(find.text('+2 more'), findsOneWidget);
    expect(
      tester.getSize(find.byType(ListView)).width,
      360,
    );

    // Same geometry at 2× text scale — pills and buttons must wrap, never
    // overflow (regression: status pill once overflowed this slot).
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(2),
          ),
          child: child!,
        ),
        home: const ProvidersScreen(),
      ),
    );
    await frames(tester, 2);
    // The BYOK card sits below the fold at 2× scale; scroll it into the
    // lazy ListView's build range before asserting.
    await tester.scrollUntilVisible(
      pillWith('NO KEY'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await frames(tester, 2);
    expect(tester.takeException(), isNull);
    expect(pillWith('NO KEY'), findsOneWidget);
  });

  testWidgets('Wide layout caps reading width without overflow', (
    tester,
  ) async {
    setView(tester, logical: const Size(1440, 900));
    removeAllByok();
    addCustomProvider(models: ['acme-chat']);
    await pumpProviders(tester);
    await frames(tester, 2);

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid Cloud'), findsOneWidget);
    expect(find.text('Acme Models'), findsOneWidget);
    // Content is centered and capped at 720 logical pixels.
    expect(tester.getSize(find.byType(ListView)).width, 720);
  });
}
