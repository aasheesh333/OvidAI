import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'providers_screen.dart';
import 'plugins_screen.dart';

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

          const SectionHeader(
            'Usage',
            subtitle: 'Per-model activity and estimated spend',
          ),
          const _UsageCard(),

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
          _settingTile(Icons.info_outline, 'About', 'OvidAI 0.1.0-demo'),
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

class _UsageCard extends StatelessWidget {
  const _UsageCard();

  static const rows = [
    ('claude-sonnet-4-6', '412', '1.2M in', '6.8M out', r'$11.42'),
    ('deepseek-chat', '380', '0.9M in', '4.1M out', r'$0.87'),
    ('gpt-5.2', '96', '0.4M in', '1.9M out', r'$7.05'),
    ('gemini-2.5-flash', '610', '2.4M in', '9.6M out', r'$0.00'),
    ('deepseek-reasoner', '44', '0.3M in', '2.2M out', r'$1.31'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const Expanded(
                flex: 5,
                child: Text('MODEL',
                    style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: Aether.textFaint))),
            _h('REQ'),
            _h('TOKENS'),
            _h('COST'),
          ]),
        ),
        for (final r in rows) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(children: [
              Expanded(
                  flex: 5,
                  child: Text(r.$1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: Aether.mono,
                          color: Aether.text))),
              _v(r.$2, width: 40),
              _v('${r.$3} · ${r.$4}', width: 108),
              _v(r.$5, width: 52, cost: true),
            ]),
          ),
        ],
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Expanded(
                child: Text('This month (demo data)',
                    style: TextStyle(
                        fontSize: 11, color: Aether.textFaint))),
            Text(r'$20.65 total',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Aether.text)),
          ]),
        ),
      ]),
    );
  }

  static Widget _h(String t) => SizedBox(
      width: t == 'TOKENS' ? 108 : (t == 'REQ' ? 40 : 52),
      child: Text(t,
          textAlign: TextAlign.right,
          style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: Aether.textFaint)));

  static Widget _v(String t, {double width = 44, bool cost = false}) =>
      SizedBox(
          width: width,
          child: Text(t,
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontSize: 11,
                  fontFamily: Aether.mono,
                  color: cost ? Aether.warn : Aether.textMuted)));
}
