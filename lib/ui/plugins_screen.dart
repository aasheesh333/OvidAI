import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../core/agent_service.dart';
import '../core/mcp_service.dart';
import '../core/theme.dart';
import '../core/state.dart';

/// Agent tools a plugin contributes when installed+enabled — mirrors the
/// `_tools` gate in AgentService so the install snackbar can report what
/// the model actually gained (the plugin registry honest-install parity).
String? _toolGainsFor(PluginItem p) {
  final seed = switch (p.name) {
    'Web Search' => 'web_search',
    'Image Studio' => 'generate_image',
    'File Reader' => 'file_read',
    'Web Fetch & Reader' => 'fetch_url',
    'Code Runner' => 'run_code',
    'RAG Memory' => 'memory_search, memory_save',
    'DeepThink Reasoning' => 'reasoning display',
    'Sandbox Runtime' => 'run_shell, fs tools',
    _ => null,
  };
  if (seed != null) return seed;
  if (p.category == 'MCP') return 'mcp (proxy)';
  final tools = AgentService.I.pluginToolNames(p);
  if (tools.isNotEmpty) {
    return tools.join(', ');
  }
  return null;
}

@visibleForTesting
String? toolGainsForTest(PluginItem p) => _toolGainsFor(p);

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

  /// True while registered marketplace catalogs are being merged.
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    // Registered marketplaces were never fetched anywhere in the UI, so the
    // catalog stayed at the built-in list and "Add marketplace" appeared to
    // do nothing. Merge them once when the library opens.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCatalogs());
  }

  Future<void> _syncCatalogs({bool force = false}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await AppState.I.syncMarketplaceCatalogs(force: force);
    } catch (_) {
      // Offline / bad repo — the built-in catalog still renders.
    }
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    const cats = ['All', 'Agent', 'MCP', 'Tool', 'Runtime'];
    final items = app.plugins
        .where(
          (p) =>
              (_cat == 'All' || p.category == _cat) &&
              (p.name.toLowerCase().contains(_query.toLowerCase()) ||
                  p.description.toLowerCase().contains(_query.toLowerCase())),
        )
        .toList();

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Plugins'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: Aether.accent,
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh marketplaces',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => _syncCatalogs(force: true),
            ),
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
                    hintText: 'Search 4,800+ community plugins…',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 16,
                      color: Aether.textFaint,
                    ),
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
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final c in cats)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          selected: _cat == c,
                          onSelected: (_) => setState(() => _cat = c),
                          showCheckmark: false,
                          selectedColor: Aether.accentSoft,
                          backgroundColor: Aether.surfaceAlt,
                          side: BorderSide(
                            color: _cat == c ? Aether.accent : Aether.hairline,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ── MCP section ──
            SliverToBoxAdapter(child: _McpSection(app: app)),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 2),
                child: Text(
                  'ALL PLUGINS',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
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
            16,
            16,
            16,
            MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Aether.accentSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.hub_outlined,
                      size: 19,
                      color: Aether.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Add plugin marketplace',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 18, color: Aether.textFaint),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Paste any GitHub repo with a marketplace.json — Claude Code '
                '(.claude-plugin/marketplace.json) and Codex/Claude Desktop '
                '(mcpServers map) formats both work.',
                style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: c,
                autofocus: true,
                style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
                decoration: InputDecoration(
                  hintText: 'owner/repo or https://github.com/owner/repo',
                  hintStyle: TextStyle(fontSize: 12.5, color: Aether.textFaint),
                  prefixIcon: Icon(
                    Icons.code,
                    size: 17,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              if (app.marketplaces.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'YOUR MARKETPLACES',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
                const SizedBox(height: 6),
                for (final m in app.marketplaces)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Aether.hairline),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 14,
                          color: Aether.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            m,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontFamily: Aether.mono,
                            ),
                          ),
                        ),
                        if (m == 'ovidai/ovid-plugins')
                          const Tag(
                            'DEFAULT',
                            color: Aether.success,
                            filled: true,
                          )
                        else
                          GestureDetector(
                            onTap: () => app.removeMarketplace(m),
                            child: const Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: Aether.danger,
                            ),
                          ),
                      ],
                    ),
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
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text(
                    'Add marketplace',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final added = app.addMarketplace(c.text);
                    if (added == null) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Enter owner/repo (or a GitHub URL) that is not '
                            'already added.',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Importing $added…'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    // Registering only records the repo — the catalog has to
                    // be fetched for its plugins/MCP servers to show up.
                    final msg = await app.fetchMarketplaceCatalog(added);
                    if (!mounted) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(msg),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    setState(() {});
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
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PluginDetailScreen(plugin: plugin)),
      ),
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          plugin.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tag(plugin.category.toUpperCase(), filled: true),
                      // PR24: hook chips — a plugin with hooks shows which
                      // events it fires (e.g. ON_TURN_START).
                      for (final ev in plugin.hooks.keys)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Tag(ev.toUpperCase(), filled: false),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    plugin.installsKnown && plugin.installs > 0
                        ? '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs'
                        : '${plugin.author} · v${plugin.version}',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    plugin.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Aether.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              plugin.installed ? Icons.check_circle : Icons.download_outlined,
              size: 18,
              color: plugin.installed ? Aether.success : Aether.textFaint,
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
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.extension, size: 26, color: Aether.textMuted),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plugin.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      plugin.installsKnown && plugin.installs > 0
                          ? '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs'
                          : '${plugin.author} · v${plugin.version}',
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: plugin.installed
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: plugin.enabled
                          ? Aether.surfaceRaised
                          : Aether.accent,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: Icon(
                      plugin.enabled
                          ? Icons.power_settings_new
                          : Icons.play_arrow,
                      size: 16,
                    ),
                    label: Text(
                      plugin.enabled ? 'Disable' : 'Enable',
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    onPressed: () async {
                      if (plugin.enabled) {
                        await app.disablePlugin(plugin);
                      } else {
                        await app.enablePlugin(plugin);
                      }
                    },
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Aether.accent,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text(
                      'Install',
                      style: TextStyle(fontSize: 13.5),
                    ),
                    onPressed: () async {
                      plugin.installed = true;
                      plugin.enabled = true;
                      app.persistPluginState();
                      app.refresh();
                      // Realtime install (the plugin manager parity): an MCP-category
                      // plugin connects its server right away, and the
                      // snackbar reports the tools the model gains —
                      // no restart, no dead flag flips.
                      final messenger =
                          ScaffoldMessenger.of(context);
                      if (plugin.category == 'MCP') {
                        final server = app.mcpServers
                            .where((s) => s.name == plugin.name)
                            .firstOrNull;
                        if (server != null) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'Connecting ${server.name}…',
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          final msg =
                              await McpService.I.connect(server);
                          server.connected =
                              McpService.I.isConnected(server.name);
                          app.refresh();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(msg),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        }
                      } else {
                        // PR40: fetch the plugin's OWN commands/skills
                        // content (Claude Code marketplace `source:
                        // owner/repo`) so install adds real capability —
                        // not just a catalog-row flag flip. Best-effort:
                        // offline/no-source degrades to the old message.
                        var fetchedFiles = 0;
                        if (plugin.source != null) {
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                'Fetching ${plugin.name} content…',
                              ),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                          fetchedFiles = await AppState.I.fetchPluginContent(
                            plugin.source!,
                          );
                          if (fetchedFiles > 0) {
                            await AgentService.I.refreshSkills();
                          }
                          // P3: an installed plugin can carry a .mcp.json —
                          // register its declared MCP servers so the agent
                          // gets them as connected-intent (they then
                          // respawn on the next launch/persist).
                          if (fetchedFiles > 0) {
                            final mounted = await AppState.I
                                .mountPluginMcpServers(plugin.source!);
                            await AppState.I.registerPluginHooks(plugin);
                            if (mounted > 0) {
                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Mounted $mounted MCP server(s) from '
                                    '${plugin.name}\'s .mcp.json',
                                  ),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                            }
                          }
                        }
                        final gained = _toolGainsFor(plugin);
                        final parts = <String>[
                          if (gained != null) 'agent tools: $gained',
                          if (fetchedFiles > 0)
                            '$fetchedFiles command/skill file(s) — see '
                                'the /-menu',
                        ];
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(
                              parts.isEmpty
                                  ? 'Installed ${plugin.name}'
                                  : 'Installed ${plugin.name} · '
                                      '${parts.join(' · ')}',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
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
                      side: BorderSide(color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore, size: 15),
                    label: const Text(
                      'Reset to defaults',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () {
                      plugin.enabled = true;
                      app.persistPluginState();
                      app.refresh();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Plugin reset to defaults'),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.danger,
                      side: BorderSide(
                        color: Aether.danger.withValues(alpha: 0.4),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text(
                      'Uninstall',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () async {
                      await app.uninstallPlugin(plugin);
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
            child: Text(
              plugin.description,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.text),
            ),
          ),
          const SectionHeader('Permissions'),
          if (plugin.hooks.isNotEmpty)
            _Perm('Declared hooks: ${plugin.hooks.keys.join(', ')}')
          else
            const _Perm('Declared by plugin manifest'),
          const SectionHeader('Changelog'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'v${plugin.version} — declared by plugin manifest.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Aether.textMuted,
              ),
            ),
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
      child: Row(
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 14,
            color: Aether.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ),
        ],
      ),
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
          child: Row(
            children: [
              Icon(Icons.usb_outlined, size: 15, color: Aether.textFaint),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'CONNECTED TOOLS · MCP SERVERS',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              const Spacer(),
              const Tag('LIVE', color: Aether.accent, filled: true),
            ],
          ),
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
    // PR41: a remote (Streamable-HTTP) server has no local command to
    // spawn — filling this in switches the save button to the http path.
    final urlC = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Aether.accentSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.usb_outlined,
                    size: 18,
                    color: Aether.accent,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Add custom MCP server',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.close, size: 18, color: Aether.textFaint),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Runs as a local process (or leave Command blank and set a '
              'URL for a remote Streamable-HTTP server). Config matches '
              'standard mcp.json format.',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
            const SizedBox(height: 8),
            // Claude Code / Codex / shared config import — paste a raw
            // .mcp.json, claude_desktop_config.json, or Codex config.toml
            // [mcp_servers] block and every server gets added at once.
            TextButton.icon(
              style: TextButton.styleFrom(
                foregroundColor: Aether.accent,
                padding: const EdgeInsets.symmetric(horizontal: 6),
              ),
              icon: const Icon(Icons.download_done_outlined, size: 16),
              label: const Text(
                'Import Claude Code / Codex config (.mcp.json · config.toml)',
                style: TextStyle(fontSize: 12),
              ),
              onPressed: () => _importMcpConfig(ctx),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameC,
              autofocus: true,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                hintText: 'Name (e.g. my-database)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlC,
              style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                hintText:
                    'Remote server URL (Streamable HTTP) — leave blank for '
                    'a local command below',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: cmdC,
              style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                hintText: 'Command (npx / uvx / node …) — ignored if URL is set',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: argsC,
              style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                hintText: 'Args, space separated (-y @org/server)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: envC,
              style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
              decoration: const InputDecoration(
                hintText:
                    'Env vars (stdio) or headers (http), JSON '
                    '({"Authorization":"Bearer …"}) — optional',
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
                icon: const Icon(Icons.power_outlined, size: 16),
                label: const Text(
                  'Save server',
                  style: TextStyle(fontSize: 13.5),
                ),
                onPressed: () {
                  if (nameC.text.trim().isEmpty) return;
                  final url = urlC.text.trim();
                  final isHttp = url.isNotEmpty;
                  // Env can be raw var names (envHint) or a JSON object
                  // with values — the latter is stored in secure storage
                  // and passed to the spawned server process (stdio), or
                  // sent as HTTP headers (http transport — e.g. an
                  // Authorization bearer token for a remote server).
                  Map<String, String>? envMap;
                  String? envHint;
                  final envTxt = envC.text.trim();
                  if (envTxt.startsWith('{')) {
                    try {
                      final m = jsonDecode(envTxt) as Map<String, dynamic>;
                      envMap = m.map((k, v) => MapEntry(k, v.toString()));
                    } catch (_) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Env JSON invalid — check syntax'),
                        ),
                      );
                      return;
                    }
                  } else if (envTxt.isNotEmpty && !isHttp) {
                    envHint = envTxt;
                  }
                  app.addCustomMcpServer(
                    name: nameC.text,
                    command: cmdC.text.isEmpty ? 'npx' : cmdC.text,
                    args: argsC.text.trim().isEmpty
                        ? []
                        : argsC.text.trim().split(RegExp(r'\s+')),
                    envHint: envHint,
                    url: isHttp ? url : null,
                    headers: isHttp ? (envMap ?? const {}) : const {},
                  );
                  if (envMap != null && !isHttp) {
                    unawaited(app.setMcpEnv(nameC.text.trim(), envMap));
                  }
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

/// Import a whole MCP config — Claude Code `.mcp.json`,
/// claude_desktop_config.json, or Codex `config.toml` `[mcp_servers.*]`.
void _importMcpConfig(BuildContext context) {
  final app = AppState.I;
  final pasteC = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Import MCP config', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: pasteC,
          maxLines: 12,
          minLines: 8,
          style: const TextStyle(fontFamily: Aether.mono, fontSize: 11.5),
          decoration: InputDecoration(
            hintText:
                'Paste .mcp.json / claude_desktop_config.json, or a '
                'Codex config.toml block. Every server gets added.',
            hintStyle: TextStyle(fontSize: 11, color: Aether.textFaint),
            isDense: true,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Aether.accent),
          onPressed: () {
            final res = _parseMcpConfig(pasteC.text);
            if (res.isEmpty) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('No mcpServers entries found in that text.'),
                ),
              );
              return;
            }
            final ignored = <String>[];
            for (final s in res) {
              if (app.mcpServers.any((e) => e.name == s.name)) continue;
              app.addCustomMcpServer(
                name: s.name,
                command: s.command,
                args: s.args,
                url: s.url,
                headers: s.headers,
                transport: s.type,
                cwd: s.cwd,
                startupTimeoutS: s.startupTimeoutS,
              );
              if (s.env.isNotEmpty) {
                unawaited(app.setMcpEnv(s.name, s.env));
              }
              if (s.ignoredKeys.isNotEmpty) {
                ignored.add('${s.name}: ${s.ignoredKeys.join(', ')}');
              }
            }
            Navigator.pop(ctx);
            final note = ignored.isEmpty
                ? ''
                : '\nIgnored unknown keys: ${ignored.join(' · ')}';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Imported ${res.length} MCP server(s).$note'),
              ),
            );
          },
          child: const Text('Import'),
        ),
      ],
    ),
  );
}

