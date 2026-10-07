import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/cloud_usage_store.dart';
import '../core/image_studio.dart';
import '../core/ovid_cloud_service.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'cloud_usage_status.dart';
import 'image_receipt_panel.dart';
import 'widgets/aether_primitives.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageLog] — real token counts metered per
/// model call by the agent loop. web-IDE StatsLine + TurnUsage pattern,
/// with server-authoritative remaining usage for Ovid Cloud.
/// ═══════════════════════════════════════════════════════════════════

/// Approximate public list pricing per model family, USD per 1M tokens
/// (input, output). Internal only; costs are not rendered.
class _Pricing {
  final double inputPer1M;
  final double outputPer1M;
  const _Pricing(this.inputPer1M, this.outputPer1M);

  static const List<(String, _Pricing)> _table = [
    ('', _Pricing(15, 75)),
    ('', _Pricing(15, 75)),
    ('', _Pricing(3, 15)),
    ('', _Pricing(3, 15)),
    ('', _Pricing(0.80, 4)),
    ('', _Pricing(0.80, 4)),
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
}

class ProviderUsage {
  final String providerId;
  final String providerName;
  final String tier; // 'FREE' | 'BYOK'
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
  /// is server-authoritative (fetched from `/usage`, shown by the plan header
  /// via [CloudUsageStore]), not computed from the device-side log. Custom and
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
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Usage'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More actions',
            icon: Icon(Icons.more_vert, color: Aether.textMuted),
            onSelected: (value) {
              if (value == 'image-receipts') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ImageReceiptsScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'image-receipts',
                child: Text('Image receipts'),
              ),
            ],
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) {
          // Aggregate INSIDE the builder: the outer build runs once, so
          // capturing here would freeze token/cost stats at first open.
          final providers = _aggregate(app);
          final tokensIn = providers.fold<int>(0, (s, p) => s + p.tokensIn);
          final tokensOut = providers.fold<int>(0, (s, p) => s + p.tokensOut);
          final todayEntries = app.usageLog.where((e) {
            if (e.providerId == AppState.ovidCloudProviderId) return false;
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
              // ---- Hero: Ovid Cloud plan (server-authoritative) ----
              const _PlanHeroHeader(),

              // ---- Local token banner (unchanged copy for parity) ----
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: _LocalTotalsStrip(
                  todayTokens: todayTokens,
                  tokensIn: tokensIn,
                  tokensOut: tokensOut,
                ),
              ),

              // ---- 'By provider' section ----
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                child: const AetherSectionTitle(
                  eyebrow: 'By provider',
                  subtitle:
                      'All-time measured usage · other providers (BYOK & free).',
                ),
              ),

              if (providers.isEmpty)
                const AetherEmptyState(
                  icon: Icons.query_stats,
                  title: 'No usage yet',
                  message: 'Start a chat to see per-provider usage here.',
                )
              else
                for (final p in providers)
                  Padding(
                    key: ValueKey(p.providerId),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: _ProviderCard(provider: p),
                  ),

              if (providers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                  child: Text(
                    'Usage tracked from real API responses '
                    '(token counts from the provider).',
                    style: AetherType.caption,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Route hosting the account-scoped [ImageReceiptPanel], reachable from the
/// Usage app bar menu. The panel is read-only: status checks are GET
/// recoveries against the saved request identity and never submit new paid
/// image work. Bound to the singleton studio and the current cloud key.
class ImageReceiptsScreen extends StatelessWidget {
  const ImageReceiptsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Image receipts'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
        children: [
          ImageReceiptPanel(
            studio: ImageStudio.I,
            headers: OvidCloudService.I.imageHeaders,
          ),
        ],
      ),
    );
  }
}

/// A single compact stat column used by the local totals strip.
Widget _stat(String label, String value, {bool big = false}) {
  return Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: Aether.textFaint)),
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

String _fmtTok(int n) => formatCompactCount(n);

