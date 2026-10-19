import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/cloud_usage_store.dart';
import '../core/format.dart';
import '../core/legal_links.dart';
import '../core/ovid_cloud_service.dart';
import '../core/play_billing.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'cloud_usage_status.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/external_link.dart';

/// Plans & Billing screen.
///
/// The plan table — names, prices, multipliers, feature lines — comes from
/// the server (`/usage.plans`, the mint's live plan table; SH-006). The
/// current plan comes from the server too (`tier` / `plan` / `plan_name`).
/// [OvidPlanCatalog.fallback] mirrors the seed table only until the server
/// answers.
///
/// Paid plans are Google Play subscriptions ([PlayBillingService]). They are
/// offered only when the server reports `billing_enabled` AND Play returns
/// the products; Play's localised price then replaces the server's indicative
/// US-dollar price. When a plan cannot be bought from this copy of the app
/// (sideloaded build without Play Billing, or paid plans not on sale) the
/// screen says so plainly — never a disabled "Coming soon" button (R4,
/// SH-005, EM-015). The server verifies every purchase before the app
/// acknowledges it. Cancel and downgrade go through the Play subscription
/// centre.
///
/// Debug/profile builds (or [allowTestUpgrade]) keep the server test path
/// ([OvidCloudService.upgradeResult]) for QA while no Play product exists.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key, this.allowTestUpgrade, this.billing});

  /// Whether the server test-upgrade path may be offered when Google Play
  /// purchases are not available. Defaults to debug/profile builds only.
  final bool? allowTestUpgrade;

  /// Google Play billing; defaults to [PlayBillingService.I].
  final PlayBillingService? billing;

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

/// How plans can be bought right now.
enum _PurchaseMode {
  /// Google Play subscriptions.
  play,

  /// Server test activation (debug/QA only).
  test,

  /// Server enabled billing; Play products are still loading.
  playLoading,

  /// Server enabled billing but this copy of the app has no Google Play
  /// Billing (sideloaded build, no Play Store, products not published).
  playOnly,

  /// The server has no purchase path for this account yet.
  notOnSale,
}

/// Specific copy for every plan-change result (F-202).
String upgradeResultMessage(UpgradeResult result, {String? planTitle}) =>
    switch (result) {
      UpgradeResult.ok =>
        planTitle == null
            ? 'Your plan is active.'
            : 'You are now on the $planTitle plan.',
      UpgradeResult.pending =>
        'Payment pending. Your plan starts as soon as Google Play confirms '
            'the payment — you can close this screen.',
      UpgradeResult.cancelled => 'Purchase cancelled. Nothing was charged.',
      UpgradeResult.offline =>
        'You appear to be offline. Check your connection and try again.',
      UpgradeResult.notAvailable =>
        'Paid plans are not available yet. Nothing was charged.',
      UpgradeResult.rejected =>
        'Ovid Cloud could not confirm this plan for your account. Sign in '
            'again and retry. Unconfirmed Google Play payments are refunded '
            'automatically.',
      UpgradeResult.nothingToRestore =>
        'No active subscription found for this Google account.',
      UpgradeResult.confirming =>
        'Payment received. Ovid is still confirming it with Google Play — '
            'your plan starts automatically, and we retry every time you '
            'open the app.',
      UpgradeResult.unknown => 'Could not complete the upgrade. Try again.',
    };

