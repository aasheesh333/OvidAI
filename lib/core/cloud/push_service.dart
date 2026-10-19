import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../background_notifications.dart';
import '../diag.dart';
import '../firebase_service.dart';
import 'cloud_rest.dart';

/// FCM data payload (`RemoteMessage.data`).
typedef PushMessageData = Map<String, dynamic>;

/// The seam between [PushService] and `firebase_messaging`.
///
/// Production wiring is [FirebaseMessagingDelegate]; tests inject a fake so
/// token registration, refresh and routing are exercised without Firebase.
abstract class PushMessagingDelegate {
  Future<bool> requestPermission();
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;
  Stream<PushMessageData> get onMessage;
  Stream<PushMessageData> get onMessageOpenedApp;
  Future<PushMessageData?> getInitialMessage();

  /// Invalidates the current registration token so the next account on this
  /// device gets a fresh one (the old token can never be re-bound to it).
  Future<void> deleteToken();
}

/// Production delegate over [FirebaseMessaging].
class FirebaseMessagingDelegate implements PushMessagingDelegate {
  const FirebaseMessagingDelegate();

  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => FirebaseService.I.getFcmToken();

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<PushMessageData> get onMessage =>
      FirebaseMessaging.onMessage.map((m) => m.data);

  @override
  Stream<PushMessageData> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => m.data);

  @override
  Future<PushMessageData?> getInitialMessage() async =>
      (await _messaging.getInitialMessage())?.data;

  @override
  Future<void> deleteToken() => _messaging.deleteToken();
}

/// Cloud push: registers this device's FCM token for the signed-in account
/// and turns FCM messages into in-app notifications / routes.
///
/// This is the thin-client replacement for the deleted foreground-service
/// keep-alive: runs execute detached on the gateway, so the device only needs
/// to be woken to show the result. Nothing here keeps the process alive.
///
/// Listening ([init]) is process-wide; registration is per account
/// ([bindAccount] on every account that becomes ready, [unbindAccount] before
/// every sign-out / reset), so a signed-out device or a second account never
/// receives the previous account's notifications (SH-003, SE-002, CT-006).
///
/// Notification `data` routes (P4 payload, worker notify.ts):
///   `{'route': '/c/<serverSessionId>'}` and
///   `{'route': '/schedule/<serverSessionId>'}` — both carry the SERVER
///   session id; the router resolves it to the local row (FE-011).
class PushService {
  PushService({
    CloudRestClient? rest,
    PushMessagingDelegate? messaging,
  })  : _rest = rest ?? CloudRestClient.I,
        _messaging = messaging ?? const FirebaseMessagingDelegate();

  static PushService? _instance;

  /// The process-wide default (production REST + Firebase messaging).
  static PushService get I => _instance ??= PushService();

  /// Replaces the singleton — test wiring only.
  @visibleForTesting
  static void installForTest(PushService service) => _instance = service;

  /// Clears the singleton — test wiring only.
  @visibleForTesting
  static void resetForTest() => _instance = null;

  final CloudRestClient _rest;
  final PushMessagingDelegate _messaging;

  /// Installed by main.dart: opens `/c/<id>`, `/schedule/<id>`, … on the app
  /// router (the existing `_openRouteFromNotification`).
  void Function(String route)? onOpenRoute;

  bool _initialized = false;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<PushMessageData>? _messageSub;
  StreamSubscription<PushMessageData>? _openedSub;

  /// The account whose uid the current FCM token is registered to on the
  /// gateway, or null when no account is bound (signed out / never bound).
  String? _boundUid;
  String? _boundToken;

  /// Serialises bind/unbind so a fast sign-out → sign-in can never interleave
  /// the DELETE for A with the POST for B.
  Future<void> _chain = Future<void>.value();

  /// The uid this device's token is currently registered to.
  String? get boundUid => _boundUid;

