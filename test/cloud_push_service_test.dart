// P8 Task 12 — PushService: FCM token registration and notification routing.
//
// The messaging side is injected through [PushMessagingDelegate] so the test
// exercises the real service logic (registration, refresh, routing) without
// Firebase. The REST side is a real CloudRestClient over MockClient, so the
// wire body (`{token, platform}` per P4's deviceRegisterRequestSchema) is
// asserted, not a stubbed callback.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/push_registration_coordinator.dart';
import 'package:ovid_ai/core/cloud/push_service.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/notification_permission.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_provider_flow_test.dart' show TestAuth, TestUser;

const _restBase = 'https://cloud.test';

class _FakeMessaging implements PushMessagingDelegate {
  String? token = 'fcm-token-1';
  Map<String, dynamic>? initial;
  int permissionRequests = 0;
  int tokenReads = 0;
  int tokenCancellations = 0;
  final events = <String>[];

  final tokenRefresh = StreamController<String>.broadcast();
  final messages = StreamController<Map<String, dynamic>>.broadcast();
  final opened = StreamController<Map<String, dynamic>>.broadcast();
  Completer<void>? tokenCallbackGate;
  Completer<void>? tokenCallbackStarted;
  Completer<void>? tokenCancellationGate;
  Completer<void>? tokenCancellationFinished;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<String?> getToken() async {
    tokenReads++;
    return token;
  }

  @override
  Stream<String> get onTokenRefresh {
    events.add('token-listener');
    final source = tokenRefresh.stream.asyncMap((token) async {
      tokenCallbackStarted?.complete();
      await tokenCallbackGate?.future;
      return token;
    });
    late final StreamSubscription<String> upstream;
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onListen: () {
        upstream = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => upstream.pause(),
      onResume: () => upstream.resume(),
      onCancel: () async {
        tokenCancellations++;
        await tokenCancellationGate?.future;
        await upstream.cancel();
        if (tokenCancellationFinished?.isCompleted == false) {
          tokenCancellationFinished!.complete();
        }
      },
    );
    return controller.stream;
  }

  @override
  Stream<Map<String, dynamic>> get onMessage => messages.stream;

  @override
  Stream<Map<String, dynamic>> get onMessageOpenedApp => opened.stream;

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async {
    events.add('initial-message');
    return initial;
  }

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

class _RegistrationStore implements PushRegistrationStore {
  PushRegistrationRecord? value;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;

  @override
  Future<PushRegistrationRecord?> read() async => value;

  @override
  Future<void> write(PushRegistrationRecord record) async {
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await writeGate?.future;
    value = record;
  }
}

class _Harness {
  _Harness() : messaging = _FakeMessaging(), requests = [] {
    rest = CloudRestClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        final status =
            request.method == 'POST' && request.url.path.endsWith('/devices')
            ? registrationStatus
            : 200;
        return http.Response(
          status == 200
              ? '{}'
              : '{"error":{"code":"unavailable","message":"registration rejected"}}',
          status,
        );
      }),
      headers: CloudHeaders(
        idToken: () async => authUid == null ? null : 'id-token-for-$authUid',
      ),
      restBase: _restBase,
    );
  }

  final _FakeMessaging messaging;
  final List<http.Request> requests;
  late final CloudRestClient rest;
  late final PushService service = PushService(
    rest: rest,
    messaging: messaging,
    currentUid: () => uidReader == null ? authUid : uidReader!(),
    auth: authService,
    notificationInitializer: () async {
      messaging.events.add('configure-start');
      await configureGate?.future;
      messaging.events.add('configure-end');
      return true;
    },
    permissionReader: useDefaultPermissionReader ? null : () async => true,
    registrationStore: registrationStore,
  );
  final routes = <String>[];
  final registrationStore = _RegistrationStore();
  String? authUid = 'uid-a';
  String? Function()? uidReader;
  FirebaseService? authService;
  bool useDefaultPermissionReader = false;
  int registrationStatus = 200;
  Completer<void>? configureGate;

  Future<void> init() async {
    service.onOpenRoute = routes.add;
    await service.init();
    await service.bindAccount('uid-a');
  }

  /// Token registrations in wire order: `{token, platform}`.
  List<Map<String, dynamic>> get registrations => [
    for (final r in requests.where(
      (r) => r.url.path.endsWith('/devices') && r.method == 'POST',
    ))
      Map<String, dynamic>.from(jsonDecode(r.body) as Map),
  ];

  /// Token unregistrations in wire order: `{token}`.
  List<Map<String, dynamic>> get unregistrations => [
    for (final r in requests.where(
      (r) => r.url.path.endsWith('/devices') && r.method == 'DELETE',
    ))
      Map<String, dynamic>.from(jsonDecode(r.body) as Map),
  ];
}

