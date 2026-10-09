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

int _entrySequence = 0;

UsageAttempt _entry({
  required String providerId,
  required String providerName,
  DateTime? time,
  int input = 20,
  int output = 10,
}) {
  final id = 'premium-entry-${_entrySequence++}';
  final startedAt = (time ?? DateTime.now()).toUtc();
  return UsageAttempt(
    attemptId: id,
    requestId: 'request-$id',
    revision: 1,
    sourceDevice: 'test-device',
    provider: providerId,
    requestedModel: 'premium-test-model',
    reportedModel: 'premium-test-model',
    purpose: 'chat',
    startedAt: startedAt,
    completedAt: startedAt,
    elapsed: const Duration(seconds: 1),
    dispatchStage: UsageDispatchStage.completed,
    outcome: UsageOutcome.succeeded,
    inputTokens: UsageTokenCount.reported(input),
    outputTokens: UsageTokenCount.reported(output),
    totalTokens: UsageTokenCount.reported(input + output),
  );
}

void main() {
  late Directory usageRoot;
  setUp(() async {
    _entrySequence = 0;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    usageRoot = await Directory.systemTemp.createTemp('usage-premium-');
    AppState.resetTestInstance();
    AppState.createForTest(usageRoot: usageRoot);
    await AppState.I.prepareUsageAttempts(
      owner: AppState.I.sessionAccountToken,
    );
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'premium-test';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
        (_) async => http.Response(
        jsonEncode({
          'tier': 'free',
          'is_paid': false,
          'remaining_pct': 0.5,
          'models': [],
        }),
        200,
        ),
      );
  });

  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    await usageRoot.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pumpAndSettle();
  }

  Future<void> record(WidgetTester tester, UsageAttempt entry) async {
    await tester.runAsync(() => AppState.I.recordUsageAttempt(entry));
  }

  testWidgets('labels local totals as all-time and today scopes', (
    tester,
  ) async {
    await record(tester,
      _entry(providerId: 'custom', providerName: 'Custom provider'),
    );

    await pumpScreen(tester, const UsageScreen());

    expect(find.text('Retained observed history'), findsOneWidget);
    expect(find.text('Today · provider-reported tokens'), findsOneWidget);
    expect(find.text('Input · output · provider-reported usage'), findsOneWidget);
  });

  testWidgets('provider card exposes a visible details action', (tester) async {
    await record(tester,
      _entry(providerId: 'custom', providerName: 'Custom provider'),
    );

    await pumpScreen(tester, const UsageScreen());

    expect(find.byTooltip('View provider details'), findsOneWidget);
  });

  testWidgets('last fourteen day chart exposes date and value points', (
    tester,
  ) async {
    final now = DateTime.now();
    for (final entry in [
      _entry(
        providerId: 'custom',
        providerName: 'Custom provider',
        time: now.subtract(const Duration(days: 2)),
      ),
      _entry(
        providerId: 'custom',
        providerName: 'Custom provider',
        time: now,
        input: 40,
        output: 20,
      ),
    ]) {
      await record(tester, entry);
    }

    await pumpScreen(
      tester,
      ProviderUsageScreen(
        provider: ProviderUsage(
          providerId: 'custom',
          providerName: 'Custom provider',
          tier: 'BYOK',
          icon: Icons.cloud,
          color: Colors.blue,
          requests: 2,
          tokensIn: 60,
          tokensOut: 30,
          models: const [],
        ),
      ),
    );

    expect(
      find.textContaining('Last 14 days · Provider-reported measured tokens'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'\d{4}-\d{2}-\d{2}: 30 tokens')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'\d{4}-\d{2}-\d{2}: 60 tokens')),
      findsOneWidget,
    );
  });
}
