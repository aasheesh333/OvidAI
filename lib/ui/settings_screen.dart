import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'plugins_screen.dart';

/// Settings — BYOK providers. Everything stored on-device.
/// Pre-added providers (some free); user just pastes a key when needed.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        automaticallyImplyLeading: true,
        title: const Text('Settings'),
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, __) => ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            const SectionHeader(
              'Providers — Bring your own key',
              subtitle:
                  'Keys never leave this device. Free providers work with zero setup.',
            ),
            for (final p in app.providers) _ProviderCard(provider: p),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aether.accent,
                  side: BorderSide(
                      color: Aether.accent.withValues(alpha: 0.4)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add custom provider',
                    style: TextStyle(fontSize: 13)),
                onPressed: () => _addProviderSheet(context),
              ),
            ),
            const SectionHeader(
              'Plugins',
              subtitle:
                  'Agent harnesses, MCP servers and the proot runtime — all run on-device.',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  for (final pl in app.plugins) ...[
                    PluginCard(plugin: pl),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
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
            _settingTile(Icons.security_outlined, 'Sandbox',
                'Ready · isolated on-device'),
            _settingTile(Icons.info_outline, 'About', 'OvidAI 0.1.0-demo'),
          ],
        ),
      ),
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

  void _addProviderSheet(BuildContext context) {
    final name = TextEditingController();
    final url = TextEditingController();
    final key = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Add custom provider',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Any OpenAI-compatible endpoint works.',
                style:
                    TextStyle(fontSize: 12.5, color: Aether.textMuted)),
            const SizedBox(height: 16),
            TextField(
                controller: name,
                style: const TextStyle(fontSize: 14),
                decoration:
                    const InputDecoration(hintText: 'Name (e.g. Together AI)')),
            const SizedBox(height: 10),
            TextField(
                controller: url,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                    hintText: 'Base URL (https://…/v1)')),
            const SizedBox(height: 10),
            TextField(
                controller: key,
                obscureText: true,
                style: const TextStyle(fontSize: 14),
                decoration:
                    const InputDecoration(hintText: 'API key (optional)')),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                onPressed: () {
                  if (name.text.trim().isEmpty) return;
                  AppState.I.providers.add(ProviderConfig(
                    name: name.text.trim(),
                    description: 'Custom provider',
                    baseUrl: url.text.trim(),
                    apiKey: key.text.trim(),
                    custom: true,
                  ));
                  AppState.I.refresh();
                  Navigator.pop(ctx);
                },
                child: const Text('Add provider',
                    style: TextStyle(fontSize: 13.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final ProviderConfig provider;
  const _ProviderCard({required this.provider});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding:
              const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Aether.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                provider.name.substring(0, 1).toUpperCase(),
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Aether.textMuted),
              ),
            ),
          ),
          title: Row(children: [
            Flexible(
                child: Text(provider.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            if (provider.isFree)
              const Tag('FREE',
                  color: Aether.success, filled: true)
            else if (provider.hasKey)
              const Tag('CONNECTED',
                  color: Aether.accent, filled: true)
            else
              const Tag('BYOK'),
          ]),
          subtitle: Text(provider.baseUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 11, color: Aether.textFaint)),
          children: [
            Text(provider.description,
                style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: Aether.textMuted)),
            const SizedBox(height: 12),
            if (!provider.isFree) ...[
              TextField(
                obscureText: true,
                style: const TextStyle(fontSize: 13.5),
                controller:
                    TextEditingController(text: provider.apiKey),
                onChanged: (v) => provider.apiKey = v,
                decoration: InputDecoration(
                  hintText: 'API key — stored only on this device',
                  suffixIcon: provider.hasKey
                      ? const Icon(Icons.check_circle,
                          size: 17, color: Aether.success)
                      : null,
                ),
              ),
              const SizedBox(height: 10),
            ],
            TextField(
              style: const TextStyle(
                  fontSize: 13.5, fontFamily: Aether.mono),
              controller: TextEditingController(text: provider.baseUrl),
              onChanged: (v) => provider.baseUrl = v,
              decoration:
                  const InputDecoration(hintText: 'Base URL'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Aether.textMuted,
                  side: const BorderSide(color: Aether.hairlineStrong),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  minimumSize: Size.zero,
                ),
                icon: const Icon(Icons.sync, size: 14),
                label: const Text('Fetch models',
                    style: TextStyle(fontSize: 12)),
                onPressed: () => ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(
                        content: Text(
                            'Demo: would GET {baseUrl}/models with your key'))),
              ),
              const SizedBox(width: 10),
              if (provider.models.isNotEmpty)
                Expanded(
                  child: Text(
                      '${provider.models.length} models available',
                      style: const TextStyle(
                          fontSize: 11.5,
                          color: Aether.textFaint)),
                ),
            ]),
            if (provider.models.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in provider.models)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4.5),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(7),
                        border:
                            Border.all(color: Aether.hairline),
                      ),
                      child: Text(m,
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: Aether.mono,
                              color: Aether.textMuted)),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
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
