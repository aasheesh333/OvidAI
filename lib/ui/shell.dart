import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/cloud_session_store.dart';
import '../core/cloud/cloud_ws.dart';
import '../core/connection_service.dart';
import '../core/github_service.dart';
import '../core/firebase_service.dart';
import '../core/mcp_service.dart';
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
      child: Padding(
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

/// Thin app-wide "You're offline" strip. Phones only saw connectivity
/// inside the drawer (and not at all in compact large-text mode); this sits
/// above every screen while the last probe failed, with a Retry that
/// re-probes immediately.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ConnectionService.I;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (!c.offline) return const SizedBox.shrink();
        final checking = c.status == ConnectionStatus.checking;
        return SafeArea(
          bottom: false,
          child: Semantics(
            liveRegion: true,
            child: Material(
              key: const ValueKey('offline-banner'),
              color: Aether.warnLight.withValues(alpha: 0.16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 16,
                      color: Aether.warnLight,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "You're offline — messages can't be sent until the "
                        'connection is back.',
                        style: TextStyle(fontSize: 12, height: 1.3),
                      ),
                    ),
                    TextButton(
                      onPressed: checking ? null : c.probe,
                      child: Text(checking ? 'Checking…' : 'Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Shows the one-time telemetry consent dialog (Play policy).
///
/// Every `FirebaseService` notification during startup used to call the
/// prompt again, and nothing guarded an already-open dialog, so two or three
/// copies could stack. The dialog was also barrier/back-dismissible while a
/// dismissal recorded nothing, so it came back on every launch. This shows
/// at most one dialog, stops listening once it has been shown, and only an
/// explicit choice closes it.
class TelemetryConsentPrompter {
  TelemetryConsentPrompter({
    required this.source,
    required this.isAvailable,
    required this.consentAsked,
    required this.setConsent,
  });

  /// Production wiring against [FirebaseService.I].
  factory TelemetryConsentPrompter.firebase() {
    final fb = FirebaseService.I;
    return TelemetryConsentPrompter(
      source: fb,
      isAvailable: () => fb.isAvailable,
      consentAsked: () => fb.consentAsked,
      setConsent: fb.setConsent,
    );
  }

  final Listenable source;
  final bool Function() isAvailable;
  final bool Function() consentAsked;
  final Future<void> Function(bool allow) setConsent;

  BuildContext Function()? _context;
  bool _listening = false;
  bool _showing = false;
  bool _shown = false;

  /// Starts watching [source]; asks after the first frame and whenever the
  /// source becomes available, until the dialog has been shown once.
  void attach(BuildContext Function() context) {
    _context = context;
    if (!_listening) {
      source.addListener(_onSourceChanged);
      _listening = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeAsk());
  }

  void detach() {
    _stopListening();
    _context = null;
  }

  void _stopListening() {
    if (!_listening) return;
    source.removeListener(_onSourceChanged);
    _listening = false;
  }

  void _onSourceChanged() {
    if (!isAvailable()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeAsk());
  }

  void maybeAsk() {
    final context = _context?.call();
    if (_showing || _shown || context == null || !context.mounted) return;
    if (!isAvailable()) return;
    if (consentAsked()) {
      _stopListening();
      return;
    }
    _showing = true;
    _shown = true;
    _stopListening();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (d) => PopScope(
        canPop: false,
        child: AlertDialog(
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
                setConsent(false);
                Navigator.pop(d);
              },
              child: const Text('No thanks'),
            ),
            FilledButton(
              onPressed: () {
                setConsent(true);
                Navigator.pop(d);
              },
              child: const Text('Allow'),
            ),
          ],
        ),
      ),
    ).whenComplete(() => _showing = false);
  }
}

/// Chat-first shell, DeepSeek-web style. The chat IS the app; everything
/// else (Studio, Browser, Plugins, Settings) lives behind icons/drawer.
///
/// Extracted from `main.dart` so the first-launch setup gate and the app
/// entry point share one shell.
class OvidShell extends StatefulWidget {
  const OvidShell({super.key});

  @override
  State<OvidShell> createState() => _OvidShellState();
}

class _OvidShellState extends State<OvidShell> with WidgetsBindingObserver {
  /// DURABILITY WARNING (2026-09-27): [AppState.lastSessionPersistFailed]
  /// was written on a failed session write but never read by anything, so
  /// chat history could silently stop being saved. This watches the flag
  /// (every write outcome that flips it notifies [AppState]) and surfaces a
  /// persistent banner instead of failing invisibly. It used to poll every
  /// 3 s for the app's whole lifetime.
  late final AppState _persistApp = AppState.I;
  bool _persistWarned = false;
  final _consent = TelemetryConsentPrompter.firebase();

  void _onPersistStateChanged() {
    final failed = _persistApp.lastSessionPersistFailed;
    if (failed != _persistWarned && mounted) {
      setState(() => _persistWarned = failed);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Ask for telemetry consent once (Play policy) after first frame.
    _consent.attach(() => context);
    // First-run welcome notice moved to LoginGate (post-login overlay).
    // Durability watchdog.
    _persistApp.addListener(_onPersistStateChanged);
    _persistWarned = _persistApp.lastSessionPersistFailed;
  }

  @override
  void dispose() {
    _persistApp.removeListener(_onPersistStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    _consent.detach();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ── Lifecycle inversion (thin client) ───────────────────────────────
    // Runs execute detached on the cloud gateway. The device only owns its
    // UI and local caches: resume re-attaches the WS link and drains the
    // outbox; backgrounding persists state; detaching tears the link down.
    // NOTHING here keeps the process alive.
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(WsMultiplexer.I.connectIfNeeded());
        unawaited(ConnectionService.I.probe());
        unawaited(CloudSessionStore.I.flushOutbox());
        // MCP/plugin services are local until Task 17; keep respawning them.
        unawaited(AppState.I.reconnectServicesAfterResume());
        // A secure-storage read that FAILED at cold start is not a sign-out:
        // the token is still on disk and usually readable moments later. Retry
        // it here so Studio does not sit "logged out" for the whole launch.
        unawaited(GitHubService.I.retryRestoreFromUi());
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // A pending coalesced session write must land before Android can
        // freeze the isolate (spec §5.4: flush on lifecycle pause).
        unawaited(AppState.I.flushSessionPersistence());
        break;
      case AppLifecycleState.detached:
        // App detached from engine/activity; cleanup MCP without corrupting
        // persisted runs, and close the cloud link (resume reconnects).
        unawaited(McpService.I.disconnectAll());
        unawaited(WsMultiplexer.I.disconnect());
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final chat = const ChatScreen();

    return Scaffold(
      backgroundColor: Aether.bg,
      // The inner chat Scaffold owns keyboard avoidance. Resizing both shells
      // subtracts the same inset twice and crowds out the composer.
      resizeToAvoidBottomInset: false,
      // Re-check connectivity whenever the drawer (with its status chip)
      // opens, as the chip has always promised.
      onDrawerChanged: (open) {
        if (open) unawaited(ConnectionService.I.probe());
      },
      drawer: wide
          ? null
          : Drawer(
              width: 288,
              backgroundColor: Aether.surface,
              child: SessionsSidebar(),
            ),
      body: Column(
        children: [
          const OfflineBanner(),
          if (_persistWarned)
            SafeArea(
              bottom: false,
              child: Semantics(
                liveRegion: true,
                child: _PersistWarningBanner(),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                if (wide) ...[
                  const SessionsSidebar(isDrawer: false),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Aether.hairline,
                  ),
                ],
                Expanded(
                  child: KeyedSubtree(
                    key: const ValueKey('shell-chat-screen'),
                    child: chat,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

}
