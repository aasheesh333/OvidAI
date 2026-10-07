import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ovid Cloud mint/usage client (2026-10-01).
///
/// The managed-gateway flow: a verified Google sign-in → the VPS mint verifier
/// returns THIS user's quota-limited virtual key + tier. The client stores the
/// key in the Ovid Cloud provider (secure storage), records the tier, and
/// defaults to Auto mode. Usage is read from the server, never computed here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'fake-id-token';
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.appCheckTokenProvider = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  test('a successful mint binds the key, tier and Auto model', () async {
    final app = AppState.I;
    final client = MockClient((request) async {
      expect(request.url.host, 'api.ovidsi.com');
      if (request.url.path == '/mint') {
        expect(request.headers['Authorization'], 'Bearer fake-id-token');
        return http.Response(
          jsonEncode({
            'key': 'sk-user-abc',
            'tier': '7x',
            'base_url': 'https://api.ovidsi.com/v1',
          }),
          200,
        );
      }
      // The bind() path then refreshes models from /v1/models.
      if (request.url.path.endsWith('/models')) {
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'auto'},
              {'id': 'ovid-pro-1'},
            ],
          }),
          200,
        );
      }
      return http.Response('not found', 404);
    });

    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);
    expect(outcome.ok, isTrue);
    expect(outcome.result!.tier, '7x');

    final provider = app.providerById(AppState.ovidCloudProviderId)!;
    expect(provider.apiKey, 'sk-user-abc');
    expect(app.ovidCloudTier, '7x');
    expect(app.ovidCloudIsPaid, isTrue);
    client.close();
  });

  test('persisted Ovid Cloud URLs migrate host without changing the route', () {
    final cloud = ProviderConfig(
      id: AppState.ovidCloudProviderId,
      name: 'Ovid Cloud',
      description: 'Managed Ovid Cloud provider',
      baseUrl: 'https://api.ovidsi.com/v1',
    );
    cloud.applyPersistedJson({
      'baseUrl': 'https://cloud.dhanuksoftwares.com/v1/models?region=us',
    });
    expect(
      cloud.baseUrl,
      'https://api.ovidsi.com/v1/models?region=us',
    );
    expect(Uri.parse(cloud.baseUrl).host, 'api.ovidsi.com');

    final generic = ProviderConfig(
      id: 'custom-provider',
      name: 'Custom',
      description: 'User provider',
      baseUrl: 'https://example.com/v1',
    );
    generic.applyPersistedJson({
      'baseUrl': 'https://cloud.dhanuksoftwares.com/custom',
    });
    expect(generic.baseUrl, 'https://cloud.dhanuksoftwares.com/custom');
  });

  test('free limit reached returns a distinct status, no key stored', () async {
    final app = AppState.I;
    final client = MockClient((request) async {
      return http.Response('monthly free limit reached', 402);
    });
    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);
    expect(outcome.status, MintStatus.freeLimitReached);
    final provider = app.providerById(AppState.ovidCloudProviderId)!;
    expect(provider.apiKey, isEmpty);
    client.close();
  });

  test('a rejected token is distinct from a server outage', () async {
    final rejected = MockClient((r) async => http.Response('no', 401));
    expect(
      (await OvidCloudService.I.bindOvidCloud(client: rejected)).status,
      MintStatus.rejected,
    );
    rejected.close();

    final down = MockClient((r) async => http.Response('oops', 503));
    expect(
      (await OvidCloudService.I.bindOvidCloud(client: down)).status,
      MintStatus.unavailable,
    );
    down.close();
  });

  test('signed-out mint never calls the network', () async {
    OvidCloudService.idTokenOverrideForTest = () async => null;
    var called = false;
    final client = MockClient((r) async {
      called = true;
      return http.Response('{}', 200);
    });
    final outcome = await OvidCloudService.I.bindOvidCloud(client: client);
    expect(outcome.status, MintStatus.notSignedIn);
    expect(called, isFalse);
    client.close();
  });

  test('usage is read from the server (cloud-based), not computed', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/usage');
      return http.Response(
        jsonEncode({
          'tier': '3x',
          'is_paid': true,
          'daily_spent_usd': 0.42,
          'daily_budget_usd': 2.5,
          'daily_remaining_usd': 2.08,
          'month_free_spent_usd': 0.0,
          'month_free_cap_usd': 10.0,
          'requests_today': 7,
          'budget_window': '30d',
          'remaining_pct': 0.832,
          'models': [
            {
              'model': 'auto',
              'input_cost_per_token': 0.0000005,
              'output_cost_per_token': 0.0000015,
              'remaining_pct': 0.832,
            },
            {
              'model': 'ovid-opus',
              'input_cost_per_token': 0.000015,
              'output_cost_per_token': 0.000075,
              'remaining_pct': 0.832,
            },
          ],
        }),
        200,
      );
    });
    final usage = await OvidCloudService.I.fetchUsage(client: client);
    expect(usage, isNotNull);
    expect(usage!.tier, '3x');
    expect(usage.isPaid, isTrue);
    expect(usage.dailySpentUsd, closeTo(0.42, 1e-9));
    expect(usage.dailyRemainingUsd, closeTo(2.08, 1e-9));
    expect(usage.requestsToday, 7);
    expect(usage.budgetWindow, '30d');
    expect(usage.remainingPct, closeTo(0.832, 1e-9));
    expect(usage.models, hasLength(2));
    expect(usage.models.first.model, 'auto');
    expect(usage.models[1].remainingPct, closeTo(0.832, 1e-9));
    client.close();
  });

  test('missing or invalid remaining usage stays unknown, never derived', () {
    for (final value in [null, -0.1, 1.1, double.nan, double.infinity]) {
      final usage = OvidUsage.fromJson({
        'daily_budget_usd': 45,
        'daily_spent_usd': 9,
        'remaining_pct': ?value,
      });
      expect(usage.remainingFraction, isNull);
      expect(usage.budgetWindow, isEmpty);
    }
  });

  test('server fraction wins over dollar fields and tier multiplier', () {
    final usage = OvidUsage.fromJson({
      'tier': '15x',
      'daily_budget_usd': 45,
      'daily_spent_usd': 9,
      'remaining_pct': 0.23,
      'budget_window': 'server-defined',
    });
    expect(usage.remainingFraction, 0.23);
    expect(usage.budgetWindow, 'server-defined');
    expect(usage.multiplier, 15);
    expect(3 * ovidPlanMultiplier('15x'), 45);
    expect(ovidPlanMultiplier('3x'), 3);
    expect(ovidPlanMultiplier('7x'), 7);
  });

  test('model usage preserves independent server fractions and unknowns', () {
    for (final value in [null, -1.0, 2.0, double.nan, double.infinity]) {
      expect(
        OvidModelUsage.fromJson({
          'model': 'auto',
          'remaining_pct': ?value,
        }).remainingFraction,
        isNull,
      );
    }
    for (final value in [0.0, 0.37, 1.0]) {
      expect(
        OvidModelUsage.fromJson({
          'model': 'auto',
          'remaining_pct': value,
        }).remainingFraction,
        value,
      );
    }
  });

  test('unavailable and malformed usage never produces a snapshot', () async {
    for (final response in [
      http.Response('unavailable', 503),
      http.Response('not json', 200),
    ]) {
      final client = MockClient((_) async => response);
      expect(await OvidCloudService.I.fetchUsage(client: client), isNull);
      client.close();
    }
  });

  test('upgrade requires explicit server success and matching tier', () async {
    for (final body in [
      <String, dynamic>{},
      {'ok': false, 'tier': '15x'},
      {'ok': true, 'tier': '7x'},
    ]) {
      final client = MockClient(
        (_) async => http.Response(jsonEncode(body), 200),
      );
      expect(await OvidCloudService.I.upgrade('15x', client: client), isNull);
      expect(AppState.I.ovidCloudTier, 'free');
      client.close();
    }
  });
}
