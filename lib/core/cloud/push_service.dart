import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../background_notifications.dart';
import '../diag.dart';
import '../firebase_service.dart';
import '../notification_permission.dart';
import 'cloud_rest.dart';
import 'push_payload_mapper.dart';
import 'push_registration_coordinator.dart';

/// FCM data payload (`RemoteMessage.data`, plus foreground notification copy).
typedef PushMessageData = Map<String, dynamic>;

/// The seam between [PushService] and `firebase_messaging`.
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

  PushMessageData _payload(RemoteMessage message) => {
    if (message.notification?.title != null)
      'title': message.notification!.title,
    if (message.notification?.body != null) 'body': message.notification!.body,
    ...message.data,
  };

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
      FirebaseMessaging.onMessage.map(_payload);

  @override
  Stream<PushMessageData> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp.map(_payload);

  @override
  Future<PushMessageData?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _payload(message);
  }

  @override
  Future<void> deleteToken() => _messaging.deleteToken();
}

/// Cloud push registration and FCM notification routing. Registration state is
/// owned by one generation-fenced [PushRegistrationCoordinator]; token presence
/// alone is never reported as a healthy gateway registration.
class PushService {
  PushService({
    CloudRestClient? rest,
    PushMessagingDelegate? messaging,
    String? Function()? currentUid,
    Listenable? auth,
    Future<bool> Function()? notificationInitializer,
    Future<Object?> Function()? permissionReader,
    PushRegistrationStore? registrationStore,
  }) : _rest = rest ?? CloudRestClient.I,
       _messaging = messaging ?? const FirebaseMessagingDelegate(),
       _currentUid = currentUid ?? (() => FirebaseService.I.uid),
       _auth = auth ?? FirebaseService.I,
       _notificationInitializer =
           notificationInitializer ?? BackgroundNotifier.I.init,
       _permissionReader =
           permissionReader ?? NotificationPermission.healthStatus,
       // ignore: prefer_initializing_formals
       _registrationStore = registrationStore;

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
  final String? Function() _currentUid;
  final Listenable _auth;
  final Future<bool> Function() _notificationInitializer;
  final Future<Object?> Function() _permissionReader;
  final PushRegistrationStore? _registrationStore;

  /// Installed by main.dart: opens validated in-app notification routes.
  void Function(String route)? onOpenRoute;

  bool _initialized = false;
  Future<void>? _initializing;
  StreamSubscription<String>? _tokenSub;
  StreamSubscription<PushMessageData>? _messageSub;
  StreamSubscription<PushMessageData>? _openedSub;
  PushRegistrationCoordinator? _coordinator;
  int _tokenListenerEpoch = 0;
  String? _lastAuthUid;
  bool _authSignOutPending = false;
  String? _authSignOutUid;
  int? _authSignOutGeneration;

  PushHealthSnapshot get health =>
      _coordinator?.health ?? const PushHealthSnapshot();

  /// The desired uid only after its current FCM token has an actual 2xx ack.
  String? get boundUid => health.registered ? health.desiredUid : null;

  /// Configures channels before attaching listeners or reading the initial
  /// message. Safe to call more than once; never requests permission or throws.
  Future<void> init() {
    if (_initialized) return Future<void>.value();
    final existing = _initializing;
    if (existing != null) return existing;
    final attempt = _initialize();
    _initializing = attempt;
    return attempt;
  }

  Future<void> _initialize() async {
    try {
      _lastAuthUid = _currentUid();
      _auth.removeListener(_onAuthChanged);
      _auth.addListener(_onAuthChanged);
      final channelsReady = await _notificationInitializer();
      final permission = await _readPermission();
      final coordinator = await PushRegistrationCoordinator.open(
        register: _registerDevice,
        unregister: _unregisterDevice,
        getToken: _messaging.getToken,
        deleteToken: _messaging.deleteToken,
        store: _registrationStore,
      );
      coordinator.updateReadiness(
        osPermissionGranted: permission,
        channelsReady: channelsReady,
      );
      _coordinator = coordinator;
      await _replaceTokenListener(coordinator, coordinator.health.generation);
      _messageSub = _messaging.onMessage.listen(_showInApp);
      _openedSub = _messaging.onMessageOpenedApp.listen(_openRoute);
      _initialized = true;
      _flushAuthSignOut();
      try {
        final initial = await _messaging.getInitialMessage();
        if (initial != null) _openRoute(initial);
      } catch (e) {
        Diag.swallow('push.initial_message', e);
      }
    } catch (e) {
      _auth.removeListener(_onAuthChanged);
      Diag.swallow('push.init', e);
    } finally {
      _initializing = null;
    }
  }

