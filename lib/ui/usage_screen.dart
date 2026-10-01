import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/ovid_cloud_service.dart';
import '../core/theme.dart';
import '../core/state.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageLog] — real token counts metered per
/// model call by the agent loop. web-IDE StatsLine + TurnUsage pattern,
/// plus APPROXIMATE USD pricing per known model family (public list
/// prices; marked "approx" everywhere).
/// ═══════════════════════════════════════════════════════════════════

/// Approximate public list pricing per model family, USD per 1M tokens
/// (input, output).  Unknown models return null → UI shows "—".
class _Pricing {
  final double inputPer1M;
  final double outputPer1M;
  const _Pricing(this.inputPer1M, this.outputPer1M);

  static const List<(String, _Pricing)> _table = [
    ('claude-opus-4', _Pricing(15, 75)),
    ('claude-opus', _Pricing(15, 75)),
    ('claude-sonnet-4', _Pricing(3, 15)),
    ('claude-sonnet', _Pricing(3, 15)),
    ('claude-3-5-haiku', _Pricing(0.80, 4)),
    ('claude-haiku', _Pricing(0.80, 4)),
    ('gpt-4o-mini', _Pricing(0.15, 0.60)),
    ('gpt-4o', _Pricing(2.50, 10)),
    ('gpt-4.1', _Pricing(2, 8)),
    ('o3-mini', _Pricing(1.10, 4.40)),
    ('o3', _Pricing(2, 8)),
    ('o4-mini', _Pricing(1.10, 4.40)),
    ('gemini-2.5-pro', _Pricing(1.25, 10)),
    ('gemini-2.5-flash', _Pricing(0.30, 2.50)),
    ('gemini-2.0-flash', _Pricing(0.10, 0.40)),
    ('gemini', _Pricing(1.25, 10)),
    ('deepseek-reasoner', _Pricing(0.55, 2.19)),
    ('deepseek-chat', _Pricing(0.27, 1.10)),
    ('deepseek-v4', _Pricing(0.25, 1.00)),
    ('deepseek', _Pricing(0.27, 1.10)),
    ('grok', _Pricing(3, 15)),
    ('mistral-large', _Pricing(2, 6)),
    ('codestral', _Pricing(0.30, 0.90)),
    ('mistral', _Pricing(2, 6)),
    ('qwen2.5-coder-32b', _Pricing(0.18, 0.18)),
    ('qwen', _Pricing(0.35, 1.40)),
    ('kimi', _Pricing(0.50, 2.00)),
    ('llama-4', _Pricing(0.18, 0.18)),
    ('llama-3.3-70b', _Pricing(0.10, 0.10)),
    ('nemotron', _Pricing(0.20, 0.60)),
    ('sonar', _Pricing(1, 1)),
  ];

  /// Pricing for a model id (keyword match, table order = precedence).
  static _Pricing? forModel(String model) {
    final m = model.split('·').first.trim().toLowerCase();
    for (final (key, pricing) in _table) {
      if (m.contains(key)) return pricing;
    }
    return null;
  }

  /// Approx USD cost for (input, output) tokens of [model]; null if the
  /// model family is unknown.
  static double? estimate(String model, int inTok, int outTok) {
    final p = forModel(model);
    if (p == null) return null;
    return inTok / 1e6 * p.inputPer1M + outTok / 1e6 * p.outputPer1M;
  }

  static String fmt(double usd) => usd >= 1
      ? '\$${usd.toStringAsFixed(2)}'
      : '\$${usd.toStringAsFixed(usd >= 0.01 ? 3 : 4)}';
}

