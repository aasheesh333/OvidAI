import 'package:flutter/material.dart';

import '../../design/o_tokens.dart';
import 'step_progress.dart';

// TODO(l10n): move welcome copy to the ARB files.

/// First step of the tour: the identity, one line about what Ovid does, and
/// the one action that starts setup. No feature bullets, no cards, no second
/// action — a returning user reaches sign-in two steps later, so a shortcut
/// here would only be a second thing to read. No back arrow (there is nothing
/// before it); close only when the host can dismiss the whole flow.
class OnboardingWelcomePage extends StatelessWidget {
  const OnboardingWelcomePage({
    super.key,
    this.onGetStarted,
    this.onClose,
    this.busy = false,
    this.error,
    this.step = const V2OnboardingStepData(
      step: V2OnboardingTour.welcome,
      totalSteps: V2OnboardingTour.totalSteps,
      trailingLabel: '',
    ),
  });

  final VoidCallback? onGetStarted;
  final VoidCallback? onClose;

  /// True while the gate is persisting the first-run choice. The primary is
  /// then disabled (and announced as disabled) and a saving line is shown.
  final bool busy;

  /// Set when persisting the choice failed. The gate lets the user retry by
  /// tapping the same action again.
  final String? error;

  final V2OnboardingStepData step;

  @override
  Widget build(BuildContext context) {
    return OnboardingStepScaffold(
      step: step,
      title: 'Welcome',
      onClose: onClose,
      primaryKey: const Key('welcome-get-started'),
      primaryLabel: 'Get started',
      onPrimary: busy ? null : onGetStarted,
      primaryLoading: busy,
      error: error,
      child: const Padding(
        padding: EdgeInsets.only(top: OSpace.xxl),
        child: OnboardingIdentity(line: 'Ovid builds, ships and answers.'),
      ),
    );
  }
}