  Future<bool?> _readPermission() async {
    try {
      final value = await _permissionReader();
      return value is bool ? value : null;
    } catch (e) {
      Diag.swallow('push.permission_status', e);
      return null;
    }
  }

  void _onAuthChanged() {
    final previous = _lastAuthUid;
    final current = _currentUid();
    _lastAuthUid = current;
    if (current != null) {
      _authSignOutPending = false;
      _authSignOutUid = null;
      _authSignOutGeneration = null;
    } else if (previous != null) {
      _authSignOutPending = true;
      _authSignOutUid = previous;
      _authSignOutGeneration = _coordinator?.health.generation;
    }
    _flushAuthSignOut();
  }

  void _flushAuthSignOut() {
    if (!_authSignOutPending || !_initialized) return;
    if (_lastAuthUid != null) {
      _authSignOutPending = false;
      _authSignOutUid = null;
      _authSignOutGeneration = null;
      return;
    }
    final coordinator = _coordinator;
    if (coordinator == null) return;
    if (coordinator.health.desiredUid == null &&
        coordinator.health.acknowledgedUid == null) {
      _authSignOutPending = false;
      _authSignOutUid = null;
      _authSignOutGeneration = null;
      return;
    }
    final outgoingUid = _authSignOutUid;
    final outgoingGeneration = _authSignOutGeneration;
    _authSignOutPending = false;
    _authSignOutUid = null;
    _authSignOutGeneration = null;
    // SDK-originated sign-out has no before-sign-out wrapper. Capture A's
    // identity before any await so a delayed teardown can never select B.
    unawaited(
      unbindAccount(
        expectedUid: outgoingUid,
        expectedGeneration: outgoingGeneration,
      ),
    );
  }

  Future<void> _detachTokenListener() async {
    _tokenListenerEpoch++;
    final subscription = _tokenSub;
    _tokenSub = null;
    await subscription?.cancel();
  }

  Future<void> _replaceTokenListener(
    PushRegistrationCoordinator coordinator,
    int generation, {
    String? uid,
  }) async {
    await _detachTokenListener();
    if (!identical(_coordinator, coordinator) ||
        coordinator.health.generation != generation ||
        (uid != null && coordinator.health.desiredUid != uid)) {
      return;
    }
    final epoch = _tokenListenerEpoch;
    late final StreamSubscription<String> subscription;
    subscription = _messaging.onTokenRefresh.listen((token) {
      // The callback belongs to the subscription's account generation, never
      // to whichever account happens to be current when a delayed event lands.
      if (epoch != _tokenListenerEpoch ||
          !identical(_tokenSub, subscription) ||
          !identical(_coordinator, coordinator) ||
          coordinator.health.generation != generation ||
          (uid != null && coordinator.health.desiredUid != uid) ||
          token.trim().isEmpty) {
        return;
      }
      unawaited(coordinator.refreshToken(token, generation: generation));
    });
    _tokenSub = subscription;
  }

  /// Asks Android for POST_NOTIFICATIONS (API 33+). Called only by explicit
  /// onboarding/settings actions, never by [init].
  Future<bool> requestPermission() async {
    await init();
    try {
      final granted = await _messaging.requestPermission();
      _coordinator?.updateReadiness(osPermissionGranted: granted);
      return granted;
    } catch (e) {
      Diag.swallow('push.permission', e);
      return false;
    }
  }

  /// Registers every ready account. A different desired account uses the
  /// serialized switch operation, which retires the outgoing token before a
  /// replacement token can be bound.
  Future<void> bindAccount(String uid) {
    // Capture ownership before init's first await. A bind delayed by channel
    // configuration must not restore A after the SDK has signed out.
    final authUid = _currentUid();
    final coordinatorGeneration = _coordinator?.health.generation;
    return _bindAccount(uid, authUid, coordinatorGeneration);
  }