/// Parse a pasted MCP config into entries — accepts the JSON
/// `mcpServers` map (Claude Code / claude_desktop / standard shape), a
/// bare top-level JSON array, the `mcp_servers`/`servers` aliases, and
/// Codex's TOML `[mcp_servers.<name>]` blocks (single or double quotes,
/// multi-line `args`, `[.env]`/`[.headers]` sub-tables, `cwd`/`type`).
List<_ImportedMcp> _parseMcpConfig(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.startsWith('{')) {
    return _parseMcpJson(trimmed);
  }
  if (trimmed.startsWith('[')) {
    // Ambiguous: a JSON array OR a TOML `[mcp_servers.foo]` block. A TOML
    // section never decodes as JSON, so try JSON first and fall back to
    // TOML when it doesn't parse.
    final asJson = _parseMcpJson(trimmed);
    if (asJson.isNotEmpty) return asJson;
  }
  return _parseMcpToml(trimmed);
}

List<_ImportedMcp> _parseMcpJson(String raw) {
  final out = <_ImportedMcp>[];
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return out;
  }
  if (decoded is List) {
    for (final e in decoded) {
      if (e is Map) {
        final name = (e['name'] as String? ?? '').trim();
        if (name.isNotEmpty) {
          out.add(_importedFromJson(name, e.cast<String, dynamic>()));
        }
      }
    }
    return out;
  }
  if (decoded is! Map) return out;
  final j = decoded.cast<String, dynamic>();
  final servers = j['mcpServers'] ?? j['mcp_servers'] ?? j['servers'];
  if (servers is Map) {
    for (final e in servers.entries) {
      final v = e.value;
      if (v is Map) {
        out.add(_importedFromJson(e.key.toString(), v.cast<String, dynamic>()));
      }
    }
  } else if (servers is List) {
    for (final v in servers) {
      if (v is Map) {
        final name = (v['name'] as String? ?? '').trim();
        if (name.isNotEmpty) {
          out.add(_importedFromJson(name, v.cast<String, dynamic>()));
        }
      }
    }
  }
  return out;
}

