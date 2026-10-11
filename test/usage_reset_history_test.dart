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
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/usage_attempt_store.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _usage({
  double remaining = .5,
  String tier = 'free',
  String? resetsAt,
  int requests = 7,
}) => {
  'tier': tier,
  'is_paid': tier != 'free',
  'remaining_pct': remaining,
  'requests_today': requests,
  'budget_window': '24h',
  'resets_at': ?resetsAt,
  'models': const [],
};

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late Map<String, dynamic> usage;
  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('usage-reset-');
    AppState.resetTestInstance();
    AppState.createForTest(usageRoot: root);
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'usage-token';
    usage = _usage();
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response('{"data":[]}', 200);
          }
          return http.Response(jsonEncode(usage), 200);
        });
  });

  tearDown(() async {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const UsageScreen()),
    );
    await _frames(tester);
  }

  test('reset countdown formatting', () {
    final now = DateTime.utc(2026, 10, 11, 8);
    expect(formatResetCountdown(null, now: now), isNull);
    expect(
      formatResetCountdown(
        now.add(const Duration(hours: 4, minutes: 12)),
        now: now,
      ),
      'Resets in 4h 12m',
    );
    expect(
      formatResetCountdown(now.add(const Duration(minutes: 9)), now: now),
      'Resets in 9m',
    );
    expect(
      formatResetCountdown(
        now.add(const Duration(days: 3, hours: 5)),
        now: now,
      ),
      'Resets in 3d 5h',
    );
    expect(formatResetCountdown(now, now: now), 'Resets in under a minute');
  });

  testWidgets('hero shows the server reset time and requests today', (
    tester,
  ) async {
    usage = _usage(
      resetsAt: DateTime.now()
          .toUtc()
          .add(const Duration(hours: 4, minutes: 12, seconds: 30))
          .toIso8601String(),
    );
    await mount(tester);
    expect(find.text('Resets in 4h 12m'), findsOneWidget);
    expect(find.text('7 requests today'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-upgrade')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('no reset claim without a server reset time', (tester) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('usage-reset')), findsNothing);
    expect(find.textContaining('Resets'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('low allowance offers an upgrade that opens Plans', (
    tester,
  ) async {
    usage = _usage(remaining: .05);
    await mount(tester);
    final upgrade = find.byKey(const ValueKey('usage-upgrade'));
    expect(upgrade, findsOneWidget);
    expect(find.text('Running low · Upgrade'), findsOneWidget);
    await tester.tap(upgrade);
    await _frames(tester);
    expect(find.text('Plans & Billing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('top plan never shows an upgrade CTA', (tester) async {
    usage = _usage(remaining: 0, tier: '15x');
    await mount(tester);
    expect(find.byKey(const ValueKey('usage-upgrade')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('truncated history renders the retention notice', (tester) async {
    await tester.runAsync(() async {
      await AppState.I.prepareUsageAttempts(
        owner: AppState.I.sessionAccountToken,
      );
      final account = root.listSync().whereType<Directory>().single;
      AppState.resetTestInstance();
      await File(
        '${account.path}/${UsageAttemptStore.journalFileName}',
      ).writeAsString(
        jsonEncode({
          'schemaVersion': UsageAttemptStore.schemaVersion,
          'revision': 1,
          'historyTruncated': true,
          'attempts': const [],
        }),
      );
      AppState.createForTest(usageRoot: root);
      await AppState.I.prepareUsageAttempts(
        owner: AppState.I.sessionAccountToken,
      );
    });
    expect(AppState.I.usageHistoryTruncated, isTrue);
    await mount(tester);
    expect(
      find.byKey(const ValueKey('usage-history-truncated')),
      findsOneWidget,
    );
    expect(find.text(usageHistoryLimitNotice), findsOneWidget);
    expect(usageHistoryLimitNotice, contains('500 requests'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('storage errors show a banner instead of "No usage yet"', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final blocked = File('${root.path}/blocked');
      await blocked.writeAsString('not a directory');
      AppState.resetTestInstance();
      AppState.createForTest(usageRoot: Directory(blocked.path));
      try {
        await AppState.I.prepareUsageAttempts(
          owner: AppState.I.sessionAccountToken,
        );
      } catch (_) {}
    });
    expect(AppState.I.usageStorageError, isNotNull);
    await mount(tester);
    expect(find.byKey(const ValueKey('usage-storage-error')), findsOneWidget);
    expect(find.text('Usage history unavailable'), findsOneWidget);
    expect(find.text('No usage yet'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
