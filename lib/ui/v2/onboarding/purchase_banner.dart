// TODO(l10n): move the purchase banner copy to the ARB files.
import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

/// What the purchase banner is reporting.
enum V2PurchaseBannerStatus {
  /// No banner. Callers can keep it in the tree and switch the status.
  hidden,

  /// The build talks to the RevenueCat Test Store, so no money moves.
  testStore,

  /// The store has not confirmed a purchase yet.
  pending,

  /// The purchase failed or the entitlement could not be confirmed.
  failed,

  /// A previous purchase was found and the plan is active again.
  restored,

  /// Restore reached the store and it reported no active subscription for
  /// this account. This is a real answer, not a failure.
  nothingToRestore,
}

/// Immutable data for [V2PurchaseBanner].
@immutable
class V2PurchaseBannerData {
  const V2PurchaseBannerData({
    this.status = V2PurchaseBannerStatus.hidden,
    this.planName,
    this.detail,
  });

  final V2PurchaseBannerStatus status;

  /// Plan the purchase belongs to, for example `Ovid Plus`. Optional: the
  /// banner stays readable without it.
  final String? planName;

  /// Extra store-provided detail, usually the failure reason. Shown under the
  /// standard copy; never replaces it.
  final String? detail;
}

/// Billing status banner for the paywall and the plan/billing screen.
///
/// It is presentational: the caller owns the purchase state and passes what
/// happened. Retry is deliberately offered only for
/// [V2PurchaseBannerStatus.failed] — retrying a pending purchase could charge
/// twice. "Manage subscription" is shown whenever a callback is supplied, so
/// the user can always leave for the store's own subscription controls.
class V2PurchaseBanner extends StatelessWidget {
  const V2PurchaseBanner({
    super.key,
    required this.data,
    this.onRetry,
    this.onManageSubscription,
  });

  final V2PurchaseBannerData data;
  final VoidCallback? onRetry;
  final VoidCallback? onManageSubscription;

  @override
  Widget build(BuildContext context) {
    final status = data.status;
    if (status == V2PurchaseBannerStatus.hidden) {
      return const SizedBox.shrink();
    }

    final c = OColors.of(context);
    final copy = _copyFor(status, c);
    final detail = _clean(data.detail);
    final live = status != V2PurchaseBannerStatus.testStore;
    final announcement = [
      _sentence(copy.title),
      copy.message,
      if (detail != null) _sentence(detail),
    ].join(' ');

    final actions = <Widget>[
      if (status == V2PurchaseBannerStatus.failed)
        OButton(
          key: const Key('purchase-banner-retry'),
          label: 'Try again',
          icon: Icons.refresh_rounded,
          onPressed: onRetry,
        ),
      if (onManageSubscription != null)
        OButton(
          key: const Key('purchase-banner-manage'),
          label: 'Manage subscription',
          variant: OButtonVariant.secondary,
          onPressed: onManageSubscription,
        ),
    ];

    final card = Container(
      key: const Key('purchase-banner-card'),
      padding: const EdgeInsets.all(OSpace.l),
      decoration: BoxDecoration(
        color: copy.tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: copy.tone.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: copy.tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(copy.icon, size: 20, color: copy.tone),
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Semantics(
                  key: const Key('purchase-banner-status'),
                  container: true,
                  liveRegion: live,
                  label: announcement,
                  excludeSemantics: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(copy.title, style: OType.h3.copyWith(color: c.text)),
                      const SizedBox(height: 2),
                      Text(
                        copy.message,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: OSpace.xs),
                        Text(
                          detail,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: OSpace.m),
            _Actions(children: actions),
          ],
        ],
      ),
    );

    return OAnimatedSwap(
      child: KeyedSubtree(key: ValueKey(status), child: card),
    );
  }

  _BannerCopy _copyFor(V2PurchaseBannerStatus status, OColors c) {
    final plan = _clean(data.planName);
    return switch (status) {
      V2PurchaseBannerStatus.testStore => _BannerCopy(
        title: 'Test Store mode',
        message:
            'Purchases here are simulated. No card is charged and no real '
            'subscription starts.',
        icon: Icons.science_outlined,
        tone: c.accent,
      ),
      V2PurchaseBannerStatus.pending => _BannerCopy(
        title: 'Finishing your purchase',
        message: plan == null
            ? 'Your purchase is still being confirmed with the store. This '
                  'can take a moment.'
            : 'Your $plan purchase is still being confirmed with the store. '
                  'This can take a moment.',
        icon: Icons.hourglass_top_rounded,
        tone: c.warn,
      ),
      V2PurchaseBannerStatus.failed => _BannerCopy(
        title: 'Purchase did not finish',
        message:
            'We could not confirm your purchase. Try again, or manage your '
            'subscription in the store.',
        icon: Icons.error_outline_rounded,
        tone: c.danger,
      ),
      V2PurchaseBannerStatus.restored => _BannerCopy(
        title: 'Purchase restored',
        message: plan == null
            ? 'Your subscription is active again.'
            : 'Your $plan subscription is active again.',
        icon: Icons.check_circle_outline_rounded,
        tone: c.success,
      ),
      V2PurchaseBannerStatus.nothingToRestore => _BannerCopy(
        title: 'No purchase found',
        message: 'No active subscription is linked to this account.',
        icon: Icons.search_off_rounded,
        tone: c.warn,
      ),
      V2PurchaseBannerStatus.hidden => _BannerCopy(
        title: '',
        message: '',
        icon: Icons.info_outline_rounded,
        tone: c.textMuted,
      ),
    };
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String _sentence(String value) {
    final trimmed = value.trim();
    return RegExp(r'[.!?]$').hasMatch(trimmed) ? trimmed : '$trimmed.';
  }
}

@immutable
class _BannerCopy {
  const _BannerCopy({
    required this.title,
    required this.message,
    required this.icon,
    required this.tone,
  });

  final String title;
  final String message;
  final IconData icon;
  final Color tone;
}

/// Stacks full-width actions when space or text scaling is tight, otherwise
/// keeps them on one trailing row.
class _Actions extends StatelessWidget {
  const _Actions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseSize = OType.label.fontSize ?? 14;
        final scale =
            MediaQuery.textScalerOf(context).scale(baseSize) / baseSize;
        final stacked = constraints.maxWidth < 340 || scale > 1.3;

        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var index = 0; index < children.length; index++) ...[
                if (index > 0) const SizedBox(height: OSpace.s),
                children[index],
              ],
            ],
          );
        }

        return Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: children,
          ),
        );
      },
    );
  }
}
