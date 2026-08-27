import 'package:flutter/material.dart';
import '../core/theme.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Real app me ye AppState usage log se aayega (har agent call pe ek
/// UsageEntry append). Abhi realistic demo data.
///
/// har entry = 1 model call: provider, model, tokens, latency, cost
/// Ovid Free entries cost $0 — quota-based; BYOK entries user ki key
/// se direct, so cost = provider ke rate card se calculate hua.
/// ═══════════════════════════════════════════════════════════════════

class ProviderUsage {
  final String provider;
  final String tier; // 'Ovid Free' | 'BYOK'
  final IconData icon;
  final Color color;

  int requests;
  int tokensInK;  // thousands of tokens in
  int tokensOutK; // thousands out
  double cost;
  final List<double> daily; // 14-day relative heights

  List<(String, int, String, double)> models; // model, reqs, tokens, $

  ProviderUsage({
    required this.provider,
    required this.tier,
    required this.icon,
    required this.color,
    required this.requests,
    required this.tokensInK,
    required this.tokensOutK,
    required this.cost,
    required this.daily,
    required this.models,
  });
}

final _providersData = <ProviderUsage>[
  ProviderUsage(
    provider: 'Ovid Free',
    tier: 'Gateway',
    icon: Icons.bolt,
    color: Aether.success,
    requests: 214,
    tokensInK: 890,
    tokensOutK: 2100,
    cost: 0.0,
    daily: [.5, .7, .6, .9, .8, 1, .9, .4, .6, .8, .7, .9, 1, .8],
    models: [
      ('ovid-flash · gemini-2.5-flash', 148, '1.6M', 0.0),
      ('ovid-turbo · llama-3.3-70b', 46, '0.9M', 0.0),
      ('ovid-think · deepseek-r1', 20, '0.5M', 0.0),
    ],
  ),
  ProviderUsage(
    provider: 'Google Gemini',
    tier: 'BYOK',
    icon: Icons.auto_awesome,
    color: Aether.accent,
    requests: 196,
    tokensInK: 2600,
    tokensOutK: 1800,
    cost: 0.48,
    daily: [.3, .5, .4, .7, .6, .9, .8, 1, .7, .9, .6, .8, 1, .9],
    models: [
      ('gemini-2.5-pro', 48, '2.2M', 0.42),
      ('gemini-2.5-flash', 148, '2.2M', 0.06),
    ],
  ),
  ProviderUsage(
    provider: 'DeepSeek',
    tier: 'BYOK',
    icon: Icons.psychology_outlined,
    color: const Color(0xFF9B7BFF),
    requests: 122,
    tokensInK: 1300,
    tokensOutK: 3200,
    cost: 0.86,
    daily: [.2, .4, .3, .9, 1, .8, .6, .5, .7, .4, .9, .6, .3, .8],
    models: [
      ('deepseek-chat', 84, '1.4M', 0.33),
      ('deepseek-reasoner', 38, '3.1M', 0.53),
    ],
  ),
  ProviderUsage(
    provider: 'Anthropic',
    tier: 'BYOK',
    icon: Icons.memory_outlined,
    color: Aether.warn,
    requests: 60,
    tokensInK: 1100,
    tokensOutK: 2900,
    cost: 7.06,
    daily: [.1, .3, .2, .5, .4, .7, .6, .9, .5, .8, .6, .4, .7, 1],
    models: [
      ('claude-sonnet-4-6', 44, '2.9M', 5.60),
      ('claude-opus-4-6', 16, '1.1M', 1.46),
    ],
  ),
  ProviderUsage(
    provider: 'OpenAI',
    tier: 'BYOK',
    icon: Icons.diamond_outlined,
    color: const Color(0xFF4CC9E8),
    requests: 22,
    tokensInK: 500,
    tokensOutK: 900,
    cost: 3.82,
    daily: [.1, .2, .1, .3, .2, .4, .3, .5, .4, .2, .3, .5, .4, .6],
    models: [
      ('gpt-5.2', 22, '1.4M', 3.82),
    ],
  ),
];

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final total =
        _providersData.fold<double>(0, (s, p) => s + p.cost);
    final reqs =
        _providersData.fold<int>(0, (s, p) => s + p.requests);
    final tokensOut = _providersData.fold<int>(0, (s, p) => s + p.tokensOutK);
    final freeReqs = _providersData
        .where((p) => p.cost == 0)
        .fold<int>(0, (s, p) => s + p.requests);

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
          leading: const BackButton(), title: const Text('Usage')),
      body: ListView(
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
              _stat('This month',
                  total == 0 ? '\$0.00' : '\$${total.toStringAsFixed(2)}',
                  big: true),
              _stat('Requests', '$reqs'),
              _stat('Free used', '$freeReqs'),
            ]),
          ),

          // ---- free tier quota reminder ----
          Container(
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Aether.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border:
                  Border.all(color: Aether.success.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.bolt, size: 18, color: Aether.success),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Ovid Free — 36 / 50 today',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Aether.success)),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: 36 / 50,
                          minHeight: 4,
                          backgroundColor:
                              Aether.success.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation(
                              Aether.success),
                        ),
                      ),
                    ]),
              ),
            ]),
          ),

          // ---- tokens out banner ----
          Container(
            margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aether.hairline),
            ),
            child: Row(children: [
              const Icon(Icons.data_usage_outlined,
                  size: 15, color: Aether.textFaint),
              const SizedBox(width: 8),
              const Text('Total output',
                  style:
                      TextStyle(fontSize: 11, color: Aether.textFaint)),
              const Spacer(),
              Text('${(tokensOut / 1000).toStringAsFixed(1)}M tokens',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      fontFamily: Aether.mono,
                      color: Aether.text)),
            ]),
          ),

          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 6),
            child: Text('BY PROVIDER',
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: Aether.textFaint)),
          ),
          for (final p in _providersData)
            _ProviderTile(provider: p),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, 0),
            child: Text(
                'Usage tracked per provider from BYOK keys + Ovid Free '
                'gateway calls. Demo data.',
                style: TextStyle(fontSize: 11, color: Aether.textFaint)),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, {bool big = false}) {
    return Expanded(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10.5, color: Aether.textFaint)),
            const SizedBox(height: 4),
            Text(value,
                style: TextStyle(
                    fontSize: big ? 22 : 16,
                    fontWeight: FontWeight.w700,
                    fontFamily: Aether.mono,
                    color: big ? Aether.accent : Aether.text)),
          ]),
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
          child: Text(p.provider,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 8),
        Tag(
          p.cost == 0 ? 'FREE' : p.tier,
          color: p.cost == 0 ? Aether.success : Aether.textMuted,
          filled: p.cost == 0,
        ),
      ]),
      subtitle: Text(
        '${p.requests} requests · ${(p.tokensInK / 1000).toStringAsFixed(1)}M in · ${(p.tokensOutK / 1000).toStringAsFixed(1)}M out',
        style: const TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            p.cost == 0 ? '\$0.00' : '\$${p.cost.toStringAsFixed(2)}',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFamily: Aether.mono,
                color: p.cost == 0 ? Aether.success : Aether.text),
          ),
          const Icon(Icons.chevron_right,
              size: 14, color: Aether.textFaint),
        ],
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ProviderUsageScreen(provider: p))),
    );
  }
}

