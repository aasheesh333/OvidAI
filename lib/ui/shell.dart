import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_notification_service.dart';
import '../core/agent_service.dart';
import '../core/firebase_service.dart';
import '../core/mcp_service.dart';
import '../core/startup_coordinator.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chat_screen.dart';
import 'sidebar.dart';

/// Chat-first shell, DeepSeek-web style. The chat IS the app; everything
/// else (Studio, Browser, Plugins, Settings) lives behind icons/drawer.
///
/// Extracted from `main.dart` so the first-launch setup gate and the app
/// entry point share one shell. An optional [startupCoordinator] is threaded
/// to the chat screen so the startup dashboard can be exercised in isolation.
class OvidShell extends StatefulWidget {
  const OvidShell({super.key, this.startupCoordinator});

  final StartupCoordinator? startupCoordinator;

  @override
  State<OvidShell> createState() => _OvidShellState();
}

class _OvidShellState extends State<OvidShell> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Foreground-notification wiring (agent keep-alive): registers the
    // notification Stop-button handler.
    unawaited(AgentNotificationService.I.init());
    FirebaseService.I.addListener(_onFirebaseReady);
    // Ask for telemetry consent once (Play policy) after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskConsent());
    // First-run welcome notice (the onboarding flow welcomeNoticeVersion):
    // one dialog per version, after the consent dialog settles.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeWelcome());
  }

  void _onFirebaseReady() {
    if (FirebaseService.I.isAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskConsent());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FirebaseService.I.removeListener(_onFirebaseReady);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ── App lifecycle → MCP/plugin lifecycle (the lifecycle coordinator tier-2 parity) ──
    // resume  → respawn every service the user wants connected
    // NOTE: `paused` intentionally does NOTHING to MCP — tearing MCP down on
    // background KILLED in-flight mcp__ tool calls mid-run. The foreground
    // service keeps the process + Dart alive while backgrounded.
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(AppState.I.reconnectServicesAfterResume());
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
        // App detached from engine/activity; cleanup MCP without corrupting persisted runs.
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
    final chat = ChatScreen(startupCoordinator: widget.startupCoordinator);

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

  /// First-run welcome notice (the onboarding flow welcomeNoticeVersion
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
        title: const Text('Welcome to Ovid AI', style: TextStyle(fontSize: 16)),
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
