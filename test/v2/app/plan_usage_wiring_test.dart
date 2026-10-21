import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_routes.dart';
import 'package:ovid_ai/ui/v2/settings/plan_billing_page.dart';
import 'package:ovid_ai/ui/v2/settings/usage_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The two live sources the Usage screen reads:
/// * `POST /usage` (OvidCloudService) — tier, today's counters, reset instant;
/// * `GET /usage/history` (CloudRestClient) — daily ledger, 30-day totals,
///   per-model split.
String _usageJson({String tier = 'free'}) {
  final resetsAt = DateTime.now()
      .toUtc()
      .add(const Duration(hours: 6, minutes: 12))
      .toIso8601String();
  return jsonEncode({
    'tier': tier,
    'is_paid': tier != 'free',
    'remaining_pct': 0.5,
    'window': '24h',
    'resets_at': resetsAt,
    'requests_today': 7,
    'today': {
      'requests': 7,
      'input_tokens': 1000000,
      'output_tokens': 500000,
      'images': 3,
      'by_model': {
        'auto': {'input_tokens': 800000, 'output_tokens': 200000},
        'gpt-x': {'input_tokens': 200000, 'output_tokens': 300000},
      },
    },
    'models': [
      {
        'id': 'auto',
        'name': 'Auto',
        'kind': 'chat',
        'priced': true,
        'remaining_messages': 40,
      },
      {
        'id': 'gpt-x',
        'name': 'GPT X',
        'kind': 'chat',
        'priced': true,
        'remaining_messages': 10,
      },
    ],
    'plans': const <Object>[],
  });
}

String _historyJson() {
  final now = DateTime.now();
  String day(int ago) {
    final d = now.subtract(Duration(days: ago));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  return jsonEncode({
    'since': now.subtract(const Duration(days: 30)).toUtc().toIso8601String(),
    'until': now.toUtc().toIso8601String(),
    'totals': {
      'runs': 9,
      'modelCalls': 21,
      'inputTokens': 2000000,
      'outputTokens': 1000000,
    },
    'days': [
      for (var ago = 6; ago >= 0; ago--)
        {
          'date': day(ago),
          'runs': 1,
          'inputTokens': (7 - ago) * 100000,
          'outputTokens': (7 - ago) * 50000,
        },
    ],
    'models': [
      {'model': 'auto', 'inputTokens': 1800000, 'outputTokens': 900000},
      {'model': 'gpt-x', 'inputTokens': 200000, 'outputTokens': 100000},
    ],
    'sessions': const <Object>[],
    'runs': const <Object>[],
    'nextBefore': null,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> paths;

  setUp(() {
    paths = [];
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();

    OvidCloudService.idTokenOverrideForTest = () async => 'usage-test-token';
    OvidCloudService.httpClientFactoryForTest = () => MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(_usageJson(), 200);
    });
    CloudRestClient.installForTest(
      CloudRestClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(_historyJson(), 200);
        }),
        headers: CloudHeaders.forTest(),
        restBase: 'https://rest.test',
      ),
    );
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    CloudRestClient.installForTest(CloudRestClient());
    AppState.resetTestInstance();
  });

  Future<BuildContext> mount(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return context;
  }

  testWidgets('Usage renders the real counters, ledger and reset window', (
    tester,
  ) async {
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    // Let /usage answer before the route snapshots it.
    for (var i = 0; i < 40 && usage.usage == null; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(usage.usage, isNotNull, reason: 'the /usage answer must load');

    unawaited(V2SettingsRoutes.open(context, 'usage', actions));
    await tester.pumpAndSettle();

    expect(find.byType(UsagePage), findsOneWidget);
    expect(paths, contains('/usage/history'));

    // Daily: today's real input + output tokens (1.5M).
    expect(find.text('1.5M'), findsOneWidget);
    expect(find.text('of 50M tokens used'), findsOneWidget);
    // Monthly: the ledger's 30-day total (3.0M), not a money value.
    expect(find.text('3.0M used'), findsOneWidget);
    expect(find.text('1.5B limit'), findsOneWidget);
    // Countdown derived from the server's resets_at.
    expect(find.textContaining('Resets in 6 h'), findsOneWidget);
    // Today's real request and image counters.
    expect(find.text('7'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // Storage is not reported by either endpoint: an honest unknown, no 0 GB.
    expect(find.text('Not tracked yet'), findsOneWidget);
    expect(find.text('0 GB'), findsNothing);
    // The per-model split comes from today.by_model.
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('GPT X'), findsOneWidget);
    expect(find.text('2 models'), findsOneWidget);

    usage.release();
  });

  testWidgets('Plan cards are enabled per plan and the current one is not', (
    tester,
  ) async {
    OvidCloudService.httpClientFactoryForTest = () => MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(_usageJson(tier: '3x'), 200);
    });
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    final context = await mount(tester);

    for (var i = 0; i < 40 && usage.usage == null; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(usage.usage, isNotNull, reason: 'the /usage answer must load');
    expect(AppState.I.ovidCloudTier, '3x');

    unawaited(V2SettingsRoutes.open(context, 'plan_billing', actions));
    await tester.pumpAndSettle();

    expect(find.byType(PlanBillingPage), findsOneWidget);

    // Go (server tier 3x) is current: marked and disabled.
    final go = tester.widget<OButton>(
      find.byKey(const ValueKey<String>('plan-cta-3x')),
    );
    expect(go.onPressed, isNull);
    expect(go.label, 'Current plan');

    // Plus and Pro are real, per-plan purchases.
    for (final tier in ['7x', '15x']) {
      final cta = tester.widget<OButton>(
        find.byKey(ValueKey<String>('plan-cta-$tier')),
      );
      expect(cta.onPressed, isNotNull, reason: 'tier $tier must be buyable');
      expect(cta.label, isNot('Current plan'));
    }

    // INR matches the USD tier exactly.
    await tester.tap(find.text('INR (₹)'));
    await tester.pumpAndSettle();
    // Once on the plan card, once in the comparison table.
    expect(find.text('₹499'), findsNWidgets(2));
    expect(find.text('₹1,799'), findsNWidgets(2));
    expect(find.text('₹9,999'), findsNWidgets(2));

    usage.release();
  });
}
