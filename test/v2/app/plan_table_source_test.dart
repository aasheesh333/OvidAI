import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/plans_client.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_routes.dart';
import 'package:ovid_ai/ui/v2/settings/plan_billing_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The gateway's real shape (`GET /cloud/v1/plans`, camelCase). The Pro row
/// deliberately carries `null` for every product limit, because a plan the
/// product table does not describe has unknown limits, not zero limits.
String _plansJson() => jsonEncode({
  'plans': [
    {
      'id': 'free',
      'tier': 'free',
      'name': 'Free',
      'priceUsd': 0,
      'priceInr': 0,
      'mult': 1,
      'windowHours': 24,
      'aliases': ['free'],
      'manualModels': false,
      'storageGb': 3,
      'customConnectors': 0,
      'projectFiles': 80,
      'uploads': {'count': 50, 'windowHours': 24},
    },
    {
      'id': 'go',
      'tier': 'go',
      'name': 'Ovid Go',
      'priceUsd': 5,
      'priceInr': 499,
      'mult': 1.5,
      'windowHours': 24,
      'aliases': ['3x'],
      'manualModels': false,
      'storageGb': 5,
      'customConnectors': 5,
      'projectFiles': 100,
      'uploads': {'count': 80, 'windowHours': 3},
    },
    {
      'id': 'plus',
      'tier': 'plus',
      'name': 'Ovid Plus',
      'priceUsd': 18,
      'priceInr': 1799,
      'mult': 5,
      'windowHours': 24,
      'aliases': ['7x'],
      'manualModels': true,
      'storageGb': 15,
      'customConnectors': 20,
      'projectFiles': 150,
      'uploads': {'count': 80, 'windowHours': 3},
    },
    {
      'id': 'pro',
      'tier': 'pro',
      'name': 'Ovid Pro',
      'priceUsd': 99,
      'priceInr': null,
      'mult': 20,
      'windowHours': 24,
      'aliases': ['15x'],
      'manualModels': null,
      'storageGb': null,
      'customConnectors': null,
      'projectFiles': null,
      'uploads': null,
    },
  ],
});

