import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/onboarding/language_goal_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_welcome.dart';
import 'package:ovid_ai/ui/v2/onboarding/paywall_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/sign_in_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/splash_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';

/// The five startup screens as one flow. These tests do not re-check each
/// screen's behaviour; they pin the things that must be identical across the
/// flow: the gutter, the content cap, the bottom action slot, the header
/// controls and the header text budget (MINIMAL_UI_CONTRACT §2, §3, §5).

class _Step {
  const _Step({
    required this.name,
    required this.screen,
    required this.primaryKey,
    required this.stepLabel,
    this.hasBack = false,
    this.hasClose = false,
  });

  final String name;
  final Widget Function() screen;
  final Key primaryKey;
  final String stepLabel;
  final bool hasBack;
  final bool hasClose;
}

final _steps = <_Step>[
  _Step(
    name: 'welcome',
    screen: () => OnboardingWelcomePage(
      onGetStarted: () {},
      onSignIn: () {},
      onLanguageTap: () {},
    ),
    primaryKey: const Key('welcome-get-started'),
    stepLabel: 'STEP 1 OF 4',
  ),
  _Step(
    name: 'language',
    screen: () => LanguageGoalPage(onBack: () {}, onContinue: (_, _) {}),
    primaryKey: const Key('language-goal-continue'),
    stepLabel: 'STEP 2 OF 4',
    hasBack: true,
  ),
  _Step(
    name: 'sign-in',
    screen: () => SignInPage(
      onBack: () {},
      onGoogle: () {},
      onPhone: () {},
      onForgotPassword: () {},
      onCreateAccount: () {},
    ),
    primaryKey: const Key('sign-in-submit'),
    stepLabel: 'STEP 3 OF 4',
    hasBack: true,
  ),
  _Step(
    name: 'paywall',
    screen: () => PaywallPage(
      onClose: () {},
      onStartTrial: (_) {},
      onContinueFree: () {},
    ),
    primaryKey: const Key('paywall-trial'),
    stepLabel: 'STEP 4 OF 4',
    hasClose: true,
  ),
];

Future<void> _pump(
  WidgetTester tester,
  Widget screen, {
  double width = 390,
  double height = 844,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: screen,
    ),
  );
  await tester.pumpAndSettle();
}

bool _isHorizontalScroll(Widget widget) =>
    widget is SingleChildScrollView &&
    widget.scrollDirection == Axis.horizontal;

int _words(String value) =>
    value.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// Width and left edge of the widget that spans the content column: the step
/// indicator on a tour step, the progress line on the splash.
Rect _contentRuler(WidgetTester tester, {required bool splash}) => splash
    ? tester.getRect(find.byType(OProgressBar))
    : tester.getRect(find.byType(OnboardingStepProgress));

