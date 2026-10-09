import 'package:flutter/material.dart';

import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/format.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageAttempts] — observed per-attempt history.
/// web-IDE StatsLine + TurnUsage pattern,
/// with server-authoritative remaining usage for Ovid Cloud.
/// ═══════════════════════════════════════════════════════════════════

/// Approximate public list pricing per model family, USD per 1M tokens
/// (input, output). Internal only; costs are not rendered.
class _Pricing {
  final double inputPer1M;
  final double outputPer1M;
  const _Pricing(this.inputPer1M, this.outputPer1M);

  static const List<(String, _Pricing)> _table = [
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
  bool inputKnown;
  bool outputKnown;
  bool inputMeasuredKnown;
  bool outputMeasuredKnown;
  bool inputHasUnknown;
  bool outputHasUnknown;
  int measuredTotalTokens;
  bool measuredTotalKnown;
  bool hasMeasuredTotalUnknown;
  final Map<UsageProvenance, int> alternateTotals;
  final Set<UsageProvenance> provenances;
  int unknownTokenFields;
  double costUsd; // approx, only known models contribute
  bool hasPricedModel;
  List<UsageModelUsage> models;
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
    this.inputKnown = true,
    this.outputKnown = true,
    this.inputMeasuredKnown = false,
    this.outputMeasuredKnown = false,
    this.inputHasUnknown = false,
    this.outputHasUnknown = false,
    this.measuredTotalTokens = 0,
    this.measuredTotalKnown = false,
    this.hasMeasuredTotalUnknown = false,
    Map<UsageProvenance, int>? alternateTotals,
    Set<UsageProvenance>? provenances,
    this.unknownTokenFields = 0,
    this.costUsd = 0,
    this.hasPricedModel = false,
  }) : alternateTotals = alternateTotals ?? <UsageProvenance, int>{},
       provenances = provenances ?? <UsageProvenance>{};
}

class UsageModelUsage {
  UsageModelUsage(this.model);
  final String model;
  int requests = 0;
  int measuredTotal = 0;
  bool measuredTotalKnown = false;
  bool hasUnknownTotal = false;
  final Map<UsageProvenance, int> alternateTotals = {};
  final Set<UsageProvenance> provenances = {};
}

class UsageScreen extends StatelessWidget {
  const UsageScreen({super.key});

