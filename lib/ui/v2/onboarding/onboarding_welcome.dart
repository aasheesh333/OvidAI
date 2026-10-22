import 'package:flutter/material.dart';

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
  });

  final VoidCallback? onGetStarted;
  final VoidCallback? onClose;

  /// True while the gate is persisting the first-run choice. The primary is
  /// then disabled (and announced as disabled) and a saving line is shown.
  final bool busy;

  /// Set when persisting the choice failed. The gate lets the user retry by
  /// tapping the same action again.
  final String? error;

  @override
  Widget build(BuildContext context) {
    return OnboardingStepScaffold(
      // The welcome is always the first step of the real tour. It is not
      // injectable: a caller must not be able to paint "Step 2 of 3" on the
      // screen that starts a four-step flow.
      step: V2OnboardingTour.welcomeStep,
      title: 'Welcome',
      onClose: onClose,
      primaryKey: const Key('welcome-get-started'),
      primaryLabel: 'Get started',
      onPrimary: busy ? null : onGetStarted,
      primaryLoading: busy,
      error: error,
      centerBody: true,
      child: const OnboardingIdentity(line: 'Ovid builds, ships and answers.'),
    );
  }
}