void main() {
  group('responsive shell', () {
    // width, left edge, content width. 16 dp gutter on a phone; the content
    // centres to 640 at 600 dp and 720 at 900 dp.
    const bands = <(double, double, double)>[
      (320, OSpace.l, 320 - 2 * OSpace.l),
      (600, OSpace.xl, 600 - 2 * OSpace.xl),
      (900, 90 + OSpace.xl, 720 - 2 * OSpace.xl),
      (1200, 240 + OSpace.xl, 720 - 2 * OSpace.xl),
    ];

    for (final band in bands) {
      final (bandWidth, left, width) = band;
      testWidgets('every step keeps the gutter and cap at $bandWidth dp', (
        tester,
      ) async {
        for (final step in _steps) {
          await _pump(tester, step.screen(), width: bandWidth, height: 900);

          expect(tester.takeException(), isNull, reason: step.name);
          final ruler = _contentRuler(tester, splash: false);
          expect(ruler.left, left, reason: '${step.name} left gutter');
          expect(ruler.width, width, reason: '${step.name} content width');
          expect(
            find.byWidgetPredicate(_isHorizontalScroll),
            findsNothing,
            reason: '${step.name} must not scroll horizontally',
          );
        }

        await _pump(tester, const SplashPage(), width: bandWidth, height: 900);
        expect(tester.takeException(), isNull, reason: 'splash');
        final ruler = _contentRuler(tester, splash: true);
        expect(ruler.left, left, reason: 'splash left gutter');
        expect(ruler.width, width, reason: 'splash content width');
      });
    }

    testWidgets('the primary action sits on the same bottom edge everywhere', (
      tester,
    ) async {
      final bottoms = <String, double>{};
      for (final step in _steps) {
        await _pump(tester, step.screen());
        final rect = tester.getRect(find.byKey(step.primaryKey));
        expect(
          rect.height,
          greaterThanOrEqualTo(OSpace.touch),
          reason: '${step.name} primary target',
        );
        bottoms[step.name] = rect.bottom;
      }

      // The splash error is the only control on the startup screens; its retry
      // uses the same slot as a step's primary.
      await _pump(
        tester,
        const SplashPage(
          data: V2SplashData(errorLabel: 'We could not reach Ovid Si.'),
          onRetry: _noop,
        ),
      );
      bottoms['splash'] = tester
          .getRect(find.byKey(const Key('splash-retry')))
          .bottom;

      expect(
        bottoms.values.toSet(),
        hasLength(1),
        reason: 'the bottom action must not move between steps: $bottoms',
      );
    });

    testWidgets('plan cards are one column on a phone and two on a tablet', (
      tester,
    ) async {
      await _pump(tester, _steps.last.screen(), width: 320, height: 900);
      final phoneFree = tester.getRect(find.text('Ovid Free'));
      final phoneGo = tester.getRect(find.text('Ovid Go'));
      expect(phoneFree.left, phoneGo.left);
      expect(phoneFree.top, lessThan(phoneGo.top));

      await _pump(tester, _steps.last.screen(), width: 600, height: 900);
      final tabletFree = tester.getRect(find.text('Ovid Free'));
      final tabletGo = tester.getRect(find.text('Ovid Go'));
      expect(tabletFree.top, tabletGo.top);
      expect(tabletFree.left, lessThan(tabletGo.left));
    });
  });

  group('header', () {
    testWidgets('welcome is the first step: no back, no close', (tester) async {
      await _pump(tester, _steps[0].screen());

      expect(find.byType(OAppBar), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('language and sign-in have a real back arrow', (tester) async {
      for (final step in [_steps[1], _steps[2]]) {
        await _pump(tester, step.screen());

        expect(find.byType(OAppBar), findsOneWidget, reason: step.name);
        expect(
          find.byIcon(Icons.arrow_back_rounded),
          findsOneWidget,
          reason: '${step.name} needs a back arrow',
        );
        expect(find.byIcon(Icons.close_rounded), findsNothing);
      }
    });

    testWidgets('paywall closes the whole flow and has no back', (
      tester,
    ) async {
      await _pump(tester, _steps[3].screen());

      expect(find.byType(OAppBar), findsOneWidget);
      expect(find.byKey(const Key('onboarding-close')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    });

    testWidgets('splash is a full-screen state: no header at all', (
      tester,
    ) async {
      await _pump(tester, const SplashPage());

      expect(find.byType(OAppBar), findsNothing);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('every step shows the same progress indicator', (tester) async {
      for (final step in _steps) {
        await _pump(tester, step.screen());

        expect(
          find.byType(OnboardingStepProgress),
          findsOneWidget,
          reason: step.name,
        );
        expect(find.text(step.stepLabel), findsOneWidget, reason: step.name);
      }
    });

    testWidgets('header copy stays inside the §3 budget', (tester) async {
      for (final step in _steps) {
        await _pump(tester, step.screen());

        final bar = tester.widget<OAppBar>(find.byType(OAppBar));
        expect(bar.title.trim(), isNotEmpty, reason: step.name);
        expect(
          _words(bar.title),
          lessThanOrEqualTo(3),
          reason: '${step.name} header title: "${bar.title}"',
        );
        if (bar.subtitle != null) {
          expect(
            _words(bar.subtitle!),
            lessThanOrEqualTo(6),
            reason: '${step.name} header subtitle: "${bar.subtitle}"',
          );
        }
      }
    });

    testWidgets('header copy still fits at 320 dp and 200 % text', (
      tester,
    ) async {
      for (final step in _steps) {
        await _pump(
          tester,
          step.screen(),
          width: 320,
          height: 640,
          textScale: 2,
        );

        expect(tester.takeException(), isNull, reason: step.name);
        final bar = tester.widget<OAppBar>(find.byType(OAppBar));
        expect(
          find.descendant(
            of: find.byType(OAppBar),
            matching: find.text(bar.title),
          ),
          findsOneWidget,
          reason: step.name,
        );
      }
    });
  });
}

void _noop() {}
