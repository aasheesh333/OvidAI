import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

UsageAttempt _attempt({
  required String id,
  required String provider,
  required UsageTokenCount input,
  UsageTokenCount? output,
  UsageTokenCount? total,
  String requestedModel = 'auto',
  String? reportedModel,
  DateTime? startedAt,
}) {
  return UsageAttempt(
    attemptId: id,
    requestId: 'request-$id',
    revision: 1,
    sourceDevice: 'device-1',
    provider: provider,
    requestedModel: requestedModel,
    reportedModel: reportedModel,
    purpose: 'chat',
    startedAt: startedAt ?? DateTime.utc(2026, 10, 8),
    dispatchStage: UsageDispatchStage.completed,
    outcome: UsageOutcome.succeeded,
    inputTokens: input,
    outputTokens: output,
    totalTokens: total,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory usageRoot;
  late List<MockClient> usageClients;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    usageRoot = await Directory.systemTemp.createTemp('usage-presentation-');
    usageClients = <MockClient>[];
    AppState.resetTestInstance();
    AppState.createForTest(usageRoot: usageRoot);
    await AppState.I.prepareUsageAttempts(
      owner: AppState.I.sessionAccountToken,
    );
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-token';
    OvidCloudService.httpClientFactoryForTest = () {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({'tier': 'free', 'remaining_pct': 0.73, 'models': []}),
          200,
        ),
      );
      usageClients.add(client);
      return client;
    };
  });

  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  Future<void> pumpUsage(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: UsageScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      for (final client in usageClients) {
        client.close();
      }
    });
  }

  testWidgets('unknown token usage is not presented as measured zero', (
    tester,
  ) async {
    final app = AppState.I;
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'unknown',
          provider: 'custom',
          input: UsageTokenCount.unknown(),
          output: UsageTokenCount.unknown(),
          total: UsageTokenCount.unknown(),
        ),
        owner: app.sessionAccountToken,
      ),
    );

    await pumpUsage(tester);

    expect(find.textContaining('Unknown'), findsWidgets);
    expect(find.textContaining('0 in'), findsNothing);
    expect(find.textContaining('0 out'), findsNothing);
  });

  testWidgets('known input remains visible when output is unknown', (
    tester,
  ) async {
    final app = AppState.I;
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'partial',
          provider: 'custom',
          input: UsageTokenCount.reported(100),
          output: UsageTokenCount.unknown(),
          total: UsageTokenCount.unknown(),
        ),
        owner: app.sessionAccountToken,
      ),
    );

    await pumpUsage(tester);

    expect(find.textContaining('100 in'), findsWidgets);
    expect(find.textContaining('Unavailable out'), findsWidgets);
    expect(find.textContaining('Unknown in'), findsNothing);
    expect(find.text('Unavailable'), findsWidgets);
  });

  testWidgets('estimated and legacy attempts are labeled in retained history', (
    tester,
  ) async {
    final app = AppState.I;
    final owner = app.sessionAccountToken;
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'estimated',
          provider: 'free-provider',
          input: UsageTokenCount.estimated(12),
          output: UsageTokenCount.estimated(3),
          total: UsageTokenCount.estimated(15),
          requestedModel: 'fast-auto',
        ),
        owner: owner,
      ),
    );
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'legacy',
          provider: 'custom',
          input: UsageTokenCount.legacy(20),
          output: UsageTokenCount.legacy(4),
          total: UsageTokenCount.legacy(24),
          requestedModel: 'old-model',
        ),
        owner: owner,
      ),
    );

    await pumpUsage(tester);

    await tester.scrollUntilVisible(find.text('free-provider'), 500);
    expect(find.textContaining('Estimated'), findsWidgets);
    await tester.scrollUntilVisible(find.text('custom'), 500);
    expect(find.textContaining('Legacy'), findsWidgets);
    expect(find.textContaining('retained'), findsWidgets);
    expect(find.textContaining('All-time measured'), findsNothing);
    expect(
      find.textContaining('Estimated/legacy · Estimated 15'),
      findsWidgets,
    );
    expect(find.textContaining('Estimated/legacy · Legacy 24'), findsWidgets);
  });

  testWidgets(
    'cloud attempts are observed history and do not change allowance',
    (tester) async {
      final app = AppState.I;
      await tester.runAsync(
        () => app.recordUsageAttempt(
          _attempt(
            id: 'cloud',
            provider: AppState.ovidCloudProviderId,
            input: UsageTokenCount.reported(10),
            output: UsageTokenCount.reported(5),
            total: UsageTokenCount.reported(15),
            requestedModel: 'auto',
            reportedModel: 'ovid-pro-1',
          ),
          owner: app.sessionAccountToken,
        ),
      );

      await pumpUsage(tester);

      expect(find.text('73% remaining'), findsWidgets);
      expect(
        find.text('Observed attempts · retained device history.'),
        findsOneWidget,
      );
      expect(find.textContaining('Ovid Cloud'), findsWidgets);
      expect(find.textContaining('Server-authoritative'), findsOneWidget);
    },
  );

  testWidgets('unresolved aliases stay distinct from reported model names', (
    tester,
  ) async {
    final app = AppState.I;
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'alias',
          provider: 'custom',
          input: UsageTokenCount.reported(2),
          output: UsageTokenCount.reported(1),
          total: UsageTokenCount.reported(3),
          requestedModel: 'auto',
        ),
        owner: app.sessionAccountToken,
      ),
    );

    await pumpUsage(tester);

    await tester.scrollUntilVisible(find.text('custom'), 500);
    await tester.tap(find.text('Show 1 model'));
    await tester.pump();
    expect(find.textContaining('Requested: auto'), findsWidgets);
    expect(find.textContaining('reported model unavailable'), findsWidgets);
  });

  testWidgets(
    'provider details chart retained attempts once, including legacy provenance',
    (tester) async {
      final app = AppState.I;
      final owner = app.sessionAccountToken;
      await tester.runAsync(
        () => app.recordUsageAttempt(
          _attempt(
            id: 'legacy-chart',
            provider: 'custom',
            input: UsageTokenCount.legacy(20),
            output: UsageTokenCount.legacy(4),
            total: UsageTokenCount.legacy(24),
            requestedModel: 'old-model',
            startedAt: DateTime.now().subtract(const Duration(days: 1)).toUtc(),
          ),
          owner: owner,
        ),
      );
      await tester.runAsync(
        () => app.recordUsageAttempt(
          _attempt(
            id: 'reported-chart',
            provider: 'custom',
            input: UsageTokenCount.reported(5),
            output: UsageTokenCount.reported(1),
            total: UsageTokenCount.reported(6),
            requestedModel: 'new-model',
          ),
          owner: owner,
        ),
      );
      await tester.runAsync(
        () => app.recordUsageAttempt(
          _attempt(
            id: 'reported-chart-2',
            provider: 'custom',
            input: UsageTokenCount.reported(7),
            output: UsageTokenCount.reported(2),
            total: UsageTokenCount.reported(9),
            requestedModel: 'new-model',
            startedAt: DateTime.now().subtract(const Duration(days: 2)).toUtc(),
          ),
          owner: owner,
        ),
      );
      app.usageLog.add(
        UsageEntry(
          time: DateTime.now().toUtc(),
          providerId: 'custom',
          providerName: 'Custom',
          model: 'old-model',
          promptTokens: 20,
          completionTokens: 4,
          totalTokens: 24,
          duration: Duration.zero,
        ),
      );

      await pumpUsage(tester);
      await tester.scrollUntilVisible(find.text('custom'), 500);
      await tester.tap(find.text('custom'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('usage-activity-chart')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'6 tokens')), findsOneWidget);
      expect(
        find.textContaining('Provider-reported measured tokens'),
        findsWidgets,
      );
      expect(
        find.textContaining('Legacy totals excluded from measured chart'),
        findsWidgets,
      );
    },
  );

  testWidgets('unknown totals are unavailable and do not create a chart', (
    tester,
  ) async {
    final app = AppState.I;
    await tester.runAsync(
      () => app.recordUsageAttempt(
        _attempt(
          id: 'unknown-total',
          provider: 'custom',
          input: UsageTokenCount.reported(100),
          output: UsageTokenCount.reported(20),
          total: UsageTokenCount.unknown(),
        ),
        owner: app.sessionAccountToken,
      ),
    );

    await pumpUsage(tester);
    await tester.scrollUntilVisible(find.text('custom'), 500);
    await tester.tap(find.text('custom'));
    await tester.pumpAndSettle();

    expect(find.text('Unavailable'), findsWidgets);
    expect(find.byKey(const ValueKey('usage-activity-chart')), findsNothing);
    expect(
      find.textContaining('Provider-reported totals unavailable'),
      findsWidgets,
    );
  });
}
