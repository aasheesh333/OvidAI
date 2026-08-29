import 'package:flutter/material.dart';
import '../core/firebase_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'auth_screen.dart';
import 'providers_screen.dart';
import 'plugins_screen.dart';
import 'usage_screen.dart';

/// Settings hub — DeepSeek/kimi-k3 web style. Providers & Plugins are
/// dedicated screens behind rows; everything else grouped below.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Profile header → Account (optional Firebase sign-in)
          InkWell(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: AnimatedBuilder(
                animation: FirebaseService.I,
                builder: (_, _) {
                  final fb = FirebaseService.I;
                  final signedIn = fb.isSignedIn;
                  return Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: Aether.surfaceRaised,
                        child: Icon(
                          signedIn ? Icons.person : Icons.person_outline,
                          size: 22,
                          color: Aether.textMuted,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            signedIn
                                ? (fb.displayName ?? fb.email ?? 'You')
                                : 'You',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            signedIn
                                ? (fb.email ?? 'Signed in')
                                : 'Local account · keys stay on device',
                            style: TextStyle(
                              fontSize: 12,
                              color: Aether.textFaint,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        signedIn ? 'Signed in' : 'Sign in',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Aether.accent,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Aether.textFaint,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          const SectionHeader('Workspace'),
          _navTile(
            context,
            Icons.key_outlined,
            'Providers',
            'BYOK · free & custom providers',
            const ProvidersScreen(),
          ),
          _navTile(
            context,
            Icons.extension_outlined,
            'Plugins',
            'Agents, MCP servers, tools',
            const PluginsScreen(),
          ),

          const SectionHeader('Workspace stats'),
          _navTile(
            context,
            Icons.bar_chart_rounded,
            'Usage',
            'Per-client spend · OvidAI, OpenCode, Claude Code, Z Code',
            const UsageScreen(),
          ),

          const SectionHeader('Personalization'),
          _switchTile(
            Icons.tune,
            'Custom instructions',
            'How the AI should respond',
            true,
          ),
          _switchTile(
            Icons.psychology_outlined,
            'Memory',
            'Remember preferences across chats',
            true,
          ),
          _switchTile(
            Icons.auto_awesome,
            'Reasoning mode',
            'Show thinking before answers',
            false,
          ),

          const SectionHeader('Chat'),
          _settingTile(Icons.dark_mode_outlined, 'Appearance', 'Dark (hacker)'),
          _settingTile(Icons.translate, 'Language', 'English'),
          _settingTile(
            Icons.image_outlined,
            'Image generation',
            'Auto · up to 1024px',
          ),
          _settingTile(Icons.mic_none, 'Voice input', 'On'),

          const SectionHeader('Agents & Sandbox'),
          _navTile(
            context,
            Icons.timer_outlined,
            'AI response timeout',
            'How long the agent may stream. Lower = snappier, higher = no cutoff of long answers.',
            const _TimeoutScreen(),
          ),
          const _ShareMemoryTile(),
          _settingTile(
            Icons.smart_toy_outlined,
            'Default agent',
            'Auto-select by task',
          ),
          _settingTile(
            Icons.public,
            'In-app browser',
            'Agent can browse & log in (ask me)',
          ),
          _switchTile(
            Icons.folder_shared_outlined,
            'GitHub sync',
            'AI edits push to your connected repo',
            true,
          ),
          _switchTile(
            Icons.flash_on,
            'Auto-run safe commands',
            'No confirm for read-only terminal commands',
            true,
          ),
          _settingTile(
            Icons.security_outlined,
            'Sandbox',
            'Ready · isolated on-device',
          ),

          const SectionHeader('Data controls'),
          _settingTile(
            Icons.download_outlined,
            'Export chats',
            'Download all sessions as JSON',
          ),
          _settingTile(
            Icons.delete_outline,
            'Delete all data',
            'Chats, keys and settings · irreversible',
          ),
          _settingTile(
            Icons.storage_outlined,
            'Storage',
            '214 MB · on-device only',
          ),

          const SectionHeader('Privacy'),
          _TelemetryTile(),
          _privacyPolicyTile(context),

          const SectionHeader('General'),
          const _ThemeToggle(),
          _settingTile(Icons.notifications_outlined, 'Notifications', 'On'),
          _settingTile(Icons.info_outline, 'About', 'Ovid AI 0.1.0-demo'),
        ],
      ),
    );
  }

  Widget _navTile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Widget screen,
  ) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(
        Icons.chevron_right,
        size: 18,
        color: Aether.textFaint,
      ),
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
    );
  }

  Widget _switchTile(
    IconData icon,
    String title,
    String subtitle,
    bool initial,
  ) {
    return _SwitchTile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      initial: initial,
    );
  }

  Widget _settingTile(IconData icon, String title, String trailing) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      trailing: Text(
        trailing,
        style: TextStyle(fontSize: 12, color: Aether.textFaint),
      ),
      onTap: () {},
    );
  }

  Widget _privacyPolicyTile(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.privacy_tip_outlined,
        size: 19,
        color: Aether.textMuted,
      ),
      title: const Text('Privacy policy', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        'dhanuk.page.gd/ovid',
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(
        Icons.open_in_new,
        size: 16,
        color: Aether.textFaint,
      ),
      onTap: () => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Privacy policy', style: TextStyle(fontSize: 15)),
          content: const Text(
            'View the Ovid AI privacy policy at:\n\nhttps://dhanuk.page.gd/ovid/\n\n'
            'It covers Firebase sign-in, optional crash reports & analytics, and how your API keys stay encrypted on-device.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Telemetry consent toggle bound to FirebaseService.
class _TelemetryTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: FirebaseService.I,
      builder: (_, _) {
        final fb = FirebaseService.I;
        return SwitchListTile(
          dense: true,
          secondary: Icon(
            Icons.insights_outlined,
            size: 19,
            color: Aether.textMuted,
          ),
          title: const Text(
            'Crash reports & analytics',
            style: TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            fb.isAvailable
                ? 'Optional · anonymous · helps fix bugs'
                : 'Not configured in this build',
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          activeTrackColor: Aether.accent,
          value: fb.consentGiven,
          onChanged: fb.isAvailable ? (x) => fb.setConsent(x) : null,
        );
      },
    );
  }
}

