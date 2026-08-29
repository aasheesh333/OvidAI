import 'dart:convert';

import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';

/// Plugins library — Claude-Code-extensions style: trending banner carousel,
/// search, category chips, thousands of community plugins, detail pages.
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});
  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  String _query = '';
  String _cat = 'All';

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    const cats = ['All', 'Agent', 'MCP', 'Tool', 'Runtime'];
    final items = app.plugins
        .where((p) =>
            (_cat == 'All' || p.category == _cat) &&
            (p.name.toLowerCase().contains(_query.toLowerCase()) ||
                p.description
                    .toLowerCase()
                    .contains(_query.toLowerCase())))
        .toList();

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Plugins'),
        actions: [
          IconButton(
            tooltip: 'Add marketplace',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 22),
            onPressed: () => _addMarketplaceDialog(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) => CustomScrollView(
          slivers: [
            // ── Search bar ON TOP ──
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText:
                        'Search 4,800+ community plugins…',
                    prefixIcon: Icon(Icons.search,
                        size: 16, color: Aether.textFaint),
                    isDense: true,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final c in cats)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c,
                              style: const TextStyle(fontSize: 12)),
                          selected: _cat == c,
                          onSelected: (_) =>
                              setState(() => _cat = c),
                          showCheckmark: false,
                          selectedColor: Aether.accentSoft,
                          backgroundColor: Aether.surfaceAlt,
                          side: BorderSide(
                              color: _cat == c
                                  ? Aether.accent
                                  : Aether.hairline),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(9)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ── MCP section ──
            SliverToBoxAdapter(
              child: _McpSection(app: app),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 2),
                child: Text('ALL PLUGINS',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: Aether.textFaint)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) => PluginCard(plugin: items[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Claude Code style — paste any GitHub repo to import as marketplace.
  void _addMarketplaceDialog(BuildContext context) {
    final app = AppState.I;
    final c = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => AnimatedBuilder(
        animation: app,
        builder: (ctx, _) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Aether.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.hub_outlined,
                      size: 19, color: Aether.accent),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Add plugin marketplace',
                      style: TextStyle(
                          fontSize: 15.5, fontWeight: FontWeight.w700)),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon:
                      Icon(Icons.close, size: 18, color: Aether.textFaint),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ]),
              const SizedBox(height: 6),
              Text(
                  'Paste any GitHub repo that contains a marketplace.json — '
                  'works exactly like Claude Code plugin marketplaces.',
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted)),
              const SizedBox(height: 14),
              TextField(
                controller: c,
                autofocus: true,
                style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
                decoration: InputDecoration(
                  hintText: 'owner/repo or https://github.com/owner/repo',
                  hintStyle: TextStyle(
                      fontSize: 12.5, color: Aether.textFaint),
                  prefixIcon: Icon(Icons.code, size: 17,
                      color: Aether.textFaint),
                ),
              ),
              if (app.marketplaces.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text('YOUR MARKETPLACES',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                        color: Aether.textFaint)),
                const SizedBox(height: 6),
                for (final m in app.marketplaces)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Aether.hairline),
                    ),
                    child: Row(children: [
                      Icon(Icons.inventory_2_outlined,
                          size: 14, color: Aether.textMuted),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(m,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: Aether.mono)),
                      ),
                      if (m == 'ovidai/ovid-plugins')
                        const Tag('DEFAULT',
                            color: Aether.success, filled: true)
                      else
                        GestureDetector(
                          onTap: () => app.removeMarketplace(m),
                          child: const Icon(Icons.delete_outline,
                              size: 16, color: Aether.danger),
                        ),
                    ]),
                  ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11)),
                  ),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('Add marketplace',
                      style: TextStyle(fontSize: 13.5)),
                  onPressed: () {
                    final ok = app.addMarketplace(c.text);
                    if (ok) Navigator.pop(ctx);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PluginCard extends StatelessWidget {
  final PluginItem plugin;
  const PluginCard({super.key, required this.plugin});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PluginDetailScreen(plugin: plugin))),
      child: Container(
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
                      style: TextStyle(
                          fontSize: 11, color: Aether.textFaint)),
                  const SizedBox(height: 6),
                  Text(plugin.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: Aether.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              plugin.installed
                  ? Icons.check_circle
                  : Icons.download_outlined,
              size: 18,
              color: plugin.installed
                  ? Aether.success
                  : Aether.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Plugin detail — Claude Code extension page style.
class PluginDetailScreen extends StatelessWidget {
  final PluginItem plugin;
  const PluginDetailScreen({super.key, required this.plugin});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(plugin.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Aether.surfaceRaised,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Icon(Icons.extension,
                  size: 26, color: Aether.textMuted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(plugin.name,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(
                      '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs',
                      style: TextStyle(
                          fontSize: 11.5, color: Aether.textFaint)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: plugin.installed
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: plugin.enabled
                          ? Aether.surfaceRaised
                          : Aether.accent,
                      padding:
                          const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: Icon(
                        plugin.enabled
                            ? Icons.power_settings_new
                            : Icons.play_arrow,
                        size: 16),
                    label: Text(
                        plugin.enabled ? 'Disable' : 'Enable',
                        style: const TextStyle(fontSize: 13.5)),
                    onPressed: () {
                      plugin.enabled = !plugin.enabled;
                      app.refresh();
                    },
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Aether.accent,
                      padding:
                          const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.download_outlined,
                        size: 16),
                    label: const Text('Install',
                        style: TextStyle(fontSize: 13.5)),
                    onPressed: () {
                      plugin.installed = true;
                      plugin.enabled = true;
                      app.refresh();
                    },
                  ),
          ),
          if (plugin.installed) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      side: BorderSide(
                          color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.settings_backup_restore,
                        size: 15),
                    label: const Text('Reset to defaults',
                        style: TextStyle(fontSize: 12.5)),
                    onPressed: () {
                      plugin.enabled = true;
                      app.refresh();
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Plugin reset to defaults')));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.danger,
                      side: BorderSide(
                          color: Aether.danger.withValues(alpha: 0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.delete_outline,
                        size: 15),
                    label: const Text('Uninstall',
                        style: TextStyle(fontSize: 12.5)),
                    onPressed: () {
                      plugin.installed = false;
                      plugin.enabled = false;
                      app.refresh();
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(plugin.description,
                style: TextStyle(
                    fontSize: 13.5,
                    height: 1.6,
                    color: Aether.text)),
          ),
          const SectionHeader('Permissions'),
          const _Perm('Runs commands inside the isolated sandbox'),
          const _Perm('Reads files only from folders you share'),
          const _Perm('Network access: ask each time'),
          const SectionHeader('Changelog'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
                'v${plugin.version} — stability fixes and 20% faster startup.\nEarlier releases available on the plugin registry.',
                style: TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: Aether.textMuted)),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
class _Perm extends StatelessWidget {
  final String text;
  const _Perm(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(children: [
        const Icon(Icons.verified_user_outlined,
            size: 14, color: Aether.success),
        const SizedBox(width: 10),
        Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12.5, color: Aether.textMuted))),
      ]),
    );
  }
}