  Future<void> _bindAccount(
    String uid,
    String? authUid,
    int? coordinatorGeneration,
  ) async {
    await init();
    final coordinator = _coordinator;
    if (coordinator == null ||
        authUid != uid ||
        _currentUid() != uid ||
        (coordinatorGeneration != null &&
            coordinator.health.generation != coordinatorGeneration)) {
      return;
    }
    final previous = coordinator.health.desiredUid;
    final previousGeneration = coordinator.health.generation;
    await _detachTokenListener();
    if (!identical(_coordinator, coordinator) ||
        _currentUid() != uid ||
        coordinator.health.generation != previousGeneration) {
      return;
    }
    final int generation;
    if (previous != null && previous != uid) {
      final switching = coordinator.switchAccount(previous, uid);
      generation = coordinator.health.generation;
      await switching;
    } else {
      generation = await coordinator.bindAccount(uid);
    }
    await _replaceTokenListener(coordinator, generation, uid: uid);
  }

  /// Test/FCM seam carrying the generation captured by the token listener.
  Future<void> refreshToken(String token, {required int generation}) async {
    await _coordinator?.refreshToken(token, generation: generation);
  }

  /// Unregisters while the outgoing account's auth is still valid, then
  /// invalidates the local FCM token. main.dart installs this before sign-out.
  Future<void> unbindAccount({
    Duration timeout = const Duration(seconds: 6),
    String? expectedUid,
    int? expectedGeneration,
  }) {
    final health = _coordinator?.health;
    final outgoingUid =
        expectedUid ??
        health?.desiredUid ??
        health?.acknowledgedUid ??
        _lastAuthUid ??
        _currentUid();
    final outgoingGeneration = expectedGeneration ?? health?.generation;
    return _unbindAccount(outgoingUid, outgoingGeneration, timeout);
  }

  Future<void> _unbindAccount(
    String? outgoingUid,
    int? outgoingGeneration,
    Duration timeout,
  ) async {
    await init();
    final coordinator = _coordinator;
    if (coordinator == null ||
        !_teardownIsCurrent(coordinator, outgoingUid, outgoingGeneration)) {
      return;
    }
    await _detachTokenListener();
    if (!identical(_coordinator, coordinator) ||
        !_teardownIsCurrent(coordinator, outgoingUid, outgoingGeneration)) {
      return;
    }
    await coordinator.unbindAccount(
      timeout: timeout,
      expectedUid: outgoingUid,
      expectedGeneration: outgoingGeneration,
    );
  }

  bool _teardownIsCurrent(
    PushRegistrationCoordinator coordinator,
    String? outgoingUid,
    int? outgoingGeneration,
  ) {
    if (outgoingUid == null) return false;
    final health = coordinator.health;
    if (outgoingGeneration != null && health.generation != outgoingGeneration) {
      return false;
    }
    if (health.desiredUid != outgoingUid &&
        health.acknowledgedUid != outgoingUid) {
      return false;
    }
    final currentAuth = _currentUid();
    return currentAuth == null || currentAuth == outgoingUid;
  }

  Future<void> drain() async => _coordinator?.drain();

  Future<void> _registerDevice(String uid, String token) async {
    _requireCurrentAccount(uid);
    await _rest.registerDevice(fcmToken: token, platform: 'android');
  }

  Future<void> _unregisterDevice(String uid, String token) async {
    // Never use B's auth for A's owner-scoped DELETE. A→null is different:
    // CloudHeaders may still hold A's valid credential during SDK teardown;
    // when it does not, authorization fails before any request is sent.
    final current = _currentUid();
    if (current != null && current != uid) {
      throw StateError('The signed-in account changed during push lifecycle.');
    }
    await _rest.unregisterDevice(fcmToken: token);
  }

  void _requireCurrentAccount(String uid) {
    if (_currentUid() != uid) {
      throw StateError('The signed-in account changed during push lifecycle.');
    }
  }

  void _showInApp(PushMessageData data) {
    final notification = PushPayloadMapper.fromData(data);
    if (notification == null) return;
    unawaited(BackgroundNotifier.I.post(notification));
  }

  void _openRoute(PushMessageData data) {
    final notification = PushPayloadMapper.fromData(data);
    if (notification == null) return;
    try {
      onOpenRoute?.call(notification.route);
    } catch (e) {
      Diag.swallow('push.open_route', e);
    }
  }

  /// Test teardown: cancels listeners and waits for queued registration work.
  @visibleForTesting
  Future<void> dispose() async {
    _auth.removeListener(_onAuthChanged);
    await _detachTokenListener();
    await _messageSub?.cancel();
    await _openedSub?.cancel();
    _tokenSub = null;
    _messageSub = null;
    _openedSub = null;
    _initialized = false;
    await drain();
  }
}
