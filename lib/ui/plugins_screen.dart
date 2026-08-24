import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';

/// Plugins marketplace — agents (OpenCode, Claude Code, Gemini CLI),
/// MCP servers, tools, and the proot runtime. Any platform plugin style.
class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cats = ['All', 'Agent', 'MCP', 'Tool', 'Runtime'];
    return DefaultTabController(
      length: cats.length,
      child: Scaffold(
        backgroundColor: Aether.bg,
        appBar: AppBar(
          leading: Builder(
            builder: (ctx) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: const Text('Plugins'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: Aether.text,
            unselectedLabelColor: Aether.textFaint,
            indicatorColor: Aether.accent,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Aether.hairline,
            labelStyle: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600),
            tabs: [for (final c in cats) Tab(text: c)],
          ),
        ),
        body: TabBarView(
          children: [
            for (final c in cats)
              _PluginList(
                  filter: c == 'All' ? null : c, categories: cats),
          ],
        ),
      ),
    );
  }
}

class _PluginList extends StatelessWidget {
  final String? filter;
  final List<String> categories;
  const _PluginList({required this.filter, required this.categories});

  @override
  Widget build(BuildContext context) {
    final items = AppState.I.plugins
        .where((p) => filter == null || p.category == filter)
        .toList();
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length + (filter == null ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (filter == null && i == 0) {
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: const Row(children: [
              Icon(Icons.verified_user_outlined,
                  size: 18, color: Aether.success),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Plugins run inside the on-device proot Ubuntu sandbox. Nothing leaves your phone unless a plugin says so.',
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Aether.textMuted),
                ),
              ),
            ]),
          );
        }
        final p = items[filter == null ? i - 1 : i];
        return _PluginCard(plugin: p);
      },
    );
  }
}

class _PluginCard extends StatelessWidget {
  final PluginItem plugin;
  const _PluginCard({required this.plugin});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Aether.surfaceRaised,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              switch (plugin.category) {
                'Agent' => Icons.smart_toy_outlined,
                'MCP' => Icons.hub_outlined,
                'Runtime' => Icons.memory,
                _ => Icons.build_outlined,
              },
              size: 19,
              color: Aether.textMuted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(
                    child: Text(plugin.name,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Tag(plugin.category.toUpperCase(), filled: true),
                ]),
                const SizedBox(height: 3),
                Text(
                    '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs',
                    style: const TextStyle(
                        fontSize: 11, color: Aether.textFaint)),
                const SizedBox(height: 6),
                Text(plugin.description,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Aether.textMuted)),
                const SizedBox(height: 10),
                Row(children: [
                  if (plugin.installed) ...[
                    const Text('Installed',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Aether.success)),
                    const Spacer(),
                    SizedBox(
                      height: 26,
                      child: Switch(
                        value: plugin.enabled,
                        activeTrackColor: Aether.accent,
                        onChanged: (v) {
                          plugin.enabled = v;
                          app.refresh();
                        },
                      ),
                    ),
                  ] else ...[
                    const Spacer(),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Aether.accent,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                      ),
                      icon: const Icon(Icons.download_outlined, size: 15),
                      label: const Text('Install',
                          style: TextStyle(fontSize: 12.5)),
                      onPressed: () {
                        plugin.installed = true;
                        plugin.enabled = true;
                        app.refresh();
                      },
                    ),
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
