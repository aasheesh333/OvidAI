import 'dart:async';

import 'package:flutter/material.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'ui/sandbox_setup.dart';
import 'ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Coalesce session writes in production; tests keep the zero-window default.
  AppState.enableSessionPersistDebounce();
  await AppState.I.initializeForFirstFrame();
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  Aether.dark = !AppState.I.lightTheme;
  runApp(
    OvidApp(
      sandboxReady: AppState.I.sandboxInstalled || AppState.I.sandboxSkipped,
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_startReadiness());
  });
}

Future<void> _startReadiness() => AppState.I.initializeReadiness();

class OvidApp extends StatefulWidget {
  const OvidApp({super.key, this.sandboxReady = true});
  final bool sandboxReady;
  @override
  State<OvidApp> createState() => _OvidAppState();
}

class _OvidAppState extends State<OvidApp> {
  @override
  void initState() {
    super.initState();
    // Rebuild the whole app when the user toggles the theme in Settings.
    AppState.I.addListener(_onThemeChanged);
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
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
      home: widget.sandboxReady
          ? const OvidShell()
          : const _FirstLaunchSetupGate(),
    );
  }
}

/// Full-screen gate shown ONLY on first launch when the sandbox is not
/// yet installed.  Runs the real SandboxService.install (payload extract
/// → chmod → symlinks → config → bash sanity → Node.js → Python) and
/// then replaces itself with the chat shell.  Non-dismissible — the
/// sandbox is required for all agent features (MCP, code execution, etc.).
class _FirstLaunchSetupGate extends StatelessWidget {
  const _FirstLaunchSetupGate();
  @override
  Widget build(BuildContext context) {
    return const SandboxSetupScreen(gateMode: true);
  }
}
