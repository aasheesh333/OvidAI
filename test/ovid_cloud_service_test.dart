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
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  test('a successful mint binds the key, tier and Auto model', () async {
    final app = AppState.I;
    final client = MockClient((request) async {
      if (request.url.path == '/mint') {
        expect(request.headers['Authorization'], 'Bearer fake-id-token');
        return http.Response(
          jsonEncode({
            'key': 'sk-user-abc',
            'tier': '10x',
            'base_url': 'https://cloud.dhanuksoftwares.com/v1',
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
    expect(outcome.result!.tier, '10x');

    final provider = app.providerById(AppState.ovidCloudProviderId)!;
    expect(provider.apiKey, 'sk-user-abc');
    expect(app.ovidCloudTier, '10x');
    expect(app.ovidCloudIsPaid, isTrue);
    client.close();
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
          'tier': '5x',
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
    expect(usage!.tier, '5x');
    expect(usage.isPaid, isTrue);
    expect(usage.dailySpentUsd, closeTo(0.42, 1e-9));
    expect(usage.dailyRemainingUsd, closeTo(2.08, 1e-9));
    expect(usage.requestsToday, 7);
    expect(usage.isMonthly, isTrue);
    expect(usage.remainingPct, closeTo(0.832, 1e-9));
    expect(usage.models, hasLength(2));
    expect(usage.models.first.model, 'auto');
    expect(usage.models[1].per1mOutput, closeTo(75, 1e-6));
    client.close();
  });
}
