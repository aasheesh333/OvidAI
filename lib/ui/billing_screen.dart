import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/firebase_service.dart';
import '../core/cloud_usage_store.dart';
import '../core/legal_links.dart';
import '../core/ovid_cloud_service.dart';
import '../core/play_billing.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'cloud_usage_status.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/external_link.dart';

/// Plans & Billing screen — premium Aether redesign.
///
/// Paid plans are Google Play subscriptions ([PlayBillingService]). They are
/// offered only when the server reports `billing_enabled` and Play returns the
/// products; prices are Play's localised [ProductDetails.price]. The server
/// verifies every purchase before the app acknowledges it. Cancel and
/// downgrade go through the Play subscription centre.
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

/// Single plan definition. Prices never live here: they come from Google
/// Play, localised to the user's market (F-199).
class _PlanOption {
  const _PlanOption(
    this.tier,
    this.title,
    this.blurb,
    this.multiplier,
    this.includes,
  );
  final String tier;
  final String title;
  final String blurb;
  final String multiplier;

  /// Fallback feature lines when the server sends no `plans` list.
  final List<String> includes;
}

const _plans = <_PlanOption>[
  _PlanOption('free', 'Free', 'Just chat — no card needed.', '×1', <String>[
    'Shared base allowance across all models',
    'No credit card required',
  ]),
  _PlanOption('3x', 'Plus', '3× the Free base usage allowance.', '×3', <String>[
    'All Ovid Cloud chat models',
    '3× the Free allowance, pooled over 30 days',
  ]),
  _PlanOption('7x', 'Pro', '7× the Free base usage allowance.', '×7', <String>[
    'All Ovid Cloud chat models',
    '7× the Free allowance, pooled over 30 days',
  ]),
  _PlanOption(
    '15x',
    'Max',
    '15× the Free base usage allowance.',
    '×15',
    <String>[
      'All Ovid Cloud chat models',
      '15× the Free allowance, pooled over 30 days',
    ],
  ),
];

/// How plans can be bought right now.
enum _PurchaseMode {
  /// Google Play subscriptions.
  play,

  /// Server test activation (debug/QA only).
  test,

  /// Server enabled billing; Play products are still loading.
  playLoading,

  /// Server enabled billing but Google Play is unavailable on this device.
  playUnavailable,

  /// Nothing is on sale yet.
  comingSoon,
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

