import 'dart:ui' show Tristate;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_welcome.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  VoidCallback? onGetStarted,
  VoidCallback? onClose,
  bool busy = false,
  String? error,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: OnboardingWelcomePage(
        onGetStarted: onGetStarted,
        onClose: onClose,
        busy: busy,
        error: error,
      ),
    ),
  );
  if (busy) {
    // The button spinner never settles; pump fixed frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  } else {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('welcome renders the header, identity and one action in light', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.bySemanticsLabel('Ovid Si logo'), findsOneWidget);
    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
    expect(find.text('STEP 1 OF 4'), findsOneWidget);
    expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    // One primary action: no sign-in shortcut, no language pill — both are
    // real steps later in the same tour.
    expect(find.text('Sign in'), findsNothing);
    expect(find.byKey(const Key('welcome-sign-in')), findsNothing);
    expect(find.byKey(const Key('welcome-language')), findsNothing);
  });

  testWidgets('no hardcoded version pill is shown', (tester) async {
    await _pump(tester);

    // The version belongs to the build (kAppVersion), not to a string that
    // goes stale; the welcome step shows identity only.
    expect(find.text('Ovid 2.4'), findsNothing);
    expect(find.textContaining('Ovid 2.'), findsNothing);
  });

  testWidgets('welcome renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('get started calls its callback', (tester) async {
    var started = 0;
    await _pump(tester, onGetStarted: () => started++);

    await tester.ensureVisible(find.byKey(const Key('welcome-get-started')));
    await tester.tap(find.byKey(const Key('welcome-get-started')));
    await tester.pump();
    expect(started, 1);
  });

  testWidgets('close action is shown only when wired', (tester) async {
    await _pump(tester);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    // Welcome is the root of the tour: no back arrow that cannot pop, and no
    // skip button whose only destination would be the step it is already on.
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
    expect(find.byKey(const Key('onboarding-skip')), findsNothing);
    expect(find.text('Skip'), findsNothing);

    await _pump(tester, onClose: () {});
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('the indicator is always the real first step of four', (
    tester,
  ) async {
    await _pump(tester);

    final data = tester
        .widget<OnboardingStepScaffold>(find.byType(OnboardingStepScaffold))
        .step;
    expect(data.active, V2OnboardingTour.welcome);
    expect(data.steps, V2OnboardingTour.totalSteps);
    expect(find.text('STEP 1 OF 4'), findsOneWidget);
    expect(find.text('STEP 1 OF 3'), findsNothing);
  });

  testWidgets('welcome fits 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      size: const Size(320, 640),
      textScale: 2,
      onGetStarted: () {},
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
    expect(find.text('Ovid Si'), findsOneWidget);
    // The primary action stays pinned to the bottom edge: the scrollable body
    // above it may clip, the CTA may not leave the screen.
    final cta = tester.getRect(find.byKey(const Key('welcome-get-started')));
    expect(cta.bottom, lessThanOrEqualTo(640));
    expect(cta.height, greaterThanOrEqualTo(48));
  });

  testWidgets('welcome survives every width, text scale and theme', (
    tester,
  ) async {
    const widths = <double>[320, 360, 412, 600, 800, 1024, 1280];
    for (final width in widths) {
      for (final scale in const <double>[1, 2]) {
        for (final dark in const <bool>[false, true]) {
          final height = width < 600 ? 640.0 : 900.0;
          final reason = '$width dp @ ${scale}x (${dark ? 'dark' : 'light'})';
          await _pump(
            tester,
            dark: dark,
            size: Size(width, height),
            textScale: scale,
            onGetStarted: () {},
          );

          expect(tester.takeException(), isNull, reason: reason);
          expect(
            find.text('Ovid builds, ships and answers.'),
            findsOneWidget,
            reason: reason,
          );

          // The step ruler spans the content column: centred on the window,
          // never wider than the 640 dp onboarding cap.
          final ruler = tester.getRect(find.byType(OnboardingStepProgress));
          expect(
            ruler.width,
            lessThanOrEqualTo(640),
            reason: '$reason: content is wider than 640',
          );
          expect(
            ruler.center.dx,
            closeTo(width / 2, 0.5),
            reason: '$reason: content is not centred',
          );

          final cta = tester.getRect(
            find.byKey(const Key('welcome-get-started')),
          );
          expect(
            cta.bottom,
            lessThanOrEqualTo(height),
            reason: '$reason: primary action is off screen',
          );
          expect(
            cta.height,
            greaterThanOrEqualTo(48),
            reason: '$reason: primary target is under 48 dp',
          );

          // The hero is centred in the free space, so it does not leave a
          // dead band under the step indicator on tall windows.
          final brand = tester.getRect(find.text('Ovid Si'));
          expect(
            brand.center.dy,
            greaterThan(tester.getRect(find.text('STEP 1 OF 4')).bottom),
            reason: '$reason: hero overlaps the step indicator',
          );
          expect(
            brand.bottom,
            lessThan(cta.top),
            reason: '$reason: hero overlaps the action',
          );
        }
      }
    }
  });

  testWidgets('the control meets the 48 dp target and carries a label', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, onGetStarted: () {}, onClose: () {});

    expect(
      tester.getSize(find.byKey(const Key('welcome-get-started'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    expect(find.bySemanticsLabel('Get started'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('an unwired action reports a disabled state', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);

    final started = tester.getSemantics(
      find.byKey(const Key('welcome-get-started')),
    );
    expect(started.flagsCollection.isEnabled, Tristate.isFalse);

    semantics.dispose();
  });

  testWidgets('busy disables the action and announces the save', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var started = 0;
    await _pump(tester, onGetStarted: () => started++, busy: true);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Saving…'), findsOneWidget);
    expect(find.bySemanticsLabel('Get started, loading'), findsWidgets);

    final button = tester.getSemantics(
      find.byKey(const Key('welcome-get-started')),
    );
    expect(button.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.byKey(const Key('welcome-get-started')));
    await tester.pump();
    expect(started, 0);

    semantics.dispose();
  });

  testWidgets('a save failure is announced and the same action retries', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      onGetStarted: () {},
      error: 'We could not save your choice. Try again.',
    );

    final error = find.text('We could not save your choice. Try again.');
    expect(error, findsOneWidget);
    expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
    expect(
      tester
          .getSemantics(find.byKey(const Key('welcome-get-started')))
          .flagsCollection
          .isEnabled,
      Tristate.isTrue,
    );

    semantics.dispose();
  });

  testWidgets('reading order follows the visible order', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, onGetStarted: () {});

    final tops = <double>[
      tester.getRect(find.text('Welcome')).top,
      tester.getRect(find.text('STEP 1 OF 4')).top,
      tester.getRect(find.text('Ovid Si')).top,
      tester.getRect(find.text('Ovid builds, ships and answers.')).top,
      tester.getRect(find.byKey(const Key('welcome-get-started'))).top,
    ];
    for (var i = 1; i < tops.length; i++) {
      expect(
        tops[i],
        greaterThan(tops[i - 1]),
        reason: 'element $i must read after element ${i - 1}',
      );
    }

    expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);
    expect(find.bySemanticsLabel('Get started'), findsWidgets);
    semantics.dispose();
  });
}
