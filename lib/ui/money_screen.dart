import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';
import '../core/format.dart';
import '../core/image_studio.dart';
import '../core/ovid_cloud_service.dart';
import '../core/plan_identity.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'cloud_usage_status.dart';
import 'image_receipt_panel.dart';
import 'widgets/aether_primitives.dart';

/// Money — the premium "Account & billing" surface.
///
/// One screen with three tabs:
///
/// * **Overview** — the plan hero ([MoneyPlanHero]): plan pill, remaining
///   allowance with progress bar, refresh, and the next-plan call-to-action,
///   plus a quiet summary of the current plan.
/// * **Usage** — per-model remaining allowance, device-measured BYOK usage,
///   and account-scoped image receipts ([MoneyUsageView]).
/// * **Plans** — the four plan cards with INR pricing ([MoneyPlansView]).
///
/// The same building blocks back the legacy [BillingScreen] / [UsageScreen]
/// routes, so there is exactly ONE hero implementation, ONE plan-card list,
/// and ONE usage view across the app. Plan names, multipliers, and prices
/// come from [PlanIdentity] — INR only, never USD. Tier state and upgrades
/// stay server-authoritative via [OvidCloudService] / [CloudUsageStore].
enum MoneyTab { overview, usage, plans }

class MoneyScreen extends StatefulWidget {
  const MoneyScreen({super.key, this.initialTab = MoneyTab.overview});

  /// Tab shown when the screen opens.
  final MoneyTab initialTab;

  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  late MoneyTab _tab = widget.initialTab;
  late final CloudUsageStore _store;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
  }

  @override
  void dispose() {
    _store.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        toolbarHeight: MediaQuery.textScalerOf(context).scale(20) > 30 ? 88 : 56,
        title: const Text('Money'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: AetherSegmentedControl<MoneyTab>(
              options: const [
                (
                  value: MoneyTab.overview,
                  label: 'Overview',
                  icon: Icons.account_balance_wallet_outlined,
                ),
                (
                  value: MoneyTab.usage,
                  label: 'Usage',
                  icon: Icons.query_stats,
                ),
                (
                  value: MoneyTab.plans,
                  label: 'Plans',
                  icon: Icons.workspace_premium_outlined,
                ),
              ],
              value: _tab,
              onChanged: (tab) => setState(() => _tab = tab),
            ),
          ),
          Expanded(
            child: switch (_tab) {
              MoneyTab.overview => _MoneyOverviewTab(store: _store),
              MoneyTab.usage => ListView(
                padding: const EdgeInsets.only(bottom: 40),
                children: [MoneyUsageView(store: _store)],
              ),
              MoneyTab.plans => ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [MoneyPlansView(store: _store)],
              ),
            },
          ),
        ],
      ),
    );
  }
}

/// Overview tab: the plan hero plus a quiet current-plan summary.
class _MoneyOverviewTab extends StatelessWidget {
  const _MoneyOverviewTab({required this.store});

  final CloudUsageStore store;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        MoneyPlanHero(store: store),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: AetherSectionTitle(eyebrow: 'Account & billing'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: AetherCard(
            padding: const EdgeInsets.all(18),
            child: _CurrentPlanFacts(store: store),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(
            'Prices are in INR. Test activation is available only when '
            'enabled by the server. Your plan changes after server confirmation.',
            style: AetherType.caption,
          ),
        ),
      ],
    );
  }
}

/// Live facts about the current plan, sourced from [PlanIdentity].
class _CurrentPlanFacts extends StatelessWidget {
  const _CurrentPlanFacts({required this.store});

  final CloudUsageStore store;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, store]),
      builder: (_, _) {
        // The Money surface follows the billing rule: only a server snapshot
        // or the identity-scoped confirmed tier names the current plan.
        final tier =
            store.usage?.tier ?? (OvidCloudService.I.confirmedTier ?? '');
        final plan = PlanIdentity.forTier(tier);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _fact('Plan', plan?.title ?? 'Unknown'),
            _fact(
              'Allowance',
              plan == null ? '—' : '${plan.multiplierLabel} the Free base',
            ),
            _fact(
              'Billing',
              plan == null ? '—' : '${plan.priceLabel} · INR',
            ),
          ],
        );
      },
    );
  }

  Widget _fact(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AetherType.bodyMuted)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: AetherType.body.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