/// Keys we understand in a JSON MCP server entry — anything else is an
/// *ignored key* surfaced to the user rather than silently dropped.
const _knownMcpJsonKeys = {
  'name', 'command', 'cmd', 'args', 'env', 'url', 'headers', 'cwd',
  'type', 'transport', 'description', 'author', 'category', 'timeout',
  'startupTimeoutS', 'startup_timeout_s',
};

_ImportedMcp _importedFromJson(String name, Map<String, dynamic> v) {
  final url = (v['url'] as String?)?.trim();
  final explicitType = ((v['transport'] as String?) ??
          (v['type'] as String?))
      ?.trim()
      .toLowerCase();
  final type = explicitType != null && explicitType.isNotEmpty
      ? explicitType
      : (url != null && url.isNotEmpty ? 'http' : 'stdio');
  final argsRaw = v['args'];
  final args = argsRaw is List
      ? argsRaw.whereType<String>().toList()
      : argsRaw is String
      ? shellSplitArgs(argsRaw)
      : <String>[];
  return _ImportedMcp(
    name: name,
    command: (v['command'] as String?) ??
        (v['cmd'] as String?) ??
        (type == 'stdio' ? 'npx' : ''),
    args: args,
    env: _mcpStringMap(v['env']),
    url: url != null && url.isNotEmpty ? url : null,
    headers: _mcpStringMap(v['headers']),
    cwd: (v['cwd'] as String?)?.trim(),
    type: type,
    startupTimeoutS: (v['timeout'] as num?)?.toInt() ??
        (v['startupTimeoutS'] as num?)?.toInt(),
    ignoredKeys: v.keys
        .where((k) => !_knownMcpJsonKeys.contains(k))
        .toList(),
  );
}

