import 'package:flutter/material.dart';
import '../core/theme.dart';
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
          // Profile header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Row(children: [
              const CircleAvatar(
                radius: 22,
                backgroundColor: Aether.surfaceRaised,
                child: Icon(Icons.person_outline,
                    size: 22, color: Aether.textMuted),
              ),
              const SizedBox(width: 14),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You',
                      style: TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w700)),
                  SizedBox(height: 2),
                  Text('Local account · keys stay on device',
                      style: TextStyle(
                          fontSize: 12, color: Aether.textFaint)),
                ],
              ),
              const Spacer(),
              const Icon(Icons.chevron_right,
                  size: 18, color: Aether.textFaint),
            ]),
          ),

          const SectionHeader('Workspace'),
          _navTile(context, Icons.key_outlined, 'Providers',
              'BYOK · free & custom providers', const ProvidersScreen()),
          _navTile(context, Icons.extension_outlined, 'Plugins',
              'Agents, MCP servers, tools', const PluginsScreen()),

          const SectionHeader('Workspace stats'),
          _navTile(context, Icons.bar_chart_rounded, 'Usage',
              'Per-client spend · OvidAI, OpenCode, Claude Code, Z Code',
              const UsageScreen()),

          const SectionHeader('Personalization'),
          _switchTile(Icons.tune, 'Custom instructions',
              'How the AI should respond', true),
          _switchTile(Icons.psychology_outlined, 'Memory',
              'Remember preferences across chats', true),
          _switchTile(Icons.auto_awesome, 'Reasoning mode',
              'Show thinking before answers', false),

          const SectionHeader('Chat'),
          _settingTile(Icons.dark_mode_outlined, 'Appearance',
              'Dark (hacker)'),
          _settingTile(Icons.translate, 'Language', 'English'),
          _settingTile(Icons.image_outlined, 'Image generation',
              'Auto · up to 1024px'),
          _settingTile(Icons.mic_none, 'Voice input', 'On'),

          const SectionHeader('Agents & Sandbox'),
          _settingTile(Icons.smart_toy_outlined, 'Default agent',
              'Auto-select by task'),
          _settingTile(Icons.public, 'In-app browser',
              'Agent can browse & log in (ask me)'),
          _switchTile(Icons.folder_shared_outlined, 'GitHub sync',
              'AI edits push to your connected repo', true),
          _switchTile(Icons.flash_on, 'Auto-run safe commands',
              'No confirm for read-only terminal commands', true),
          _settingTile(Icons.security_outlined, 'Sandbox',
              'Ready · isolated on-device'),

          const SectionHeader('Data controls'),
          _settingTile(Icons.download_outlined, 'Export chats',
              'Download all sessions as JSON'),
          _settingTile(Icons.delete_outline, 'Delete all data',
              'Chats, keys and settings · irreversible'),
          _settingTile(Icons.storage_outlined, 'Storage',
              '214 MB · on-device only'),

          const SectionHeader('General'),
          _settingTile(Icons.notifications_outlined, 'Notifications',
              'On'),
          _settingTile(Icons.info_outline, 'About', 'Ovid AI 0.1.0-demo'),
        ],
      ),
    );
  }

  Widget _navTile(BuildContext context, IconData icon, String title,
      String subtitle, Widget screen) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle,
          style:
              const TextStyle(fontSize: 11.5, color: Aether.textFaint)),
      trailing: const Icon(Icons.chevron_right,
          size: 18, color: Aether.textFaint),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => screen)),
    );
  }

  Widget _switchTile(
      IconData icon, String title, String subtitle, bool initial) {
    return _SwitchTile(
        icon: icon, title: title, subtitle: subtitle, initial: initial);
  }

  Widget _settingTile(IconData icon, String title, String trailing) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      trailing: Text(trailing,
          style:
              const TextStyle(fontSize: 12, color: Aether.textFaint)),
      onTap: () {},
    );
  }
}

class _SwitchTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool initial;
  const _SwitchTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.initial});
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
      subtitle: Text(widget.subtitle,
          style:
              const TextStyle(fontSize: 11.5, color: Aether.textFaint)),
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
