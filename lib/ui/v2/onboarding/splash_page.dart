import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the splash copy (status, error and retry labels) to the ARB
// files.

/// Data for the splash screen. The splash owns no navigation: the wiring layer
/// swaps it out when startup finishes.
@immutable
class V2SplashData {
  const V2SplashData({
    this.progress = 0,
    this.statusLabel = 'Starting your agent',
    this.errorLabel,
  });

  /// Startup progress, 0 to 1. Defaults to the honest "nothing loaded yet"
  /// value; the wiring layer injects real progress.
  final double progress;

  final String statusLabel;

  /// Set when startup failed. The splash then shows the message and a retry
  /// action instead of the progress line.
  final String? errorLabel;

  bool get hasError => errorLabel != null;
}

/// Branded startup screen: mark, wordmark, tagline and a thin progress line.
/// There are deliberately no actions on the happy path; the only control is
/// the retry shown when startup fails.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key, this.data = const V2SplashData(), this.onRetry});

  final V2SplashData data;

  /// Called by the retry action that appears when [V2SplashData.errorLabel] is
  /// set. When null there is nothing that can retry, so no retry control is
  /// rendered. The splash never navigates on its own.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Keep the halo inside narrow (320 dp) screens instead of letting a
          // fixed 340 dp circle get clipped by the stack.
          final halo = (constraints.maxWidth * 0.85).clamp(160.0, 340.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              // The one approved gradient in this group: the soft violet halo.
              Center(
                child: IgnorePointer(
                  child: Container(
                    width: halo,
                    height: halo,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          c.accent.withValues(alpha: 0.18),
                          c.accent.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // The identity block and the status dock share one scroll view:
              // they spread out on a tall screen and scroll instead of
              // clipping when the text scale is large.
              SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: constraints.maxHeight,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      OSpace.screen,
                      OSpace.xl,
                      OSpace.screen,
                      OSpace.xxl,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: OSpace.huge),
                          child: OFadeSlide(child: _SplashIdentity()),
                        ),
                        OFadeSlide(
                          child: data.hasError
                              ? _SplashError(
                                  label: data.errorLabel!,
                                  onRetry: onRetry,
                                )
                              : _SplashProgress(
                                  progress: data.progress,
                                  label: data.statusLabel,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SplashIdentity extends StatelessWidget {
  const _SplashIdentity();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SplashMark(),
        const SizedBox(height: OSpace.xl),
        Semantics(
          container: true,
          header: true,
          child: Text(
            'Ovid Si',
            textAlign: TextAlign.center,
            style: OType.display.copyWith(color: c.text),
          ),
        ),
        const SizedBox(height: OSpace.xs),
        Text(
          'CHAT. CODE. CREATE.',
          textAlign: TextAlign.center,
          style: OType.overline.copyWith(
            color: c.textMuted,
            letterSpacing: 3,
          ),
        ),
      ],
    );
  }
}

/// Loading state: one merged announcement for the bar and its label, so a
/// screen reader does not read the same sentence twice.
class _SplashProgress extends StatelessWidget {
  const _SplashProgress({required this.progress, required this.label});

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final percent = (progress.clamp(0.0, 1.0) * 100).round();
    return Semantics(
      container: true,
      label: label,
      value: '$percent percent',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 160,
              child: OProgressBar(value: progress, height: 3),
            ),
            const SizedBox(height: OSpace.m),
            Text(
              label,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Error state: what failed, plus the one action that can fix it.
class _SplashError extends StatelessWidget {
  const _SplashError({required this.label, this.onRetry});

  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          label: label,
          child: ExcludeSemantics(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.danger),
            ),
          ),
        ),
        // Only offer the action that can actually fix the failure. A visible
        // "Try again" with no handler is a dead control, not a recovery path.
        if (onRetry != null) ...[
          const SizedBox(height: OSpace.m),
          OButton(
            key: const Key('splash-retry'),
            label: 'Try again',
            icon: Icons.refresh_rounded,
            variant: OButtonVariant.secondary,
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}

class _SplashMark extends StatelessWidget {
  const _SplashMark();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Ovid Si logo',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        width: 120,
        height: 120,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.08),
              ),
            ),
            Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceAlt,
                border: Border.all(color: c.hairline),
              ),
              child: CustomPaint(
                size: const Size.square(104),
                painter: _MarkPainter(colors: c),
              ),
            ),
            Positioned(
              top: 10,
              right: 12,
              child: Container(
                width: 10,
                height: 10,
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
