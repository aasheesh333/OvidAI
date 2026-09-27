import 'dart:async';

import 'package:flutter/material.dart';

import '../core/agent_notification_service.dart';
import '../core/agent_service.dart';
import '../core/device_control_service.dart';
import '../core/github_service.dart';
import '../core/firebase_service.dart';
import '../core/mcp_service.dart';
import '../core/startup_coordinator.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chat_screen.dart';
import 'sidebar.dart';

/// Shown when the debounced session write has failed, i.e. chat history is
/// no longer being persisted. Deliberately non-dismissible: the condition
/// clears on its own as soon as a write succeeds again.
class _PersistWarningBanner extends StatelessWidget {
  const _PersistWarningBanner();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Aether.danger.withValues(alpha: 0.16),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 16, color: Aether.danger),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "Chat history isn't being saved — free up storage and "
                "restart Ovid to protect this conversation.",
                style: TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
  /// DURABILITY WARNING (2026-09-27): [AppState.lastSessionPersistFailed]
  /// was written on a failed session write but never read by anything, so
  /// chat history could silently stop being saved. This polls the flag and
  /// surfaces a persistent banner instead of failing invisibly.
  Timer? _persistWarnTimer;
  bool _persistWarned = false;

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
    // Studio first-open owns the sandbox install now (mandatory full
    // install incl. Node.js/Python via openStudio). The shell still kicks
    // the background job below, but it is verify-only unless the user
    // explicitly retries — it never apt-updates at startup anymore.
    // Idempotent — cheap disk probes no-op when the runtimes are present.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(AppState.I.maybeStartBackgroundRuntimeInstall()),
    );
    // Durability watchdog: a few seconds is enough for the debounced
    // session write to land, so a genuine failure shows up promptly.
    _persistWarnTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      final failed = AppState.I.lastSessionPersistFailed;
      if (failed != _persistWarned && mounted) {
        setState(() => _persistWarned = failed);
      }
    });
  }

  void _onFirebaseReady() {
    if (FirebaseService.I.isAvailable) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAskConsent());
    }
  }

  @override
  void dispose() {
    _persistWarnTimer?.cancel();
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
        // If Ovid's accessibility service is enabled in Settings but the
        // OS has not rebound it (app restart), absorb the rebind window
        // now (pure wait — no programmatic toggle, which could disable the
        // service in Settings) so control mode works without a manual
        // off/on toggle.
        unawaited(DeviceControlService.I.refreshServiceBinding());
        // A secure-storage read that FAILED at cold start is not a sign-out:
        // the token is still on disk and usually readable moments later. Retry
        // it here so Studio does not sit "logged out" for the whole launch.
        unawaited(GitHubService.I.retryRestoreFromUi());
        // Control overlay is visible only while backgrounded.
        unawaited(AgentService.I.setAppForegrounded(true));
        // PR32: a run that survived the background must keep its
        // notification (some OEMs drop it on pause).
        if (AgentService.I.anyRunActive) {
          AgentNotificationService.I.agentWorking('resumed — task running…');
        }
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // A pending coalesced session write must land before Android can
        // freeze the isolate (spec §5.4: flush on lifecycle pause).
        unawaited(AppState.I.flushSessionPersistence());
        // Control overlay appears only once the app is backgrounded.
        unawaited(AgentService.I.setAppForegrounded(false));
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
      body: Column(
        children: [
          if (_persistWarned) const _PersistWarningBanner(),
          Expanded(
            child: wide
                ? Row(
                    children: [
                      const SessionsSidebar(isDrawer: false),
                      const VerticalDivider(width: 1),
                      Expanded(child: chat),
                    ],
                  )
                : chat,
          ),
        ],
      ),
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