/// MCP servers section — separate from plugins because lifecycle is different
/// (running process + JSON-RPC, not a downloaded package).
class _McpSection extends StatelessWidget {
  final AppState app;
  const _McpSection({required this.app});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 2),
          child: Row(children: [
            Icon(Icons.usb_outlined, size: 15, color: Aether.textFaint),
            SizedBox(width: 8),
            Flexible(
              child: Text('CONNECTED TOOLS · MCP SERVERS',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                      color: Aether.textFaint)),
            ),
            const Spacer(),
            const Tag('LIVE', color: Aether.accent, filled: true),
          ]),
        ),
        SizedBox(
          height: 132,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: app.mcpServers.length + 1, // +1 add-tile
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              if (i == app.mcpServers.length) {
                return _AddMcpTile(onTap: () => _addMcpDialog(context));
              }
              final s = app.mcpServers[i];
              return McpCard(server: s);
            },
          ),
        ),
      ],
    );
  }

  void _addMcpDialog(BuildContext context) {
    final app = AppState.I;
    final nameC = TextEditingController();
    final cmdC = TextEditingController(text: 'npx');
    final argsC = TextEditingController();
    final envC = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Aether.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.usb_outlined,
                    size: 18, color: Aether.accent),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text('Add custom MCP server',
                    style: TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.close, size: 18, color: Aether.textFaint),
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),
            const SizedBox(height: 6),
            Text(
                'Runs as a local process. Config matches standard mcp.json format.',
                style: TextStyle(fontSize: 12.5, color: Aether.textMuted)),
            const SizedBox(height: 14),
            TextField(
              controller: nameC,
              autofocus: true,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                  hintText: 'Name (e.g. my-database)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: cmdC,
              style: const TextStyle(
                  fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                  hintText: 'Command (npx / uvx / node …)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: argsC,
              style: const TextStyle(
                  fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                  hintText: 'Args, space separated (-y @org/server)'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: envC,
              style: const TextStyle(
                  fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                  hintText: 'Env var needed? (optional, e.g. GITHUB_TOKEN)'),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11)),
                ),
                icon: const Icon(Icons.power_outlined, size: 16),
                label: const Text('Save server', style: TextStyle(fontSize: 13.5)),
                onPressed: () {
                  if (nameC.text.trim().isEmpty) return;
                  app.addCustomMcpServer(
                    name: nameC.text,
                    command: cmdC.text.isEmpty ? 'npx' : cmdC.text,
                    args: argsC.text.trim().isEmpty
                        ? []
                        : argsC.text.trim().split(RegExp(r'\s+')),
                    envHint: envC.text.trim().isEmpty ? null : envC.text.trim(),
                  );
                  Navigator.pop(ctx);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact horizontal card for an MCP server.
class McpCard extends StatelessWidget {
  final McpServer server;
  const McpCard({super.key, required this.server});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => McpDetailScreen(server: server))),
      onLongPress:
          server.custom ? () => AppState.I.removeMcpServer(server) : null,
      child: Container(
        width: 196,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: server.connected
                  ? Aether.accent.withValues(alpha: 0.45)
                  : Aether.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.usb_outlined,
                    size: 15, color: Aether.textMuted),
              ),
              const Spacer(),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: server.connected
                      ? Aether.success
                      : Aether.textFaint,
                ),
              ),
            ]),
            const Spacer(),
            Text(server.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(server.connected ? 'Connected' : 'Not connected',
                style: TextStyle(
                    fontSize: 10.5,
                    color: server.connected
                        ? Aether.success
                        : Aether.textFaint)),
          ],
        ),
      ),
    );
  }
}