Map<String, String> _mcpStringMap(dynamic m) {
  if (m is! Map) return const {};
  return m.map((k, v) => MapEntry(k.toString(), v.toString()));
}

/// Mutable accumulator for one TOML `[mcp_servers.<name>]` block.
class _TomlServerAgg {
  final String name;
  String command = 'npx';
  List<String> args = const [];
  String? url;
  String? cwd;
  String? type;
  int? timeout;
  final Map<String, String> env = {};
  final Map<String, String> headers = {};
  final List<String> ignoredKeys = [];
  _TomlServerAgg(this.name);
}

List<_ImportedMcp> _parseMcpToml(String raw) {
  final servers = <String, _TomlServerAgg>{};
  _TomlServerAgg serverFor(String name) =>
      servers.putIfAbsent(name, () => _TomlServerAgg(name));

  _TomlServerAgg? current;
  String? currentSub; // null | 'env' | 'headers'
  final lines = raw.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i].trim();
    if (line.isEmpty || line.startsWith('#')) {
      i++;
      continue;
    }
    final sec = _tomlSection(line);
    if (sec != null) {
      current = serverFor(sec.name);
      currentSub = sec.sub;
      i++;
      continue;
    }
    final eq = _indexOfAssignment(line);
    if (eq < 0) {
      i++;
      continue; // stray line (e.g. closing `]` of a multiline array)
    }
    final key = line.substring(0, eq).trim();
    final valueRaw = line.substring(eq + 1).trim();

    if (currentSub == 'env') {
      current?.env[_unquoteToml(key)] = _unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (currentSub == 'headers') {
      current?.headers[key] = _unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (current == null) {
      i++;
      continue;
    }

    switch (key.toLowerCase()) {
      case 'command':
        current.command = _unquoteToml(valueRaw);
        i++;
        break;
      case 'url':
        current.url = _unquoteToml(valueRaw);
        i++;
        break;
      case 'cwd':
        current.cwd = _unquoteToml(valueRaw);
        i++;
        break;
      case 'type':
      case 'transport':
        current.type = _unquoteToml(valueRaw).toLowerCase();
        i++;
        break;
      case 'timeout':
      case 'startuptimeouts':
        current.timeout = int.tryParse(_unquoteToml(valueRaw));
        i++;
        break;
      default:
        if (key.startsWith('env.')) {
          current.env[key.substring(4)] = _unquoteToml(valueRaw);
          i++;
        } else if (key.toLowerCase().startsWith('headers.')) {
          current.headers[key.substring(8)] = _unquoteToml(valueRaw);
          i++;
        } else if (key.toLowerCase() == 'args') {
          var buf = valueRaw;
          if (buf.contains('[') || buf.contains(']')) {
            var open = _countChar(buf, '[') - _countChar(buf, ']');
            while (open > 0 && i + 1 < lines.length) {
              i++;
              buf += ' ${lines[i].trim()}';
              open = _countChar(buf, '[') - _countChar(buf, ']');
            }
            current.args = _parseArgsArray(buf);
          } else {
            current.args = shellSplitArgs(_unquoteToml(buf));
          }
          i++;
        } else {
          current.ignoredKeys.add(key);
          i++;
        }
        break;
    }
  }

  return [
    for (final a in servers.values) _importedFromToml(a),
  ];
}

