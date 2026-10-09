import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium `usage_screen` redesign contract (wave 2 UI).
///
/// These tests pin the *public* surface the redesign owes callers:
/// [AetherEmptyState] when the attempt journal has no rows, per-provider
/// [AetherCard]s with request/token counts aggregated from provider-reported
/// attempts, the plan pill derived from the existing tier/paid state, the
/// inline per-model toggle, and the rule that Ovid Cloud attempts render on
/// their own observed-history card — never leaking into a BYOK provider's
/// counts or the server-authoritative allowance hero.

int _attemptSequence = 0;

/// A completed attempt whose token counts are provider-reported, i.e. the
/// only provenance that contributes to measured totals on the usage screen.
UsageAttempt _attempt({
  required String providerId,
  String model = 'model',
  int prompt = 20,
  int completion = 10,
}) {
  final id = 'usage-screen-${_attemptSequence++}';
  final startedAt = DateTime.now().toUtc();
  return UsageAttempt(
    attemptId: id,
    requestId: 'request-$id',
    revision: 1,
    sourceDevice: 'test-device',
    provider: providerId,
    requestedModel: model,
    reportedModel: model,
    purpose: 'chat',
    startedAt: startedAt,
    completedAt: startedAt,
    elapsed: const Duration(seconds: 1),
    dispatchStage: UsageDispatchStage.completed,
    outcome: UsageOutcome.succeeded,
    inputTokens: UsageTokenCount.reported(prompt),
    outputTokens: UsageTokenCount.reported(completion),
    totalTokens: UsageTokenCount.reported(prompt + completion),
  );
}

/// The screen resolves display names through [AppState.providerById].
void _addAcme(String name) {
  AppState.I.providers.add(
    ProviderConfig(
      id: 'custom-acme',
      name: name,
      description: '',
      baseUrl: 'https://acme.invalid/v1',
      models: const ['model'],
      requiresApiKey: true,
    ),
  );
}