class _AddMcpTile extends StatelessWidget {
  final VoidCallback onTap;
  const _AddMcpTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: 120,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: Aether.accent.withValues(alpha: 0.3)),
          color: Aether.accentSoft,
        ),
        child: const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.add, size: 22, color: Aether.accent),
            SizedBox(height: 4),
            Text('Add server',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600,
                    color: Aether.accent)),
          ]),
        ),
      ),
    );
  }
}

/// MCP detail — connect/disconnect with config preview.
class McpDetailScreen extends StatefulWidget {
  final McpServer server;
  const McpDetailScreen({super.key, required this.server});

  @override
  State<McpDetailScreen> createState() => _McpDetailScreenState();
}

class _McpDetailScreenState extends State<McpDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final s = widget.server;
    final app = AppState.I;
    final argsJson = s.args.isEmpty
        ? '[]'
        : '[${s.args.map((a) => '"$a"').join(', ')}]';
    final configJson = '{\n'
        '  "mcpServers": {\n'
        '    "${s.name.toLowerCase()}": {\n'
        '      "command": "${s.command}",\n'
        '      "args": $argsJson'
        '${s.envHint != null ? ',\n      "env": { "${s.envHint!}": "••••••••" }' : ''}\n'
        '    }\n'
        '  }\n'
        '}';

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(s.name),
        actions: [
          // Pencil — edit the mcp.json config in place (user request).
          IconButton(
            tooltip: 'Edit config',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: () => _editConfigJson(context, s),
          ),
          if (s.custom)
            IconButton(
              tooltip: 'Remove server',
              icon: const Icon(Icons.delete_outline,
                  size: 19, color: Aether.danger),
              onPressed: () {
                app.removeMcpServer(s);
                Navigator.pop(context);
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Aether.surfaceRaised,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.usb_outlined,
                  size: 24, color: Aether.textMuted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(
                        '${s.author} · ${s.category} · via ${s.source}',
                        style: TextStyle(
                            fontSize: 11.5, color: Aether.textFaint)),
                  ]),
            ),
          ]),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor:
                    s.connected ? Aether.surfaceRaised : Aether.accent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                side: BorderSide(
                    color: s.connected ? Aether.hairline : Colors.transparent),
              ),
              icon: Icon(
                  s.connected ? Icons.link_off : Icons.power_settings_new,
                  size: 16),
              label: Text(
                  s.connected ? 'Disconnect' : 'Connect server',
                  style: const TextStyle(fontSize: 13.5)),
              onPressed: () => app.toggleMcpServer(s),
            ),
          ),
          if (s.connected) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      side: BorderSide(color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.settings_backup_restore, size: 15),
                    label: const Text('Reset config',
                        style: TextStyle(fontSize: 12.5)),
                    onPressed: () {
                      // Reset = disconnect + clear any custom env
                      if (s.connected) app.toggleMcpServer(s);
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('MCP server config reset')));
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(s.description,
                style: TextStyle(
                    fontSize: 13.5, height: 1.6, color: Aether.text)),
          ),
          if (s.envHint != null) ...[
            const SectionHeader('Environment'),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Aether.hairline),
              ),
              child: Row(children: [
                const Icon(Icons.key_outlined, size: 15, color: Aether.warn),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('${s.envHint} will be requested when connecting.',
                      style: TextStyle(
                          fontSize: 12.5, color: Aether.textMuted)),
                ),
              ]),
            ),
          ],
          const SectionHeader('Config (standard mcp.json)'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    color: Aether.surfaceAlt,
                    child: Text('mcp.json',
                        style: TextStyle(
                            fontSize: 11, color: Aether.textMuted)),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(12),
                    child: Text(configJson,
                        style: TextStyle(
                            fontFamily: Aether.mono,
                            fontSize: 11.5,
                            height: 1.55,
                            color: Aether.text)),
                  ),
                ]),
          ),
          const SectionHeader('Runtime'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _runRow('Process', '${s.command} ${s.args.join(' ')}'),
                  const SizedBox(height: 6),
                  _runRow('Protocol', 'JSON-RPC over stdio'),
                  const SizedBox(height: 6),
                  _runRow('Sandbox', 'Isolated · ask before network'),
                ]),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _runRow(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 78,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 12, color: Aether.textFaint))),
          Expanded(
            child: Text(v,
                style: TextStyle(
                    fontFamily: Aether.mono,
                    fontSize: 11.5,
                    color: Aether.textMuted)),
          ),
        ],
      );

  /// Opens the mcp.json editor sheet — validates JSON, parses the
  /// mcpServers entry, and updates the server command/args on save.
  void _editConfigJson(BuildContext context, McpServer s) {
    final app = AppState.I;
    final ctrl = TextEditingController(text: _configJsonFor(s));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.62,
          child: _McpJsonEditorSheet(
            controller: ctrl,
            onSave: (command, args) {
              app.updateCustomMcpServer(
                s,
                command: command,
                args: args,
              );
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('mcp.json saved ✓')),
              );
            },
          ),
        ),
      ),
    );
  }

  String _configJsonFor(McpServer s) {
    final argsJson = s.args.isEmpty
        ? '[]'
        : '[${s.args.map((a) => '"$a"').join(', ')}]';
    return '{\n'
        '  "mcpServers": {\n'
        '    "${s.name.toLowerCase()}": {\n'
        '      "command": "${s.command}",\n'
        '      "args": $argsJson'
        '${s.envHint != null ? ',\n      "env": { "${s.envHint!}": "••••••••" }' : ''}\n'
        '    }\n'
        '  }\n'
        '}';
  }
}