  /// Starts listening for token refreshes, foreground messages and taps.
  /// Never requests the notification permission: the first-run onboarding
  /// owns that prompt so prompts never stack (EM-005, EM-016). Safe to call
  /// more than once; never throws.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      _tokenSub = _messaging.onTokenRefresh.listen((token) {
        if (token.isEmpty) return;
        // Signed out: there is nobody to register the new token for.
        if (_boundUid == null) return;
        _boundToken = token;
        unawaited(_register(token));
      });
      _messageSub = _messaging.onMessage.listen(_showInApp);
      _openedSub = _messaging.onMessageOpenedApp.listen(_openRoute);
      final initial = await _messaging.getInitialMessage();
      if (initial != null) _openRoute(initial);
    } catch (e) {
      Diag.swallow('push.init', e);
    }
  }

  /// Asks Android for POST_NOTIFICATIONS (API 33+). Called by the first-run
  /// onboarding step and the Settings toggle, never implicitly.
  Future<bool> requestPermission() async {
    try {
      return await _messaging.requestPermission();
    } catch (e) {
      Diag.swallow('push.permission', e);
      return false;
    }
  }

  /// Registers this device's token for [uid]. Runs for every account that
  /// becomes ready (not once per process), so account B is registered after
  /// A signs out in the same process. Idempotent per uid.
  Future<void> bindAccount(String uid) => _serial(() async {
        await init();
        if (_boundUid == uid) return;
        _boundUid = uid;
        try {
          final token = await _messaging.getToken();
          if (_boundUid != uid) return;
          if (token != null && token.isNotEmpty) {
            _boundToken = token;
            await _register(token);
          }
        } catch (e) {
          Diag.swallow('push.bind', e);
        }
      });

  /// Unregisters this device from the bound account (`DELETE /devices` with
  /// the still-valid ID token), then invalidates the FCM token so pushes for
  /// that account can never reach this device again. Call BEFORE the
  /// Firebase sign-out. Best-effort, bounded by [timeout], never throws.
  Future<void> unbindAccount({
    Duration timeout = const Duration(seconds: 6),
  }) => _serial(() async {
        final uid = _boundUid;
        final token = _boundToken;
        _boundUid = null;
        _boundToken = null;
        if (uid == null) return;
        if (token != null && token.isNotEmpty) {
          try {
            await _rest.unregisterDevice(fcmToken: token).timeout(timeout);
          } catch (e) {
            Diag.swallow('push.unregister_device', e);
          }
        }
        try {
          await _messaging.deleteToken().timeout(timeout);
        } catch (e) {
          Diag.swallow('push.delete_token', e);
        }
      });

  Future<void> _serial(Future<void> Function() op) {
    final next = _chain.then((_) => op());
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _register(String token) async {
    try {
      await _rest.registerDevice(fcmToken: token, platform: 'android');
    } catch (e) {
      Diag.swallow('push.register_device', e);
    }
  }

  /// Foreground message: reuse [BackgroundNotifier]'s routing so the user's
  /// notification settings and the visible-chat suppression still apply.
  void _showInApp(PushMessageData data) {
    final route = _route(data);
    final notification = OvidNotification(
      kind: OvidNotificationKind.jobDone,
      title: _text(data['title']) ?? 'Ovid Si',
      body: _text(data['body']) ?? '',
      route: route ?? NotificationRoutes.home,
    );
    unawaited(BackgroundNotifier.I.post(notification));
  }

  void _openRoute(PushMessageData data) {
    final route = _route(data);
    if (route == null) return;
    try {
      onOpenRoute?.call(route);
    } catch (e) {
      Diag.swallow('push.open_route', e);
    }
  }

  /// Only absolute in-app paths are accepted (same bound as the native
  /// `routeNotificationIntent`: starts with `/`, at most 200 chars).
  String? _route(PushMessageData data) {
    final raw = data['route'];
    if (raw is! String) return null;
    final route = raw.trim();
    if (route.isEmpty || route.length > 200 || !route.startsWith('/')) {
      return null;
    }
    return route;
  }

  String? _text(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  /// Test teardown: cancels listeners. Production keeps them for the app's
  /// lifetime (the process no longer outlives the UI).
  @visibleForTesting
  Future<void> dispose() async {
    await _tokenSub?.cancel();
    await _messageSub?.cancel();
    await _openedSub?.cancel();
    _tokenSub = null;
    _messageSub = null;
    _openedSub = null;
    _initialized = false;
    _boundUid = null;
    _boundToken = null;
  }
}
