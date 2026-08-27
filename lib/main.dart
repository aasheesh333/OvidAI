import 'dart:async';

import 'package:flutter/material.dart';
import 'core/firebase_service.dart';
import 'core/github_service.dart';
import 'core/state.dart';
import 'core/theme.dart';
import 'ui/sidebar.dart';
import 'ui/chat_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.I.initialize();
  // Firebase is optional: if google-services.json isn't injected (local debug),
  // FirebaseService degrades to offline no-ops and the app still runs.
  await FirebaseService.I.initialize();
  runApp(const OvidApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(GitHubService.I.initialize());
  });
}

class OvidApp extends StatelessWidget {
  const OvidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ovid',
      debugShowCheckedModeBanner: false,
      theme: Aether.theme(),
      home: const _Shell(),
    );
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
          : const Drawer(
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
