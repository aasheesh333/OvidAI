import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'step_progress.dart';

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

/// Startup screen: the same mark and wordmark as the welcome step, with the
/// real startup progress docked where every other step puts its action.
///
/// A full-screen state, so it has no header and no step counter: during boot
/// the tour has not started, and a signed-in launch never sees the tour at
/// all. It shares the onboarding gutter, content width and identity block,
/// which is what makes it read as the first screen of the same flow. There are
/// deliberately no actions on the happy path; the only control is the retry
/// shown when startup fails.
class SplashPage extends StatelessWidget {
  const SplashPage({super.key, this.data = const V2SplashData(), this.onRetry});

  final V2SplashData data;

  /// Called by the retry action that appears when [V2SplashData.errorLabel] is
  /// set. When null there is nothing that can retry, so no retry control is
  /// rendered. The splash never navigates on its own.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          // The identity and the bottom dock share one scroll view: they
          // spread out on a tall screen and scroll instead of clipping when
          // the text scale is large.
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: OContent(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const SizedBox.shrink(),
                      const OFadeSlide(child: _SplashIdentity()),
                      Padding(
                        padding: const EdgeInsets.only(bottom: OSpace.m),
                        child: OFadeSlide(
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
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The identity block shared with the welcome step: mark plus wordmark, no
/// tagline. A slogan would be a second thing to read before the app starts.
class _SplashIdentity extends StatelessWidget {
  const _SplashIdentity();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const OnboardingMark(size: 96),
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OProgressBar(value: progress, height: 3),
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

/// Error state: what failed, plus the one action that can fix it. The retry
/// button sits in the same bottom slot as every onboarding primary action.
class _SplashError extends StatelessWidget {
  const _SplashError({required this.label, this.onRetry});

  final String label;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
            expand: true,
            onPressed: onRetry,
          ),
        ],
      ],
    );
  }
}
