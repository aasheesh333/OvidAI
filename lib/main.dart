import 'dart:async';

import 'package:flutter/material.dart';
import 'core/agent_service.dart';
import 'core/firebase_service.dart';
import 'core/github_service.dart';
import 'core/sandbox_service.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'ui/sidebar.dart';
import 'ui/chat_screen.dart';
import 'ui/sandbox_setup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.I.initialize();
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  Aether.dark = !AppState.I.lightTheme;
  // Firebase is optional: if google-services.json isn't injected (local debug),
  // FirebaseService degrades to offline no-ops and the app still runs.
  await FirebaseService.I.initialize();
  // Sandbox installs on FIRST LAUNCH (blocking) — the user never has to
  // tap Studio to trigger it. Later launches check the disk and skip.
  final sandboxReady = await SandboxService.I.checkExisting();
  AppState.I.sandboxInstalled = sandboxReady;
  runApp(OvidApp(sandboxReady: sandboxReady));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(GitHubService.I.initialize());
    // Pre-warm the browser only after the sandbox gate is satisfied (the
    // setup screen replaces the shell until install completes).
    if (sandboxReady) unawaited(AgentService.I.prewarmBrowser());
  });
}

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
          ? const _Shell()
          : const _FirstLaunchSetupGate(),
    );
  }
}

/// Full-screen gate shown ONLY on first launch when the sandbox is not
/// yet installed.  Runs the real SandboxService.install (payload extract
/// → chmod → symlinks → config → bash sanity → Node.js → Python) and
/// then replaces itself with the chat _Shell.  Non-dismissible — the
/// sandbox is required for all agent features (MCP, code execution, etc.).
class _FirstLaunchSetupGate extends StatelessWidget {
  const _FirstLaunchSetupGate();
  @override
  Widget build(BuildContext context) {
    return const SandboxSetupScreen(gateMode: true);
  }
}

/// Chat-first shell, DeepSeek-web style. The chat IS the app; everything
/// else (Studio, Browser, Plugins, Settings) lives behind icons/drawer.
class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  void initState() {
    super.initState();
    // Ask for telemetry consent once (Play policy) after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskConsent());
  }

  void _maybeAskConsent() {
    final fb = FirebaseService.I;
    if (!fb.isAvailable || fb.consentAsked || !mounted) return;
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text(
          'Help improve Ovid AI?',
          style: TextStyle(fontSize: 16),
        ),
        content: const Text(
          'Share anonymous crash reports and usage stats (Firebase Crashlytics & Analytics) to help fix bugs faster. '
          'This is optional and off unless you allow it. See our privacy policy for details.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () {
              fb.setConsent(false);
              Navigator.pop(d);
            },
            child: const Text('No thanks'),
          ),
          FilledButton(
            onPressed: () {
              fb.setConsent(true);
              Navigator.pop(d);
            },
            child: const Text('Allow'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 840;
    final chat = const ChatScreen();

    return Scaffold(
      drawer: wide
          ? null
          : Drawer(
              width: 288,
              backgroundColor: Aether.surface,
              child: SessionsSidebar(),
            ),
      body: wide
          ? Row(
              children: [
                const SessionsSidebar(),
                const VerticalDivider(width: 1),
                Expanded(child: chat),
              ],
            )
          : chat,
    );
  }
}
