import 'dart:async';
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
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, __) => CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: _TrendingCarousel()),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
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
            const SliverToBoxAdapter(
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
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => PluginCard(plugin: items[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Auto-scrolling trending banners (3-4 slides).
class _TrendingCarousel extends StatefulWidget {
  const _TrendingCarousel();
  @override
  State<_TrendingCarousel> createState() => _TrendingCarouselState();
}

class _TrendingCarouselState extends State<_TrendingCarousel> {
  final _page = PageController(viewportFraction: 0.92);
  int _idx = 0;
  Timer? _timer;

  static const slides = [
    (
      'OpenCode Agent',
      'Autonomous coding inside your sandbox — trending #1 this week',
      Icons.smart_toy_outlined,
      Aether.accent
    ),
    (
      'MCP Server Hub',
      '4,800+ MCP servers. Connect anything to any model.',
      Icons.hub_outlined,
      Aether.success
    ),
    (
      'Image Studio',
      'Generate & edit images inline in chat, free.',
      Icons.auto_awesome,
      Aether.warn
    ),
    (
      'Web Agent',
      'Let AI browse, log in and automate the web for you.',
      Icons.public,
      Aether.accent
    ),
  ];

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_page.hasClients) return;
      final next = (_idx + 1) % slides.length;
      _page.animateToPage(next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 118,
      child: PageView.builder(
        controller: _page,
        itemCount: slides.length,
        onPageChanged: (i) => setState(() => _idx = i),
        itemBuilder: (_, i) {
          final s = slides[i];
          return Container(
            margin: const EdgeInsets.fromLTRB(6, 12, 6, 4),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: s.$4.withValues(alpha: 0.3)),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [s.$4.withValues(alpha: 0.16), Aether.surface],
              ),
            ),
            child: Row(children: [
              Icon(s.$3, size: 26, color: s.$4),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Tag('TRENDING',
                          color: Aether.warn, filled: true),
                      const SizedBox(width: 8),
                      Text(s.$1,
                          style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700)),
                    ]),
                    const SizedBox(height: 4),
                    Text(s.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: Aether.textMuted)),
                  ],
                ),
              ),
            ]),
          );
        },
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
                      style: const TextStyle(
                          fontSize: 11, color: Aether.textFaint)),
                  const SizedBox(height: 6),
                  Text(plugin.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
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
              child: const Icon(Icons.extension,
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
                      style: const TextStyle(
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
          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(plugin.description,
                style: const TextStyle(
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
                style: const TextStyle(
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
                style: const TextStyle(
                    fontSize: 12.5, color: Aether.textMuted))),
      ]),
    );
  }
}
