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
}

/// Cloud push: registers this device's FCM token and turns FCM messages into
/// in-app notifications / routes.
///
/// This is the thin-client replacement for the deleted foreground-service
/// keep-alive: runs execute detached on the gateway, so the device only needs
/// to be woken to show the result. Nothing here keeps the process alive.
///
/// Notification `data` routes (P4 payload):
///   `{'route': '/c/<sessionId>'}` and `{'route': '/schedule/<scheduleId>'}`.
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

  /// Requests permission, registers the current token, and starts listening.
  /// Safe to call more than once and never throws: push is best-effort.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _messaging.requestPermission();
      final token = await _messaging.getToken();
      if (token != null && token.isNotEmpty) {
        await _register(token);
      }
      _tokenSub = _messaging.onTokenRefresh.listen((token) {
        if (token.isEmpty) return;
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
      title: _text(data['title']) ?? 'Ovid',
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
  }
}
