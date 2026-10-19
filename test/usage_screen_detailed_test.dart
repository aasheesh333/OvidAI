// SH-016 / SE-020 / owner ask: the Usage screen is detailed and comes from
// server data — plan, allowance left, localized reset, per-model window
// counters, and the per-day / per-model / per-chat / per-run ledger.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/usage_history.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _usage() => {
  'tier': '7x',
  'plan': 'pro',
  'plan_name': 'Pro',
  'is_paid': true,
  'remaining_fraction': .62,
  'daily_budget_usd': 10.0,
  'window': '24h',
  'resets_at': DateTime.now()
      .toUtc()
      .add(const Duration(hours: 5, minutes: 20))
      .toIso8601String(),
  'today': {
    'requests': 12,
    'input_tokens': 120000,
    'output_tokens': 8000,
    'images': 1,
    'by_model': {
      'gpt-x': {
        'requests': 10,
        'input_tokens': 100000,
        'output_tokens': 6000,
        'images': 0,
      },
    },
  },
  'models': [
    {
      'id': 'gpt-x',
      'name': 'GPT X',
      'kind': 'chat',
      'priced': true,
      'remaining_messages': 140,
      'model': 'gpt-x',
      'input_cost_per_token': 0.000001,
      'output_cost_per_token': 0.000004,
    },
  ],
  'plans': [
    {'tier': 'free', 'id': 'free', 'name': 'Free', 'price_usd': 0, 'mult': 1},
    {'tier': '7x', 'id': 'pro', 'name': 'Pro', 'price_usd': 25, 'mult': 23},
  ],
};

Map<String, dynamic> _history({String? nextBefore}) {
  final today = DateTime.now();
  String d(int ago) {
    final t = today.subtract(Duration(days: ago));
    return '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  Map<String, Object> counts(int runs, int input, int output) => {
    'runs': runs,
    'modelCalls': runs * 2,
    'inputTokens': input,
    'outputTokens': output,
    'cacheReadTokens': 0,
    'cacheWriteTokens': 0,
  };

  return {
    'since': today.subtract(const Duration(days: 6)).toUtc().toIso8601String(),
    'until': today.toUtc().toIso8601String(),
    'utcOffsetMinutes': 0,
    'totals': counts(3, 200000, 9000),
    'days': [
      {'date': d(0), ...counts(2, 150000, 7000)},
      {'date': d(1), ...counts(0, 0, 0)},
      {'date': d(2), ...counts(1, 50000, 2000)},
    ],
    'models': [
      {'model': 'gpt-x', ...counts(3, 200000, 9000)},
    ],
    'sessions': [
      {
        'sessionId': 'srv-1',
        'title': 'Refactor the parser',
        'lastAt': today.toUtc().toIso8601String(),
        ...counts(2, 150000, 7000),
      },
      {'sessionId': 'srv-2', 'title': null, ...counts(1, 50000, 2000)},
    ],
    'runs': [
      {
        'runId': 'run-1',
        'sessionId': 'srv-1',
        'sessionTitle': 'Refactor the parser',
        'status': 'completed',
        'startedAt': today.toUtc().toIso8601String(),
        'finishedAt': today.toUtc().add(const Duration(seconds: 95)).toIso8601String(),
        'models': ['gpt-x'],
        ...counts(1, 100000, 5000),
      },
    ],
    'nextBefore': nextBefore,
  };
}

void main() {
  late List<Uri> historyCalls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    OvidPlanCatalog.resetForTest();
    OvidCloudService.idTokenOverrideForTest = () async => 't';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(jsonEncode(_usage()), 200),
    );
    historyCalls = [];
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    OvidPlanCatalog.resetForTest();
    AppState.resetTestInstance();
  });

  UsageHistoryStore historyStore({int status = 200, String? nextBefore}) =>
      UsageHistoryStore(
        utcOffsetMinutes: () => 330,
        rest: CloudRestClient(
          headers: CloudHeaders.forTest(),
          restBase: 'https://cloud.test/cloud/v1',
          httpClient: MockClient((request) async {
            historyCalls.add(request.url);
            if (status != 200) {
              return http.Response(
                '{"error":{"code":"not_found","message":"x"}}',
                status,
              );
            }
            return http.Response(
              jsonEncode(_history(
                nextBefore: request.url.queryParameters['before'] == null
                    ? nextBefore
                    : null,
              )),
              200,
            );
          }),
        ),
      );

  Future<void> pump(
    WidgetTester tester,
    UsageHistoryStore store, {
    Size size = const Size(500, 4200),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: UsageScreen(history: store)));
    await tester.pumpAndSettle();
  }

  testWidgets('plan, allowance, localized reset and per-model window', (
    tester,
  ) async {
    await pump(tester, historyStore());
    expect(find.text('Pro plan'), findsOneWidget);
    expect(find.text('×23'), findsOneWidget, reason: 'not the raw "7X" tier');
    expect(find.text('62% remaining'), findsOneWidget);
    final reset = tester.widget<Text>(find.byKey(const ValueKey('usage-reset')));
    expect(reset.data, startsWith('Resets in 5 h'));
    expect(reset.data, isNot(contains('.000')));
    expect(find.byKey(const ValueKey('usage-window-model-gpt-x')), findsOneWidget);
    // 100k in × $1e-6 + 6k out × $4e-6 = $0.124 of a $10 budget ≈ 1.2%.
    expect(find.text('≈ 1.2% of allowance'), findsWidgets);
    expect(find.textContaining('140 messages'), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-change-plan')), findsOneWidget);
    // Usage is never shown in money.
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('history: per day, per model, per chat and per run', (
    tester,
  ) async {
    await pump(tester, historyStore(nextBefore: 'cursor-1'));
    expect(historyCalls.first.path, '/cloud/v1/usage/history');
    expect(historyCalls.first.queryParameters['days'], '30');
    expect(historyCalls.first.queryParameters['utcOffsetMinutes'], '330');
    expect(find.byKey(const ValueKey('usage-history-totals')), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-history-daily')), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-history-models')), findsOneWidget);
    expect(find.text('Refactor the parser'), findsWidgets);
    expect(find.text('Deleted chat'), findsOneWidget);
    final run = find.byKey(const ValueKey('usage-run-run-1'));
    expect(run, findsOneWidget);
    expect(
      find.descendant(of: run, matching: find.textContaining('1m 35s')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('usage-runs-more')));
    await tester.pumpAndSettle();
    expect(historyCalls.last.queryParameters['before'], 'cursor-1');
    expect(find.byKey(const ValueKey('usage-runs-more')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('usage-range-7')));
    await tester.pumpAndSettle();
    expect(historyCalls.last.queryParameters['days'], '7');
    expect(find.text('Last 7 days'), findsOneWidget);
  });

  testWidgets('an older gateway without the endpoint is explained', (
    tester,
  ) async {
    await pump(tester, historyStore(status: 404));
    expect(
      find.byKey(const ValueKey('usage-history-unsupported')),
      findsOneWidget,
    );
  });

  testWidgets('pull to refresh reloads both sources', (tester) async {
    await pump(tester, historyStore(), size: const Size(400, 800));
    final before = historyCalls.length;
    await tester.fling(
      find.byKey(const ValueKey('usage-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(historyCalls.length, greaterThan(before));
  });

  test('allowance share is null without a model price', () {
    final usage = OvidUsage.fromJson(_usage());
    expect(allowanceShare(usage, 'auto', 1000, 1000), isNull);
    expect(allowanceShare(usage, 'gpt-x', 100000, 6000), closeTo(0.0124, 1e-9));
  });
}