  int _tierRank(String tier) => _plans.indexWhere((p) => p.tier == tier);

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
      return _billing.loaded
          ? _PurchaseMode.playUnavailable
          : _PurchaseMode.playLoading;
    }
    return testAllowed ? _PurchaseMode.test : _PurchaseMode.comingSoon;
  }

  String? _priceFor(_PlanOption plan, _PurchaseMode mode) {
    if (plan.tier == 'free') return 'Free';
    if (mode != _PurchaseMode.play) return null;
    final product = _billing.productFor(plan.tier);
    if (product == null) return null;
    return '${product.price} / ${_billing.periodLabel(plan.tier)}';
  }

  Future<UpgradeOutcome> _purchase(_PlanOption plan, _PurchaseMode mode) =>
      mode == _PurchaseMode.play
      ? _billing.buy(plan.tier)
      : OvidCloudService.I.upgradeResult(plan.tier);

  Future<void> _manageSubscription() => openExternalLink(
    context,
    playSubscriptionCenterUri(
      productId:
          _usage?.planExpiresAt != null || _billing.ownedProductId != null
          ? (_billing.ownedProductId ??
                kOvidPlayProducts[_usage?.tier ??
                    OvidCloudService.I.confirmedTier ??
                    ''])
          : null,
    ).toString(),
  );

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        toolbarHeight: MediaQuery.textScalerOf(context).scale(20) > 30
            ? 88
            : 56,
        title: const Text('Plans & Billing'),
      ),
      body: AnimatedBuilder(
        // Only the tier is read here: it changes through OvidCloudService
        // (which notifies) and the usage store — not on every AppState
        // notification such as streamed tokens of a background run.
        animation: Listenable.merge([
          FirebaseService.I,
          _store,
          OvidCloudService.I,
          _billing,
        ]),
        builder: (_, _) {
          final mode = _mode();
          final canPurchase =
              mode == _PurchaseMode.play || mode == _PurchaseMode.test;
          final tier = _usage?.tier ?? OvidCloudService.I.confirmedTier ?? '';
          final isPaid = _usage?.isPaid ?? (tier.isNotEmpty && tier != 'free');
          final currentPlan = _plans.firstWhere(
            (p) => p.tier == tier,
            orElse: () => _plans.first,
          );
          final currentRank = _tierRank(tier);
          final currentIndex = _plans.indexWhere((p) => p.tier == tier);
          final nextPlan =
              (currentIndex >= 0 && currentIndex < _plans.length - 1)
              ? _plans[currentIndex + 1]
              : null;
          final expiresAt = _usage?.planExpiresAt ?? _billing.expiresAt;
          final autoRenews = _usage?.planAutoRenews ?? _billing.autoRenewing;
          // A Play-managed subscription is cancelled/downgraded in Play.
          final playManaged =
              isPaid &&
              (mode == _PurchaseMode.play ||
                  expiresAt != null ||
                  _billing.ownedTier != null);
          final features = _usage?.planFeatures ?? const {};

          Widget checkout(
            _PlanOption p,
            String label,
            bool ghost, {
            Key? key,
          }) => _CheckoutButton(
            key: key,
            plan: p,
            ghost: ghost,
            label: label,
            isChange: currentRank > 0,
            priceLabel: _priceFor(p, mode),
            play: mode == _PurchaseMode.play,
            purchase: () => _purchase(p, mode),
          );

          // The header surfaces an "Upgrade" CTA targeting the next tier up,
          // so the primary action is reachable without scrolling through the
          // plan list on small screens.
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _CurrentPlanHeader(
                plan: currentPlan,
                hasTier: currentIndex >= 0,
                isPaid: isPaid,
                loading: _loading,
                usage: _usage,
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
                        'Upgrade',
                        false,
                        key: const ValueKey('upgrade-header'),
                      )
                    : null,
                comingSoon:
                    nextPlan != null && currentIndex >= 0 && !canPurchase
                    ? switch (mode) {
                        _PurchaseMode.playLoading => 'Loading plans…',
                        _PurchaseMode.playUnavailable =>
                          'Paid plans need Google Play. Update or sign in to the '
                              'Play Store, then reopen this screen.',
                        _ => 'Paid plans coming soon',
                      }
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
                child: AetherSectionTitle(
                  eyebrow: 'Choose a plan',
                  subtitle: _usage == null && !_loading
                      ? 'Plans scale off the shared Free base allowance.'
                      : null,
                ),
              ),
              for (final p in _plans)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: _PlanCard(
                    key: ValueKey('plan-${p.tier}'),
                    plan: p,
                    price: _priceFor(p, mode),
                    features: features[p.tier]?.isNotEmpty == true
                        ? features[p.tier]!
                        : p.includes,
                    currentTier: tier,
                    rank: _tierRank(p.tier),
                    currentRank: currentRank,
                    mode: mode,
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
                  _ =>
                    'Paid plans are coming soon; nothing can be purchased yet.',
                }, style: AetherType.caption),
              ),
              if (mode == _PurchaseMode.play)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        key: const ValueKey('billing-restore'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: _restoring ? null : _restore,
                        child: Text(
                          _restoring ? 'Restoring…' : 'Restore purchases',
                        ),
                      ),
                      const ExternalLinkButton(
                        label: 'Terms',
                        url: LegalLinks.terms,
                      ),
                      const ExternalLinkButton(
                        label: 'Privacy',
                        url: LegalLinks.privacyPolicy,
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Gradient header summarising the current plan and server-reported allowance.
/// The content is layered on top of [AetherGradientHeader] so
/// the subtle wash matches other premium Aether surfaces.
class _CurrentPlanHeader extends StatelessWidget {
  const _CurrentPlanHeader({
    required this.plan,
    required this.hasTier,
    required this.isPaid,
    required this.loading,
    required this.usage,
    required this.store,
    this.renewal,
    this.onManage,
    this.upgrade,
    this.comingSoon,
  });

  final _PlanOption plan;
  final bool hasTier;
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

  /// Shown instead of [upgrade] when nothing can be bought.
  final String? comingSoon;

  @override
  Widget build(BuildContext context) {
    final pct = usage?.remainingFraction;
    final percentText = pct == null
        ? null
        : '${(pct * 100).round()}% remaining';
    final pillColor = isPaid ? Aether.accent : Aether.textMuted;
    final pillLabel = (hasTier ? plan.title : 'Unknown').toUpperCase();

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
              AetherPill(label: pillLabel, color: pillColor, filled: true),
              Text('Current plan', style: AetherType.label),
            ],
          ),
          const SizedBox(height: 10),
          Text(hasTier ? plan.title : 'Plan unavailable', style: AetherType.h1),
          const SizedBox(height: 4),
          Text(
            hasTier
                ? plan.blurb
                : 'Refresh to verify this account’s cloud plan.',
            style: AetherType.bodyMuted,
          ),
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
          else
            _UsageBar(pct: pct, percentText: percentText),
          CloudUsageStatus(store: store),
          if (upgrade != null) ...[
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: upgrade),
          ] else if (comingSoon != null) ...[
            const SizedBox(height: 16),
            Text(
              comingSoon!,
              key: const ValueKey('paid-plans-coming-soon'),
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

    // Wrap in the Aether gradient so the header reads as the "hero" of the
    // screen. The gradient primitive clamps its own height; we let the inner
    // content extend past it naturally via a Stack-less overlay — the
    // gradient is purely decorative wash under the card.
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
  const _UsageBar({required this.pct, required this.percentText});
  final double? pct;
  final String? percentText;

  @override
  Widget build(BuildContext context) {
    if (pct == null || percentText == null) {
      return Text('Usage unavailable', style: AetherType.caption);
    }
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
              pct! < 0.1 ? Aether.danger : Aether.accent,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(percentText!, style: AetherType.caption),
      ],
    );
  }
}

