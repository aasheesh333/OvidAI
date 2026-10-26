import 'package:ovid_ai/ui/v2/onboarding/sign_in_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';

import 'a11y_support.dart';

void main() {
  group('SignInPage a11y', () {
    Future<void> pumpSignIn(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        SignInPage(
          onGoogle: () {},
          onPhone: () {},
          step: const V2OnboardingStepData(
            step: V2OnboardingTour.signIn,
            totalSteps: V2OnboardingTour.totalSteps,
            trailingLabel: '',
          ),
        ),
        textScale: textScale,
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'SignInPage', (scale) async {
        await pumpSignIn(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpSignIn(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
