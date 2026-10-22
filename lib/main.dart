import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'core/app_lock.dart';
import 'core/billing_uid.dart';
import 'core/cert_pinning.dart';
import 'core/cloud/cloud_account_binding.dart';
import 'core/cloud/cloud_agent_facade.dart';
import 'core/cloud/cloud_session_store.dart';
import 'core/cloud/cloud_ws.dart';
import 'core/cloud/projects.dart';
import 'core/cloud/push_service.dart';
import 'core/diag.dart';
import 'core/state.dart';
import 'core/studio_drafts.dart';
import 'core/background_notifications.dart';
import 'core/composer_drafts.dart';
import 'core/firebase_service.dart';
import 'core/native_routes.dart';
import 'core/play_billing.dart';
import 'core/revenuecat_billing.dart';
import 'core/session_history_store.dart';
import 'core/theme.dart';
import 'ui/app_router.dart';
import 'ui/design/o_theme.dart';
import 'ui/login_gate.dart';
import 'ui/shell.dart';
import 'ui/v2/app/v2_app_shell.dart';
import 'ui/v2/app/app_lock_gate.dart';
import 'ui/v2/app/v2_onboarding_gate.dart';
import 'ui/v2/v2_gallery.dart';
import 'ui/v2/v2_registry.dart';
import 'core/share_link_resolver.dart';
import 'l10n/l10n.dart';
import 'ui/collab_session_screen.dart';
import 'ui/shared_conversation_screen.dart';
import 'ui/widgets/error_views.dart';

export 'ui/app_router.dart' show appNavigatorKey;

/// UI generation switch.
///
/// The rebuilt UI is the default: every build ships the v2 shell, onboarding,
/// settings and screens. The legacy shell is reachable only for rollback with
/// `--dart-define=OVID_UI_V1=true`.
const bool kOvidUiV1 = bool.fromEnvironment('OVID_UI_V1');
const bool kOvidUiV2 = !kOvidUiV1;

/// Design-review surface: every v2 screen with a light/dark toggle.
/// `flutter run --dart-define=OVID_UI_GALLERY=true`.
const bool kOvidUiGallery = bool.fromEnvironment('OVID_UI_GALLERY');

bool openShareWithNavigator(GlobalKey<NavigatorState> navigatorKey, Uri uri) {
  final route = ShareLinkResolver.route(uri);
  final navigator = navigatorKey.currentState;
  if (route == null || navigator == null) return false;
  navigator.push(_routeFor(route));
  return true;
}

Route<void> _shareViewerRoute(String token) => MaterialPageRoute<void>(
  builder: (_) => SharedConversationScreen(token: token),
);

/// Read-only links open the viewer; Collab links (`/s/<token>/<invite>`)
/// open the join screen.
Route<void> _routeFor(
  ShareRoute route, [
  Route<void> Function(String token) viewer = _shareViewerRoute,
]) => switch (route) {
  ShareViewerRoute(:final token) => viewer(token),
  CollabJoinRoute(:final token, :final invite) => MaterialPageRoute<void>(
    builder: (_) => CollabJoinScreen(token: token, invite: invite),
  ),
};

/// Opens `/s/<token>` share links (and `/s/<token>/<invite>` Collab links)
/// on the app navigator.
///
/// Only *in-flight* opens are de-duplicated: a token is held from the moment
/// a link arrives (covering the initial link racing the first stream event)
/// until the viewer it pushed is popped. Tapping the same link again after
/// going back therefore opens it again.
///
/// When the navigator is not attached yet (cold start), the open is retried
/// on the next frame, and a frame is explicitly scheduled so the retry does
/// not wait for an unrelated pointer event. Retries are capped at
/// [maxAttempts]; the cap is logged through [Diag].
class ShareLinkOpener {
  ShareLinkOpener({
    required this.navigatorKey,
    this.maxAttempts = 10,
    Route<void> Function(String token)? routeBuilder,
    bool Function()? isActive,
  }) : _routeBuilder = routeBuilder ?? _shareViewerRoute,
       _isActive = isActive ?? (() => true);

  final GlobalKey<NavigatorState> navigatorKey;
  final int maxAttempts;
  final Route<void> Function(String token) _routeBuilder;
  final bool Function() _isActive;
  final _inFlight = <String>{};

  @visibleForTesting
  Set<String> get inFlightTokens => Set.unmodifiable(_inFlight);

  void open(Uri uri) {
    final link = ShareLinkResolver.parse(uri);
    final route = ShareLinkResolver.routeFor(link);
    if (link == null || route == null || !_isActive()) return;
    if (!_inFlight.add(link.key)) return;
    _attempt(link.key, route, 0);
  }