class _SwitchTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool initial;
  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.initial,
  });
  @override
  State<_SwitchTile> createState() => _SwitchTileState();
}

class _SwitchTileState extends State<_SwitchTile> {
  late bool v = widget.initial;
  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(widget.icon, size: 19, color: Aether.textMuted),
      title: Text(widget.title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        widget.subtitle,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: SizedBox(
        height: 26,
        child: Switch(
          value: v,
          activeTrackColor: Aether.accent,
          onChanged: (x) => setState(() => v = x),
        ),
      ),
      onTap: () => setState(() => v = !v),
    );
  }
}

/// Share-session-memory toggle — real, persisted in AppState. OFF by default
/// so each chat session stays isolated (its own sandbox workspace + memory).
/// ON lets the AI search across every chat via the memory_search tool.
class _ShareMemoryTile extends StatelessWidget {
  const _ShareMemoryTile();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) => ListTile(
        dense: true,
        leading: Icon(Icons.psychology_outlined,
            size: 19, color: Aether.textMuted),
        title: const Text('Share session memory', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          app.shareSessionMemory
              ? 'ON — the AI can search across all chats (memory_search).'
              : 'OFF — every chat is isolated; the AI sees only this session.',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        trailing: SizedBox(
          height: 26,
          child: Switch(
            value: app.shareSessionMemory,
            activeTrackColor: Aether.accent,
            onChanged: (v) => app.setShareSessionMemory(v),
          ),
        ),
        onTap: () => app.setShareSessionMemory(!app.shareSessionMemory),
      ),
    );
  }
}

/// AI response timeout picker — real, persisted in AppState (responseTimeoutSec).
/// Light/dark theme toggle — flips Aether palette app-wide, persisted.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) => SwitchListTile(
        dense: true,
        secondary: Icon(
          Icons.light_mode_outlined,
          size: 19,
          color: Aether.textMuted,
        ),
        title: const Text('Light theme', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          app.lightTheme ? 'ON — bright surfaces' : 'OFF — dark (default)',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        value: app.lightTheme,
        activeTrackColor: Aether.accent,
        onChanged: (v) => app.setLightTheme(v),
      ),
    );
  }
}

class _TimeoutScreen extends StatelessWidget {
  const _TimeoutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('AI response timeout'),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (_, _) {
          final cur = AppState.I.responseTimeoutSec;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'How long the agent may stream before being cut off. '
                'Long reasoning chains need a generous budget; casual chat '
                'feels snappier with a short one.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              RadioGroup<int>(
                groupValue: cur,
                onChanged: (v) {
                  if (v != null) AppState.I.setResponseTimeout(v);
                },
                child: Column(
                  children: [
                    for (final sec in AppState.timeoutPresets)
                      RadioListTile<int>(
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          sec < 60 ? '$sec seconds' : '${sec ~/ 60} minute${sec > 60 ? 's' : ''}',
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          switch (sec) {
                            60 => 'Quick answers',
                            120 => 'Default — balanced',
                            300 => 'Long tasks, web research',
                            _ => 'Heavy multi-tool runs',
                          },
                          style: TextStyle(
                            fontSize: 11,
                            color: Aether.textFaint,
                          ),
                        ),
                        value: sec,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Custom values: pick any number of seconds between 5 s and 60 min.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              Slider(
                value: cur.toDouble().clamp(5.0, 3600.0),
                min: 5,
                max: 3600,
                divisions: 71,
                activeColor: Aether.accent,
                inactiveColor: Aether.surfaceAlt,
                label: '${cur}s',
                onChanged: (v) => AppState.I.setResponseTimeout(v.round()),
              ),
            ],
          );
        },
      ),
    );
  }
}