Future<
  ({FirebaseService firebase, TestAuth auth, StreamController<User?> changes})
>
_createRealSdkAuth(_Harness h) async {
  final app = AppState.createForTest();
  app.suspendCoalescedPersistenceForTest = true;
  ImageStudio.I.bindAccount(null);
  final user = TestUser('uid-a', ['google.com']);
  final auth = TestAuth()..currentUser = user;
  final changes = StreamController<User?>.broadcast(sync: true);
  final firebase = FirebaseService.forTest(
    initializeApp: () async {},
    configure: () async {},
    identity: AuthIdentity(
      auth: () => auth,
      providers: AuthProviders(),
      googleCredential: () async => null,
    ),
    initialUser: user,
    userChanges: changes.stream,
  );
  addTearDown(() async {
    firebase.dispose();
    await changes.close();
    ImageStudio.I.bindAccount(null);
    await app.awaitPendingSessionWritesForTest();
    AppState.resetTestInstance();
  });
  await firebase.initialize();
  h.uidReader = () => firebase.uid;
  h.authService = firebase;
  return (firebase: firebase, auth: auth, changes: changes);
}

Future<
  ({FirebaseService firebase, TestAuth auth, StreamController<User?> changes})
>
_bindRealSdkAuth(_Harness h) async {
  final sdk = await _createRealSdkAuth(h);
  await h.service.init();
  await h.service.bindAccount('uid-a');
  expect(h.service.boundUid, 'uid-a');
  return sdk;
}

Future<void> _signalSdkSignOut(
  _Harness h,
  FirebaseService firebase,
  TestAuth auth,
  StreamController<User?> changes, {
  required bool authAvailable,
}) async {
  final signedOut = Completer<void>();
  void listener() {
    if (firebase.uid == null && !signedOut.isCompleted) {
      signedOut.complete();
    }
  }

  firebase.addListener(listener);
  auth.currentUser = null;
  if (!authAvailable) h.authUid = null;
  changes.add(null);
  await signedOut.future.timeout(const Duration(seconds: 5));
  firebase.removeListener(listener);
}

Future<void> _signalSdkReplacement(
  _Harness h,
  FirebaseService firebase,
  TestAuth auth,
  StreamController<User?> changes,
) async {
  final replaced = Completer<void>();
  void listener() {
    if (firebase.uid == 'uid-b' && !replaced.isCompleted) {
      replaced.complete();
    }
  }

  firebase.addListener(listener);
  auth.currentUser = TestUser('uid-b', ['google.com']);
  h.authUid = 'uid-b';
  changes.add(auth.currentUser);
  await replaced.future.timeout(const Duration(seconds: 5));
  firebase.removeListener(listener);
}

Future<void> _emitSdkSignOut(
  _Harness h,
  FirebaseService firebase,
  TestAuth auth,
  StreamController<User?> changes, {
  required bool authAvailable,
}) async {
  await _signalSdkSignOut(
    h,
    firebase,
    auth,
    changes,
    authAvailable: authAvailable,
  );
  for (
    var attempt = 0;
    attempt < 20 && h.messaging.deletedTokens == 0;
    attempt++
  ) {
    await Future<void>.delayed(Duration.zero);
  }
  await h.service.drain();
}

void _useNativePermission(
  _Harness h,
  Object? result, {
  bool missingPlugin = false,
  bool fallbackFails = false,
}) {
  h.useDefaultPermissionReader = true;
  NotificationPermission.androidOverrideForTest = true;
  NotificationPermission.invokeOverrideForTest = (method) async {
    if (missingPlugin) throw MissingPluginException();
    return result;
  };
  if (fallbackFails) {
    NotificationPermissionAccess.status = () async {
      throw StateError('Permission status unavailable.');
    };
  }
}

