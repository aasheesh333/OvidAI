import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'core/state.dart';
import 'ui/sidebar.dart';
import 'ui/chat_screen.dart';
import 'ui/studio_screen.dart';
import 'ui/plugins_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/browser_screen.dart';

void main() => runApp(const OvidApp());

class OvidApp extends StatelessWidget {
  const OvidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OvidAI',
      debugShowCheckedModeBanner: false,
      theme: Aether.theme(),
      home: const _Shell(),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, __) {
        final screen = switch (app.navIndex) {
          1 => const StudioScreen(),
          2 => const BrowserScreen(),
          3 => const PluginsScreen(),
          4 => const SettingsScreen(),
          _ => const ChatScreen(),
        };
        final wide = MediaQuery.of(context).size.width >= 840;

        final body = wide
            ? Row(children: [
                const SessionsSidebar(),
                const VerticalDivider(width: 1),
                Expanded(child: screen),
              ])
            : screen;

        return Scaffold(
          drawer: wide ? null : const Drawer(
            width: 288,
            backgroundColor: Aether.surface,
            child: SessionsSidebar(),
          ),
          body: body,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  height: 62,
                  backgroundColor: Aether.surface,
                  indicatorColor: Aether.accentSoft,
                  selectedIndex: app.navIndex > 4 ? 0 : app.navIndex,
                  onDestinationSelected: app.setNav,
                  destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.chat_bubble_outline, size: 20),
                        selectedIcon:
                            Icon(Icons.chat_bubble, size: 20, color: Aether.accent),
                        label: 'Chat'),
                    NavigationDestination(
                        icon: Icon(Icons.code, size: 20),
                        selectedIcon:
                            Icon(Icons.code, size: 20, color: Aether.accent),
                        label: 'Studio'),
                    NavigationDestination(
                        icon: Icon(Icons.public, size: 20),
                        selectedIcon:
                            Icon(Icons.public, size: 20, color: Aether.accent),
                        label: 'Browser'),
                    NavigationDestination(
                        icon: Icon(Icons.extension_outlined, size: 20),
                        selectedIcon: Icon(Icons.extension,
                            size: 20, color: Aether.accent),
                        label: 'Plugins'),
                    NavigationDestination(
                        icon: Icon(Icons.settings_outlined, size: 20),
                        selectedIcon: Icon(Icons.settings,
                            size: 20, color: Aether.accent),
                        label: 'Settings'),
                  ],
                ),
        );
      },
    );
  }
}