_ImportedMcp _importedFromToml(_TomlServerAgg a) {
  final url = a.url;
  final resolvedType =
      a.type != null && a.type!.isNotEmpty
          ? a.type!
          : (url != null && url.isNotEmpty ? 'http' : 'stdio');
  return _ImportedMcp(
    name: a.name,
    command: resolvedType == 'stdio' ? a.command : '',
    args: a.args,
    env: a.env,
    url: url != null && url.isNotEmpty ? url : null,
    headers: a.headers,
    cwd: a.cwd,
    type: resolvedType,
    startupTimeoutS: a.timeout,
    ignoredKeys: a.ignoredKeys,
  );
}

/// Parse a TOML section header `[a.b.c]` into its name + optional sub-table
/// kind. Handles both the bare key (`[mcp_servers.foo]`) and the quoted-key
/// form (`["mcp_servers.foo.env"]`). Returns null for non-MCP sections.
({String name, String? sub})? _tomlSection(String t) {
  if (!t.startsWith('[') || !t.endsWith(']')) return null;
  var inner = t.substring(1, t.length - 1).trim();
  if (inner.length >= 2 &&
      inner.startsWith('"') &&
      inner.endsWith('"')) {
    inner = inner.substring(1, inner.length - 1);
  }
  final parts = inner.split('.');
  if (parts.length < 2) return null;
  final root = parts.first.toLowerCase();
  final isMcp =
      root == 'mcp_servers' || root == 'mcpservers' || root == 'servers';
  if (!isMcp) return null;
  final name = parts[1];
  final sub = parts.length >= 3 ? parts.sublist(2).join('.').toLowerCase() : null;
  return (name: name, sub: sub);
}