/// Results after which retrying the same action can help.
bool upgradeResultRetryable(UpgradeResult result) => switch (result) {
  UpgradeResult.cancelled ||
  UpgradeResult.offline ||
  UpgradeResult.rejected ||
  UpgradeResult.unknown => true,
  _ => false,
};

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime value) {
  final d = value.toLocal();
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// "About 23× the Free allowance." from the plan's own multiplier.
String _planBlurb(OvidPlan plan, num freeMult) {
  if (plan.isFree) return 'Just chat — no card needed.';
  final ratio = freeMult > 0 ? plan.mult / freeMult : plan.mult;
  final r = ratio == ratio.roundToDouble()
      ? ratio.toInt().toString()
      : ratio.toStringAsFixed(1);
  return 'About $r× the Free allowance.';
}

/// Feature lines: the server's, else generated from the plan's numbers.
List<String> _planFeatures(OvidPlan plan, num freeMult) {
  if (plan.features.isNotEmpty) return plan.features;
  return [
    if (plan.isFree)
      'The standard Free allowance'
    else
      _planBlurb(plan, freeMult).replaceAll('.', ''),
    if (plan.window != null) 'Allowance resets every ${plan.window}',
    'All Ovid Cloud chat models',
  ];
}

class _BillingScreenState extends State<BillingScreen> {
  late final CloudUsageStore _store;
  late final PlayBillingService _billing;
  bool _billingRequested = false;
  bool _restoring = false;
  OvidUsage? get _usage => _store.usage;
  bool get _loading => _store.loading && _usage == null;

  @override
  void initState() {
    super.initState();
    _store = CloudUsageStore.acquire(AppState.I);
    _billing = widget.billing ?? PlayBillingService.I;
  }

  @override
  void dispose() {
    _store.release();
    super.dispose();
  }

  List<OvidPlan> get _plans {
    final server = _usage?.plans;
    return server != null && server.isNotEmpty
        ? server
        : OvidPlanCatalog.plans;
  }

  int _tierRank(String tier) =>
      _plans.indexWhere((p) => p.tier == tier || p.id == tier);

  _PurchaseMode _mode() {
    final testAllowed =
        (widget.allowTestUpgrade ?? !kReleaseMode) &&
        !OvidCloudService.I.upgradeDisabledByServer;
    if (_usage?.billingEnabled == true) {
      if (!_billingRequested) {
        _billingRequested = true;
        scheduleMicrotask(_billing.ensureLoaded);
      }
      if (_billing.available) return _PurchaseMode.play;
      if (testAllowed) return _PurchaseMode.test;
      return _billing.loaded ? _PurchaseMode.playOnly : _PurchaseMode.playLoading;
    }
    return testAllowed ? _PurchaseMode.test : _PurchaseMode.notOnSale;
  }

  /// Play's localised price when Play sells the plan; otherwise the server's
  /// indicative US-dollar price (SH-021). "Free" for the free plan.
  String? _priceFor(OvidPlan plan, _PurchaseMode mode) {
    if (plan.isFree) return 'Free';
    if (mode == _PurchaseMode.play) {
      final product = _billing.productFor(plan.tier);
      if (product != null) {
        return '${product.price} / ${_billing.periodLabel(plan.tier)}';
      }
    }
    return plan.indicativePrice;
  }

  Future<UpgradeOutcome> _purchase(OvidPlan plan, _PurchaseMode mode) =>
      mode == _PurchaseMode.play
      ? _billing.buy(plan.tier)
      : OvidCloudService.I.upgradeResult(plan.tier);

  Future<void> _manageSubscription() {
    final tier = _usage?.tier ?? OvidCloudService.I.confirmedTier ?? '';
    final productId = _usage?.planExpiresAt != null ||
            _billing.ownedProductId != null
        ? (_billing.ownedProductId ??
              OvidPlanCatalog.byTier(tier)?.productId ??
              kOvidPlayProducts[tier])
        : null;
    return openExternalLink(
      context,
      playSubscriptionCenterUri(productId: productId).toString(),
    );
  }

  Future<void> _restore() async {
    if (_restoring) return;
    setState(() => _restoring = true);
    final outcome = await _billing.restore();
    if (!mounted) return;
    setState(() => _restoring = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          outcome.ok
              ? 'Subscription restored.'
              : upgradeResultMessage(outcome.result),
        ),
      ),
    );
    if (outcome.ok) _store.refresh();
  }

  String? _unavailableCopy(_PurchaseMode mode) => switch (mode) {
    _PurchaseMode.play || _PurchaseMode.test => null,
    _PurchaseMode.playLoading => 'Loading plans from Google Play…',
    _PurchaseMode.playOnly =>
      'Upgrades are bought through Google Play. This copy of Ovid Si was not '
          'installed from the Play Store, so it cannot take payments. Install '
          'Ovid Si from Google Play to upgrade; your account and chats carry '
          'over.',
    _PurchaseMode.notOnSale =>
      'Paid plans cannot be bought in this version of the app yet. Your '
          'current plan and allowance are shown above.',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text(
          'Plans & Billing',
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async => _store.refresh(),
        child: AnimatedBuilder(
          // Only the plan inputs: usage, the confirmed tier, Play state. Not
          // every auth notification (SH-035).
          animation: Listenable.merge([_store, OvidCloudService.I, _billing]),
          builder: (_, _) => _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final mode = _mode();
    final canPurchase = mode == _PurchaseMode.play || mode == _PurchaseMode.test;
    final plans = _plans;
    final freeMult =
        plans.where((p) => p.isFree).firstOrNull?.mult ?? 1;
    final usage = _usage;
    final tier = usage?.tier ?? OvidCloudService.I.confirmedTier ?? '';
    final isPaid = usage?.isPaid ?? (tier.isNotEmpty && tier != 'free');
    final currentIndex = _tierRank(tier);
    final currentPlan = currentIndex >= 0 ? plans[currentIndex] : null;
    final nextPlan = (currentIndex >= 0 && currentIndex < plans.length - 1)
        ? plans[currentIndex + 1]
        : null;
    final expiresAt = usage?.planExpiresAt ?? _billing.expiresAt;
    final autoRenews = usage?.planAutoRenews ?? _billing.autoRenewing;
    // A Play-managed subscription is cancelled/downgraded in Play.
    final playManaged =
        isPaid &&
        (mode == _PurchaseMode.play ||
            expiresAt != null ||
            _billing.ownedTier != null);
    final unavailable = _unavailableCopy(mode);

    Widget checkout(OvidPlan p, String label, bool ghost, {Key? key}) =>
        _CheckoutButton(
          key: key,
          plan: p,
          ghost: ghost,
          label: label,
          isChange: currentIndex > 0,
          priceLabel: _priceFor(p, mode),
          blurb: _planBlurb(p, freeMult),
          play: mode == _PurchaseMode.play,
          purchase: () => _purchase(p, mode),
          abandon: mode == _PurchaseMode.play
              ? () => _billing.abandonPurchase(p.tier)
              : null,
        );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _CurrentPlanHeader(
          name: usage?.displayPlanName ?? currentPlan?.name,
          blurb: currentPlan == null ? null : _planBlurb(currentPlan, freeMult),
          isPaid: isPaid,
          loading: _loading,
          usage: usage,
          store: _store,
          renewal: isPaid && expiresAt != null
              ? (autoRenews == false
                    ? 'Ends on ${_formatDate(expiresAt)}'
                    : 'Renews on ${_formatDate(expiresAt)}')
              : null,
          onManage: playManaged ? _manageSubscription : null,
          upgrade: nextPlan != null && currentIndex >= 0 && canPurchase
              ? checkout(
                  nextPlan,
                  'Upgrade to ${nextPlan.name}',
                  false,
                  key: const ValueKey('upgrade-header'),
                )
              : null,
          unavailable: nextPlan != null && currentIndex >= 0 ? unavailable : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: AetherSectionTitle(
            eyebrow: 'Choose a plan',
            subtitle: mode == _PurchaseMode.play
                ? null
                : 'Prices in US dollars per month. Google Play shows your '
                      'local price at checkout.',
          ),
        ),
        for (final p in plans)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: _PlanCard(
              key: ValueKey('plan-${p.tier}'),
              plan: p,
              price: _priceFor(p, mode),
              multiplier: ovidMultiplierLabel(p.mult),
              features: _planFeatures(p, freeMult),
              isCurrent: currentIndex >= 0 && plans[currentIndex] == p,
              rank: plans.indexOf(p),
              currentRank: currentIndex,
              canPurchase: canPurchase,
              loadingPlay: mode == _PurchaseMode.playLoading,
              playManaged: playManaged,
              onManage: _manageSubscription,
              checkout: (label, ghost) => checkout(
                p,
                label,
                ghost,
                key: ValueKey('upgrade-${p.tier}'),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Text(switch (mode) {
            _PurchaseMode.play =>
              'Subscriptions are billed by Google Play in your local '
                  'currency and renew automatically until you cancel in '
                  'Google Play. Your plan changes after Ovid Cloud '
                  'confirms the purchase.',
            _PurchaseMode.test =>
              'Test activation is available only when enabled by the '
                  'server. Your plan changes after server confirmation.',
            // Said once: the header already explains it when it shows an
            // upgrade slot.
            _ => nextPlan != null && currentIndex >= 0 ? '' : unavailable ?? '',
          }, key: const ValueKey('billing-footnote'), style: AetherType.caption),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Always visible (SH-035): a new phone may need to restore
              // while Play is still loading; disabled with the reason.
              TextButton(
                key: const ValueKey('billing-restore'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _restoring || mode != _PurchaseMode.play
                    ? null
                    : _restore,
                child: Text(
                  _restoring
                      ? 'Restoring…'
                      : mode == _PurchaseMode.play
                      ? 'Restore purchases'
                      : 'Restore purchases (needs Google Play)',
                ),
              ),
              const ExternalLinkButton(label: 'Terms', url: LegalLinks.terms),
              const ExternalLinkButton(
                label: 'Privacy',
                url: LegalLinks.privacyPolicy,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Header summarising the current plan (from the server) and its allowance.
class _CurrentPlanHeader extends StatelessWidget {
  const _CurrentPlanHeader({
    required this.name,
    required this.blurb,
    required this.isPaid,
    required this.loading,
    required this.usage,
    required this.store,
    this.renewal,
    this.onManage,
    this.upgrade,
    this.unavailable,
  });

  /// Server plan name; null only while nothing is known yet.
  final String? name;
  final String? blurb;
  final bool isPaid;
  final bool loading;
  final OvidUsage? usage;
  final CloudUsageStore store;

  /// "Renews on …" / "Ends on …" for a paid subscription (F-198).
  final String? renewal;

  /// Opens the Google Play subscription centre (cancel, downgrade, payment).
  final VoidCallback? onManage;

  /// "Upgrade" CTA to the next tier, reachable without scrolling.
  final Widget? upgrade;

  /// Shown instead of [upgrade] when nothing can be bought here.
  final String? unavailable;

  @override
  Widget build(BuildContext context) {
    final pct = usage?.remainingFraction;
    final resetsAt = usage?.resetsAt;
    final pillColor = isPaid ? Aether.accent : Aether.textMuted;
    final known = name != null && name!.isNotEmpty;
    final title = known
        ? name!
        : loading
        ? 'Loading your plan…'
        : 'Your plan';

    final card = AetherCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (known)
                AetherPill(
                  label: name!.toUpperCase(),
                  color: pillColor,
                  filled: true,
                ),
              Text('Current plan', style: AetherType.label),
            ],
          ),
          const SizedBox(height: 10),
          Text(title, key: const ValueKey('billing-plan-name'), style: AetherType.h1),
          if (blurb != null) ...[
            const SizedBox(height: 4),
            Text(blurb!, style: AetherType.bodyMuted),
          ],
          if (renewal != null) ...[
            const SizedBox(height: 6),
            Text(
              renewal!,
              key: const ValueKey('billing-renewal'),
              style: AetherType.label,
            ),
          ],
          const SizedBox(height: 14),
          if (loading)
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (pct != null)
            _UsageBar(pct: pct, resetsAt: resetsAt),
          CloudUsageStatus(store: store),
          if (upgrade != null) ...[
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: upgrade),
          ] else if (unavailable != null) ...[
            const SizedBox(height: 16),
            Text(
              unavailable!,
              key: const ValueKey('paid-plans-unavailable'),
              style: AetherType.label,
            ),
          ],
          if (onManage != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: _BillingButton(
                buttonKey: const ValueKey('billing-manage'),
                ghost: true,
                label: 'Manage subscription',
                onPressed: onManage,
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
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: card,
        ),
      ],
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.pct, required this.resetsAt});
  final double pct;
  final DateTime? resetsAt;

  @override
  Widget build(BuildContext context) {
    final low = pct < 0.1;
    final reset = resetsAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 8,
            backgroundColor: Aether.surfaceAlt,
            valueColor: AlwaysStoppedAnimation(
              low ? Aether.danger : Aether.accent,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('${(pct * 100).round()}% remaining', style: AetherType.caption),
        if (reset != null)
          Text(formatResetLabel(reset), style: AetherType.caption),
        if (low)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              // What happens at 0 (SH-035).
              reset == null
                  ? 'When it runs out, chats pause until the allowance resets '
                        'or you upgrade.'
                  : 'When it runs out, chats pause until '
                        '${formatLocalDateTime(reset)} or you upgrade.',
              key: const ValueKey('billing-low-explainer'),
              style: AetherType.caption.copyWith(color: Aether.danger),
            ),
          ),
      ],
    );
  }
}

