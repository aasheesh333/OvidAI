import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'core/diag.dart';
import 'core/state.dart';
import 'core/studio_drafts.dart';
import 'core/agent_notification_service.dart';
import 'core/agent_service.dart';
import 'core/composer_drafts.dart';
import 'core/mcp_service.dart';
import 'core/session_history_store.dart';
import 'core/theme.dart';
import 'ui/app_router.dart';
import 'ui/login_gate.dart';
import 'ui/mcp_oauth_sheet.dart';
import 'ui/shell.dart';
import 'core/share_link_resolver.dart';
import 'l10n/l10n.dart';
import 'ui/shared_conversation_screen.dart';
import 'ui/widgets/error_views.dart';

export 'ui/app_router.dart' show appNavigatorKey;

bool openShareWithNavigator(GlobalKey<NavigatorState> navigatorKey, Uri uri) {
  final route = ShareLinkResolver.route(uri);
  final navigator = navigatorKey.currentState;
  if (route is! ShareViewerRoute || navigator == null) return false;
  navigator.push(_shareViewerRoute(route.token));
  return true;
}

Route<void> _shareViewerRoute(String token) => MaterialPageRoute<void>(
  builder: (_) => SharedConversationScreen(token: token),
);

/// Opens `/s/<token>` share links on the app navigator.
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
    final route = ShareLinkResolver.route(uri);
    if (route is! ShareViewerRoute || !_isActive()) return;
    if (!_inFlight.add(route.token)) return;
    _attempt(route.token, 0);
  }

  void _attempt(String token, int attempt) {
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
        _attempt(token, attempt + 1);
        return;
      }
      navigator
          .push(_routeBuilder(token))
          .whenComplete(() => _inFlight.remove(token));
    });
    SchedulerBinding.instance.scheduleFrame();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installReleaseErrorWidget();
  AppState.I.registerProductionAccountFeatures();
  // Coalesce session writes in production; tests keep the zero-window default.
  AppState.enableSessionPersistDebounce();
  // Chat history lives in SQLite (one-time verified migration from prefs).
  // Kill switch: replace with `disableSqlite()` to roll history back.
  SessionHistoryRepository.I.enableSqlite();
  // Unsaved Studio drafts survive process death (app-private directory).
  StudioDraftStore.I.enable();
  await AppState.I.initializeForFirstFrame();
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  if (AppState.I.themeMode == 'system') {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    Aether.dark = brightness != Brightness.light;
    AppState.I.lightTheme = brightness == Brightness.light;
  } else {
    Aether.dark = !AppState.I.lightTheme;
  }
  // First launch goes straight to the chat shell — there is no setup gate
  // anymore. The sandbox (core + runtimes) installs on Studio first-open
  // via openStudio(); the sandboxInstalled detection above stays available
  // for guards elsewhere.
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
    // chat root, validated id, then select.
    AgentNotificationService.I.selectSessionHandler = _openChatFromNotification;
    _restoreAndListenForLinks();
  }

  bool _openChatFromNotification(String sessionId, [int attempt = 0]) {
    if (AppRouter.openChat(sessionId)) return true;
    // Cold start: the navigator may not be attached for a few frames.
    if (appNavigatorKey.currentState == null && attempt < 10 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openChatFromNotification(sessionId, attempt + 1),
      );
      WidgetsBinding.instance.scheduleFrame();
    }
    return false;
  }

  /// Every incoming link: MCP OAuth redirects and chat links are routed
  /// here; share links keep their dedicated handling in [_openShare].
  void _onLink(Uri uri) {
    if (McpService.isMcpOAuthCallback(uri)) {
      unawaited(
        handleMcpOAuthRedirect(
          uri,
          messenger: appScaffoldMessengerKey.currentState,
        ),
      );
      return;
    }
    final route = AppRouter.parse(uri);
    if (route is ChatRoute || route is ScheduleRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AppRouter.go(route!);
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
        _openShare(
          Uri.parse('${ShareLinkResolver.canonicalOrigin}/s/${deferred.token}'),
        );
      }
    } on Object {
      // Deferred links are optional and may fail when the provider is absent.
    }
  }

  void _openShare(Uri uri) => _shareOpener.open(uri);

  void _onThemeChanged() {
    if (!mounted || Aether.dark == _builtDark) return;
    _applyPalette();
  }

  /// Rebuilds for a light/dark flip. `Theme.of` and `context.aether` readers
  /// update through [MaterialApp.themeMode]; widgets that still read the
  /// static `Aether.*` getters (const subtrees, cached builder children, open
  /// sheets and dialogs) are marked dirty explicitly so nothing keeps
  /// painting the old palette.
  void _applyPalette() {
    _builtDark = Aether.dark;
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
    if (state == AppLifecycleState.resumed) {
      unawaited(AgentService.I.wakeSchedules());
    }
    // Android may kill a paused process: write pending Studio drafts now.
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
    if (AgentNotificationService.I.selectSessionHandler ==
        _openChatFromNotification) {
      AgentNotificationService.I.selectSessionHandler = null;
    }
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid',
      navigatorKey: appNavigatorKey,
      // Enables state restoration (navigator + restorable widgets) after the
      // OS kills the process in the background.
      restorationScopeId: 'ovid',
      scaffoldMessengerKey: appScaffoldMessengerKey,
      onGenerateRoute: AppRouter.onGenerateRoute,
      debugShowCheckedModeBanner: false,
      theme: Aether.themeFor(dark: false),
      darkTheme: Aether.themeFor(dark: true),
      // The app resolves "system" itself (didChangePlatformBrightness) so the
      // static palette and the Theme always agree on the same frame.
      themeMode: _builtDark ? ThemeMode.dark : ThemeMode.light,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const LoginGate(child: OvidShell()),
    );
  }
}