/// Today's token snapshot + "in · out" micro-banner, kept behaviourally
/// identical to the previous layout so downstream tests that assert these
/// exact text strings (`'30'`, `'20 in · 10 out'`) still pass under the
/// redesign.
class _LocalTotalsStrip extends StatelessWidget {
  const _LocalTotalsStrip({
    required this.todayTokens,
    required this.tokensIn,
    required this.tokensOut,
  });

  final int todayTokens;
  final int tokensIn;
  final int tokensOut;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('All-time measured usage', style: AetherType.caption),
        const SizedBox(height: 8),
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [_stat('Today · measured tokens', _fmtTok(todayTokens))],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Aether.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Aether.hairline),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                Icons.data_usage_outlined,
                size: 15,
                color: Aether.textFaint,
              ),
              const SizedBox(width: 8),
              Text(
                'Input · output · all recorded usage',
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
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
      ],
    );
  }
}

/// Hero plan header rendered on an [AetherGradientHeader] wash.
///
/// Server-authoritative data from [CloudUsageStore] / [OvidCloudService] drives
/// the pill (FREE/PLUS/PRO/MAX), the big "remaining" number, and the soft
/// progress bar. Freshness state is surfaced via [CloudUsageStatus].
class _PlanHeroHeader extends StatefulWidget {
  const _PlanHeroHeader();

  @override
  State<_PlanHeroHeader> createState() => _PlanHeroHeaderState();
}

class _PlanHeroHeaderState extends State<_PlanHeroHeader> {
  late final CloudUsageStore _store;
  OvidUsage? get _usage => _store.usage;
  bool get _loading => _store.loading && _usage == null;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
    _store.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _store.release();
    super.dispose();
  }

  /// Human-readable plan name for the pill.
  ///
  /// Honours both the server's `is_paid` and [AppState.ovidCloudIsPaid] — the
  /// FREE/PLUS/PRO/MAX pill is purely a visual summary of the already-decided
  /// plan state; neither the tier nor the paid flag is invented here.
  String _pillLabel(String tier, bool isPaid) {
    if (!isPaid || tier == 'free' || tier.isEmpty) return 'FREE';
    switch (tier) {
      case '3x':
        return 'PLUS';
      case '7x':
        return 'PRO';
      case '15x':
        return 'MAX';
      default:
        return tier.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final tier = _usage?.tier ?? app.ovidCloudTier;
    final isPaid = _usage?.isPaid ?? app.ovidCloudIsPaid;
    final label = _pillLabel(tier, isPaid);
    final pillColor = isPaid ? Aether.accent : Aether.textMuted;
    final pct = _usage?.remainingFraction;

    final card = AetherCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(Icons.auto_awesome, size: 18, color: Aether.accent),
              Text('Ovid Cloud', style: AetherType.title),
              AetherPill(label: label, color: pillColor),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _usage == null
                ? 'Saved plan · awaiting server confirmation'
                : _store.stale || _store.error != null
                ? 'Last known plan and allowance'
                : 'Server-confirmed plan and allowance',
            style: AetherType.caption,
          ),
          const SizedBox(height: 14),
          if (_loading)
            const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            _RemainingHero(pct: pct),
          const SizedBox(height: 10),
          Text('Server-authoritative', style: AetherType.caption),
          CloudUsageStatus(store: _store),
          if (_usage != null && _usage!.models.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'AVAILABLE MODELS · remaining usage',
              style: AetherType.caption.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 8),
            for (final m in _usage!.models) _ModelRow(model: m),
            const SizedBox(height: 4),
            Text(
              'All models share your plan’s usage allowance.',
              style: AetherType.caption,
            ),
          ],
        ],
      ),
    );

    return Stack(
      children: [
        const AetherGradientHeader(height: 110, child: SizedBox.expand()),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: card),
      ],
    );
  }
}

class _RemainingHero extends StatelessWidget {
  const _RemainingHero({required this.pct});
  final double? pct;

