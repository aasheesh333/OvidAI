import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_welcome.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  VoidCallback? onGetStarted,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: OnboardingWelcomePage(
        onGetStarted: onGetStarted,
        onClose: onClose,
      ),
    ),
  );
  await tester.pumpAndSettle();
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
    // Welcome is the root of the tour: no back arrow that cannot pop.
    expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);

    await _pump(tester, onClose: () {});
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
  });

  testWidgets('welcome fits 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: OnboardingWelcomePage(onGetStarted: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
    expect(find.text('Ovid Si'), findsOneWidget);
    // The primary action stays pinned to the bottom edge: the scrollable body
    // above it may clip, the CTA may not leave the screen.
    final cta = tester.getRect(find.byKey(const Key('welcome-get-started')));
    expect(cta.bottom, lessThanOrEqualTo(640));
    expect(cta.height, greaterThanOrEqualTo(48));
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
}