String _usageJson({String tier = 'go'}) => jsonEncode({
  'tier': tier,
  'is_paid': tier != 'free',
  'remaining_pct': 0.5,
  'window': '24h',
  'requests_today': 3,
  'today': {
    'requests': 3,
    'input_tokens': 1000,
    'output_tokens': 500,
    'images': 0,
  },
  'models': const <Object>[],
  'plans': const <Object>[],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('plan id resolution', () {
    test('canonical ids and every legacy spelling resolve to one plan', () {
      const expected = <String, String>{
        'free': 'Free',
        'go': 'Go',
        'plus': 'Plus',
        'pro': 'Pro',
        // The values real `users.tier` rows still hold.
        '3x': 'Go',
        '7x': 'Plus',
        '15x': 'Pro',
        // The mint's older seeds.
        'starter': 'Go',
        'max': 'Pro',
        // Stored tier strings are not guaranteed to be tidy.
        'GO': 'Go',
        ' 7x ': 'Plus',
      };
      for (final entry in expected.entries) {
        expect(
          V2SettingsRoutes.planSpecForTest(entry.key).name,
          entry.value,
          reason: 'tier ${entry.key}',
        );
      }
    });

    test('an unknown tier is Unknown, never Free', () {
      for (final id in ['mystery', 'team', '']) {
        final spec = V2SettingsRoutes.planSpecForTest(id);
        expect(spec.name, 'Unknown', reason: 'tier "$id"');
        expect(spec.storageGb, isNull, reason: 'tier "$id" storage');
      }
    });

    test('the retired 50M token claim is not part of the plan copy', () {
      for (final id in ['free', 'go', 'plus', 'pro']) {
        final spec = V2SettingsRoutes.planSpecForTest(id);
        expect(spec.tagline.toLowerCase(), isNot(contains('token')));
      }
    });
  });

  group('the gateway plan table', () {
    List<CloudPlan> parse() => [
      for (final raw in (jsonDecode(_plansJson()) as Map)['plans'] as List)
        ?CloudPlan.tryParse(raw),
    ];

    test('parses the camelCase shape and resolves ids', () {
      final plans = parse();
      expect(plans.map((plan) => plan.id), ['free', 'go', 'plus', 'pro']);

      final go = plans.firstWhere((plan) => plan.id == 'go');
      expect(go.canonicalId, 'go');
      expect(go.name, 'Ovid Go');
      expect(go.priceUsd, 5);
      expect(go.priceInr, 499);
      expect(go.mult, 1.5);
      expect(go.storageGb, 5);
      expect(go.customConnectors, 5);
      expect(go.projectFiles, 100);
      expect(go.uploads?.count, 80);
      expect(go.uploads?.windowHours, 3);
    });

    test('keeps a null limit null instead of turning it into zero', () {
      final pro = parse().firstWhere((plan) => plan.id == 'pro');
      expect(pro.priceInr, isNull);
      expect(pro.manualModels, isNull);
      expect(pro.storageGb, isNull);
      expect(pro.customConnectors, isNull);
      expect(pro.projectFiles, isNull);
      expect(pro.uploads, isNull);
    });

    test('a legacy row id resolves through the server mapping', () {
      final starter = CloudPlan.tryParse({
        'id': 'starter',
        'tier': 'go',
        'name': 'Ovid Go',
        'priceUsd': 5,
        'priceInr': 499,
        'mult': 1.5,
        'windowHours': 24,
        'aliases': ['3x'],
      });
      expect(starter?.canonicalId, 'go');
    });
  });

  group('limits and prices', () {
    test('null limits render —, never 0', () {
      const limits = V2PlanLimits(
        id: 'pro',
        name: 'Ovid Pro',
        storageGb: null,
        filesPerWindow: null,
        fileWindowLabel: '',
        filesPerProject: null,
        manualModels: null,
        autoMultiplier: null,
        customConnectors: null,
        dailyTokenCap: null,
        monthlyTokenCap: null,
      );
      expect(limits.storageLabel, '—');
      expect(limits.filesLabel, '—');
      expect(limits.filesPerProjectLabel, '—');
      expect(limits.modelAccessLabel, '—');
      expect(limits.autoMultiplierLabel, '—');
      expect(limits.customConnectorsLabel, '—');
      expect(limits.dailyCapLabel, '—');
      expect(limits.monthlyCapLabel, '—');
    });

    test('no yearly price is invented from the monthly price', () {
      const go = V2Plan(
        id: 'go',
        name: 'Ovid Go',
        tagline: '',
        priceUsd: 5,
        priceInr: 499,
      );
      expect(go.amount(V2Currency.usd, V2BillingPeriod.monthly), 5);
      expect(go.amount(V2Currency.inr, V2BillingPeriod.monthly), 499);
      expect(go.amount(V2Currency.usd, V2BillingPeriod.yearly), isNull);
      expect(go.amount(V2Currency.inr, V2BillingPeriod.yearly), isNull);
      expect(
        go.priceLabel(V2Currency.usd, period: V2BillingPeriod.yearly),
        '—',
      );
    });
  });

  testWidgets('a go customer reads the server table, not a Free fallback', (
    tester,
  ) async {
    final paths = <String>[];
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();

    OvidCloudService.idTokenOverrideForTest = () async => 'plan-test-token';
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((request) async {
          paths.add(request.url.path);
          return http.Response(_usageJson(), 200);
        });
    CloudRestClient.installForTest(
      CloudRestClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/plans')) {
            return http.Response(_plansJson(), 200);
          }
          return http.Response('{}', 404);
        }),
        headers: CloudHeaders.forTest(),
        restBase: 'https://rest.test',
      ),
    );
    addTearDown(() {
      OvidCloudService.idTokenOverrideForTest = null;
      OvidCloudService.httpClientFactoryForTest = null;
      CloudRestClient.installForTest(CloudRestClient());
      AppState.resetTestInstance();
    });

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

    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(usage);
    for (var i = 0; i < 40 && usage.usage == null; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(usage.usage, isNotNull, reason: 'the /usage answer must load');

    unawaited(V2SettingsRoutes.open(context, 'plan_billing', actions));
    await tester.pumpAndSettle();

    expect(paths, contains('/plans'));

    final goCard = find.byKey(const ValueKey<String>('plan-card-go'));
    expect(goCard, findsOneWidget);
    expect(
      find.descendant(of: goCard, matching: find.text('Ovid Go')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: goCard, matching: find.text(r'$5')),
      findsOneWidget,
    );
    // The bug: a paying Go account was shown the Free plan's $0 and limits.
    expect(
      find.descendant(of: goCard, matching: find.text('Free')),
      findsNothing,
    );
    expect(
      find.descendant(of: goCard, matching: find.text(r'$0')),
      findsNothing,
    );
    expect(find.text('50M tokens a day'), findsNothing);

    // A null limit is a dash in the comparison table, never a zero.
    final proStorage = find.byKey(
      const ValueKey<String>('plan-compare-cell-pro-storage'),
    );
    expect(
      find.descendant(of: proStorage, matching: find.text('—')),
      findsOneWidget,
    );
    final proConnectors = find.byKey(
      const ValueKey<String>('plan-compare-cell-pro-connectors'),
    );
    expect(
      find.descendant(of: proConnectors, matching: find.text('—')),
      findsOneWidget,
    );
    expect(find.text('0 GB'), findsNothing);

    // No server yearly price exists, so yearly says so instead of inventing
    // ten monthly payments.
    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: goCard, matching: find.text('—')),
      findsOneWidget,
    );
    expect(find.text('No yearly price for Ovid Go.'), findsOneWidget);

    // The INR price is the server's product price, not a conversion.
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INR (₹)'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: goCard, matching: find.text('₹499')),
      findsOneWidget,
    );
    final proCard = find.byKey(const ValueKey<String>('plan-card-pro'));
    expect(
      find.descendant(of: proCard, matching: find.text('—')),
      findsOneWidget,
    );

    usage.release();
  });
}