  /// Aggregate the retained attempt journal into observed per-provider history.
  /// The Ovid Cloud card is deliberately separate from the server allowance:
  /// this is what the device observed, not a billing projection.
  List<ProviderUsage> _aggregate(AppState app) {
    final byId = <String, ProviderUsage>{};
    for (final e in app.usageAttempts) {
      final config = app.providerById(e.provider);
      final providerName = e.provider == AppState.ovidCloudProviderId
          ? 'Ovid Cloud'
          : (config?.name ?? e.provider);
      final p = byId.putIfAbsent(
        e.provider,
        () => ProviderUsage(
          providerId: e.provider,
          providerName: providerName,
          tier: e.provider == AppState.ovidCloudProviderId
              ? 'CLOUD'
              : (config?.isFree ?? false)
              ? 'FREE'
              : 'BYOK',
          icon: _iconFor(providerName),
          color: _colorFor(providerName),
          requests: 0,
          tokensIn: 0,
          tokensOut: 0,
          models: [],
        ),
      );
      p.requests++;
      final tokens = [e.inputTokens, e.outputTokens, e.totalTokens];
      for (final token in tokens) {
        if (token == null || token.value == null) {
          p.unknownTokenFields++;
          p.provenances.add(UsageProvenance.unknown);
        } else {
          p.provenances.add(token.provenance);
        }
      }
      final input = e.inputTokens;
      final output = e.outputTokens;
      if (input?.provenance == UsageProvenance.providerReported &&
          input?.value != null) {
        p.inputKnown = true;
        p.inputMeasuredKnown = true;
        p.tokensIn += input!.value!;
      } else if (input == null || input.value == null) {
        p.inputHasUnknown = true;
        p.inputKnown = p.inputMeasuredKnown;
      } else {
        p.inputKnown = p.inputMeasuredKnown;
      }
      if (output?.provenance == UsageProvenance.providerReported &&
          output?.value != null) {
        p.outputKnown = true;
        p.outputMeasuredKnown = true;
        p.tokensOut += output!.value!;
      } else if (output == null || output.value == null) {
        p.outputHasUnknown = true;
        p.outputKnown = p.outputMeasuredKnown;
      } else {
        p.outputKnown = p.outputMeasuredKnown;
      }
      final total = e.totalTokens;
      if (total?.provenance == UsageProvenance.providerReported &&
          total?.value != null) {
        p.measuredTotalKnown = true;
        p.measuredTotalTokens += total!.value!;
      } else if (total == null || total.value == null) {
        p.hasMeasuredTotalUnknown = true;
      } else {
        p.alternateTotals.update(
          total.provenance,
          (value) => value + total.value!,
          ifAbsent: () => total.value!,
        );
      }
      final model = e.reportedModel == null
          ? 'Requested: ${e.requestedModel} · reported model unavailable'
          : e.reportedModel!;
      if (input?.provenance == UsageProvenance.providerReported &&
          output?.provenance == UsageProvenance.providerReported &&
          input?.value != null &&
          output?.value != null) {
        final cost = _Pricing.estimate(model, input!.value!, output!.value!);
        if (cost != null) {
          p
            ..costUsd += cost
            ..hasPricedModel = true;
        }
      }
      final m = p.models.where((m) => m.model == model).firstOrNull;
      final modelUsage = m ?? UsageModelUsage(model);
      if (m == null) p.models.add(modelUsage);
      modelUsage.requests++;
      if (total?.provenance == UsageProvenance.providerReported &&
          total?.value != null) {
        modelUsage.measuredTotalKnown = true;
        modelUsage.measuredTotal += total!.value!;
      } else if (total != null && total.value != null) {
        modelUsage.alternateTotals.update(
          total.provenance,
          (value) => value + total.value!,
          ifAbsent: () => total.value!,
        );
      }
      if (total == null || total.value == null) {
        modelUsage.hasUnknownTotal = true;
        modelUsage.provenances.add(UsageProvenance.unknown);
      } else {
        modelUsage.provenances.add(total.provenance);
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
          final todayEntries = app.usageAttempts.where((e) {
            final d = e.startedAt.toLocal();
            final now = DateTime.now();
            return d.year == now.year &&
                d.month == now.month &&
                d.day == now.day;
          }).toList();
          final todayMeasured = todayEntries.where(
            (e) =>
                e.totalTokens?.provenance == UsageProvenance.providerReported,
          );
          final todayTokens = todayMeasured.fold<int>(
            0,
            (s, e) => s + e.totalTokens!.value!,
          );
          final todayHasUnknown = todayEntries.any(
            (e) => e.totalTokens == null || e.totalTokens!.value == null,
          );
          final todayAlternate = <UsageProvenance, int>{};
          for (final e in todayEntries) {
            final total = e.totalTokens;
            if (total != null &&
                total.value != null &&
                total.provenance != UsageProvenance.providerReported) {
              todayAlternate.update(
                total.provenance,
                (value) => value + total.value!,
                ifAbsent: () => total.value!,
              );
            }
          }
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
                  inputKnown: providers.any((p) => p.inputKnown),
                  outputKnown: providers.any((p) => p.outputKnown),
                  inputHasUnknown: providers.any((p) => p.inputHasUnknown),
                  outputHasUnknown: providers.any((p) => p.outputHasUnknown),
                  hasUnknown: providers.any((p) => p.unknownTokenFields > 0),
                  todayHasUnknown: todayHasUnknown,
                  todayAlternate: todayAlternate,
                ),
              ),

              // ---- 'By provider' section ----
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                child: const AetherSectionTitle(
                  eyebrow: 'By provider',
                  subtitle: 'Observed attempts · retained device history.',
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
                    'Observed attempts are separate from the server allowance. '
                    'Unknown prices remain unavailable.',
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

String _displayTokenValue(int value, bool known, bool hasUnknown) {
  if (!known) return 'Unavailable';
  return hasUnknown ? '${_fmtTok(value)} · some unavailable' : _fmtTok(value);
}

String _formatProvenanceTotals(Map<UsageProvenance, int> totals) {
  final entries = totals.entries.toList()
    ..sort(
      (a, b) => _provenanceLabel(a.key).compareTo(_provenanceLabel(b.key)),
    );
  return entries
      .map((entry) => '${_provenanceLabel(entry.key)} ${_fmtTok(entry.value)}')
      .join(' · ');
}

String _provenanceLabel(UsageProvenance provenance) {
  switch (provenance) {
    case UsageProvenance.providerReported:
      return 'Reported';
    case UsageProvenance.locallyEstimated:
      return 'Estimated';
    case UsageProvenance.derived:
      return 'Derived';
    case UsageProvenance.legacyUnspecified:
      return 'Legacy';
    case UsageProvenance.unknown:
      return 'Unknown';
  }
}

String _provenanceSummary(ProviderUsage provider) {
  final labels = provider.provenances.map(_provenanceLabel).toSet().toList()
    ..sort();
  if (provider.unknownTokenFields > 0 && !labels.contains('Unknown')) {
    labels.add('Unknown');
  }
  return labels.join(' · ');
}

/// Today's token snapshot + "in · out" micro-banner, kept behaviourally
/// identical to the previous layout so downstream tests that assert these
/// exact text strings (`'30'`, `'20 in · 10 out'`) still pass under the
/// redesign.
class _LocalTotalsStrip extends StatelessWidget {
  const _LocalTotalsStrip({
    required this.todayTokens,
    required this.tokensIn,
    required this.tokensOut,
    required this.inputKnown,
    required this.outputKnown,
    required this.inputHasUnknown,
    required this.outputHasUnknown,
    required this.hasUnknown,
    required this.todayHasUnknown,
    required this.todayAlternate,
  });

  final int todayTokens;
  final int tokensIn;
  final int tokensOut;
  final bool inputKnown;
  final bool outputKnown;
  final bool inputHasUnknown;
  final bool outputHasUnknown;
  final bool hasUnknown;
  final bool todayHasUnknown;
  final Map<UsageProvenance, int> todayAlternate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Retained observed history', style: AetherType.caption),
        const SizedBox(height: 8),
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _stat(
                'Today · provider-reported tokens',
                todayHasUnknown
                    ? (todayTokens == 0
                          ? 'Unavailable'
                          : '${_fmtTok(todayTokens)} · some unavailable')
                    : _fmtTok(todayTokens),
              ),
            ],
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
                hasUnknown
                    ? 'Input · output · some values unavailable'
                    : 'Input · output · provider-reported usage',
                style: TextStyle(fontSize: 11, color: Aether.textFaint),
              ),
              if (hasUnknown)
                Text(
                  'Unavailable',
                  style: TextStyle(fontSize: 11, color: Aether.textFaint),
                ),
              Text(
                '${_displayTokenValue(tokensIn, inputKnown, inputHasUnknown)} in · '
                '${_displayTokenValue(tokensOut, outputKnown, outputHasUnknown)} out',
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
        if (todayAlternate.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            'Estimated/legacy totals · ${_formatProvenanceTotals(todayAlternate)}',
            style: AetherType.caption,
          ),
        ],
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
        '${p.requests} requests · '
        '${_displayTokenValue(p.tokensIn, p.inputKnown, p.inputHasUnknown)} in · '
        '${_displayTokenValue(p.tokensOut, p.outputKnown, p.outputHasUnknown)} out';
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
                if (_provenanceSummary(p).isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Token provenance · ${_provenanceSummary(p)}',
                    style: AetherType.caption,
                  ),
                ],
                if (p.measuredTotalKnown || p.hasMeasuredTotalUnknown) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Measured · ${p.hasMeasuredTotalUnknown ? 'Unavailable' : _fmtTok(p.measuredTotalTokens)}',
                    style: AetherType.caption,
                  ),
                ],
                if (p.alternateTotals.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Estimated/legacy · ${_formatProvenanceTotals(p.alternateTotals)}',
                    style: AetherType.caption,
                  ),
                ],
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
  final UsageModelUsage model;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(model.model, style: AetherType.mono.copyWith(color: Aether.text)),
      const SizedBox(height: 4),
      Text(
        '${model.requests} req · ${model.measuredTotalKnown && !model.hasUnknownTotal ? '${_fmtTok(model.measuredTotal)} provider-reported tok' : 'Unavailable total'}',
        style: AetherType.caption,
      ),
      if (model.alternateTotals.isNotEmpty)
        Text(
          'Estimated/legacy · ${_formatProvenanceTotals(model.alternateTotals)}',
          style: AetherType.caption,
        ),
      if (model.provenances.isNotEmpty)
        Text(
          'Provenance · ${model.provenances.map(_provenanceLabel).join(' · ')}',
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
      AppState.I.usageRevision,
      AppState.I.usageAttempts.lastOrNull,
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
                      AppState.I.usageRevision,
                      AppState.I.usageAttempts.lastOrNull,
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
    // Calendar-day buckets come from the attempt journal only. Legacy rows are
    // already migrated into that journal, so reading usageLog here would count
    // them a second time.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daily = List<int>.filled(14, 0);
    for (final entry in AppState.I.usageAttempts) {
      if (entry.provider != p.providerId || entry.startedAt.isAfter(now)) {
        continue;
      }
      final local = entry.startedAt.toLocal();
      final date = DateTime(local.year, local.month, local.day);
      final age = today.difference(date).inDays;
      final total = entry.totalTokens;
      if (age >= 0 &&
          age < 14 &&
          total?.provenance == UsageProvenance.providerReported &&
          total?.value != null &&
          total!.value! > 0) {
        daily[13 - age] += total.value!;
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
                  _cell(
                    'Tokens in',
                    _displayTokenValue(
                      p.tokensIn,
                      p.inputKnown,
                      p.inputHasUnknown,
                    ),
                  ),
                  _cell(
                    'Tokens out',
                    _displayTokenValue(
                      p.tokensOut,
                      p.outputKnown,
                      p.outputHasUnknown,
                    ),
                  ),
                  _cell(
                    'Measured total',
                    p.measuredTotalKnown && !p.hasMeasuredTotalUnknown
                        ? _fmtTok(p.measuredTotalTokens)
                        : 'Unavailable',
                  ),
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
                p.hasMeasuredTotalUnknown
                    ? 'Provider-reported totals unavailable for some attempts; not enough measured activity for a trend.'
                    : 'Provider-reported totals unavailable or not enough recent activity for a trend.',
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
                    'Last 14 days · Provider-reported measured tokens · relative to busiest day',
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
                  const SizedBox(height: 4),
                  Text(
                    'Legacy totals excluded from measured chart.',
                    style: AetherType.caption,
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