/// Detailed per-provider usage screen.
class ProviderUsageScreen extends StatelessWidget {
  final ProviderUsage provider;
  const ProviderUsageScreen({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final p = provider;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(p.provider)),
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
                      Text(p.provider,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(p.tier,
                          style: const TextStyle(
                              fontSize: 12, color: Aether.textFaint)),
                      Text('${p.requests} requests this month',
                          style: const TextStyle(
                              fontSize: 11, color: Aether.textFaint)),
                    ]),
              ),
              Text(
                p.cost == 0 ? '\$0.00' : '\$${p.cost.toStringAsFixed(2)}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    fontFamily: Aether.mono,
                    color: p.cost == 0 ? Aether.success : p.color),
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
              _cell('Tokens in', '${(p.tokensInK / 1000).toStringAsFixed(1)}M'),
              _cell('Tokens out',
                  '${(p.tokensOutK / 1000).toStringAsFixed(1)}M'),
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
                    for (final d in p.daily)
                      Expanded(
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 2.5),
                          child: FractionallySizedBox(
                            heightFactor: d,
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              decoration: BoxDecoration(
                                color: p.color.withValues(
                                    alpha: 0.35 + d * 0.5),
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
                    Text('14 days ago',
                        style: TextStyle(
                            fontSize: 9.5, color: Aether.textFaint)),
                    Text('Today',
                        style: TextStyle(
                            fontSize: 9.5, color: Aether.textFaint)),
                  ]),
            ]),
          ),

          const _SectionLabel('PER MODEL'),
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
                  cells: ['MODEL', 'REQ', 'TOKENS', 'COST'],
                  flexes: [5, 2, 2, 2]),
              const Divider(height: 12),
              for (final m in p.models)
                _Row(cells: [
                  m.$1,
                  '${m.$2}',
                  m.$3,
                  m.$4 == 0 ? '—' : '\$${m.$4.toStringAsFixed(2)}',
                ], flexes: const [5, 2, 2, 2]),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _cell(String label, String value) {
    return Expanded(
      child: Column(children: [
        Text(value,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                fontFamily: Aether.mono)),
        const SizedBox(height: 3),
        Text(label,
            style:
                const TextStyle(fontSize: 10.5, color: Aether.textFaint)),
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
