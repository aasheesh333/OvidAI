import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move onboarding step chrome copy to the ARB files.

/// The tour is one flow of four steps. Keeping the order and the count in one
/// place is what makes every step show the same progress indicator.
abstract final class V2OnboardingTour {
  static const int welcome = 1;
  static const int language = 2;
  static const int signIn = 3;
  static const int plan = 4;
  static const int totalSteps = 4;

  /// Step chrome for the first step. It is also the default on the shared
  /// frame, so a caller that forgets to pass [V2OnboardingStepData] still sees
  /// the real tour ("Step 1 of 4") instead of a fictional shorter one.
  ///
  /// No trailing label: the header already names the step, so repeating it
  /// beside the bars would be a second title.
  static const V2OnboardingStepData welcomeStep = V2OnboardingStepData(
    step: welcome,
    totalSteps: totalSteps,
    trailingLabel: '',
  );
}

/// Where the user is inside the onboarding flow.
///
/// [step] is clamped to `1..[steps]` on read, so a stale or out-of-range value
/// can never paint four bars for a three-step flow or announce "Step 0".
@immutable
class V2OnboardingStepData {
  const V2OnboardingStepData({
    this.step = V2OnboardingTour.welcome,
    this.totalSteps = V2OnboardingTour.totalSteps,
    this.trailingLabel = '',
  });

  final int step;
  final int totalSteps;

  /// Short right-aligned label next to "STEP 1 OF 4", e.g. the step name.
  /// Empty hides it, which is the default because the header already names
  /// the step.
  final String trailingLabel;

  int get steps => totalSteps < 1 ? 1 : totalSteps;

  int get active => step.clamp(1, steps);
}

/// The onboarding content cap. The flow reads as one narrow column, so it
/// centres tighter than the app-wide band caps: a phone is uncapped, a tablet
/// stops at 480 and a wide window at 640. A wider window adds margin, not
/// line length (MINIMAL_UI_CONTRACT §5).
double onboardingContentMaxWidth(double width) {
  if (width >= OBreakpoints.wide) return 640;
  if (width >= OBreakpoints.tablet) return 480;
  return double.infinity;
}

/// The identity block the flow opens with: the mark, the "Ovid Si" wordmark
/// and one optional muted line. Splash, welcome and sign-in share it so the
/// first three screens read as the same product. No tagline stack, no feature
/// bullets — one line at most.
class OnboardingIdentity extends StatelessWidget {
  const OnboardingIdentity({super.key, this.line, this.markSize = 96});

  /// The single line under the wordmark. Null shows mark and wordmark only.
  final String? line;

