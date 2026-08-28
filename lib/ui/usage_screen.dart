import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/state.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageLog] — real token counts metered per
/// model call by the agent loop. DSH-web StatsLine + TurnUsage pattern.
/// ═══════════════════════════════════════════════════════════════════

class ProviderUsage {
  final String providerId;
  final String providerName;
  final String tier; // 'Ovid Free' | 'BYOK'
  final IconData icon;
  final Color color;
  int requests;
  int tokensIn;
  int tokensOut;
  List<(String, int, int)> models; // model, reqs, totalTokens
  ProviderUsage({
    required this.providerId,
    required this.providerName,
    required this.tier,
    required this.icon,
    required this.color,
    required this.requests,
    required this.tokensIn,
    required this.tokensOut,
    required this.models,
  });
}

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  /// Aggregate the real usage log into per-provider summaries.
  List<ProviderUsage> _aggregate(AppState app) {
    // Pick provider metadata from the catalog for icon/color.
    final byId = <String, ProviderUsage>{};
    for (final e in app.usageLog) {
      final p = byId.putIfAbsent(
        e.providerId,
        () => ProviderUsage(
          providerId: e.providerId,
          providerName: e.providerName,
          tier: 'BYOK',
          icon: _iconFor(e.providerName),
          color: _colorFor(e.providerName),
          requests: 0,
          tokensIn: 0,
          tokensOut: 0,
          models: [],
        ),
      );
      p
        ..requests += 1
        ..tokensIn += e.promptTokens
        ..tokensOut += e.completionTokens;
      // Per-model aggregation.
      final m = p.models.where((m) => m.$1 == e.model).firstOrNull;
      if (m != null) {
        p.models[p.models.indexOf(m)] = (m.$1, m.$2 + 1, m.$3 + e.totalTokens);
      } else {
        p.models.add((e.model, 1, e.totalTokens));
      }
    }
    return byId.values.toList()
      ..sort((a, b) => b.requests.compareTo(a.requests));
  }

  IconData _iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('openai')) return Icons.diamond_outlined;
    if (n.contains('anthropic')) return Icons.memory_outlined;
    if (n.contains('gemini') || n.contains('google')) {
      return Icons.auto_awesome;
    }
    if (n.contains('deepseek')) return Icons.psychology_outlined;
    return Icons.cloud_outlined;
  }

  Color _colorFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('openai')) return const Color(0xFF4CC9E8);
    if (n.contains('anthropic')) return Aether.warn;
    if (n.contains('gemini') || n.contains('google')) return Aether.accent;
    if (n.contains('deepseek')) return const Color(0xFF9B7BFF);
    return Aether.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final providers = _aggregate(app);
    final reqs = providers.fold<int>(0, (s, p) => s + p.requests);
    final tokensOut = providers.fold<int>(0, (s, p) => s + p.tokensOut);

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Usage')),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) {
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              // ---- Month summary ----
              Container(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Aether.hairline),
                ),
                child: Row(children: [
                  _stat('All time', '$reqs', big: true),
                  _stat('Requests', '$reqs'),
                  _stat('Providers', '${providers.length}'),
                ]),
              ),

              // ---- tokens banner ----
              Container(
                margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Aether.hairline),
                ),
                child: Row(children: [
                  const Icon(
                    Icons.data_usage_outlined,
                    size: 15,
                    color: Aether.textFaint,
                  ),
                  const SizedBox(width: 8),
                  const Text('Total output', style: TextStyle(
                    fontSize: 11,
                    color: Aether.textFaint,
                  )),
                  const Spacer(),
                  Text(
                    '${tokensOut > 1000 ? '${(tokensOut / 1000).toStringAsFixed(1)}K' : tokensOut} tokens',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFamily: Aether.mono,
                      color: Aether.text,
                    ),
                  ),
                ]),
              ),

              const Padding(
                padding: EdgeInsets.fromLTRB(18, 18, 18, 6),
                child: Text(
                  'BY PROVIDER',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Aether.textFaint,
                  ),
                ),
              ),

              if (providers.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(
                    child: Text(
                      'No usage yet.\nSend a message to start tracking token usage.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        color: Aether.textMuted,
                      ),
                    ),
                  ),
                )
              else
                for (final p in providers)
                  _ProviderTile(provider: p),

              if (providers.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
                  child: Text(
                    'Usage tracked from real API responses (token counts from the provider).',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _stat(String label, String value, {bool big = false}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(
            fontSize: 10.5,
            color: Aether.textFaint,
          )),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: big ? 22 : 16,
              fontWeight: FontWeight.w700,
              fontFamily: Aether.mono,
              color: big ? Aether.accent : Aether.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// List tile — one row per provider.
class _ProviderTile extends StatelessWidget {
  final ProviderUsage provider;
  const _ProviderTile({required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    return ListTile(
      leading: CircleAvatar(
        radius: 17,
        backgroundColor: p.color.withValues(alpha: 0.12),
        child: Icon(p.icon, size: 17, color: p.color),
      ),
      title: Row(children: [
        Flexible(
          child: Text(p.providerName, style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          )),
        ),
        const SizedBox(width: 8),
        Tag(
          p.tier,
          color: Aether.textMuted,
          filled: false,
        ),
      ]),
      subtitle: Text(
        '${p.requests} requests · ${_fmtK(p.tokensIn)} in · ${_fmtK(p.tokensOut)} out',
        style: const TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: const Icon(Icons.chevron_right,
          size: 14, color: Aether.textFaint),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProviderUsageScreen(provider: p)),
      ),
    );
  }

  String _fmtK(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';
}

/// Detailed per-provider usage screen.
class ProviderUsageScreen extends StatelessWidget {
  final ProviderUsage provider;
  const ProviderUsageScreen({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final daily = AppState.I.dailyActivityFor(p.providerId, days: 14);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(p.providerName)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: p.color.withValues(alpha: 0.12),
                child: Icon(p.icon, size: 22, color: p.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.providerName, style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    )),
                    Text(p.tier, style: const TextStyle(
                      fontSize: 12,
                      color: Aether.textFaint,
                    )),
                    Text('${p.requests} requests',
                        style: const TextStyle(
                            fontSize: 11, color: Aether.textFaint)),
                  ],
                ),
              ),
            ]),
          ),

          // quick stats
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(children: [
              _cell('Requests', '${p.requests}'),
              _cell('Tokens in', _fmtK(p.tokensIn)),
              _cell('Tokens out', _fmtK(p.tokensOut)),
            ]),
          ),

          const _SectionLabel('LAST 14 DAYS'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(children: [
              SizedBox(
                height: 72,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final d in daily)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2.5),
                          child: FractionallySizedBox(
                            heightFactor: d,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: p.color.withValues(alpha: 0.35 + d * 0.5),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('14 days ago', style: TextStyle(
                    fontSize: 9.5,
                    color: Aether.textFaint,
                  )),
                  Text('Today', style: TextStyle(
                    fontSize: 9.5,
                    color: Aether.textFaint,
                  )),
                ],
              ),
            ]),
          ),

          const _SectionLabel('PER MODEL'),
          if (p.models.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text(
                  'No per-model breakdown yet.',
                  style: TextStyle(fontSize: 12, color: Aether.textMuted),
                ),
              ),
            )
          else
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              decoration: BoxDecoration(
                color: Aether.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Aether.hairline),
              ),
              child: Column(children: [
                const _Row(
                  h: true,
                  cells: ['MODEL', 'REQ', 'TOKENS'],
                  flexes: [5, 2, 3],
                ),
                const Divider(height: 12),
                for (final m in p.models)
                  _Row(cells: [m.$1, '${m.$2}', _fmtK(m.$3)],
                      flexes: const [5, 2, 3]),
              ]),
            ),
        ],
      ),
    );
  }

  String _fmtK(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}K' : '$n';

  Widget _cell(String label, String value) {
    return Expanded(
      child: Column(children: [
        Text(value, style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          fontFamily: Aether.mono,
        )),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(
          fontSize: 10.5,
          color: Aether.textFaint,
        )),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Aether.textFaint)),
      );
}

class _Row extends StatelessWidget {
  final List<String> cells;
  final List<int> flexes;
  final bool h;
  const _Row({required this.cells, required this.flexes, this.h = false});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(
            flex: flexes[i],
            child: Text(cells[i],
                overflow: TextOverflow.ellipsis,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  fontSize: h ? 9.5 : 11.5,
                  fontFamily: Aether.mono,
                  fontWeight: h ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: h ? 1.1 : 0,
                  color: h ? Aether.textFaint : Aether.text,
                )),
          ),
      ]),
    );
  }
}