/// A single plan tile; the active plan gets an accent border.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.price,
    required this.multiplier,
    required this.features,
    required this.isCurrent,
    required this.rank,
    required this.currentRank,
    required this.canPurchase,
    required this.loadingPlay,
    required this.playManaged,
    required this.onManage,
    required this.checkout,
  });

  final OvidPlan plan;

  /// Play price, the server's indicative price, or "Free".
  final String? price;
  final String multiplier;
  final List<String> features;
  final bool isCurrent;
  final int rank;
  final int currentRank;
  final bool canPurchase;
  final bool loadingPlay;

  /// The current paid plan is a Play subscription: lower tiers and Free are
  /// reached through the Play subscription centre.
  final bool playManaged;
  final VoidCallback onManage;
  final Widget Function(String label, bool ghost) checkout;

  @override
  Widget build(BuildContext context) {
    final isBelow = currentRank >= 0 && rank < currentRank;
    final isFree = plan.isFree;

    final Widget action;
    if (isCurrent) {
      action = const SizedBox(
        width: double.infinity,
        child: _BillingButton(label: 'Current plan', onPressed: null),
      );
    } else if (isBelow && playManaged) {
      // Downgrade / cancel happen in Google Play at the end of the paid
      // period; there is no in-app proration for lower tiers.
      action = SizedBox(
        key: ValueKey('manage-${plan.tier}'),
        width: double.infinity,
        child: _BillingButton(
          ghost: true,
          label: isFree ? 'Cancel in Google Play' : 'Change in Google Play',
          onPressed: onManage,
        ),
      );
    } else if (isFree) {
      action = Text('Included with your account', style: AetherType.bodyMuted);
    } else if (!canPurchase) {
      // No fake button (R4): say it, once, as text.
      action = Text(
        loadingPlay ? 'Loading from Google Play…' : 'Not available in this app',
        key: ValueKey('not-purchasable-${plan.tier}'),
        style: AetherType.bodyMuted,
      );
    } else if (isBelow) {
      action = checkout('Change plan', true);
    } else {
      action = checkout('Upgrade', false);
    }

    final card = AetherCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(plan.name, style: AetherType.h2)),
              AetherPill(label: multiplier, color: Aether.accent, filled: true),
            ],
          ),
          if (price != null) ...[
            const SizedBox(height: 12),
            Text(price!, style: AetherType.display),
          ],
          const SizedBox(height: 14),
          for (final feature in features)
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
          action,
        ],
      ),
    );

    if (!isCurrent) return MergeSemantics(child: card);
    return Semantics(
      selected: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AetherRadius.rLg),
          border: Border.all(color: Aether.accent, width: 1.5),
        ),
        child: card,
      ),
    );
  }
}

