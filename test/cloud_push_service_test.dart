// P8 Task 12 — PushService: FCM token registration and notification routing.
//
// The messaging side is injected through [PushMessagingDelegate] so the test
// exercises the real service logic (registration, refresh, routing) without
// Firebase. The REST side is a real CloudRestClient over MockClient, so the
// wire body (`{token, platform}` per P4's deviceRegisterRequestSchema) is
// asserted, not a stubbed callback.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/push_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _restBase = 'https://cloud.test';

class _FakeMessaging implements PushMessagingDelegate {
  String? token = 'fcm-token-1';
  Map<String, dynamic>? initial;
  int permissionRequests = 0;

  final tokenRefresh = StreamController<String>.broadcast();
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  final opened = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get onTokenRefresh => tokenRefresh.stream;

  @override
  Stream<Map<String, dynamic>> get onMessage => messages.stream;

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => opened.stream;

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => initial;

  int deletedTokens = 0;

  @override
  Future<void> deleteToken() async {
    deletedTokens++;
    // FCM mints a fresh token for the next getToken().
    token = 'fcm-token-after-delete-$deletedTokens';
  }

  Future<void> close() async {
    await tokenRefresh.close();
    await messages.close();
    await opened.close();
  }
}

class _Harness {
  _Harness()
      : messaging = _FakeMessaging(),
        requests = [] {
    rest = CloudRestClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
      headers: CloudHeaders.forTest(),
      restBase: _restBase,
    );
    service = PushService(rest: rest, messaging: messaging);
  }

  final _FakeMessaging messaging;
  final List<http.Request> requests;
  late final CloudRestClient rest;
  late final PushService service;
  final routes = <String>[];

  Future<void> init() async {
    service.onOpenRoute = routes.add;
    await service.init();
    await service.bindAccount('uid-a');
  }

  /// Token registrations in wire order: `{token, platform}`.
  List<Map<String, dynamic>> get registrations => [
        for (final r in requests.where(
            (r) => r.url.path.endsWith('/devices') && r.method == 'POST'))
          Map<String, dynamic>.from(jsonDecode(r.body) as Map),
      ];

  /// Token unregistrations in wire order: `{token}`.
  List<Map<String, dynamic>> get unregistrations => [
        for (final r in requests.where(
            (r) => r.url.path.endsWith('/devices') && r.method == 'DELETE'))
          Map<String, dynamic>.from(jsonDecode(r.body) as Map),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BackgroundNotifier.I.resetForTest();
    BackgroundNotifier.I.foregroundOverrideForTest = () => true;
    h = _Harness();
    PushService.installForTest(h.service);
  });

  tearDown(() async {
    await h.messaging.close();
    BackgroundNotifier.I.resetForTest();
    PushService.resetForTest();
  });

  test('binding an account registers the FCM token without prompting',
      () async {
    await h.init();

    // The onboarding sequence owns the permission prompt (EM-005/EM-016).
    expect(h.messaging.permissionRequests, 0);
    expect(h.registrations, [
      {'token': 'fcm-token-1', 'platform': 'android'},
    ]);
    final auth = h.requests.single.headers.entries
        .where((e) => e.key.toLowerCase() == 'authorization')
        .single;
    expect(auth.value, startsWith('Bearer '));
  });

  test('a token refresh re-registers', () async {
    await h.init();
    h.messaging.tokenRefresh.add('fcm-token-2');
    await Future<void>.delayed(Duration.zero);

    expect(h.registrations, [
      {'token': 'fcm-token-1', 'platform': 'android'},
      {'token': 'fcm-token-2', 'platform': 'android'},
    ]);
  });

  test('a notification tap routes /c/<sessionId>', () async {
    await h.init();
    h.messaging.opened.add({'route': '/c/abc'});
    await Future<void>.delayed(Duration.zero);

    expect(h.routes, ['/c/abc']);
  });

  test('a schedule notification routes /schedule/<id>', () async {
    await h.init();
    h.messaging.opened.add({'route': '/schedule/sched-9'});
    await Future<void>.delayed(Duration.zero);

    expect(h.routes, ['/schedule/sched-9']);
  });

  test('the initial message routes on cold start', () async {
    h.messaging.initial = {'route': '/c/cold'};
    await h.init();

    expect(h.routes, ['/c/cold']);
  });

  test('a foreground message reaches the in-app presenter', () async {
    final shown = <OvidNotification>[];
    BackgroundNotifier.I.inAppPresenter = shown.add;
    await h.init();

    h.messaging.messages.add({
      'route': '/c/abc',
      'title': 'Ovid finished',
      'body': 'The reply is ready.',
    });
    await Future<void>.delayed(Duration.zero);

    expect(shown, hasLength(1));
    expect(shown.single.title, 'Ovid finished');
    expect(shown.single.body, 'The reply is ready.');
    expect(shown.single.route, '/c/abc');
    // A foreground message must not also post a system notification.
    expect(
      BackgroundNotifier.I.postedForTest.where((n) => n.route == '/c/abc'),
      isEmpty,
    );
  });

  test('init is idempotent and never throws when messaging fails', () async {
    h.messaging.token = null;
    await h.init();
    await h.init();
    expect(h.messaging.permissionRequests, 0);
    expect(h.registrations, isEmpty);
  });

  test('requestPermission asks only when called explicitly', () async {
    await h.init();
    expect(await h.service.requestPermission(), isTrue);
    expect(h.messaging.permissionRequests, 1);
  });

  test('unbind DELETEs the token, then invalidates it (SE-002)', () async {
    await h.init();
    await h.service.unbindAccount();

    expect(h.unregistrations, [
      {'token': 'fcm-token-1'},
    ]);
    expect(h.messaging.deletedTokens, 1);
    expect(h.service.boundUid, isNull);
  });

  test('signed out: a token refresh is not registered to anyone', () async {
    await h.init();
    await h.service.unbindAccount();
    h.messaging.tokenRefresh.add('fcm-token-x');
    await Future<void>.delayed(Duration.zero);

    expect(h.registrations, [
      {'token': 'fcm-token-1', 'platform': 'android'},
    ]);
  });

  test('account switch in one process registers account B (CT-006)',
      () async {
    await h.init(); // A
    await h.service.unbindAccount();
    await h.service.bindAccount('uid-b');

    expect(h.service.boundUid, 'uid-b');
    expect(h.registrations, [
      {'token': 'fcm-token-1', 'platform': 'android'},
      {'token': 'fcm-token-after-delete-1', 'platform': 'android'},
    ]);
  });

  test('binding the same account twice registers once', () async {
    await h.init();
    await h.service.bindAccount('uid-a');
    expect(h.registrations, hasLength(1));
  });

  test('unbind with nothing bound makes no request', () async {
    await h.service.init();
    await h.service.unbindAccount();
    expect(h.requests, isEmpty);
    expect(h.messaging.deletedTokens, 0);
  });
}