Map<String, dynamic> _payload({
  String kind = 'agentFinished',
  String channel = 'agent_updates',
  String sessionId = 'abc',
  String? route,
  String title = 'Ovid finished',
  String body = 'The reply is ready.',
}) => {
  'kind': kind,
  'channel': channel,
  'sessionId': sessionId,
  'route': route ?? '/c/$sessionId',
  'title': title,
  'body': body,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationPermission.resetForTest();
    NotificationPermissionAccess.reset();
    BackgroundNotifier.I.resetForTest();
    BackgroundNotifier.I.foregroundOverrideForTest = () => true;
    h = _Harness();
  });

  tearDown(() async {
    await h.service.dispose();
    await h.service.drain();
    await h.messaging.close();
    BackgroundNotifier.I.resetForTest();
    NotificationPermission.resetForTest();
    NotificationPermissionAccess.reset();
    PushService.resetForTest();
  });

  test(
    'binding an account registers the FCM token without prompting',
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
    },
  );

  test('a token refresh re-registers', () async {
    await h.init();
    h.messaging.tokenRefresh.add('fcm-token-2');
    await Future<void>.delayed(Duration.zero);
    await h.service.drain();

    expect(h.registrations, [
      {'token': 'fcm-token-1', 'platform': 'android'},
      {'token': 'fcm-token-2', 'platform': 'android'},
    ]);
  });

  test('a notification tap routes /c/<sessionId>', () async {
    await h.init();
    h.messaging.opened.add(_payload());
    await Future<void>.delayed(Duration.zero);

    expect(h.routes, ['/c/abc']);
  });

  test('a schedule notification routes /schedule/<id>', () async {
    await h.init();
    h.messaging.opened.add(
      _payload(
        kind: 'scheduleSucceeded',
        channel: 'scheduler_results',
        sessionId: 'sched-9',
        route: '/schedule/sched-9',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(h.routes, ['/schedule/sched-9']);
  });

  test('the initial message routes on cold start', () async {
    h.messaging.initial = _payload(sessionId: 'cold');
    await h.init();

    expect(h.routes, ['/c/cold']);
  });

  test('a foreground message reaches the in-app presenter', () async {
    final shown = <OvidNotification>[];
    BackgroundNotifier.I.inAppPresenter = shown.add;
    await h.init();

    h.messaging.messages.add(_payload());
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

  test(
    'first bind held by channel config cannot resurrect SDK sign-out',
    () async {
      final sdk = await _createRealSdkAuth(h);
      h.configureGate = Completer<void>();
      final binding = h.service.bindAccount('uid-a');
      expect(h.messaging.events, ['configure-start']);

      await _signalSdkSignOut(
        h,
        sdk.firebase,
        sdk.auth,
        sdk.changes,
        authAvailable: false,
      );
      h.configureGate!.complete();
      await binding;
      await h.service.drain();

      expect(h.service.health.desiredUid, isNull);
      expect(h.service.health.acknowledgedUid, isNull);
      expect(h.service.boundUid, isNull);
      expect(h.messaging.tokenReads, 0);
      expect(h.registrations, isEmpty);
      expect(h.messaging.deletedTokens, 0);
    },
  );

  test('SDK userChanges null invalidates push without A auth', () async {
    final sdk = await _bindRealSdkAuth(h);
    await _emitSdkSignOut(
      h,
      sdk.firebase,
      sdk.auth,
      sdk.changes,
      authAvailable: false,
    );

    expect(h.unregistrations, isEmpty);
    expect(h.messaging.deletedTokens, 1);
    expect(h.service.boundUid, isNull);
    expect(h.service.health.desiredUid, isNull);
  });

  test('SDK userChanges null unregisters with still-valid A auth', () async {
    final sdk = await _bindRealSdkAuth(h);
    await _emitSdkSignOut(
      h,
      sdk.firebase,
      sdk.auth,
      sdk.changes,
      authAvailable: true,
    );

    expect(h.unregistrations, [
      {'token': 'fcm-token-1'},
    ]);
    expect(h.messaging.deletedTokens, 1);
    expect(h.service.boundUid, isNull);
  });

  test('SDK sign-out during boot init tears down restored binding', () async {
    final sdk = await _bindRealSdkAuth(h);
    await h.service.dispose();
    h.configureGate = Completer<void>();
    final initializing = h.service.init();
    expect(h.messaging.events.last, 'configure-start');

    await _signalSdkSignOut(
      h,
      sdk.firebase,
      sdk.auth,
      sdk.changes,
      authAvailable: false,
    );
    h.configureGate!.complete();
    await initializing;
    for (
      var attempt = 0;
      attempt < 20 && h.messaging.deletedTokens == 0;
      attempt++
    ) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.service.drain();

    expect(h.messaging.deletedTokens, 1);
    expect(h.service.health.desiredUid, isNull);
    expect(h.service.boundUid, isNull);
  });

  test(
    'A unbind desired clear then B bind cannot register A installed token',
    () async {
      final sdk = await _bindRealSdkAuth(h);
      h.registrationStore.writeGate = Completer<void>();
      h.registrationStore.writeStarted = Completer<void>();
      await _signalSdkSignOut(
        h,
        sdk.firebase,
        sdk.auth,
        sdk.changes,
        authAvailable: false,
      );
      await h.registrationStore.writeStarted!.future.timeout(
        const Duration(seconds: 5),
      );
      expect(h.service.health.desiredUid, isNull);

      await _signalSdkReplacement(h, sdk.firebase, sdk.auth, sdk.changes);
      final generationBeforeB = h.service.health.generation;
      final binding = h.service.bindAccount('uid-b');
      for (
        var attempt = 0;
        attempt < 50 &&
            (h.service.health.desiredUid != 'uid-b' ||
                h.service.health.generation == generationBeforeB);
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.service.health.desiredUid, 'uid-b');
      expect(h.service.health.generation, greaterThan(generationBeforeB));
      expect(
        h.messaging.tokenReads,
        1,
        reason: 'B must still be queued behind A',
      );
      h.registrationStore.writeGate!.complete();
      await binding;
      await h.service.drain();

      expect(h.messaging.deletedTokens, 1);
      expect(h.registrations.last['token'], 'fcm-token-after-delete-1');
      expect(
        h.registrations.where((r) => r['token'] == 'fcm-token-1'),
        hasLength(1),
        reason: 'only the original A bind may use A\'s installed token',
      );
      expect(h.service.health.desiredUid, 'uid-b');
      expect(h.service.health.acknowledgedUid, 'uid-b');
      expect(h.service.health.acknowledgedToken, 'fcm-token-after-delete-1');
      expect(h.service.health.registered, isTrue);
    },
  );

  test(
    'stale A teardown during cancellation cannot unbind replacement B',
    () async {
      final sdk = await _bindRealSdkAuth(h);
      final cancellationsBefore = h.messaging.tokenCancellations;
      h.messaging.tokenCancellationGate = Completer<void>();
      h.messaging.tokenCancellationFinished = Completer<void>();
      await _signalSdkSignOut(
        h,
        sdk.firebase,
        sdk.auth,
        sdk.changes,
        authAvailable: false,
      );
      for (
        var attempt = 0;
        attempt < 20 && h.messaging.tokenCancellations == cancellationsBefore;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.messaging.tokenCancellations, cancellationsBefore + 1);

      await _signalSdkReplacement(h, sdk.firebase, sdk.auth, sdk.changes);
      await h.service.bindAccount('uid-b');
      expect(h.service.boundUid, 'uid-b');
      final deletedAfterB = h.messaging.deletedTokens;
      final unregistersAfterB = h.unregistrations.length;

      h.messaging.tokenCancellationGate!.complete();
      await h.messaging.tokenCancellationFinished!.future;
      await Future<void>.delayed(Duration.zero);
      await h.service.drain();

      expect(h.service.health.desiredUid, 'uid-b');
      expect(h.service.health.acknowledgedUid, 'uid-b');
      expect(h.service.boundUid, 'uid-b');
      expect(h.service.health.registered, isTrue);
      expect(h.messaging.deletedTokens, deletedAfterB);
      expect(h.unregistrations, hasLength(unregistersAfterB));
    },
  );

  test('account switch in one process registers account B (CT-006)', () async {
    await h.init(); // A
    await h.service.unbindAccount();
    h.authUid = 'uid-b';
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

  test('non-2xx registration is not healthy despite token presence', () async {
    h.registrationStatus = 503;
    await h.init();

    expect(h.service.health.tokenAvailable, isTrue);
    expect(h.service.health.registered, isFalse);
    expect(h.service.health.acknowledgedUid, isNull);
    expect(h.service.boundUid, isNull);
  });

  test(
    'direct account replacement never binds the outgoing token to B',
    () async {
      await h.init();
      final oldGeneration = h.service.health.generation;
      h.authUid = 'uid-b';

      await h.service.bindAccount('uid-b');
      await h.service.refreshToken(
        'late-token-for-a',
        generation: oldGeneration,
      );

      expect(h.service.boundUid, 'uid-b');
      expect(h.registrations.last['token'], 'fcm-token-after-delete-1');
      expect(
        h.registrations.where((r) => r['token'] == 'late-token-for-a'),
        isEmpty,
      );
      final deleteAuth = h.requests.where((r) => r.method == 'DELETE');
      expect(
        deleteAuth,
        isEmpty,
        reason: 'B auth must not be used to unregister A',
      );
    },
  );

  test('late A token-stream callback cannot register its token to B', () async {
    await h.init();
    h.messaging.tokenCallbackGate = Completer<void>();
    h.messaging.tokenCallbackStarted = Completer<void>();
    h.messaging.tokenRefresh.add('late-token-for-a');
    await h.messaging.tokenCallbackStarted!.future;

    h.authUid = 'uid-b';
    await h.service.bindAccount('uid-b');
    final registrationsForB = h.registrations.length;
    h.messaging.tokenCallbackGate!.complete();
    await Future<void>.delayed(Duration.zero);
    await h.service.drain();

    expect(h.registrations, hasLength(registrationsForB));
    expect(
      h.registrations.where((r) => r['token'] == 'late-token-for-a'),
      isEmpty,
    );
    expect(h.service.boundUid, 'uid-b');
    expect(h.service.health.acknowledgedToken, isNot('late-token-for-a'));
  });

  test(
    'agent failure foreground payload keeps its kind channel and session',
    () async {
      final shown = <OvidNotification>[];
      BackgroundNotifier.I.inAppPresenter = shown.add;
      await h.init();

      h.messaging.messages.add(
        _payload(
          kind: 'agentFailed',
          sessionId: 'failed-session',
          title: 'Ovid could not finish this run',
          body: 'The run stopped.',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(shown, hasLength(1));
      expect(shown.single.kind, OvidNotificationKind.agentFailed);
      expect(shown.single.channel, OvidChannel.agentUpdates);
      expect(shown.single.sessionId, 'failed-session');
      expect(shown.single.route, '/c/failed-session');
    },
  );

  test(
    'payload without explicit metadata is not defaulted to jobDone',
    () async {
      final shown = <OvidNotification>[];
      BackgroundNotifier.I.inAppPresenter = shown.add;
      await h.init();

      h.messaging.messages.add({'route': '/c/abc', 'title': 'Legacy'});
      await Future<void>.delayed(Duration.zero);

      expect(shown, isEmpty);
    },
  );

  test('PushService init waits for boot channel configuration', () async {
    h.configureGate = Completer<void>();
    h.messaging.initial = _payload(sessionId: 'cold');
    h.service.onOpenRoute = h.routes.add;

    final initializing = h.service.init();
    await Future<void>.delayed(Duration.zero);
    expect(h.messaging.events, ['configure-start']);
    expect(h.routes, isEmpty);

    h.configureGate!.complete();
    await initializing;
    final configured = h.messaging.events.indexOf('configure-end');
    expect(configured, isNonNegative);
    expect(
      h.messaging.events.indexOf('token-listener'),
      greaterThan(configured),
    );
    expect(
      h.messaging.events.indexOf('initial-message'),
      greaterThan(configured),
    );
    expect(h.routes, ['/c/cold']);
  });

  test('native granted permission is a granted health fact', () async {
    _useNativePermission(h, true);
    await h.service.init();
    expect(h.service.health.osPermissionGranted, isTrue);
  });

  test('native denied permission is a denied health fact', () async {
    _useNativePermission(h, false);
    await h.service.init();
    expect(h.service.health.osPermissionGranted, isFalse);
  });

  test('native null permission is unknown, not granted', () async {
    _useNativePermission(h, null);
    await h.service.init();
    expect(h.service.health.osPermissionGranted, isNull);
  });

  test('unexpected native permission is unknown, not granted', () async {
    _useNativePermission(h, 'unexpected');
    await h.service.init();
    expect(h.service.health.osPermissionGranted, isNull);
  });

  test('native and fallback permission failures are unknown', () async {
    _useNativePermission(h, null, missingPlugin: true, fallbackFails: true);
    await h.service.init();
    expect(h.service.health.osPermissionGranted, isNull);
  });

  test('unbind with nothing bound makes no request', () async {
    await h.service.init();
    await h.service.unbindAccount();
    expect(h.requests, isEmpty);
    expect(h.messaging.deletedTokens, 0);
  });
}