  void _attempt(String token, ShareRoute route, int attempt) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_isActive()) {
        _inFlight.remove(token);
        return;
      }
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        if (attempt + 1 >= maxAttempts) {
          _inFlight.remove(token);
          Diag.swallow(
            'deeplink.open',
            StateError('navigator not ready after $maxAttempts frames'),
          );
          return;
        }
        _attempt(token, route, attempt + 1);
        return;
      }
      navigator
          .push(_routeFor(route, _routeBuilder))
          .whenComplete(() => _inFlight.remove(token));
    });
    SchedulerBinding.instance.scheduleFrame();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installReleaseErrorWidget();
  // M7: no-op unless built with OVID_CERT_PINNING=true AND pins configured.
  installOvidCertificatePinning();
  AppState.I.registerProductionAccountFeatures();
  // Billing reads the account id through this seam so `play_billing.dart` does
  // not have to import Firebase (and therefore sqlite3) just for the uid.
  ovidBillingUidProvider = () => FirebaseService.I.uid;
  // Coalesce session writes in production; tests keep the zero-window default.
  AppState.enableSessionPersistDebounce();
  // Chat history lives in SQLite (one-time verified migration from prefs).
  // Kill switch: replace with `disableSqlite()` to roll history back.
  SessionHistoryRepository.I.enableSqlite();
  // Unsaved Studio drafts survive process death (app-private directory).
  StudioDraftStore.I.enable();
  await AppState.I.initializeForFirstFrame();
  // W1: install the ProjectsPort before any chat surface can read it. The
  // controller is the sidebar's source of truth and the adapter makes the
  // composer `@project:` rows / turn refs live (the gateway now validates
  // them fail-closed).
  ProjectsController.I;
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  if (AppState.I.themeMode == 'system') {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    Aether.dark = brightness != Brightness.light;
    AppState.I.lightTheme = brightness == Brightness.light;
  } else {
    Aether.dark = !AppState.I.lightTheme;
  }
  // First launch goes straight to the chat shell — login → session list (or
  // the empty state → new chat) → send. There is no setup gate: the local
  // sandbox/runtime install was deleted with the on-device agent (P8 Task 20).
  //
  // Runs execute detached on the cloud gateway; this process is a thin
  // client. Push wakes it to show results — nothing here keeps it alive.
  runApp(const OvidApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_startReadiness());
  });
}

Future<void> _startReadiness() => AppState.I.initializeReadiness();

class OvidApp extends StatefulWidget {
  const OvidApp({super.key});
  @override
  State<OvidApp> createState() => _OvidAppState();
}

class _OvidAppState extends State<OvidApp> with WidgetsBindingObserver {
  /// The theme value this widget last built with.
  ///
  /// PERF (2026-09-24): this is the ROOT of the app and `AppState` notifies on
  /// every streamed token, so an unconditional `setState` here invalidated
  /// `MaterialApp`, its theme and every route once per token. Only a theme
  /// toggle is worth a rebuild, so the listener now compares before rebuilding.
  bool _builtDark = Aether.dark;

  /// Persisted preference this widget last built with. A change from
  /// `system` to `light` does not necessarily flip [Aether.dark] (the device
  /// may already be light), but MaterialApp still has to rebuild.
  String _builtMode = AppState.I.themeMode;
  final _links = AppLinks();
  final _resolver = ShareLinkResolver();
  StreamSubscription<Uri>? _linkSubscription;
  late final _shareOpener = ShareLinkOpener(
    navigatorKey: appNavigatorKey,
    isActive: () => mounted,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppState.I.setAccountFeaturesForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    // Rebuild the whole app when the user toggles the theme in Settings.
    AppState.I.addListener(_onThemeChanged);
    // Notification taps route through the app router (07 §1): back to the
    // chat root, validated id, then select. FCM is the delivery path now;
    // local notifications reach Dart through the `ovid/native` channel
    // (CT-009), whose cold-start route Dart pulls once the engine is up.
    PushService.I.onOpenRoute = _openRouteFromNotification;
    NativeRouteChannel.install(_openRouteFromNotification);
    unawaited(_openPendingNativeRoute());
    unawaited(PushService.I.init());
    BackgroundNotifier.I.inAppPresenter = _showInAppNotification;
    // The outgoing account's push token is unregistered while its ID token
    // still works, before every sign-out and reset (SE-002).
    FirebaseService.I.addBeforeSignOut(PushService.I.unbindAccount);
    // Push registration, the WS link, session sync and billing state follow
    // EVERY account that becomes ready — not just the first one in this
    // process (SH-003, SH-008, SH-013, CT-006).
    _accountBinding.start();
    _restoreAndListenForLinks();
  }

