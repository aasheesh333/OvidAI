import 'dart:async';

import 'package:flutter/material.dart';

import 'core/state.dart';
import 'core/theme.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Coalesce session writes in production; tests keep the zero-window default.
  AppState.enableSessionPersistDebounce();
  await AppState.I.initializeForFirstFrame();
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  Aether.dark = !AppState.I.lightTheme;
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

class _OvidAppState extends State<OvidApp> {
  /// The theme value this widget last built with.
  ///
  /// PERF (2026-09-24): this is the ROOT of the app and `AppState` notifies on
  /// every streamed token, so an unconditional `setState` here invalidated
  /// `MaterialApp`, its theme and every route once per token. Only a theme
  /// toggle is worth a rebuild, so the listener now compares before rebuilding.
  bool _builtDark = Aether.dark;

  @override
  void initState() {
    super.initState();
    // Rebuild the whole app when the user toggles the theme in Settings.
    AppState.I.addListener(_onThemeChanged);
  }

  void _onThemeChanged() {
    if (!mounted || Aether.dark == _builtDark) return;
    _builtDark = Aether.dark;
    setState(() {});
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onThemeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid',
      debugShowCheckedModeBanner: false,
      theme: Aether.theme(),
      home: const OvidShell(),
    );
  }
}