/// Marketing copy per plan. Kept next to the cards that render it; the
/// identity facts (name, multiplier, price) live in [PlanIdentity].
String planBlurb(PlanIdentity plan) => switch (plan.tier) {
  'free' => 'Just chat — no card needed.',
  _ => '${plan.multiplier}× the Free base usage allowance.',
};

List<String> planIncludes(PlanIdentity plan) => switch (plan.tier) {
  'free' => <String>[
    'Shared base allowance across all models',
    'No credit card required',
  ],
  _ => <String>['${plan.multiplier}× the Free base allowance'],
};

/// THE plan hero — pill, remaining allowance, progress bar, refresh, and
/// next-plan CTA. This is the only hero implementation; the Money overview,
/// the billing route, and the usage route all embed this same widget.
///
/// Server-authoritative data from [CloudUsageStore] drives the pill
/// (FREE/PLUS/PRO/MAX via [PlanIdentity.pillLabel]) and the remaining
/// fraction; freshness and errors surface via [CloudUsageStatus].
///
/// When no server snapshot exists, the billing surfaces
/// ([trustPersistedTier] == false) only present the identity-scoped tier the
/// service confirmed this session — an unscoped persisted plan is never
/// presented as the account's plan — while the usage surface
/// ([trustPersistedTier] == true) may show the persisted local plan.
class MoneyPlanHero extends StatelessWidget {
  const MoneyPlanHero({
    super.key,
    required this.store,
    this.trustPersistedTier = false,
  });

  /// The shared allowance projection. Owned by the host screen.
  final CloudUsageStore store;

  /// Whether the persisted local plan ([AppState.ovidCloudTier]) may stand in
  /// when the server has not confirmed one. Billing keeps this off.
  final bool trustPersistedTier;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: Listenable.merge([app, store]),
      builder: (_, _) {
        final usage = store.usage;
        final loading = store.loading && usage == null;
        final tier =
            usage?.tier ??
            (trustPersistedTier
                ? app.ovidCloudTier
                : (OvidCloudService.I.confirmedTier ?? ''));
        final isPaid =
            usage?.isPaid ??
            (trustPersistedTier
                ? app.ovidCloudIsPaid
                : (tier.isNotEmpty && tier != 'free'));
        final plan = PlanIdentity.forTier(tier);
        final nextPlan = PlanIdentity.nextAfter(tier);
        final pct = usage?.remainingFraction;
        final pillText = tier.isEmpty
            ? 'UNKNOWN'
            : PlanIdentity.pillLabel(tier, isPaid: isPaid);
        final statusCaption = usage == null
            ? 'Saved plan · awaiting server confirmation'
            : (store.stale || store.error != null)
            ? 'Last known plan and allowance'
            : 'Server-confirmed plan and allowance';

        final card = AetherCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 18,
                          color: Aether.accent,
                        ),
                        Text('Ovid Cloud', style: AetherType.title),
                        AetherPill(
                          label: pillText,
                          color: isPaid ? Aether.accent : Aether.textMuted,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh allowance',
                    onPressed: store.refresh,
                    icon: Icon(Icons.sync, size: 18, color: Aether.textMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                plan == null ? 'Plan unavailable' : plan.title,
                style: AetherType.h1,
              ),
              const SizedBox(height: 4),
              Text(
                plan == null
                    ? 'Refresh to verify this account’s cloud plan.'
                    : planBlurb(plan),
                style: AetherType.bodyMuted,
              ),
              const SizedBox(height: 14),
              if (loading)
                const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                _RemainingHero(pct: pct),
              const SizedBox(height: 10),
              Text(statusCaption, style: AetherType.caption),
              CloudUsageStatus(store: store),
              if (nextPlan != null) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: _UpgradeButton(
                    plan: nextPlan,
                    ghost: false,
                    label: 'Upgrade',
                    buttonKey: const ValueKey('upgrade-header'),
                  ),
                ),
              ],
            ],
          ),
        );

        return Stack(
          children: [
            const AetherGradientHeader(height: 110, child: SizedBox.expand()),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: card,
            ),
          ],
        );
      },
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

