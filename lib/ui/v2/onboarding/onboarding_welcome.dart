import 'package:flutter/material.dart';

import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'step_progress.dart';

// TODO(l10n): move welcome copy to the ARB files.

@immutable
class V2OnboardingWelcomeData {
  const V2OnboardingWelcomeData({this.language = 'English'});

  final String language;
}

/// First step of the tour: the identity, the language the app will speak, and
/// the one action that starts setup. No back arrow (there is nothing before
/// it); close only when the host can dismiss the whole flow.
class OnboardingWelcomePage extends StatelessWidget {
  const OnboardingWelcomePage({
    super.key,
    this.data = const V2OnboardingWelcomeData(),
    this.onGetStarted,
    this.onSignIn,
    this.onLanguageTap,
    this.onClose,
    this.busy = false,
    this.error,
    this.step = const V2OnboardingStepData(
      step: V2OnboardingTour.welcome,
      totalSteps: V2OnboardingTour.totalSteps,
      trailingLabel: '',
    ),
  });

  final V2OnboardingWelcomeData data;
  final VoidCallback? onGetStarted;
  final VoidCallback? onSignIn;
  final VoidCallback? onLanguageTap;
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
      subtitle: 'Your always-on personal agent.',
      onClose: onClose,
      primaryKey: const Key('welcome-get-started'),
      primaryLabel: 'Get started',
      onPrimary: busy ? null : onGetStarted,
      primaryLoading: busy,
      error: error,
      secondaryActions: [
        OTextAction(
          key: const Key('welcome-sign-in'),
          label: 'Sign in',
          onPressed: busy ? null : onSignIn,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: OnboardingLanguagePill(
              key: const Key('welcome-language'),
              label: data.language,
              onTap: busy ? null : onLanguageTap,
            ),
          ),
          const SizedBox(height: OSpace.xxl),
          const Center(child: OnboardingMark(size: 96)),
        ],
      ),
    );
  }
}