  @override
  Widget build(BuildContext context) {
    if (pct == null) {
      return Text('Usage unavailable', style: AetherType.bodyMuted);
    }
    final percentText = '${(pct! * 100).round()}% remaining';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(percentText, style: AetherType.display),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: Aether.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(
              pct! < 0.1 ? Aether.danger : Aether.accent,
            ),
          ),
        ),
      ],
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});
  final OvidModelUsage model;

  @override
  Widget build(BuildContext context) {
    final pct = model.remainingFraction;
    final label = pct == null
        ? 'Usage unavailable'
        : '${(pct * 100).round()}% remaining';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ovidModelLabel(model.model),
            style: TextStyle(
              fontSize: 12,
              fontFamily: Aether.mono,
              color: Aether.text,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: pct != null && pct < 0.15 ? Aether.danger : Aether.accent,
            ),
          ),
          const SizedBox(height: 4),
          if (pct != null)
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
}

/// Per-provider card.
///
/// Replaces the previous `ListTile` + chevron with a self-contained
/// [AetherCard] featuring an icon chip, provider title with a tier
/// [AetherPill], a mono counts row (reqs / in / out), and an
/// button that toggles an inline per-model breakdown. Tapping the
/// card still opens the full [ProviderUsageScreen] for charts and totals.
class _ProviderCard extends StatefulWidget {
  const _ProviderCard({required this.provider});
  final ProviderUsage provider;

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final countsLine =
        '${p.requests} requests · ${_fmtTok(p.tokensIn)} in · ${_fmtTok(p.tokensOut)} out';
    return InkWell(
      borderRadius: BorderRadius.circular(AetherRadius.rLg),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProviderUsageScreen(provider: p)),
      ),
      child: Stack(
        children: [
          AetherCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: p.color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(AetherRadius.rMd),
                        border: Border.all(
                          color: p.color.withValues(alpha: 0.25),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Icon(p.icon, size: 18, color: p.color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.providerName, style: AetherType.title),
                          const SizedBox(height: 4),
                          AetherPill(
                            label: p.tier,
                            color: p.tier == 'FREE'
                                ? Aether.success
                                : Aether.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  countsLine,
                  style: AetherType.bodyMuted.copyWith(
                    fontFamily: Aether.mono,
                    fontSize: 12,
                  ),
                ),
                if (p.models.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      label: Text(
                        _expanded
                            ? 'Hide models'
                            : 'Show ${p.models.length} model${p.models.length == 1 ? '' : 's'}',
                      ),
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      onPressed: () => setState(() => _expanded = !_expanded),
                    ),
                  ),
                  if (_expanded) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(AetherRadius.rMd),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final m in p.models)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: _ModelCounts(model: m),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Tooltip(
              message: 'View provider details',
              child: Semantics(
                button: true,
                label: 'View provider details',
                child: InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ProviderUsageScreen(provider: p),
                    ),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.open_in_new, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keep the complete model identifier readable even at large text sizes.
class _ModelCounts extends StatelessWidget {
  const _ModelCounts({required this.model});
  final (String, int, int) model;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(model.$1, style: AetherType.mono.copyWith(color: Aether.text)),
      const SizedBox(height: 4),
      Text(
        '${model.$2} req · ${_fmtTok(model.$3)} tok',
        style: AetherType.caption,
      ),
    ],
  );
}

/// Detailed per-provider usage screen.
class ProviderUsageScreen extends StatefulWidget {
  final ProviderUsage provider;
  const ProviderUsageScreen({super.key, required this.provider});

  @override
  State<ProviderUsageScreen> createState() => _ProviderUsageScreenState();
}

class _ProviderUsageScreenState extends State<ProviderUsageScreen> {
  ProviderUsage get provider => widget.provider;
  late final Object _initialRevision;
  late final Object _initialIdentity;

