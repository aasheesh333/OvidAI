import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/account_health.dart';
import 'package:ovid_ai/core/cloud/account_profile_client.dart';
import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_routes.dart';
import 'package:ovid_ai/ui/v2/settings/account_health_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/response_wait_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud_agent_facade_test.dart' show FakeCloudSocket;

CloudRestClient _rest(
  Future<http.Response> Function(http.Request request) handler,
) => CloudRestClient(
  restBase: 'https://cloud.test',
  headers: CloudHeaders.forTest(),
  httpClient: MockClient(handler),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rename persists the display name then refreshes collab projection',
    () async {
      final events = <String>[];
      late http.Request request;
      final client = AccountProfileClient(
        rest: _rest((incoming) async {
          request = incoming;
          events.add('${incoming.method} ${incoming.url.path}');
          return http.Response(
            jsonEncode({'displayName': 'Ada Lovelace'}),
            200,
          );
        }),
        refreshCollabProjection: () => events.add('collab refresh'),
      );

      await client.rename('  Ada Lovelace  ');

      expect(request.method, 'PATCH');
      expect(request.url.path, '/account/profile');
      expect(jsonDecode(request.body), {'displayName': 'Ada Lovelace'});
      expect(events, ['PATCH /account/profile', 'collab refresh']);
    },
  );

  test(
    'a rejected rename does not refresh a stale collab projection',
    () async {
      var refreshes = 0;
      final client = AccountProfileClient(
        rest: _rest((_) async => http.Response('{"error":{}}', 400)),
        refreshCollabProjection: () => refreshes++,
      );

      await expectLater(
        client.rename('Ada'),
        throwsA(isA<CloudApiException>()),
      );
      expect(refreshes, 0);
    },
  );

  test('an unconfirmed rename does not refresh collab projection', () async {
    var refreshes = 0;
    final client = AccountProfileClient(
      rest: _rest((_) async => http.Response('{}', 200)),
      refreshCollabProjection: () => refreshes++,
    );

    await expectLater(client.rename('Ada'), throwsStateError);
    expect(refreshes, 0);
  });

  test(
    'response wait presets persist server-side without cancelling runs',
    () async {
      expect(
        responseWaitPresets.map((preset) => (preset.label, preset.seconds)),
        [('Fast', 15), ('Balanced', 45), ('Deep', 120)],
      );

      final requests = <http.Request>[];
      final client = AccountSettingsClient(
        rest: _rest((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'notificationsEnabled': true,
              'byokDefault': null,
              'responseWaitSeconds': body['responseWaitSeconds'],
            }),
            200,
          );
        }),
      );

      for (final seconds in [15, 45, 120, 600]) {
        final saved = await client.setResponseWaitSeconds(seconds);
        expect(saved.responseWaitSeconds, seconds);
      }

      expect(requests, hasLength(4));
      for (final request in requests) {
        expect(request.method, 'PATCH');
        expect(request.url.path, '/settings');
        expect(request.url.path, isNot(contains('cancel')));
        expect(jsonDecode(request.body).keys, ['responseWaitSeconds']);
      }

      await expectLater(client.setResponseWaitSeconds(14), throwsArgumentError);
      await expectLater(
        client.setResponseWaitSeconds(601),
        throwsArgumentError,
      );
      expect(requests, hasLength(4), reason: 'invalid values never reach HTTP');
    },
  );

  test('an unconfirmed response wait is not treated as persisted', () async {
    final client = AccountSettingsClient(
      rest: _rest(
        (_) async => http.Response(
          jsonEncode({'notificationsEnabled': true, 'byokDefault': null}),
          200,
        ),
      ),
    );

    await expectLater(client.setResponseWaitSeconds(45), throwsStateError);
  });

  testWidgets('response wait offers Fast 15, Balanced 45 and Deep 120', (
    tester,
  ) async {
    final writes = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: ResponseWaitPage(
          data: V2ResponseWaitPageData(
            seconds: 45,
            onChanged: (seconds) async => writes.add(seconds),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fast · 15 s'), findsOneWidget);
    expect(find.text('Balanced · 45 s'), findsOneWidget);
    expect(find.text('Deep · 2 min'), findsOneWidget);

    await tester.tap(find.widgetWithText(OPressable, 'Fast · 15 s'));
    await tester.pumpAndSettle();
    expect(writes, [15]);
    expect(tester.widget<Slider>(find.byType(Slider)).value, 15);
    expect(tester.widget<Slider>(find.byType(Slider)).min, 15);
    expect(tester.widget<Slider>(find.byType(Slider)).max, 600);
  });

  testWidgets('Fast 15 reaches AppState and the production watchdog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    addTearDown(AppState.resetTestInstance);
    OvidCloudService.idTokenOverrideForTest = () async => 'settings-test';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(
        jsonEncode({'tier': 'free', 'plans': const <Object?>[]}),
        200,
      ),
    );
    addTearDown(() {
      OvidCloudService.idTokenOverrideForTest = null;
      OvidCloudService.httpClientFactoryForTest = null;
    });
    final rest = _rest(
      (_) async => http.Response(
        jsonEncode({
          'notificationsEnabled': true,
          'byokDefault': null,
          'responseWaitSeconds': 15,
        }),
        200,
      ),
    );
    final usage = CloudUsageStore.acquire(AppState.I);
    final actions = V2SettingsActions(
      usage,
      accountSettings: AccountSettingsClient(rest: rest),
    );
    addTearDown(() {
      actions.dispose();
      usage.release();
    });

    await actions.setResponseWait(15);
    final prefs = await SharedPreferences.getInstance();

    final sockets = <FakeCloudSocket>[];
    final ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (url) async {
        final socket = FakeCloudSocket();
        sockets.add(socket);
        return socket;
      },
      prefs: prefs,
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    final facade = CloudAgentFacade(rest: rest, ws: ws, store: null);
    facade.subscribeForTest('s1');
    await tester.pump(const Duration(milliseconds: 50));
    sockets.single.server({
      'op': 'event',
      'event': {
        'sessionId': 's1',
        'seq': '1-0',
        'type': 'run_started',
        'payload': {'runId': 'run-1'},
        'ts': '2026-10-24T10:00:00.000Z',
      },
    });
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 15));

    final actual = (
      AppState.I.responseTimeoutSec,
      facade.stalledFor('s1'),
      facade.busyFor('s1'),
    );
    facade.dispose();
    await ws.disconnect();
    await tester.pump();
    expect(actual, (15, true, true));
  });

  test('crash consent gates actual collection in both directions', () async {
    SharedPreferences.setMockInitialValues({});
    final records = <Object>[];
    final collectionSwitches = <bool>[];
    final analyticsSwitches = <bool>[];
    final service = FirebaseService.forTest(
      initializeApp: () async {},
      configure: () async {},
      setCrashCollection: (enabled) async => collectionSwitches.add(enabled),
      setAnalyticsCollection: (enabled) async => analyticsSwitches.add(enabled),
      crashRecorder: (error, stack, fatal) async => records.add(error),
    );

    await service.initializeCrashReporting();
    service.recordZoneError(StateError('before consent'), StackTrace.current);
    await testerFlush(service);
    expect(records, isEmpty);
    expect(collectionSwitches, [false]);

    await service.setConsent(true);
    service.recordZoneError(StateError('opted in'), StackTrace.current);
    await testerFlush(service);
    expect(records, hasLength(1));

    await service.setConsent(false);
    service.recordZoneError(StateError('opted out'), StackTrace.current);
    await testerFlush(service);
    expect(records, hasLength(1));
    expect(collectionSwitches, [false, true, false]);
    expect(analyticsSwitches, [false, true, false]);
  });

  test(
    'consent revoked during release write blocks native crash record',
    () async {
      SharedPreferences.setMockInitialValues({});
      final releaseGate = Completer<void>();
      final records = <Object>[];
      var releaseWrites = 0;
      final service = FirebaseService.forTest(
        initializeApp: () async {},
        configure: () async {},
        setCrashCollection: (_) async {},
        setAnalyticsCollection: (_) async {},
        crashReleaseWriter: (_) {
          releaseWrites++;
          return releaseGate.future;
        },
        crashRecorder: (error, stack, fatal) async => records.add(error),
      );
      await service.initializeCrashReporting();
      await service.setConsent(true);

      final pending = service.recordZoneError(
        StateError('secret prompt must stay sanitized'),
        StackTrace.current,
      );
      expect(releaseWrites, 1);
      await service.setConsent(false);
      releaseGate.complete();

      expect(await pending, isFalse);
      expect(records, isEmpty);
    },
  );

  test('health parses devices, security and upload windows', () {
    final health = AccountHealth.fromJson({
      'devices': {'total': 2, 'active': 1, 'currentRegistered': true},
      'security': {
        'status': 'ok',
        'multiIpFlags': 0,
        'lastCheckedAt': '2026-10-24T10:00:00.000Z',
      },
      'plan': {
        'limits': {
          'uploads': {'count': 80, 'windowHours': 3},
        },
      },
    });

    expect(health.devices?.total, 2);
    expect(health.devices?.active, 1);
    expect(health.devices?.currentRegistered, isTrue);
    expect(health.security?.status, 'ok');
    expect(health.security?.multiIpFlags, 0);
    expect(
      health.security?.lastCheckedAt,
      DateTime.parse('2026-10-24T10:00:00.000Z'),
    );
    expect(health.plan?.limits?.uploads?.count, 80);
    expect(health.plan?.limits?.uploads?.windowHours, 3);
  });

  test('unknown supplemental health does not hide a known quota warning', () {
    const data = V2AccountHealthPageData(
      accountStatus: V2AccountStatus.active,
      storageFraction: 0.95,
    );

    expect(data.statusLabel, 'Attention needed · Storage almost full');
    expect(data.isHealthy, isFalse);
  });

  test('unknown supplemental health renders dashes and is not healthy', () {
    const data = V2AccountHealthPageData(accountStatus: V2AccountStatus.active);

    expect(data.devicesText, '—');
    expect(data.securityText, '—');
    expect(data.uploadWindowText, '—');
    expect(data.isHealthy, isFalse);
    expect(data.statusLabel, isNot('Healthy'));
    expect(data.statusLabel, contains('unknown'));
  });

  testWidgets('security attention renders review, never Healthy', (
    tester,
  ) async {
    await _pumpRouteHealth(tester, _healthFixture(securityStatus: 'attention'));

    expect(find.text('Attention needed · Security review'), findsOneWidget);
    expect(find.text('Review needed'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });

  testWidgets('security degraded renders degraded, never Healthy', (
    tester,
  ) async {
    await _pumpRouteHealth(tester, _healthFixture(securityStatus: 'degraded'));

    expect(find.text('Attention needed · Security degraded'), findsOneWidget);
    expect(find.text('Degraded'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
  });

  testWidgets('verified-good security permits Healthy control', (tester) async {
    await _pumpRouteHealth(tester, _healthFixture());

    expect(find.text('Healthy'), findsOneWidget);
    expect(find.text('No issues reported'), findsOneWidget);
    expect(find.text('Attention needed · Security review'), findsNothing);
  });

  testWidgets('incomplete security stays dash and unknown, never Healthy', (
    tester,
  ) async {
    await _pumpRouteHealth(
      tester,
      _healthFixture(securityStatus: 'attention', includeSecurityTime: false),
    );

    expect(find.text('—'), findsWidgets);
    expect(find.text('Attention needed · Status unknown'), findsOneWidget);
    expect(find.text('Healthy'), findsNothing);
    expect(find.text('Review needed'), findsNothing);
  });

  test(
    'partial device security and upload facts are never complete health',
    () {
      Map<String, Object?> full() => {
        'devices': {'total': 2, 'active': 1, 'currentRegistered': true},
        'security': {
          'status': 'ok',
          'multiIpFlags': 0,
          'lastCheckedAt': '2026-10-24T10:00:00.000Z',
        },
        'plan': {
          'limits': {
            'uploads': {'count': 80, 'windowHours': 3},
          },
        },
      };
      expect(
        AccountHealth.fromJson(full()).hasCompleteSupplementalFacts,
        isTrue,
      );

      final partial = <String, Map<String, Object?>>{
        'device active': full()..['devices'] = {'total': 2},
        'device registration': full()..['devices'] = {'total': 2, 'active': 1},
        'security flags': full()
          ..['security'] = {
            'status': 'ok',
            'lastCheckedAt': '2026-10-24T10:00:00.000Z',
          },
        'security check time': full()
          ..['security'] = {'status': 'ok', 'multiIpFlags': 0},
        'upload window': full()
          ..['plan'] = {
            'limits': {
              'uploads': {'count': 80},
            },
          },
      };
      for (final entry in partial.entries) {
        final health = AccountHealth.fromJson(entry.value);
        expect(health.hasCompleteSupplementalFacts, isFalse, reason: entry.key);
      }

      const page = V2AccountHealthPageData(
        accountStatus: V2AccountStatus.active,
        devicesLabel: '1 active of 2',
        securityLabel: '',
        uploadWindowLabel: '80 files / 3 h',
        supplementalHealthKnown: true,
      );
      expect(page.securityText, '—');
      expect(page.isHealthy, isFalse);
      expect(page.statusLabel, contains('unknown'));
    },
  );
}

Map<String, Object?> _healthFixture({
  String securityStatus = 'ok',
  int securityFlags = 0,
  bool includeSecurityTime = true,
}) => {
  'plan': {
    'tier': '7x',
    'id': 'plus',
    'name': 'Ovid Plus',
    'limits': {
      'uploads': {'count': 80, 'windowHours': 3},
    },
  },
  'devices': {'total': 2, 'active': 1, 'currentRegistered': true},
  'security': {
    'status': securityStatus,
    'multiIpFlags': securityFlags,
    if (includeSecurityTime) 'lastCheckedAt': '2026-10-24T10:00:00.000Z',
  },
  'standing': {'banned': false, 'deletion': null},
};

Future<void> _pumpRouteHealth(
  WidgetTester tester,
  Map<String, Object?> json,
) async {
  SharedPreferences.setMockInitialValues({});
  AppState.resetTestInstance();
  AppState.createForTest();
  OvidCloudService.idTokenOverrideForTest = () async => 'health-test';
  OvidCloudService.httpClientFactoryForTest = () => MockClient(
    (_) async => http.Response(
      jsonEncode({'tier': 'free', 'plans': const <Object?>[]}),
      200,
    ),
  );
  final usage = CloudUsageStore.acquire(AppState.I);
  final actions = V2SettingsActions(usage);
  addTearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AppState.resetTestInstance();
  });

  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: Builder(
        builder: (ctx) {
          context = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  final data = V2SettingsRoutes.healthData(
    context,
    actions,
    accountHealth: AccountHealth.fromJson(json),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: AccountHealthPage(data: data),
    ),
  );
  await tester.pumpAndSettle();
  actions.dispose();
  usage.release();
}

/// Crash recording is intentionally fire-and-forget in production; drain the
/// microtask queue so the test observes only completed recorder calls.
Future<void> testerFlush(FirebaseService service) =>
    Future<void>.delayed(Duration.zero);