/// The plan-change CTA. Opens [_CheckoutSheet], which owns its own busy and
/// error state so a rebuilt/disposed button never strands the sheet.
class _CheckoutButton extends StatelessWidget {
  const _CheckoutButton({
    super.key,
    required this.plan,
    required this.ghost,
    required this.label,
    required this.isChange,
    required this.priceLabel,
    required this.blurb,
    required this.play,
    required this.purchase,
    this.abandon,
  });
  final OvidPlan plan;
  final bool ghost;
  final String label;
  final bool isChange;
  final String? priceLabel;
  final String blurb;
  final bool play;
  final Future<UpgradeOutcome> Function() purchase;
  final VoidCallback? abandon;

  void _open(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    showModalBottomSheet<UpgradeOutcome>(
      context: context,
      backgroundColor: Aether.surface,
      isScrollControlled: true,
      useSafeArea: true,
      // The sheet blocks back/scrim while busy via PopScope; drag-to-close
      // bypasses PopScope, so it is off for checkout (F-201).
      enableDrag: false,
      builder: (_) => _CheckoutSheet(
        plan: plan,
        heading: '${ghost || isChange ? 'Change' : 'Upgrade'} to ${plan.name}',
        priceLabel: priceLabel,
        blurb: blurb,
        play: play,
        isChange: isChange,
        purchase: purchase,
        abandon: abandon,
      ),
    ).then((outcome) {
      if (outcome == null || !outcome.ok || !messenger.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            upgradeResultMessage(outcome.result, planTitle: plan.name),
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: _BillingButton(
        ghost: ghost,
        label: label,
        onPressed: () => _open(context),
      ),
    );
  }
}

class _CheckoutSheet extends StatefulWidget {
  const _CheckoutSheet({
    required this.plan,
    required this.heading,
    required this.priceLabel,
    required this.blurb,
    required this.play,
    required this.isChange,
    required this.purchase,
    this.abandon,
  });
  final OvidPlan plan;
  final String heading;
  final String? priceLabel;
  final String blurb;
  final bool play;
  final bool isChange;
  final Future<UpgradeOutcome> Function() purchase;

  /// Gives up on a Play sheet that never answered (SH-014).
  final VoidCallback? abandon;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  /// After this long without a Play answer the sheet offers Cancel (SH-014).
  static const stuckAfter = Duration(seconds: 30);

  bool _busy = false;
  bool _stuck = false;
  Timer? _stuckTimer;
  UpgradeOutcome? _failure;

  @override
  void dispose() {
    _stuckTimer?.cancel();
    super.dispose();
  }

  Future<void> _pay() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stuck = false;
      _failure = null;
    });
    _stuckTimer?.cancel();
    _stuckTimer = Timer(stuckAfter, () {
      if (mounted && _busy) setState(() => _stuck = true);
    });
    final outcome = await widget.purchase();
    _stuckTimer?.cancel();
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(outcome);
      return;
    }
    // Failure keeps the sheet open with the reason inline (F-201/F-202).
    setState(() {
      _busy = false;
      _stuck = false;
      _failure = outcome;
    });
  }

  void _giveUp() {
    widget.abandon?.call();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure?.result;
    final terminal = failure != null && !upgradeResultRetryable(failure);
    final price = widget.priceLabel;
    return PopScope(
      canPop: !_busy || _stuck,
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.heading, style: AetherType.h2),
                const SizedBox(height: 6),
                Text(
                  price == null ? widget.blurb : '$price · ${widget.blurb}',
                  style: AetherType.bodyMuted,
                ),
                const SizedBox(height: 14),
                if (widget.play) ...[
                  Text(
                    'Billed ${price ?? 'at the price shown by Google Play'} '
                    'through Google Play. Renews automatically each period '
                    'until you cancel; cancel anytime in Google Play → '
                    'Payments & subscriptions. Taxes are included where '
                    'required.',
                    key: const ValueKey('billing-terms'),
                    style: AetherType.caption,
                  ),
                  if (widget.isChange) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Your current plan is replaced right away; Google Play '
                      'charges only the prorated difference for this period.',
                      style: AetherType.caption,
                    ),
                  ],
                  Wrap(
                    children: const [
                      ExternalLinkButton(label: 'Terms', url: LegalLinks.terms),
                      ExternalLinkButton(
                        label: 'Privacy',
                        url: LegalLinks.privacyPolicy,
                      ),
                    ],
                  ),
                ] else
                  Text(
                    'Test activation is available only when enabled by the server. '
                    'No payment is taken; activation is confirmed by the server.',
                    style: AetherType.caption,
                  ),
                if (failure != null) ...[
                  const SizedBox(height: 14),
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      key: const ValueKey('billing-sheet-error'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(AetherRadius.rSm),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: Text(
                        upgradeResultMessage(failure, planTitle: widget.plan.name),
                        style: AetherType.body,
                      ),
                    ),
                  ),
                ],
                if (_stuck) ...[
                  const SizedBox(height: 14),
                  Text(
                    'Google Play has not answered yet. If you closed the Play '
                    'sheet, cancel here — a payment that did go through is '
                    'still confirmed automatically.',
                    key: const ValueKey('billing-sheet-stuck'),
                    style: AetherType.caption,
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: terminal
                      ? _BillingButton(
                          buttonKey: const ValueKey('billing-sheet-close'),
                          label: 'Close',
                          onPressed: () => Navigator.pop(context),
                        )
                      : _BillingButton(
                          buttonKey: const ValueKey('billing-pay-now'),
                          label: failure != null
                              ? 'Retry'
                              : widget.play
                              ? 'Subscribe${price == null ? '' : ' · $price'}'
                              : 'Activate test plan',
                          busy: _busy,
                          onPressed: _busy ? null : _pay,
                        ),
                ),
                if (!terminal) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      key: const ValueKey('billing-sheet-cancel'),
                      onPressed: !_busy
                          ? () => Navigator.pop(context)
                          : _stuck
                          ? _giveUp
                          : null,
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
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
      backgroundColor: ghost ? Colors.transparent : Aether.accent,
      foregroundColor: ghost ? Aether.text : (Aether.dark ? Colors.black : Colors.white),
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