class ProviderUsage {
  final String providerId;
  final String providerName;
  final String tier; // 'Ovid Free' | 'BYOK'
  final IconData icon;
  final Color color;
  int requests;
  int tokensIn;
  int tokensOut;
  double costUsd; // approx, only known models contribute
  bool hasPricedModel;
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
    this.costUsd = 0,
    this.hasPricedModel = false,
  });
}

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  /// Aggregate the real usage log into per-provider summaries.
  ///
  /// The built-in Ovid Cloud provider is intentionally EXCLUDED here: its usage
  /// is server-authoritative (fetched from `/usage`, shown by
  /// [_OvidCloudUsageCard]), not computed from the device-side log. Custom and
  /// other built-in providers (the user's own keys) stay app-side as before.
  List<ProviderUsage> _aggregate(AppState app) {
    // Pick provider metadata from the catalog for icon/color.
    final byId = <String, ProviderUsage>{};
    for (final e in app.usageLog) {
      if (e.providerId == AppState.ovidCloudProviderId) continue;
      final p = byId.putIfAbsent(
        e.providerId,
        () => ProviderUsage(
          providerId: e.providerId,
          providerName: e.providerName,
          // Built-in free providers (Groq/Gemini/…) are not BYOK.
          tier: (app.providerById(e.providerId)?.isFree ?? false)
              ? 'FREE'
              : 'BYOK',
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
      final cost = _Pricing.estimate(
        e.model,
        e.promptTokens,
        e.completionTokens,
      );
      if (cost != null) {
        p
          ..costUsd += cost
          ..hasPricedModel = true;
      }
      // Per-model aggregation (in+out split kept for the detail view).
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
    if (n.contains('anthropic')) return Aether.warnLight;
    if (n.contains('gemini') || n.contains('google')) return Aether.accent;
    if (n.contains('deepseek')) return const Color(0xFF9B7BFF);
    return Aether.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Usage')),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) {
          // Aggregate INSIDE the builder: the outer build runs once, so
          // capturing here would freeze token/cost stats at first open.
          final providers = _aggregate(app);
          final reqs = providers.fold<int>(0, (s, p) => s + p.requests);
          final tokensIn = providers.fold<int>(0, (s, p) => s + p.tokensIn);
          final tokensOut = providers.fold<int>(0, (s, p) => s + p.tokensOut);
          final costUsd = providers.fold<double>(0, (s, p) => s + p.costUsd);
          final anyPriced = providers.any((p) => p.hasPricedModel);
          final todayEntries = app.usageLog.where((e) {
            final d = e.time;
            final now = DateTime.now();
            return d.year == now.year &&
                d.month == now.month &&
                d.day == now.day;
          }).toList();
          final todayTokens = todayEntries.fold<int>(
            0,
            (s, e) => s + e.totalTokens,
          );
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              // ---- Ovid Cloud plan (server-authoritative; free tier is Zen) ----
              const _OvidCloudUsageCard(),
              // ---- All-time summary (custom + other providers, app-side) ----
              Container(
                margin: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Aether.surface,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Aether.hairline),
                ),
                child: Row(
                  children: [
                    _stat(
                      'Est. cost',
                      anyPriced ? _Pricing.fmt(costUsd) : '—',
                      big: true,
                    ),
                    _stat('Today', _fmtTok(todayTokens)),
                    _stat('Requests', '$reqs'),
                    _stat('Providers', '${providers.length}'),
                  ],
                ),
              ),
              if (anyPriced)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
                  child: Text(
                    'Costs are approximate (public list prices per model; '
                    'cached-input, promos and free tiers not reflected).',
                    style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                  ),
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
                child: Row(
                  children: [
                    Icon(
                      Icons.data_usage_outlined,
                      size: 15,
                      color: Aether.textFaint,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Input · output',
                      style: TextStyle(fontSize: 11, color: Aether.textFaint),
                    ),
                    const Spacer(),
                    Text(
                      '${_fmtTok(tokensIn)} in · ${_fmtTok(tokensOut)} out',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFamily: Aether.mono,
                        color: Aether.text,
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
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
                for (final p in providers) _ProviderTile(provider: p),

              if (providers.isNotEmpty)
                Padding(
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

  static String _fmtTok(int n) => formatCompactCount(n);

  Widget _stat(String label, String value, {bool big = false}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
          ),
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
      title: Row(
        children: [
          Flexible(
            child: Text(
              p.providerName,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Tag(p.tier, color: Aether.textMuted, filled: false),
        ],
      ),
      subtitle: Text(
        '${p.requests} requests · ${_fmtK(p.tokensIn)} in · ${_fmtK(p.tokensOut)} out'
        '${p.hasPricedModel ? ' · ≈ ${_Pricing.fmt(p.costUsd)}' : ''}',
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.chevron_right, size: 14, color: Aether.textFaint),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProviderUsageScreen(provider: p)),
      ),
    );
  }

  String _fmtK(int n) => formatCompactCount(n);
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
            child: Row(
              children: [
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
                      Text(
                        p.providerName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        p.tier,
                        style: TextStyle(fontSize: 12, color: Aether.textFaint),
                      ),
                      Text(
                        '${p.requests} requests',
                        style: TextStyle(fontSize: 11, color: Aether.textFaint),
                      ),
                    ],
                  ),
                ),
              ],
            ),
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
            child: Row(
              children: [
                _cell('Requests', '${p.requests}'),
                _cell('Tokens in', _fmtK(p.tokensIn)),
                _cell('Tokens out', _fmtK(p.tokensOut)),
                _cell(
                  'Est. cost',
                  p.hasPricedModel ? '≈ ${_Pricing.fmt(p.costUsd)}' : '—',
                ),
              ],
            ),
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
            child: Column(
              children: [
                SizedBox(
                  height: 72,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final d in daily)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2.5,
                            ),
                            child: FractionallySizedBox(
                              heightFactor: d,
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: p.color.withValues(
                                    alpha: 0.35 + d * 0.5,
                                  ),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '14 days ago',
                      style: TextStyle(fontSize: 9.5, color: Aether.textFaint),
                    ),
                    Text(
                      'Today',
                      style: TextStyle(fontSize: 9.5, color: Aether.textFaint),
                    ),
                  ],
                ),
              ],
            ),
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
              child: Column(
                children: [
                  const _Row(
                    h: true,
                    cells: ['MODEL', 'REQ', 'TOKENS', '≈ COST'],
                    flexes: [5, 2, 3, 3],
                  ),
                  const Divider(height: 12),
                  for (final m in p.models)
                    _Row(
                      cells: [
                        m.$1,
                        '${m.$2}',
                        _fmtK(m.$3),
                        _modelCost(p.providerId, m.$1),
                      ],
                      flexes: const [5, 2, 3, 3],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _fmtK(int n) => formatCompactCount(n);

  /// Approx USD cost for ONE model on this provider, computed from the raw
  /// log (per-model in/out split lives there, not in the aggregate tuple).
  String _modelCost(String providerId, String model) {
    var i = 0, o = 0;
    for (final e in AppState.I.usageLog) {
      if (e.providerId != providerId || e.model != model) continue;
      i += e.promptTokens;
      o += e.completionTokens;
    }
    final cost = _Pricing.estimate(model, i, o);
    return cost == null ? '—' : _Pricing.fmt(cost);
  }

  Widget _cell(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              fontFamily: Aether.mono,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
        color: Aether.textFaint,
      ),
    ),
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
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: flexes[i],
              child: Text(
                cells[i],
                overflow: TextOverflow.ellipsis,
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
                style: TextStyle(
                  fontSize: h ? 9.5 : 11.5,
                  fontFamily: Aether.mono,
                  fontWeight: h ? FontWeight.w700 : FontWeight.w400,
                  letterSpacing: h ? 1.1 : 0,
                  color: h ? Aether.textFaint : Aether.text,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ovid Cloud plan card — server-authoritative usage.
///
/// Usage is fetched from the gateway's `/usage` (the source of truth), never
/// computed on the device, so it is identical across a user's devices and
/// cannot be faked. Free tier is Zen-style: a plain "Free plan" card with NO
/// numbers. Paid tiers (5x/10x/20x) show today's spend, budget and requests.
class _OvidCloudUsageCard extends StatefulWidget {
  const _OvidCloudUsageCard();

  @override
  State<_OvidCloudUsageCard> createState() => _OvidCloudUsageCardState();
}

class _OvidCloudUsageCardState extends State<_OvidCloudUsageCard> {
  OvidUsage? _usage;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final u = await OvidCloudService.I.fetchUsage();
    if (!mounted) return;
    setState(() {
      _usage = u;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final tier = _usage?.tier ?? app.ovidCloudTier;
    final isPaid = _usage?.isPaid ?? app.ovidCloudIsPaid;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Aether.accent.withValues(alpha: 0.14), Aether.surface],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: Aether.accent),
              const SizedBox(width: 8),
              Text(
                'Ovid Cloud',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Aether.text,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: isPaid ? Aether.accent : Aether.surfaceAlt,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isPaid ? '${tier.toUpperCase()} PLAN' : 'FREE',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                    color: isPaid ? Colors.white : Aether.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (!isPaid)
            // Zen-style free tier: no numbers at all.
            Text(
              'You\u2019re on the free plan. Just chat \u2014 no usage to track. '
              'Upgrade for a higher daily limit.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: Aether.textMuted,
              ),
            )
          else
            _paidUsage(_usage),
        ],
      ),
    );
  }

  Widget _paidUsage(OvidUsage? u) {
    if (u == null) {
      return Text(
        'Usage will appear here once your plan is active.',
        style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
      );
    }
    final pct = u.dailyBudgetUsd <= 0
        ? 0.0
        : (u.dailySpentUsd / u.dailyBudgetUsd).clamp(0.0, 1.0);
    final monthly = u.isMonthly;
    final windowLabel = monthly ? 'this month' : 'today';
    final resetLabel = monthly
        ? 'no daily cap · monthly pool'
        : 'resets every 24h';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _cloudStat(
              'Used $windowLabel',
              '\$${u.dailySpentUsd.toStringAsFixed(2)}',
            ),
            _cloudStat(
              monthly ? 'Monthly budget' : 'Daily limit',
              '\$${u.dailyBudgetUsd.toStringAsFixed(2)}',
            ),
            _cloudStat('Requests', '${u.requestsToday}'),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 7,
            backgroundColor: Aether.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(
              pct > 0.9 ? Aether.danger : Aether.accent,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '\$${u.dailyRemainingUsd.toStringAsFixed(2)} left $windowLabel \u00b7 $resetLabel',
          style: TextStyle(fontSize: 11, color: Aether.textFaint),
        ),
        if (u.models.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            'AVAILABLE MODELS · remaining of your budget',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.9,
              color: Aether.textFaint,
            ),
          ),
          const SizedBox(height: 8),
          for (final m in u.models) _modelBar(m),
          const SizedBox(height: 4),
          Text(
            'All models share one budget. A costly model drains it faster — '
            'every model\u2019s bar drops together; a cheaper model leaves more.',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: Aether.textFaint,
            ),
          ),
        ],
      ],
    );
  }

  Widget _modelBar(OvidModelUsage m) {
    final pct = m.remainingPct.clamp(0.0, 1.0);
    final price = m.per1mOutput;
    final priceLabel = price == null
        ? ''
        : '\$${price.toStringAsFixed(price >= 10 ? 0 : 2)}/1M out';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  ovidModelLabel(m.model),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: Aether.mono,
                    color: Aether.text,
                  ),
                ),
              ),
              if (priceLabel.isNotEmpty)
                Text(
                  priceLabel,
                  style: TextStyle(fontSize: 10, color: Aether.textFaint),
                ),
              const SizedBox(width: 8),
              Text(
                '${(pct * 100).round()}%',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: pct < 0.15 ? Aether.danger : Aether.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: Aether.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(
                pct < 0.15 ? Aether.danger : Aether.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cloudStat(String label, String value) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFamily: Aether.mono,
              color: Aether.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
          ),
        ],
      ),
    );
  }
}
