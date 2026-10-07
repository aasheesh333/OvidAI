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

UsageEntry _entry({
  required String providerId,
  required String providerName,
  DateTime? time,
  int input = 20,
  int output = 10,
}) => UsageEntry(
  time: time ?? DateTime.now(),
  providerId: providerId,
  providerName: providerName,
  model: 'premium-test-model',
  promptTokens: input,
  completionTokens: output,
  totalTokens: input + output,
  duration: const Duration(seconds: 1),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
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

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pumpAndSettle();
  }

  testWidgets('labels local totals as all-time and today scopes', (
    tester,
  ) async {
    AppState.I.usageLog.add(
      _entry(providerId: 'custom', providerName: 'Custom provider'),
    );

    await pumpScreen(tester, const UsageScreen());

    expect(find.text('All-time measured usage'), findsOneWidget);
    expect(find.text('Today · measured tokens'), findsOneWidget);
    expect(find.text('Input · output · all recorded usage'), findsOneWidget);
  });

  testWidgets('provider card exposes a visible details action', (tester) async {
    AppState.I.usageLog.add(
      _entry(providerId: 'custom', providerName: 'Custom provider'),
    );

    await pumpScreen(tester, const UsageScreen());

    expect(find.byTooltip('View provider details'), findsOneWidget);
  });

  testWidgets('last fourteen day chart exposes date and value points', (
    tester,
  ) async {
    final now = DateTime.now();
    AppState.I.usageLog.addAll([
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
    ]);

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
      find.textContaining('Last 14 days · measured tokens'),
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