/// The plans section: eyebrow, the four [PlanIdentity] cards, and the INR
/// footnote. Shared by the Money "Plans" tab and the billing route so the
/// pricing surface exists exactly once.
class MoneyPlansView extends StatelessWidget {
  const MoneyPlansView({
    super.key,
    required this.store,
    this.trustPersistedTier = false,
  });

  /// The shared allowance projection. Owned by the host screen.
  final CloudUsageStore store;

  /// Whether the persisted local plan may mark a card current when the server
  /// has not confirmed one. Billing keeps this off — see [MoneyPlanHero].
  final bool trustPersistedTier;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, store]),
      builder: (_, _) {
        final usage = store.usage;
        final loading = store.loading && usage == null;
        final tier =
            usage?.tier ??
            (trustPersistedTier
                ? AppState.I.ovidCloudTier
                : (OvidCloudService.I.confirmedTier ?? ''));
        final currentRank = PlanIdentity.rankOf(tier);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
              child: AetherSectionTitle(
                eyebrow: 'Choose a plan',
                subtitle: usage == null && !loading
                    ? 'Plans scale off the shared Free base allowance.'
                    : null,
              ),
            ),
            for (final plan in PlanIdentity.all)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: _MoneyPlanCard(
                  key: ValueKey('plan-${plan.tier}'),
                  plan: plan,
                  currentTier: tier,
                  currentRank: currentRank,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Prices are in INR. Test activation is available only when '
                'enabled by the server. Your plan changes after server confirmation.',
                style: AetherType.caption,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A single plan tile. Uses [AetherCard] as the base surface and promotes
/// the active plan with an accent border.
class _MoneyPlanCard extends StatelessWidget {
  const _MoneyPlanCard({
    super.key,
    required this.plan,
    required this.currentTier,
    required this.currentRank,
  });

  final PlanIdentity plan;
  final String currentTier;
  final int currentRank;

  @override
  Widget build(BuildContext context) {
    final isCurrent = plan.tier == currentTier;
    final isBelow = PlanIdentity.rankOf(plan.tier) < currentRank;
    final isFree = plan.tier == 'free';

    final card = AetherCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(plan.title, style: AetherType.h2)),
              AetherPill(
                label: plan.multiplierLabel,
                color: Aether.accent,
                filled: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(plan.priceLabel, style: AetherType.display),
          const SizedBox(height: 14),
          for (final feature in planIncludes(plan))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Aether.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(feature, style: AetherType.body)),
                ],
              ),
            ),
          const SizedBox(height: 14),
          if (isCurrent)
            const SizedBox(
              width: double.infinity,
              child: _BillingButton(label: 'Current plan', onPressed: null),
            )
          else if (isFree)
            Text('Included with your account', style: AetherType.bodyMuted)
          else if (isBelow || currentRank < 0)
            _UpgradeButton(plan: plan, ghost: true, label: 'Change plan')
          else
            _UpgradeButton(plan: plan, ghost: false, label: 'Upgrade'),
        ],
      ),
    );

    if (!isCurrent) return card;
    // Accent-outlined overlay for the currently-active plan.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        border: Border.all(color: Aether.accent, width: 1.5),
      ),
      child: card,
    );
  }
}

/// The plan-change CTA. Opens a bottom sheet with a "Pay now"
/// button, which calls [OvidCloudService.upgrade] directly — the test
/// bypass flips the server into instant-grant mode without changing the
/// client wiring.
class _UpgradeButton extends StatefulWidget {
  const _UpgradeButton({
    required this.plan,
    required this.ghost,
    required this.label,
    this.buttonKey,
  });
  final PlanIdentity plan;
  final bool ghost;
  final String label;

  /// Overrides the inner tappable's `upgrade-<tier>` key. The header CTA
  /// passes a distinct key so it never collides with the plan card's button
  /// for the same tier (which would make `find.byKey` ambiguous).
  final Key? buttonKey;

