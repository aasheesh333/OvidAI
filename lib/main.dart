import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import 'core/state.dart';
import 'core/agent_service.dart';
import 'core/theme.dart';
import 'ui/login_gate.dart';
import 'ui/shell.dart';
import 'core/share_link_resolver.dart';
import 'ui/shared_conversation_screen.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

bool openShareWithNavigator(GlobalKey<NavigatorState> navigatorKey, Uri uri) {
  final route = ShareLinkResolver.route(uri);
  final navigator = navigatorKey.currentState;
  if (route is! ShareViewerRoute || navigator == null) return false;
  navigator.push(MaterialPageRoute(
    builder: (_) => SharedConversationScreen(token: route.token),
  ));
  return true;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Coalesce session writes in production; tests keep the zero-window default.
  AppState.enableSessionPersistDebounce();
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
  final _openedTokens = <String>{};
  final _pendingTokens = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild the whole app when the user toggles the theme in Settings.
    AppState.I.addListener(_onThemeChanged);
    _restoreAndListenForLinks();
  }

  Future<void> _restoreAndListenForLinks() async {
    // Subscribe first: platform startup calls can await indefinitely or fail on
    // platforms without an App Links implementation.
    _linkSubscription = _links.uriLinkStream.listen(
      _openShare,
      onError: (Object error, StackTrace stack) {},
    );
    try {
      await _resolver.readInstallReferrer();
    } on Object {
      // Install referrer support is optional on platforms without it.
    }
    try {
      final initial = await _links.getInitialLink();
      if (initial != null) _openShare(initial);
    } on Object {
      // Initial app links may be unavailable during platform startup.
    }
    try {
      final deferred = await _resolver.restoreDeferred();
      if (deferred != null) {
        _openShare(Uri.parse('${ShareLinkResolver.canonicalOrigin}/s/${deferred.token}'));
      }
    } on Object {
      // Deferred links are optional and may fail when the provider is absent.
    }
  }

  void _openShare(Uri uri) {
    final route = ShareLinkResolver.route(uri);
    if (route is! ShareViewerRoute || !mounted ||
        _openedTokens.contains(route.token) ||
        !_pendingTokens.add(route.token)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _openedTokens.contains(route.token)) {
        _pendingTokens.remove(route.token);
        return;
      }
      if (openShareWithNavigator(appNavigatorKey, uri)) {
        _pendingTokens.remove(route.token);
        _openedTokens.add(route.token);
      } else {
        _pendingTokens.remove(route.token);
        _openShare(uri);
      }
    });
  }

  void _onThemeChanged() {
    if (!mounted || Aether.dark == _builtDark) return;
    _builtDark = Aether.dark;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AgentService.I.wakeSchedules());
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
      if (mounted && Aether.dark != _builtDark) {
        _builtDark = Aether.dark;
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppState.I.removeListener(_onThemeChanged);
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: Aether.theme(),
      home: const LoginGate(child: OvidShell()),
    );
  }
}