  late final _accountBinding = CloudAccountBinding(
    auth: FirebaseService.I,
    readyUid: () {
      final firebase = FirebaseService.I;
      return firebase.isAvailable && firebase.accountReady
          ? firebase.uid
          : null;
    },
    signedIn: () => FirebaseService.I.isSignedIn,
    onBind: _bindCloudAccount,
    onUnbind: _unbindCloudAccount,
  );

  Future<void> _bindCloudAccount(String uid) async {
    // Session-delete teardown hook: deleting a chat drops its WS
    // subscription, projection and every other facade surface
    // (state.deleteSession also fires the server-side DELETE).
    AppState.I.onSessionDeleted = CloudAgentFacade.I.dropSession;
    unawaited(PushService.I.bindAccount(uid));
    unawaited(PlayBillingService.I.ensureLoaded());
    await CloudSessionStore.I.ready;
    try {
      await WsMultiplexer.I.connectIfNeeded();
      await CloudSessionStore.I.refreshSessions();
    } catch (e) {
      Diag.swallow('main.warmCloud', e);
    }
    // A link or notification tap that arrived before the account was ready
    // opens now, against reconciled sessions (SH-019).
    if (mounted) _drainPendingRoute();
  }

  Future<void> _unbindCloudAccount(String previousUid) async {
    AppRouter.clearPending();
    await PushService.I.unbindAccount();
    await WsMultiplexer.I.resetForAccountChange();
    CloudSessionStore.I.resetSyncState();
    PlayBillingService.I.resetForAccount();
  }

  void _drainPendingRoute([int attempt = 0]) {
    if (AppRouter.drainPending()) return;
    if (AppRouter.pendingRoute != null &&
        appNavigatorKey.currentState == null &&
        attempt < 10 &&
        mounted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _drainPendingRoute(attempt + 1),
      );
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  Future<void> _openPendingNativeRoute() async {
    final route = await NativeRouteChannel.takePendingRoute();
    if (route != null && mounted) _openRouteFromNotification(route);
  }

  /// Notification tap → `/c/<id>`, `/schedule/<id>`, `/settings` or `/`.
  /// Opened through [AppRouter.open]: parked until the account is ready
  /// (never above the login screen, never before hydration).
  void _openRouteFromNotification(String path, [int attempt = 0]) {
    final route = AppRouter.parse(Uri.parse(path));
    if (route == null) return;
    if (AppRouter.open(route)) return;
    // Cold start: the navigator may not be attached for a few frames.
    if (appNavigatorKey.currentState == null && attempt < 10 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openRouteFromNotification(path, attempt + 1),
      );
      WidgetsBinding.instance.scheduleFrame();
    }
  }