  @override
  void initState() {
    super.initState();
    // A caller-supplied snapshot remains a valid initial seed, but can never
    // resurrect counts after the live log has changed or been cleared.
    _initialRevision = (
      AppState.I.usageLog.length,
      AppState.I.usageLog.lastOrNull,
    );
    _initialIdentity = OvidCloudService.I.accountIdentity;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, OvidCloudService.I]),
      builder: (context, _) => _buildDetail(context),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final p =
        const UsageScreen()
            ._aggregate(AppState.I)
            .where((p) => p.providerId == provider.providerId)
            .firstOrNull ??
        ((_initialRevision ==
                    (
                      AppState.I.usageLog.length,
                      AppState.I.usageLog.lastOrNull,
                    ) &&
                _initialIdentity == OvidCloudService.I.accountIdentity)
            ? provider
            : ProviderUsage(
                providerId: provider.providerId,
                providerName: provider.providerName,
                tier: provider.tier,
                icon: provider.icon,
                color: provider.color,
                requests: 0,
                tokensIn: 0,
                tokensOut: 0,
                models: [],
              ));
    // Calendar-day buckets from measured tokens only. The shared activity
    // helper gives even empty days a minimum bar height, which would imply
    // activity here. Never turn a caller-supplied totals snapshot into history.
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final daily = List<int>.filled(14, 0);
    for (final entry in AppState.I.usageLog) {
      if (entry.providerId != p.providerId || entry.time.isAfter(now)) continue;
      final local = entry.time.toLocal();
      final date = DateTime.utc(local.year, local.month, local.day);
      final age = today.difference(date).inDays;
      if (age >= 0 && age < 14 && entry.totalTokens > 0) {
        daily[13 - age] += entry.totalTokens;
      }
    }
    final hasTrend = daily.where((tokens) => tokens > 0).length >= 2;
    final maxTokens = daily.reduce((a, b) => a > b ? a : b);
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth /
                        MediaQuery.textScalerOf(context).scale(1) <
                    280;
                final cells = [
                  _cell('Requests', '${p.requests}'),
                  _cell('Tokens in', _fmtTok(p.tokensIn)),
                  _cell('Tokens out', _fmtTok(p.tokensOut)),
                ];
                return stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final cell in cells)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: cell,
                            ),
                        ],
                      )
                    : Row(
                        children: [
                          for (final cell in cells) Expanded(child: cell),
                        ],
                      );
              },
            ),
          ),

          const _SectionLabel('LAST 14 DAYS · ACTIVITY SCOPE'),
          if (!hasTrend)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'Not enough recent activity for a trend.',
                style: AetherType.caption,
              ),
            )
          else
            Container(
              key: const ValueKey('usage-activity-chart'),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              decoration: BoxDecoration(
                color: Aether.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Aether.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Last 14 days · measured tokens · relative to busiest day',
                    style: AetherType.caption,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 72,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (var i = 0; i < daily.length; i++)
                          Expanded(
                            child: _ChartPoint(
                              date: today.subtract(Duration(days: 13 - i)),
                              tokens: daily[i],
                              maxTokens: maxTokens,
                              color: p.color,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 16,
                    runSpacing: 4,
                    children: [
                      Text(
                        '13 days ago',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Aether.textFaint,
                        ),
                      ),
                      Text(
                        'Today',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Aether.textFaint,
                        ),
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
                  for (final m in p.models)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: _ModelCounts(model: m),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(String label, String value) {
    return Column(
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
        Text(label, style: TextStyle(fontSize: 10.5, color: Aether.textFaint)),
      ],
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

class _ChartPoint extends StatelessWidget {
  const _ChartPoint({
    required this.date,
    required this.tokens,
    required this.maxTokens,
    required this.color,
  });

  final DateTime date;
  final int tokens;
  final int maxTokens;
  final Color color;

  String get _dateLabel => date.toIso8601String().split('T').first;

  @override
  Widget build(BuildContext context) {
    final label = '$_dateLabel: $tokens tokens';
    return Semantics(
      button: true,
      label: label,
      hint: 'Double tap to hear this day’s measured token value',
      onTap: () => ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(label))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: FractionallySizedBox(
          heightFactor: tokens / maxTokens,
          alignment: Alignment.bottomCenter,
          child: Container(
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.35 + tokens / maxTokens * 0.5),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