Future<void> _record(WidgetTester tester, List<UsageAttempt> attempts) async {
  // The durable journal does real filesystem I/O, outside the fake clock.
  await tester.runAsync(() async {
    for (final attempt in attempts) {
      expect(
        await AppState.I.recordUsageAttempt(
          attempt,
          owner: AppState.I.sessionAccountToken,
        ),
        isTrue,
      );
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory usageRoot;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    usageRoot = await Directory.systemTemp.createTemp('usage-screen-test-');
    AppState.createForTest(usageRoot: usageRoot);
    await AppState.I.prepareUsageAttempts(
      owner: AppState.I.sessionAccountToken,
    );
    _attemptSequence = 0;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    // Server usage fetch fails so the hero header falls back to the local
    // AppState tier rather than a fabricated server snapshot.
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response('down', 503));
  });

  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  Future<void> pumpUsage(
    WidgetTester tester, {
    double width = 420,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const UsageScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders empty state when the attempt journal is empty', (tester) async {
    await pumpUsage(tester);

    expect(find.text('No usage yet'), findsOneWidget);
    expect(
      find.text('Start a chat to see per-provider usage here.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.query_stats), findsOneWidget);
  });

  for (final width in [320.0, 360.0, 390.0, 411.0]) {
    testWidgets('server usage and model toggle fit ${width}dp at 1.3x', (
      tester,
    ) async {
      AppState.I.setOvidCloudTier('free');
      OvidCloudService.httpClientFactoryForTest = () => MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tier': '15x',
            'is_paid': true,
            'daily_budget_usd': 45,
            'daily_spent_usd': 1,
            'daily_remaining_usd': 44,
            'budget_window': '30d',
            'remaining_pct': 0.37,
            'models': [
              {
                'model': 'ovid-pro-1',
                'output_cost_per_token': 0.000075,
                'remaining_pct': 0.23,
              },
            ],
          }),
          200,
        ),
      );
      _addAcme('Acme Models with a long provider name');
      await _record(tester, [
        _attempt(
          providerId: AppState.ovidCloudProviderId,
          prompt: 900000,
          completion: 100000,
        ),
        _attempt(
          providerId: 'custom-acme',
          model: 'custom-model-with-a-long-name',
        ),
      ]);

      await pumpUsage(tester, width: width, textScale: 1.3);

      // Hero: server-authoritative allowance and plan pill.
      expect(find.text('MAX'), findsOneWidget);
      expect(find.text('37% remaining'), findsOneWidget);
      expect(find.text('23% remaining'), findsOneWidget);
      expect(
        tester
            .widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .map((bar) => bar.value),
        [0.37, 0.23],
      );
      // Retained totals include every provider-reported attempt.
      expect(find.text('1M'), findsOneWidget);
      expect(find.text('900K in · 100K out'), findsOneWidget);

      // The observed CLOUD history card is its own card, below the fold at
      // this scale, so bring the lazy list child into view before asserting.
      final cloudCard = find.byKey(const ValueKey(AppState.ovidCloudProviderId));
      await tester.scrollUntilVisible(cloudCard, 150);
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: cloudCard, matching: find.text('Ovid Cloud')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: cloudCard,
          matching: find.text('1 requests · 900K in · 100K out'),
        ),
        findsOneWidget,
      );

      // The BYOK card counts only its own single attempt.
      final acmeCard = find.byKey(const ValueKey('custom-acme'));
      expect(
        find.descendant(
          of: acmeCard,
          matching: find.text('1 requests · 20 in · 10 out'),
        ),
        findsOneWidget,
      );

      final toggle = find
          .descendant(of: acmeCard, matching: find.text('Show 1 model'))
          .hitTestable();
      await tester.scrollUntilVisible(toggle, 150);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('custom-model-with-a-long-name'), findsOneWidget);
      expect(find.text('1 req · 30 provider-reported tok'), findsOneWidget);

      final renderedText = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data ?? '')
          .join(' ');
      expect(
        renderedText,
        isNot(matches(RegExp(r'\$|USD', caseSensitive: false))),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('renders a provider card with request and token counts', (
    tester,
  ) async {
    _addAcme('Acme Models');
    await _record(tester, [
      _attempt(providerId: 'custom-acme', model: 'gpt-4o'),
    ]);
    await pumpUsage(tester);

    // Not the empty state.
    expect(find.text('No usage yet'), findsNothing);

    // Provider name + tier pill.
    expect(find.text('Acme Models'), findsOneWidget);
    expect(find.text('BYOK'), findsOneWidget);

    // Counts row: reqs | in | out.
    expect(find.text('1 requests · 20 in · 10 out'), findsOneWidget);
  });

  testWidgets('renders FREE pill when the plan is not paid', (tester) async {
    AppState.I.setOvidCloudTier('free');
    await pumpUsage(tester);

    expect(AppState.I.ovidCloudIsPaid, isFalse);
    expect(find.text('FREE'), findsOneWidget);
  });

  testWidgets('renders PLUS pill when tier is plus and paid', (tester) async {
    AppState.I.setOvidCloudTier('3x');
    await pumpUsage(tester);

    expect(AppState.I.ovidCloudIsPaid, isTrue);
    expect(find.text('PLUS'), findsOneWidget);
    expect(find.text('FREE'), findsNothing);
  });

  testWidgets('expands the inline model list on toggle', (tester) async {
    _addAcme('Acme Models');
    await _record(tester, [
      _attempt(providerId: 'custom-acme', model: 'gpt-4o'),
    ]);
    await pumpUsage(tester);

    // Collapsed: per-model name hidden, toggle offered.
    expect(find.text('gpt-4o'), findsNothing);
    expect(find.text('Show 1 model'), findsOneWidget);

    await tester.tap(find.text('Show 1 model'));
    await tester.pumpAndSettle();

    // Expanded: model name + per-model request/token caption visible.
    expect(find.text('gpt-4o'), findsOneWidget);
    expect(find.text('1 req · 30 provider-reported tok'), findsOneWidget);
    expect(find.text('Hide models'), findsOneWidget);
  });

  testWidgets('keeps ovid cloud attempts on their own card, apart from BYOK', (
    tester,
  ) async {
    // A huge cloud attempt must never leak into a BYOK provider's card or
    // into the server-authoritative allowance header.
    _addAcme('Acme Models');
    await _record(tester, [
      _attempt(
        providerId: AppState.ovidCloudProviderId,
        model: 'auto',
        prompt: 900000,
        completion: 100000,
      ),
      _attempt(providerId: 'custom-acme', model: 'gpt-4o'),
    ]);
    await pumpUsage(tester);

    // Hero plan header + one observed-history CLOUD card, nothing more.
    expect(find.text('Ovid Cloud'), findsNWidgets(2));
    expect(find.text('Server-authoritative'), findsOneWidget);
    final cloudCard = find.byKey(const ValueKey(AppState.ovidCloudProviderId));
    expect(
      find.descendant(of: cloudCard, matching: find.text('CLOUD')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cloudCard,
        matching: find.text('1 requests · 900K in · 100K out'),
      ),
      findsOneWidget,
    );

    // The BYOK card counts only its own single attempt.
    final acmeCard = find.byKey(const ValueKey('custom-acme'));
    expect(
      find.descendant(of: acmeCard, matching: find.text('Acme Models')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: acmeCard,
        matching: find.text('1 requests · 20 in · 10 out'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('2 requests'), findsNothing);
  });
}