/// A single plan tile. Uses [AetherCard] as the base surface and promotes
/// the active plan with an accent border.
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.price,
    required this.features,
    required this.currentTier,
    required this.rank,
    required this.currentRank,
    required this.mode,
    required this.playManaged,
    required this.onManage,
    required this.checkout,
  });

  final _PlanOption plan;

  /// Localised Play price ("€4.99 / month"), "Free", or null when unknown.
  final String? price;
  final List<String> features;
  final String currentTier;
  final int rank;
  final int currentRank;
  final _PurchaseMode mode;

  /// The current paid plan is a Play subscription: lower tiers and Free are
  /// reached through the Play subscription centre.
  final bool playManaged;
  final VoidCallback onManage;
  final Widget Function(String label, bool ghost) checkout;

  @override
  Widget build(BuildContext context) {
    final isCurrent = plan.tier == currentTier;
    final isBelow = currentRank >= 0 && rank < currentRank;
    final isFree = plan.tier == 'free';
    final canPurchase =
        mode == _PurchaseMode.play || mode == _PurchaseMode.test;

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
                label: plan.multiplier,
                color: Aether.accent,
                filled: true,
              ),
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
          if (isCurrent)
            SizedBox(
              width: double.infinity,
              child: const _BillingButton(
                label: 'Current plan',
                onPressed: null,
              ),
            )
          else if (isBelow && playManaged)
            // Downgrade / cancel happen in Google Play at the end of the
            // paid period; there is no in-app proration for lower tiers.
            SizedBox(
              key: ValueKey('manage-${plan.tier}'),
              width: double.infinity,
              child: _BillingButton(
                ghost: true,
                label: isFree
                    ? 'Cancel in Google Play'
                    : 'Change in Google Play',
                onPressed: onManage,
              ),
            )
          else if (isFree)
            Text('Included with your account', style: AetherType.bodyMuted)
          else if (!canPurchase)
            SizedBox(
              key: ValueKey('coming-soon-${plan.tier}'),
              width: double.infinity,
              child: _BillingButton(
                ghost: true,
                label: mode == _PurchaseMode.playLoading
                    ? 'Loading…'
                    : mode == _PurchaseMode.playUnavailable
                    ? 'Unavailable'
                    : 'Coming soon',
                onPressed: null,
              ),
            )
          else if (isBelow)
            checkout('Change plan', true)
          else if (currentRank < 0)
            Text('Plan status unavailable', style: AetherType.bodyMuted)
          else
            checkout('Upgrade', false),
        ],
      ),
    );

    if (!isCurrent) return MergeSemantics(child: card);
    // Accent-outlined overlay for the currently-active plan.
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
    required this.play,
    required this.purchase,
  });
  final _PlanOption plan;
  final bool ghost;
  final String label;
  final bool isChange;
  final String? priceLabel;
  final bool play;
  final Future<UpgradeOutcome> Function() purchase;

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
        heading: '${ghost || isChange ? 'Change' : 'Upgrade'} to ${plan.title}',
        priceLabel: priceLabel,
        play: play,
        isChange: isChange,
        purchase: purchase,
      ),
    ).then((outcome) {
      if (outcome == null || !outcome.ok || !messenger.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            upgradeResultMessage(outcome.result, planTitle: plan.title),
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
    required this.play,
    required this.isChange,
    required this.purchase,
  });
  final _PlanOption plan;
  final String heading;
  final String? priceLabel;
  final bool play;
  final bool isChange;
  final Future<UpgradeOutcome> Function() purchase;

  @override
  State<_CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends State<_CheckoutSheet> {
  bool _busy = false;
  UpgradeOutcome? _failure;

  Future<void> _pay() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failure = null;
    });
    final outcome = await widget.purchase();
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(outcome);
      return;
    }
    // Failure keeps the sheet open with the reason inline (F-201/F-202).
    setState(() {
      _busy = false;
      _failure = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final failure = _failure?.result;
    final terminal = failure != null && !upgradeResultRetryable(failure);
    final price = widget.priceLabel;
    return PopScope(
      canPop: !_busy,
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
                  price == null ? plan.blurb : '$price · ${plan.blurb}',
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
                        upgradeResultMessage(failure, planTitle: plan.title),
                        style: AetherType.body,
                      ),
                    ),
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
                      onPressed: _busy ? null : () => Navigator.pop(context),
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