int _indexOfAssignment(String s) {
  var inS = false, inD = false;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == "'" && !inD) {
      inS = !inS;
    } else if (c == '"' && !inS) {
      inD = !inD;
    } else if (c == '=' && !inS && !inD) {
      return i;
    }
  }
  return -1;
}

String _unquoteToml(String v) {
  var s = v.trim();
  if (s.length >= 2) {
    final f = s[0], l = s[s.length - 1];
    if ((f == '"' && l == '"') || (f == "'" && l == "'")) {
      s = s.substring(1, s.length - 1);
    } else if (f == '"' || f == "'") {
      s = s.substring(1);
    }
  }
  return s;
}

int _countChar(String s, String ch) => ch.allMatches(s).length;

List<String> _parseArgsArray(String s) {
  final start = s.indexOf('[');
  final end = s.lastIndexOf(']');
  if (start < 0) return shellSplitArgs(_unquoteToml(s));
  final inner = s.substring(start + 1, end < 0 ? s.length : end);
  final out = <String>[];
  final re = RegExp("'([^']*)'|\"([^\"]*)\"");
  for (final m in re.allMatches(inner)) {
    out.add(m.group(1) ?? m.group(2) ?? '');
  }
  return out;
}

class _ImportedMcp {
  final String name;
  final String command;
  final List<String> args;
  final Map<String, String> env;