  /// App in the foreground: show background events in-app, never as a
  /// duplicate system notification.
  void _showInAppNotification(OvidNotification n) {
    final messenger = appScaffoldMessengerKey.currentState;
    if (messenger == null || !mounted) return;
    final text = [n.title, if (n.body.isNotEmpty) n.body].join('\n');
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(text),
        action: SnackBarAction(
          label: context.l10n.notificationOpen,
          onPressed: () => _openRouteFromNotification(n.route),
        ),
      ),
    );
  }

  /// Every incoming link: chat links are routed here; share links keep their
  /// dedicated handling in [_openShare].
  void _onLink(Uri uri) {
    final route = AppRouter.parse(uri);
    if (route is ChatRoute || route is ScheduleRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AppRouter.open(route!);
      });
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _openShare(uri);
  }

  Future<void> _restoreAndListenForLinks() async {
    // Subscribe first: platform startup calls can await indefinitely or fail on
    // platforms without an App Links implementation.
    _linkSubscription = _links.uriLinkStream.listen(
      _onLink,
      onError: (Object error, StackTrace stack) =>
          Diag.swallow('deeplink.stream', error, stack),
    );
    try {
      await _resolver.readInstallReferrer();
    } on Object {
      // Install referrer support is optional on platforms without it.
    }
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) _onLink(initial);
    } on Object {
      // Initial app links may be unavailable during platform startup.
    }
    try {
      final deferred = await _resolver.restoreDeferred();
      if (deferred != null) {
        _openShare(ShareLinkResolver.uriFor(deferred));
      }
    } on Object {
      // Deferred links are optional and may fail when the provider is absent.
    }
  }

  void _openShare(Uri uri) => _shareOpener.open(uri);

  void _onThemeChanged() {
    if (!mounted) return;
    final mode = AppState.I.themeMode;
    if (Aether.dark == _builtDark && mode == _builtMode) return;
    _builtMode = mode;
    _applyPalette();
  }

  /// Rebuilds for a light/dark flip. `Theme.of` and `context.aether` readers
  /// update through [MaterialApp.themeMode]; widgets that still read the
  /// static `Aether.*` getters (const subtrees, cached builder children, open
  /// sheets and dialogs) are marked dirty explicitly so nothing keeps
  /// painting the old palette.
  void _applyPalette() {
    _builtDark = Aether.dark;
    _builtMode = AppState.I.themeMode;
    setState(() {});
    Aether.rebuildAll(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppState.I.setAccountFeaturesForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // Backgrounding may be followed by process death: write composer
      // drafts now instead of waiting for the debounce.
      unawaited(ComposerDraftStore.I.flush());
    }
    if (state == AppLifecycleState.paused) {
      unawaited(StudioDraftStore.I.flush());
    }
  }

  @override
  void didChangePlatformBrightness() {
    // When in system theme mode, follow the OS brightness change.
    if (AppState.I.themeMode == 'system') {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final isLight = brightness == Brightness.light;
      AppState.I.lightTheme = isLight;
      Aether.dark = !isLight;
      if (mounted && Aether.dark != _builtDark) _applyPalette();
    }
  }

  @override
  void dispose() {
    AppState.I.setAccountFeaturesForeground(false);
    WidgetsBinding.instance.removeObserver(this);
    AppState.I.removeListener(_onThemeChanged);
    _accountBinding.stop();
    if (PushService.I.onOpenRoute == _openRouteFromNotification) {
      PushService.I.onOpenRoute = null;
    }
    if (BackgroundNotifier.I.inAppPresenter == _showInAppNotification) {
      BackgroundNotifier.I.inAppPresenter = null;
    }
    _linkSubscription?.cancel();
    super.dispose();
  }

  /// Gate "Sign out instead" handler.
  ///
  /// Signing out is also the account re-auth path for an app lock whose PIN
  /// secret can no longer be read: clear that unrecoverable secret so a fresh
  /// sign-in is not locked behind a PIN nobody can enter. A working PIN is
  /// left untouched.
  Future<void> _signOutAndResetLock() async {
    await FirebaseService.I.signOut();
    await AppLock.I.resetAfterReauth();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid Si',
      navigatorKey: appNavigatorKey,
      // Enables state restoration (navigator + restorable widgets) after the
      // OS kills the process in the background.
      restorationScopeId: 'ovid',
      scaffoldMessengerKey: appScaffoldMessengerKey,
      onGenerateRoute: AppRouter.onGenerateRoute,
      debugShowCheckedModeBanner: false,
      // Ovid Si palette: the approved Stitch theme for dark, a derived light
      // counterpart, and `system` by default with light as the fallback.
      theme: OTheme.light(),
      darkTheme: OTheme.dark(),
      themeMode: OTheme.modeFor(AppState.I.themeMode),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // The lock must sit ABOVE the Navigator. `builder` wraps every route, so
      // a pushed page (Settings, Artifacts, Schedules, dialogs, or a route
      // restored after a cold start) can never render on top of the lock while
      // the app is locked. Mounting it inside `home` only covered the shell.
      builder: (context, child) => AppLockGate(
        onSignOut: _signOutAndResetLock,
        child: child ?? const SizedBox.shrink(),
      ),
      home: kOvidUiGallery
          ? V2GalleryPage(screens: v2Screens)
          : kOvidUiV2
          ? V2OnboardingGate(
              purchase: (planId) async {
                // Paywall ids are product names; billing uses plan tiers.
                final tier = switch (planId) {
                  'go' => '3x',
                  'plus' => '7x',
                  'pro' => '15x',
                  _ => null,
                };
                if (tier == null) return false;
                final rc = RevenueCatBilling.I;
                final outcome = rc.available
                    ? await rc.buy(tier)
                    : await PlayBillingService.I.buy(tier);
                if (outcome.ok) {
                  // Unlock only on the server's answer (or the debug/profile
                  // Test Store demo), never on the client outcome alone.
                  await applyPurchasedPlan(
                    outcome.tier ?? tier,
                    demo: rc.available && rc.lastPurchaseWasDemo,
                  );
                }
                return outcome.ok;
              },
              child: const LoginGate(child: V2AppShell()),
            )
          : const LoginGate(child: OvidShell()),
    );
  }
}