  final double markSize;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        OnboardingMark(size: markSize),
        const SizedBox(height: OSpace.xl),
        // The wordmark is the display-sized title of these screens, so it is
        // marked as a heading wherever the identity appears.
        Semantics(
          header: true,
          child: Text(
            'Ovid Si',
            textAlign: TextAlign.center,
            style: OType.display.copyWith(color: c.text),
          ),
        ),
        if (line != null) ...[
          const SizedBox(height: OSpace.s),
          Text(
            line!,
            textAlign: TextAlign.center,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Segmented step indicator: "STEP 1 OF 4" plus one filled bar per step.
///
/// The whole block is a single semantics node labelled "Step 1 of 4"; the
/// visual text and bars are excluded so a screen reader does not repeat the
/// step twice.
class OnboardingStepProgress extends StatelessWidget {
  const OnboardingStepProgress({
    super.key,
    this.data = V2OnboardingTour.welcomeStep,
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

/// The one page frame every onboarding step uses.
///
/// It owns the chrome the flow repeats: the header (back only when there is a
/// real previous step, close only when it leaves the whole tour), the
/// "STEP 1 OF 4" indicator, a scrolling body and a pinned footer with the
/// single primary action. The screen supplies content and callbacks; it never
/// hand-rolls its own gutter, title or bottom bar.
///
/// States:
/// - [primaryLoading] shows the button spinner, disables skip and announces
///   [loadingLabel] as a live region.
/// - [primaryEnabled] false (or no [onPrimary]) renders the button disabled and
///   announced as such, without hiding it, so the layout does not jump.
/// - [primaryVisible] false removes the footer entirely, for states that have
///   no action (loading skeletons).
/// - [error] renders a live-region error banner above the action, e.g. when a
///   save failed and the same button retries.
class OnboardingStepScaffold extends StatelessWidget {
  const OnboardingStepScaffold({
    super.key,
    required this.child,
    this.step = V2OnboardingTour.welcomeStep,
    this.title,
    this.subtitle,
    this.onBack,
    this.backKey = const Key('onboarding-back'),
    this.onClose,
    this.closeKey = const Key('onboarding-close'),
    this.onSkip,
    this.skipKey = const Key('onboarding-skip'),
    this.skipLabel = 'Skip',
    this.primaryKey = const Key('onboarding-primary'),
    this.primaryLabel = 'Continue',
    this.onPrimary,
    this.primaryEnabled = true,
    this.primaryVisible = true,
    this.primaryLoading = false,
    this.primaryIcon = Icons.arrow_forward_rounded,
    this.loadingLabel = 'Saving…',
    this.footerNote,
    this.secondaryActions = const <Widget>[],
    this.error,
    this.dismissKeyboard = false,
    this.scrollable = true,
    this.centerBody = false,
  });

  final Widget child;

  /// Where this step sits in the tour. Every tour step shows it.
  final V2OnboardingStepData step;

  /// The one header title. Three words maximum.
  final String? title;

  /// Optional single header line. Six words maximum.
  final String? subtitle;

  /// Only pass this when there is a real previous step.
  final VoidCallback? onBack;
  final Key backKey;

  /// Only pass this when it leaves the whole tour.
  final VoidCallback? onClose;
  final Key closeKey;

  /// Hidden when null. Disabled while [primaryLoading] is true.
  final VoidCallback? onSkip;
  final Key skipKey;
  final String skipLabel;

  final Key primaryKey;
  final String primaryLabel;
  final VoidCallback? onPrimary;

  /// Host-owned validity flag (e.g. the step's form is incomplete).
  final bool primaryEnabled;
  final bool primaryVisible;
  final bool primaryLoading;
  final IconData? primaryIcon;

  /// Live-region caption under the button while [primaryLoading] is true.
  final String loadingLabel;

  /// Small caption under the button when idle, e.g. "You can change this
  /// later." Replaced by [loadingLabel] while saving.
  final String? footerNote;

  /// Text-only actions under the primary button. Never a second full-width
  /// button: one primary action per zone.
  final List<Widget> secondaryActions;

  /// Save/load failure. Shown above the button and announced.
  final String? error;

  /// Wraps the scroll view so tapping outside a field dismisses the keyboard.
  final bool dismissKeyboard;

  /// False for a body that scrolls itself (a skeleton list), so the shell does
  /// not nest a viewport inside a scroll view.
  final bool scrollable;

  /// Vertically centres a short body between the step indicator and the
  /// footer. Content taller than the space still scrolls from the top instead
  /// of clipping, so large text loses nothing.
  final bool centerBody;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final Widget body = scrollable ? _scrollingBody() : child;
    return OScaffold(
      appBar: OAppBar(
        title: title ?? '',
        subtitle: subtitle,
        // The tour owns the back path explicitly; the default arrow would pop
        // whatever route happens to sit below the gate.
        showBack: false,
        leading: onBack == null
            ? null
            : OIconButton(
                key: backKey,
                icon: Icons.arrow_back_rounded,
                semanticLabel: 'Back',
                onPressed: onBack,
              ),
        actions: [
          if (onSkip != null)
            OButton(
              key: skipKey,
              label: skipLabel,
              variant: OButtonVariant.ghost,
              semanticLabel: skipLabel,
              onPressed: primaryLoading ? null : onSkip,
            ),
          if (onClose != null)
            OIconButton(
              key: closeKey,
              icon: Icons.close_rounded,
              semanticLabel: 'Close',
              onPressed: onClose,
            ),
        ],
      ),
      body: OContent(
        maxWidth: onboardingContentMaxWidth(MediaQuery.sizeOf(context).width),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: OSpace.l),
              child: OnboardingStepProgress(data: step),
            ),
            Expanded(
              child: dismissKeyboard ? ODismissKeyboard(child: body) : body,
            ),
            if (primaryVisible) _footer(c),
          ],
        ),
      ),
    );
  }

  Widget _scrollingBody() {
    const padding = EdgeInsets.only(top: OSpace.s, bottom: OSpace.xl);
    if (!centerBody) {
      return SingleChildScrollView(
        padding: padding,
        child: OFadeSlide(child: child),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxHeight - padding.vertical;
        return SingleChildScrollView(
          padding: padding,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: available > 0 ? available : 0,
            ),
            child: Align(
              alignment: Alignment.center,
              child: OFadeSlide(child: child),
            ),
          ),
        );
      },
    );
  }

  Widget _footer(OColors c) {
    final loading = primaryLoading;
    final enabled = primaryEnabled && !loading && onPrimary != null;
    // Order matters: the primary action is the last child, so it always sits
    // on the same bottom edge on every step. Notes and secondary actions grow
    // upward instead of pushing the CTA around.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) ...[
              _FooterError(message: error!),
              const SizedBox(height: OSpace.m),
            ],
            if (loading) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  loadingLabel,
                  textAlign: TextAlign.center,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(height: OSpace.s),
            ] else if (footerNote != null) ...[
              Text(
                footerNote!,
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
              const SizedBox(height: OSpace.s),
            ],
            if (!loading && secondaryActions.isNotEmpty) ...[
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: secondaryActions,
              ),
              const SizedBox(height: OSpace.xs),
            ],
            OButton(
              key: primaryKey,
              label: primaryLabel,
              icon: primaryIcon,
              expand: true,
              loading: loading,
              semanticLabel: loading ? '$primaryLabel, loading' : primaryLabel,
              onPressed: enabled ? onPrimary : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The Ovid Si mark, shared by the splash, the tour steps and the lock screen
/// so the flow opens with the same identity instead of two different
/// illustrations.
class OnboardingMark extends StatelessWidget {
  const OnboardingMark({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final inner = size * 0.867;
    final dot = size * 0.083;
    return Semantics(
      label: 'Ovid Si logo',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.08),
              ),
            ),
            Container(
              width: inner,
              height: inner,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceAlt,
                border: Border.all(color: c.hairline),
              ),
              child: CustomPaint(
                size: Size.square(inner),
                painter: _MarkPainter(colors: c),
              ),
            ),
            Positioned(
              top: size * 0.083,
              right: size * 0.1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.success,
                  border: Border.all(color: c.bg, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({required this.colors});

  final OColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);

    // Dashed outer orbit.
    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors.hairlineStrong;
    final outerRect = Rect.fromCircle(
      center: center,
      radius: size.width / 2 - 5,
    );
    for (var i = 0; i < 24; i++) {
      canvas.drawArc(outerRect, i * 0.261799, 0.14, false, outerPaint);
    }

    // Inner orbit and soft core.
    final innerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.hairline;
    canvas.drawCircle(center, size.width * 0.32, innerPaint);
    canvas.drawCircle(
      center,
      size.width * 0.18,
      Paint()..color = colors.accentSoft,
    );

    // Four-point autonomous spark.
    final r = size.width * 0.15;
    final t = size.width * 0.035;
    final spark = Path()
      ..moveTo(center.dx, center.dy - r)
      ..lineTo(center.dx + t, center.dy - t)
      ..lineTo(center.dx + r, center.dy)
      ..lineTo(center.dx + t, center.dy + t)
      ..lineTo(center.dx, center.dy + r)
      ..lineTo(center.dx - t, center.dy + t)
      ..lineTo(center.dx - r, center.dy)
      ..lineTo(center.dx - t, center.dy - t)
      ..close();
    canvas.drawPath(spark, Paint()..color = colors.accent);
    canvas.drawCircle(center, 2.4, Paint()..color = colors.onAccent);
  }

  @override
  bool shouldRepaint(covariant _MarkPainter oldDelegate) =>
      oldDelegate.colors != colors;
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
