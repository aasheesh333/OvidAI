import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move onboarding step chrome copy to the ARB files.

/// Where the user is inside the onboarding flow.
///
/// [step] is clamped to `1..[steps]` on read, so a stale or out-of-range value
/// can never paint four bars for a three-step flow or announce "Step 0".
@immutable
class V2OnboardingStepData {
  const V2OnboardingStepData({
    this.step = 1,
    this.totalSteps = 3,
    this.trailingLabel = 'Setup',
  });

  final int step;
  final int totalSteps;

  /// Short right-aligned label next to "STEP 1 OF 3", e.g. the step name.
  final String trailingLabel;

  int get steps => totalSteps < 1 ? 1 : totalSteps;

  int get active => step.clamp(1, steps);
}

/// Segmented step indicator: "STEP 1 OF 3" plus one filled bar per step.
///
/// The whole block is a single semantics node labelled "Step 1 of 3"; the
/// visual text and bars are excluded so a screen reader does not repeat the
/// step twice.
class OnboardingStepProgress extends StatelessWidget {
  const OnboardingStepProgress({
    super.key,
    this.data = const V2OnboardingStepData(),
  });

  final V2OnboardingStepData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final active = data.active;
    final steps = data.steps;
    final fillDuration = OMove.duration(context, OMotion.base);
    return Semantics(
      label: 'Step $active of $steps',
      container: true,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: OSpace.s,
              runSpacing: OSpace.xs,
              children: [
                Text(
                  'STEP $active OF $steps',
                  style: OType.overline.copyWith(color: c.textMuted),
                ),
                if (data.trailingLabel.isNotEmpty)
                  Text(
                    data.trailingLabel,
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
              ],
            ),
            const SizedBox(height: OSpace.s),
            Row(
              children: [
                for (var i = 0; i < steps; i++) ...[
                  if (i > 0) const SizedBox(width: OSpace.s),
                  Expanded(
                    child: AnimatedContainer(
                      duration: fillDuration,
                      curve: OMotion.standard,
                      height: 4,
                      decoration: BoxDecoration(
                        color: i < active ? c.accentFill : c.surfaceRaised,
                        borderRadius: BorderRadius.circular(ORadius.pill),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Page frame for one onboarding step.
///
/// It owns the chrome the flow repeats: back / close / skip in the header, the
/// "STEP 1 OF 3" indicator, a scrolling body and a pinned footer with the
/// primary action. The screen supplies only presentational content and
/// callbacks; it never reaches into state or navigation itself.
///
/// States:
/// - [primaryLoading] shows the button spinner, disables skip and announces
///   [loadingLabel] as a live region.
/// - [primaryEnabled] false (or no [onPrimary]) renders the button disabled and
///   announced as such, without hiding it, so the layout does not jump.
/// - [error] renders a live-region error banner above the action, e.g. when a
///   save failed and the same button retries.
class OnboardingStepScaffold extends StatelessWidget {
  const OnboardingStepScaffold({
    super.key,
    required this.child,
    this.step = const V2OnboardingStepData(),
    this.title,
    this.onBack,
    this.onClose,
    this.onSkip,
    this.skipLabel = 'Skip',
    this.primaryLabel = 'Continue',
    this.onPrimary,
    this.primaryEnabled = true,
    this.primaryLoading = false,
    this.primaryIcon = Icons.arrow_forward_rounded,
    this.loadingLabel = 'Saving…',
    this.footerNote,
    this.error,
  });

  final Widget child;
  final V2OnboardingStepData step;

  /// Optional chrome title, e.g. "Language & goal". Rendered on its own line
  /// under the actions so it can wrap at large text sizes.
  final String? title;

  final VoidCallback? onBack;
  final VoidCallback? onClose;

  /// Hidden when null. Disabled while [primaryLoading] is true.
  final VoidCallback? onSkip;
  final String skipLabel;

  final String primaryLabel;
  final VoidCallback? onPrimary;

  /// Host-owned validity flag (e.g. the step's form is incomplete).
  final bool primaryEnabled;
  final bool primaryLoading;
  final IconData? primaryIcon;

  /// Live-region caption under the button while [primaryLoading] is true.
  final String loadingLabel;

  /// Small caption under the button when idle, e.g. "You can change this
  /// later." Replaced by [loadingLabel] while saving.
  final String? footerNote;

  /// Save/load failure. Shown above the button and announced.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(c),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                OSpace.screen,
                OSpace.s,
                OSpace.screen,
                OSpace.xl,
              ),
              child: OFadeSlide(child: child),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _footer(c),
    );
  }

  Widget _header(OColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.s, OSpace.xs, OSpace.s, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (onBack != null)
                OIconButton(
                  key: const Key('onboarding-back'),
                  icon: Icons.arrow_back_rounded,
                  semanticLabel: 'Back',
                  onPressed: onBack,
                ),
              const Spacer(),
              if (onSkip != null)
                OButton(
                  key: const Key('onboarding-skip'),
                  label: skipLabel,
                  variant: OButtonVariant.ghost,
                  semanticLabel: skipLabel,
                  onPressed: primaryLoading ? null : onSkip,
                ),
              if (onClose != null)
                OIconButton(
                  key: const Key('onboarding-close'),
                  icon: Icons.close_rounded,
                  semanticLabel: 'Close',
                  onPressed: onClose,
                ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
            child: OnboardingStepProgress(data: step),
          ),
          if (title != null) ...[
            const SizedBox(height: OSpace.l),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: OSpace.l),
              child: Text(
                title!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: OType.h2.copyWith(color: c.text),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footer(OColors c) {
    final loading = primaryLoading;
    final enabled = primaryEnabled && !loading && onPrimary != null;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            OSpace.screen,
            OSpace.m,
            OSpace.screen,
            OSpace.m,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null) ...[
                _FooterError(message: error!),
                const SizedBox(height: OSpace.m),
              ],
              OButton(
                key: const Key('onboarding-primary'),
                label: primaryLabel,
                icon: primaryIcon,
                expand: true,
                loading: loading,
                semanticLabel: loading
                    ? '$primaryLabel, loading'
                    : primaryLabel,
                onPressed: enabled ? onPrimary : null,
              ),
              if (loading) ...[
                const SizedBox(height: OSpace.s),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    loadingLabel,
                    textAlign: TextAlign.center,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ] else if (footerNote != null) ...[
                const SizedBox(height: OSpace.s),
                Text(
                  footerNote!,
                  textAlign: TextAlign.center,
                  style: OType.caption.copyWith(color: c.textFaint),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _FooterError extends StatelessWidget {
  const _FooterError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(OSpace.m),
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(ORadius.m),
          border: Border.all(color: c.danger.withValues(alpha: 0.40)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: c.danger),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                message,
                style: OType.bodySm.copyWith(color: c.danger),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