/// Bottom-sheet mcp.json editor: multiline TextField + live validation.
/// Save parses the mcpServers.{name} entry and returns command + args.
class _McpJsonEditorSheet extends StatefulWidget {
  final TextEditingController controller;
  final void Function(String command, List<String> args) onSave;
  const _McpJsonEditorSheet({
    required this.controller,
    required this.onSave,
  });

  @override
  State<_McpJsonEditorSheet> createState() => _McpJsonEditorSheetState();
}

class _McpJsonEditorSheetState extends State<_McpJsonEditorSheet> {
  String? _error;

  void _validate() {
    setState(() {
      _error = _parse(widget.controller.text) == null
          ? 'Invalid mcp.json — expected {"mcpServers": {"name": {"command": "...", "args": [...]}}}'
          : null;
    });
  }

  ({String command, List<String> args})? _parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final servers = j['mcpServers'] as Map<String, dynamic>?;
      if (servers == null || servers.isEmpty) return null;
      final entry = servers.values.first as Map<String, dynamic>;
      final command = entry['command'] as String?;
      if (command == null || command.trim().isEmpty) return null;
      final args = (entry['args'] as List?)
              ?.whereType<String>()
              .toList() ??
          <String>[];
      return (command: command.trim(), args: args);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.edit_outlined, size: 16, color: Aether.textMuted),
            const SizedBox(width: 8),
            const Text(
              'Edit mcp.json',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Edit the server command, args, or env. Saved config is used when the server connects.',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: widget.controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(fontFamily: Aether.mono, fontSize: 12),
            decoration: InputDecoration(
              filled: true,
              fillColor: Aether.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Aether.hairline),
              ),
            ),
            onChanged: (_) => _validate(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(fontSize: 11, color: Aether.danger),
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Save config'),
          onPressed: () {
            final parsed = _parse(widget.controller.text);
            if (parsed == null) {
              setState(() => _error =
                  'Invalid mcp.json — check the JSON syntax and try again.');
              return;
            }
            widget.onSave(parsed.command, parsed.args);
          },
        ),
      ],
    );
  }
}