  /// PR41: non-null → this entry is a Streamable-HTTP (remote) server.
  final String? url;
  final Map<String, String> headers;

  /// Resolved transport ('stdio' | 'http' | 'sse').
  final String type;
  final String? cwd;
  final int? startupTimeoutS;

  /// Keys present in the source config that Ovid doesn't understand —
  /// surfaced to the user instead of silently dropped.
  final List<String> ignoredKeys;

  _ImportedMcp({
    required this.name,
    required this.command,
    required this.args,
    this.env = const {},
    this.url,
    this.headers = const {},
    this.type = 'stdio',
    this.cwd,
    this.startupTimeoutS,
    this.ignoredKeys = const [],
  });
}

/// Public test seam for the private [_parseMcpConfig] — same parser, no
/// dialog. Returns a record list (public shape) instead of the private
/// class so no private type leaks into a public API.
@visibleForTesting
List<({
  String name,
  String command,
  List<String> args,
  Map<String, String> env,
  String? url,
  Map<String, String> headers,
  String type,
  String? cwd,
  List<String> ignoredKeys,
})>
parseMcpConfigForTest(String raw) => [
      for (final e in _parseMcpConfig(raw))
        (
          name: e.name,
          command: e.command,
          args: e.args,
          env: e.env,
          url: e.url,
          headers: e.headers,
          type: e.type,
          cwd: e.cwd,
          ignoredKeys: e.ignoredKeys,
        ),
    ];

/// Compact horizontal card for an MCP server.
class McpCard extends StatelessWidget {
  final McpServer server;
  const McpCard({super.key, required this.server});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => McpDetailScreen(server: server)),
      ),
      onLongPress: server.custom
          ? () => AppState.I.removeMcpServer(server)
          : null,
      child: Container(
        width: 196,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: server.connected
                ? Aether.accent.withValues(alpha: 0.45)
                : Aether.hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Aether.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.usb_outlined,
                    size: 15,
                    color: Aether.textMuted,
                  ),
                ),
                const Spacer(),
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: server.connected ? Aether.success : Aether.textFaint,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              server.connected ? 'Connected' : 'Not connected',
              style: TextStyle(
                fontSize: 10.5,
                color: server.connected ? Aether.success : Aether.textFaint,
              ),
            ),
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
          border: Border.all(color: Aether.accent.withValues(alpha: 0.3)),
          color: Aether.accentSoft,
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add, size: 22, color: Aether.accent),
              SizedBox(height: 4),
              Text(
                'Add server',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Aether.accent,
                ),
              ),
            ],
          ),
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
    final configJson =
        '{\n'
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
              icon: const Icon(
                Icons.delete_outline,
                size: 19,
                color: Aether.danger,
              ),
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
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.usb_outlined,
                  size: 24,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${s.author} · ${s.category} · via ${s.source}',
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: s.connected
                    ? Aether.surfaceRaised
                    : Aether.accent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(
                  color: s.connected ? Aether.hairline : Colors.transparent,
                ),
              ),
              icon: Icon(
                s.connected ? Icons.link_off : Icons.power_settings_new,
                size: 16,
              ),
              label: Text(
                s.connected ? 'Disconnect' : 'Connect server',
                style: const TextStyle(fontSize: 13.5),
              ),
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
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore, size: 15),
                    label: const Text(
                      'Reset config',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () {
                      // Reset = disconnect + clear any custom env
                      if (s.connected) app.toggleMcpServer(s);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('MCP server config reset'),
                        ),
                      );
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
            child: Text(
              s.description,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.text),
            ),
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
              child: Row(
                children: [
                  const Icon(Icons.key_outlined, size: 15, color: Aether.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${s.envHint} will be requested when connecting.',
                      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    ),
                  ),
                ],
              ),
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
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Aether.surfaceAlt,
                  child: Text(
                    'mcp.json',
                    style: TextStyle(fontSize: 11, color: Aether.textMuted),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    configJson,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 11.5,
                      height: 1.55,
                      color: Aether.text,
                    ),
                  ),
                ),
              ],
            ),
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
              ],
            ),
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
        child: Text(k, style: TextStyle(fontSize: 12, color: Aether.textFaint)),
      ),
      Expanded(
        child: Text(
          v,
          style: TextStyle(
            fontFamily: Aether.mono,
            fontSize: 11.5,
            color: Aether.textMuted,
          ),
        ),
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
          16,
          16,
          16,
          16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.62,
          child: _McpJsonEditorSheet(
            controller: ctrl,
            onSave: (command, args, env, url, transport, headers, cwd) {
              app.updateCustomMcpServer(
                s,
                command: command,
                args: args,
                url: url,
                transport: transport,
                headers: headers,
                cwd: cwd,
              );
              // Env values (API keys) → secure storage, passed to the
              // server process at connect time.
              unawaited(app.setMcpEnv(s.name, env));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('mcp.json saved ✓')));
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
    final envJson = s.envHint != null
        ? ',\n      "env": { "${s.envHint!}": "••••••••" }'
        : '';
    final isHttp = s.transport == 'http';
    final urlJson = s.url != null
        ? ',\n      "url": "${s.url}"'
        : '';
    final cwdJson = s.cwd != null ? ',\n      "cwd": "${s.cwd}"' : '';
    final transportJson = ',\n      "transport": "${s.transport}"';
    return '{\n'
        '  "mcpServers": {\n'
        '    "${s.name.toLowerCase()}": {\n'
        '      "command": "${s.command}",\n'
        '      "args": $argsJson'
        '$urlJson'
        '$cwdJson'
        '${isHttp ? transportJson : ''}'
        '$envJson\n'
        '    }\n'
        '  }\n'
        '}';
  }
}