  @override
  State<_UpgradeButton> createState() => _UpgradeButtonState();
}

class _UpgradeButtonState extends State<_UpgradeButton> {
  bool _busy = false;

  Future<void> _payNow(BuildContext sheetContext, StateSetter setSheet) async {
    if (_busy) return;
    final plan = widget.plan;
    // A confirmed plan refresh can replace this card/header and dispose its
    // button before the service finishes refreshing models. The sheet and
    // screen messenger own completion feedback, not the initiating button.
    final messenger = ScaffoldMessenger.of(context);
    setSheet(() => _busy = true);
    final newTier = await OvidCloudService.I.upgrade(plan.tier);
    _busy = false;
    if (sheetContext.mounted) Navigator.of(sheetContext).pop();
    if (!messenger.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          newTier == plan.tier
              ? 'You are now on the ${plan.title} plan.'
              : 'Could not complete the upgrade. Try again.',
        ),
      ),
    );
  }

  void _openSheet() {
    final plan = widget.plan;
    final heading = '${widget.ghost ? 'Change' : 'Upgrade'} to ${plan.title}';
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Aether.surface,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(heading, style: AetherType.h2),
                  const SizedBox(height: 6),
                  Text(
                    '${plan.priceLabel} · ${planBlurb(plan)}',
                    style: AetherType.bodyMuted,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Test activation is available only when enabled by the server. '
                    'Pay now requests this plan; activation is confirmed by the server.',
                    style: AetherType.caption,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: _BillingButton(
                      buttonKey: const ValueKey('billing-pay-now'),
                      label: 'Pay now · ${plan.priceLabel}',
                      busy: _busy,
                      onPressed: _busy
                          ? null
                          : () => _payNow(sheetCtx, setSheet),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _busy ? null : () => Navigator.pop(sheetCtx),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = widget.buttonKey ?? ValueKey('upgrade-${widget.plan.tier}');
    if (widget.ghost) {
      return SizedBox(
        key: key,
        width: double.infinity,
        child: _BillingButton(
          ghost: true,
          label: widget.label,
          onPressed: _openSheet,
        ),
      );
    }
    return SizedBox(
      key: key,
      width: double.infinity,
      child: _BillingButton(label: widget.label, onPressed: _openSheet),
    );
  }
}

/// Billing labels may wrap at accessibility text sizes; minimum height is a
/// touch target, never a fixed box that clips the label.
class _BillingButton extends StatelessWidget {
  const _BillingButton({
    required this.label,
    required this.onPressed,
    this.buttonKey,
    this.ghost = false,
    this.busy = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Key? buttonKey;
  final bool ghost;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? Semantics(
            label: 'Requesting plan change',
            liveRegion: true,
            child: const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : Text(label, textAlign: TextAlign.center);
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
      ),
      textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      backgroundColor: ghost ? Colors.transparent : Aether.accentC,
      foregroundColor: ghost
          ? Aether.text
          : (Aether.dark ? Colors.black : Colors.white),
    );
    if (ghost) {
      return TextButton(
        key: buttonKey,
        style: style,
        onPressed: onPressed,
        child: child,
      );
    }
    return FilledButton(
      key: buttonKey,
      style: style,
      onPressed: onPressed,
      child: child,
    );
  }
}

/// ═══════════════════════════════════════════════════════════════════
/// PROVIDER-WISE usage tracking — "kisne kitna khaya" view.
/// ───────────────────────────────────────────────────────────────────
/// Aggregated from [AppState.usageLog] — real token counts metered per
/// model call by the agent loop, with server-authoritative remaining usage
/// for Ovid Cloud. Costs are never estimated or rendered: INR plan pricing
/// lives in [PlanIdentity]; there is no USD table anywhere in this flow.
/// ═══════════════════════════════════════════════════════════════════

class ProviderUsage {
  final String providerId;
  final String providerName;
  final String tier; // 'FREE' | 'BYOK'
  final IconData icon;
  final Color color;
  int requests;
  int tokensIn;
  int tokensOut;
  double costUsd; // legacy aggregate field, never rendered
  bool hasPricedModel; // legacy aggregate field, never rendered
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

/// Aggregate the real usage log into per-provider summaries.
///
/// The built-in Ovid Cloud provider is intentionally EXCLUDED here: its usage
/// is server-authoritative (fetched from `/usage`, shown by the plan hero via
/// [CloudUsageStore]), not computed from the device-side log. Custom and other
/// built-in providers (the user's own keys) stay app-side as before.
List<ProviderUsage> _aggregateProviderUsage(AppState app) {
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
    // Per-model aggregation (in+out split kept for the detail view).
    final m = p.models.where((m) => m.$1 == e.model).firstOrNull;
    if (m != null) {
      p.models[p.models.indexOf(m)] = (m.$1, m.$2 + 1, m.$3 + e.totalTokens);
    } else {
      p.models.add((e.model, 1, e.totalTokens));
    }
  }
  return byId.values.toList()..sort((a, b) => b.requests.compareTo(a.requests));
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

/// The usage body: per-model remaining allowance, device-measured BYOK
/// totals and cards, and (optionally) the account-scoped image receipts.
/// Shared by the Money "Usage" tab and the usage route — one implementation.
class MoneyUsageView extends StatelessWidget {
  const MoneyUsageView({
    super.key,
    required this.store,
    this.includeReceipts = true,
  });

  /// The shared allowance projection. Owned by the host screen.
  final CloudUsageStore store;

  /// Whether the inline [ImageReceiptPanel] is included. The standalone
  /// usage route keeps receipts behind its app-bar menu instead.
  final bool includeReceipts;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: Listenable.merge([app, store]),
      builder: (_, _) {
        final usage = store.usage;
        final providers = _aggregateProviderUsage(app);
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---- Per-model remaining allowance (server-authoritative) ----
            if (usage != null && usage.models.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: AetherCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'AVAILABLE MODELS · remaining usage',
                        style: AetherType.caption.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.9,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final m in usage.models) _ModelRow(model: m),
                      const SizedBox(height: 4),
                      Text(
                        'All models share your plan’s usage allowance.',
                        style: AetherType.caption,
                      ),
                    ],
                  ),
                ),
              ),

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
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 22, 18, 10),
              child: AetherSectionTitle(
                eyebrow: 'By provider',
                subtitle: 'Local measured usage · other providers (BYOK & free).',
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

            // ---- Account-scoped image receipts ----
            if (includeReceipts)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
                child: ImageReceiptPanel(
                  studio: ImageStudio.I,
                  headers: OvidCloudService.I.imageHeaders,
                ),
              ),
          ],
        );
      },
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
        Text(
          'Other providers · measured on this device',
          style: AetherType.caption,
        ),
        const SizedBox(height: 8),
        AetherCard(
          padding: const EdgeInsets.all(16),
          child: Row(children: [_stat('Today’s tokens', _fmtTok(todayTokens))]),
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
/// A self-contained [AetherCard] featuring an icon chip, provider title with
/// a tier [AetherPill], a mono counts row (reqs / in / out), and a button
/// that toggles an inline per-model breakdown. Tapping the card opens the
/// full [ProviderUsageScreen] for charts and totals.
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
      child: AetherCard(
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
                    border: Border.all(color: p.color.withValues(alpha: 0.25)),
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
        _aggregateProviderUsage(
              AppState.I,
            ).where((p) => p.providerId == provider.providerId).firstOrNull ??
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

          const _SectionLabel('LAST 14 DAYS'),
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
                    'Daily measured tokens · relative to busiest day',
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
                            child: Semantics(
                              label:
                                  '${today.subtract(Duration(days: 13 - i)).toIso8601String().split('T').first}: ${daily[i]} tokens',
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2.5,
                                ),
                                child: FractionallySizedBox(
                                  heightFactor: daily[i] / maxTokens,
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: p.color.withValues(
                                        alpha:
                                            0.35 + daily[i] / maxTokens * 0.5,
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
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
        Text(
          label,
          style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
        ),
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
