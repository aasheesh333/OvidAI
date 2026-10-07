import 'package:flutter/material.dart';

import '../core/firebase_service.dart';
import '../core/cloud_usage_store.dart';
import '../core/ovid_cloud_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'cloud_usage_status.dart';
import 'widgets/aether_primitives.dart';

/// Plans & Billing screen — premium Aether redesign.
///
/// Preserves the plan tiles (Free, Plus ₹499, Pro ₹899, Max ₹1699), hides
/// USD everywhere, retains the selected-tier state, and routes "Pay now" through
/// [OvidCloudService.upgrade] (which is server-gated by the test-upgrade env).
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key});

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

/// Single plan definition. Price strings are pre-localised to INR — the
/// screen must never surface USD, even transiently.
class _PlanOption {
  const _PlanOption(
    this.tier,
    this.title,
    this.price,
    this.blurb,
    this.multiplier,
    this.includes,
  );
  final String tier;
  final String title;
  final String price;
  final String blurb;
  final String multiplier;
  final List<String> includes;
}

const _plans = <_PlanOption>[
  _PlanOption(
    'free',
    'Free',
    'Free',
    'Just chat — no card needed.',
    '×1',
    <String>[
      'Shared base allowance across all models',
      'No credit card required',
    ],
  ),
  _PlanOption(
    '3x',
    'Plus',
    '₹499',
    '3× the Free base usage allowance.',
    '×3',
    <String>[
      '3× the Free base allowance',
    ],
  ),
  _PlanOption(
    '7x',
    'Pro',
    '₹899',
    '7× the Free base usage allowance.',
    '×7',
    <String>[
      '7× the Free base allowance',
    ],
  ),
  _PlanOption(
    '15x',
    'Max',
    '₹1699',
    '15× the Free base usage allowance.',
    '×15',
    <String>[
      '15× the Free base allowance',
    ],
  ),
];

class _BillingScreenState extends State<BillingScreen> {
  late final CloudUsageStore _store;
  OvidUsage? get _usage => _store.usage;
  bool get _loading => _store.loading && _usage == null;

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

  int _tierRank(String tier) {
    const order = ['free', '3x', '7x', '15x'];
    final i = order.indexOf(tier);
    return i;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        toolbarHeight: MediaQuery.textScalerOf(context).scale(20) > 30 ? 88 : 56,
        title: const Text('Plans & Billing'),
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([app, FirebaseService.I, _store]),
        builder: (_, _) {
          final tier = _usage?.tier ?? OvidCloudService.I.confirmedTier ?? '';
          final isPaid =
              _usage?.isPaid ?? (tier.isNotEmpty && tier != 'free');
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
                nextPlan: nextPlan,
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
                    currentTier: tier,
                    rank: _tierRank(p.tier),
                    currentRank: currentRank,
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
    this.nextPlan,
  });

  final _PlanOption plan;
  final bool hasTier;
  final bool isPaid;
  final bool loading;
  final OvidUsage? usage;
  final CloudUsageStore store;

  /// The next paid tier above the current plan, if any. When present the
  /// header surfaces a prominent "Upgrade" call-to-action so it is reachable
  /// without scrolling through the plan list.
  final _PlanOption? nextPlan;

  @override
  Widget build(BuildContext context) {
    final pct = usage?.remainingFraction;
    final percentText =
        pct == null ? null : '${(pct * 100).round()}% remaining';
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
          Text(
            hasTier ? plan.title : 'Plan unavailable',
            style: AetherType.h1,
          ),
          const SizedBox(height: 4),
          Text(
            hasTier
                ? plan.blurb
                : 'Refresh to verify this account’s cloud plan.',
            style: AetherType.bodyMuted,
          ),
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
          if (nextPlan != null && hasTier) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: _UpgradeButton(
                plan: nextPlan!,
                ghost: false,
                label: 'Upgrade',
                buttonKey: const ValueKey('upgrade-header'),
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
    required this.currentTier,
    required this.rank,
    required this.currentRank,
  });

  final _PlanOption plan;
  final String currentTier;
  final int rank;
  final int currentRank;

  @override
  Widget build(BuildContext context) {
    final isCurrent = plan.tier == currentTier;
    final isBelow = rank < currentRank;
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
                label: plan.multiplier,
                color: Aether.accent,
                filled: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(plan.price, style: AetherType.display),
          const SizedBox(height: 14),
          for (final feature in plan.includes)
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
          else if (isFree)
            Text('Included with your account', style: AetherType.bodyMuted)
          else if (currentRank >= 0 && isBelow)
            _UpgradeButton(
              plan: plan,
              ghost: true,
              label: 'Change plan',
            )
          else if (currentRank < 0)
            Text('Plan status unavailable', style: AetherType.bodyMuted)
          else
            _UpgradeButton(
              plan: plan,
              ghost: false,
              label: 'Upgrade',
            ),
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
  final _PlanOption plan;
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
                  Text(
                    heading,
                    style: AetherType.h2,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${plan.price} · ${plan.blurb}',
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
                      label: 'Pay now · ${plan.price}',
                      busy: _busy,
                      onPressed:
                          _busy ? null : () => _payNow(sheetCtx, setSheet),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed:
                          _busy ? null : () => Navigator.pop(sheetCtx),
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
    final key =
        widget.buttonKey ?? ValueKey('upgrade-${widget.plan.tier}');
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
      child: _BillingButton(
        label: widget.label,
        onPressed: _openSheet,
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
      backgroundColor: ghost ? Colors.transparent : Aether.accentC,
      foregroundColor: ghost ? Aether.text : (Aether.dark ? Colors.black : Colors.white),
    );
    if (ghost) {
      return TextButton(key: buttonKey, style: style, onPressed: onPressed, child: child);
    }
    return FilledButton(key: buttonKey, style: style, onPressed: onPressed, child: child);
  }
}