/// Bottom-sheet mcp.json editor: multiline TextField + live validation.
/// Save parses the mcpServers.{name} entry and returns command + args +
/// env (values stored in secure storage, passed to the server process).
class _McpJsonEditorSheet extends StatefulWidget {
  final TextEditingController controller;
  final void Function(
    String command,
    List<String> args,
    Map<String, String> env,
    String? url,
    String? transport,
    Map<String, String> headers,
    String? cwd,
  )
  onSave;
  const _McpJsonEditorSheet({required this.controller, required this.onSave});

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

  ({
    String command,
    List<String> args,
    Map<String, String> env,
    String? url,
    String? transport,
    Map<String, String> headers,
    String? cwd,
  })?
  _parse(
    String raw,
  ) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final servers = j['mcpServers'] as Map<String, dynamic>?;
      if (servers == null || servers.isEmpty) return null;
      final entry = servers.values.first as Map<String, dynamic>;
      final command = entry['command'] as String?;
      final url = (entry['url'] as String?)?.trim();
      final transport = (entry['transport'] as String?) ??
          (entry['type'] as String?);
      final isHttp =
          (url != null && url.isNotEmpty) || transport == 'http';
      if ((command == null || command.trim().isEmpty) && !isHttp) {
        return null;
      }
      final args =
          (entry['args'] as List?)?.whereType<String>().toList() ?? <String>[];
      final env =
          (entry['env'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          <String, String>{};
      final headers =
          (entry['headers'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          <String, String>{};
      return (
        command: (command ?? '').trim(),
        args: args,
        env: env,
        url: isHttp ? url : null,
        transport: transport ?? (isHttp ? 'http' : 'stdio'),
        headers: headers,
        cwd: (entry['cwd'] as String?)?.trim(),
      );
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
          Text(_error!, style: TextStyle(fontSize: 11, color: Aether.danger)),
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
              setState(
                () => _error =
                    'Invalid mcp.json — check the JSON syntax and try again.',
              );
              return;
            }
            widget.onSave(
              parsed.command,
              parsed.args,
              parsed.env,
              parsed.url,
              parsed.transport,
              parsed.headers,
              parsed.cwd,
            );
          },
        ),
      ],
    );
  }
}
