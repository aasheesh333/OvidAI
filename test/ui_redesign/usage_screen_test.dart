import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium `usage_screen` redesign contract (wave 2 UI).
///
/// These tests pin the *public* surface the redesign owes callers:
/// [AetherEmptyState] when the local log has no measurable rows, per-provider
/// [AetherCard]s with request/token counts, the plan pill derived from the
/// existing tier/paid state, the inline per-model toggle, and the hard rule
/// that the Ovid Cloud provider is never rendered as a device-side card (its
/// usage is server-authoritative, shown in the hero header).

UsageEntry _entry({
  required String providerId,
  required String providerName,
  String model = 'model',
  int prompt = 20,
  int completion = 10,
}) => UsageEntry(
  time: DateTime.now(),
  providerId: providerId,
  providerName: providerName,
  model: model,
  promptTokens: prompt,
  completionTokens: completion,
  totalTokens: prompt + completion,
  duration: const Duration(seconds: 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    // Server usage fetch fails so the hero header falls back to the local
    // AppState tier rather than a fabricated server snapshot.
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response('down', 503));
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
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

  testWidgets('renders empty state when usageLog is empty', (tester) async {
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
      AppState.I.usageLog.addAll([
        _entry(
          providerId: AppState.ovidCloudProviderId,
          providerName: 'Ovid Cloud',
          prompt: 900000,
          completion: 100000,
        ),
        _entry(
          providerId: 'custom-acme',
          providerName: 'Acme Models with a long provider name',
          model: 'custom-model-with-a-long-name',
        ),
      ]);

      await pumpUsage(tester, width: width, textScale: 1.3);

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
      expect(find.text('Ovid Cloud'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('20 in · 10 out'), findsOneWidget);
      expect(find.text('1 requests · 20 in · 10 out'), findsOneWidget);

      final toggle = find.text('Show 1 model').hitTestable();
      await tester.scrollUntilVisible(toggle, 150);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('custom-model-with-a-long-name'), findsOneWidget);
      expect(find.text('1 req · 30 tok'), findsOneWidget);

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
    AppState.I.usageLog.add(
      _entry(
        providerId: 'custom-acme',
        providerName: 'Acme Models',
        model: 'gpt-4o',
      ),
    );
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
    AppState.I.usageLog.add(
      _entry(
        providerId: 'custom-acme',
        providerName: 'Acme Models',
        model: 'gpt-4o',
        prompt: 20,
        completion: 10,
      ),
    );
    await pumpUsage(tester);

    // Collapsed: per-model name hidden, toggle offered.
    expect(find.text('gpt-4o'), findsNothing);
    expect(find.text('Show 1 model'), findsOneWidget);

    await tester.tap(find.text('Show 1 model'));
    await tester.pumpAndSettle();

    // Expanded: model name + per-model request/token caption visible.
    expect(find.text('gpt-4o'), findsOneWidget);
    expect(find.text('1 req · 30 tok'), findsOneWidget);
    expect(find.text('Hide models'), findsOneWidget);
  });

  testWidgets('excludes ovidCloudProviderId from per-provider cards', (
    tester,
  ) async {
    // A huge cloud entry would dominate the totals if it leaked into the
    // device-side aggregation. A custom BYOK entry rides alongside it.
    AppState.I.usageLog
      ..add(
        _entry(
          providerId: AppState.ovidCloudProviderId,
          providerName: 'Ovid Cloud',
          model: 'auto',
          prompt: 900000,
          completion: 100000,
        ),
      )
      ..add(
        _entry(
          providerId: 'custom-acme',
          providerName: 'Acme Models',
          model: 'gpt-4o',
        ),
      );
    await pumpUsage(tester);

    // "Ovid Cloud" appears exactly once — in the hero plan header, never as
    // a per-provider card.
    expect(find.text('Ovid Cloud'), findsOneWidget);

    // Only the custom provider's single row is counted, proving the cloud
    // entry was excluded from [_aggregate].
    expect(find.text('Acme Models'), findsOneWidget);
    expect(find.text('1 requests · 20 in · 10 out'), findsOneWidget);
    expect(find.text('2 requests · 900020 in · 100010 out'), findsNothing);
  });
}
