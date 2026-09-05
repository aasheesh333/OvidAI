import 'dart:async';

import 'package:flutter/material.dart';
import 'core/agent_service.dart';
import 'core/agent_notification_service.dart';
import 'core/firebase_service.dart';
import 'core/github_service.dart';
import 'core/hook_service.dart';
import 'core/mcp_service.dart';
import 'core/sandbox_service.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'ui/sidebar.dart';
import 'ui/chat_screen.dart';
import 'ui/sandbox_setup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.I.initialize();
  // PR24: plugin-hook kill-switch restore (Settings toggle).
  await HookService.I.loadEnabled();
  // Apply persisted theme BEFORE first frame (no dark flash on light).
  Aether.dark = !AppState.I.lightTheme;
  // Firebase is optional: if google-services.json isn't injected (local debug),
  // FirebaseService degrades to offline no-ops and the app still runs.
  await FirebaseService.I.initialize();
  // PR32: checkExisting is now FAST (file-exists + config writes only —
  // no bash). The PR22 self-heal moved OUT of the boot path: awaiting it
  // here kept runApp blocked on multi-minute find+sed passes → the
  // reported "black screen on every app open". It runs post-frame below.
      final sandboxReady = await SandboxService.I.checkExisting();
      AppState.I.sandboxInstalled = sandboxReady;
      // A device that can't run the sandbox (Android 6, exec-blocked ROM)
      // must not trap the user on the install gate — chat works without
      // it. Post-frame hooks below still key off the REAL disk state.
      runApp(
        OvidApp(sandboxReady: sandboxReady || AppState.I.sandboxSkipped),
      );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(GitHubService.I.initialize());
    // PR32: background self-heal (usr symlink, shebangs, exec bits, libz)
    // — AFTER first paint, never blocking it.
    if (sandboxReady) unawaited(SandboxService.I.selfHealInBackground());
    // Pre-warm the browser only after the sandbox gate is satisfied (the
    // setup screen replaces the shell until install completes).
    if (sandboxReady) unawaited(AgentService.I.prewarmBrowser());
    // Self-heal runtime tools: if the sandbox is present but node/python/
    // git/curl are missing (e.g. an earlier launch failed halfway through
    // the runtime install), re-run the runtime installer in the
    // background. Logged in Settings → Device health.
    if (sandboxReady) {
      unawaited(() async {
        if (!await SandboxService.I.runtimesVerified()) {
          await SandboxService.I.installCoreRuntimes((_, _, _) {});
        }
      }());
    }
    // Storage-quota housekeeping (DSH Part 5): orphaned ws_* dirs from
    // deleted sessions are swept; over-quota workspaces LRU-evict with a
    // 30-day grace window. Never blocks first paint.
    unawaited(
      SandboxService.I.enforceWorkspaceQuota(
        activeSandboxIds: AppState.I.sessions
            .map((s) => s.sandboxId)
            .whereType<String>()
            .toSet(),
      ),
    );
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

class _ShellState extends State<_Shell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Foreground-notification wiring (agent keep-alive): registers the
    // notification Stop-button handler.
    unawaited(AgentNotificationService.I.init());
    // Ask for telemetry consent once (Play policy) after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskConsent());
    // First-run welcome notice (DSH ui-onboarding welcomeNoticeVersion):
    // one dialog per version, after the consent dialog settles.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
    // MCP auto-reconnect: respawn servers the user had connected.
    unawaited(AppState.I.reconnectMcpServers());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ── App lifecycle → MCP lifecycle (DSH tier-2 parity) ──
    // resume  → respawn every server the user wants connected
    // NOTE: `paused` intentionally does NOTHING to MCP — tearing MCP down on
    // background KILLED in-flight mcp__ tool calls mid-run. The foreground
    // service keeps the process + Dart alive while backgrounded.
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(AppState.I.reconnectMcpServers());
        // PR32: a run that survived the background must keep its
        // notification (some OEMs drop it on pause).
        if (AgentService.I.anyRunActive) {
          AgentNotificationService.I.agentWorking('resumed — task running…');
        }
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // PR32 keep-alive: while ANY agent run is active, make sure the
        // foreground service is up BEFORE Android can freeze the isolate.
        // (It normally starts at runTask; this covers races + OEM killers.)
        if (AgentService.I.anyRunActive) {
          AgentNotificationService.I.agentWorking('working in background…');
        }
        break;
      case AppLifecycleState.detached:
        unawaited(McpService.I.disconnectAll());
        break;
    }
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

  /// First-run welcome notice (DSH ui-onboarding welcomeNoticeVersion
  /// parity): shown once per [AppState.welcomeVersion], skipped while the
  /// telemetry consent dialog is still pending so the two never stack.
  void _maybeWelcome() {
    final app = AppState.I;
    if (!mounted || app.welcomeSeen) return;
    if (FirebaseService.I.isAvailable && !FirebaseService.I.consentAsked) {
      // Consent dialog owns this frame — retry next frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
      return;
    }
    showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Welcome to Ovid AI',
            style: TextStyle(fontSize: 16)),
        content: const Text(
          'An on-device coding agent: chat, run real Linux commands in the '
          'sandbox, browse the web, and sync with GitHub. '
          'Keys stay on your device. Open Settings any time to tune providers, '
          'reply language, and privacy.',
          style: TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          FilledButton(
            onPressed: () {
              app.markWelcomeSeen();
              Navigator.pop(d);
            },
            child: const Text("Let's go"),
          ),
        ],
      ),
    );
  }
}
