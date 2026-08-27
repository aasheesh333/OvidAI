import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'ui/sidebar.dart';
import 'ui/chat_screen.dart';

void main() => runApp(const OvidApp());

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
class _Shell extends StatelessWidget {
  const _Shell();

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
          ? Row(children: [
              const SessionsSidebar(),
              const VerticalDivider(width: 1),
              Expanded(child: chat),
            ])
          : chat,
    );
  }
}
