import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_welcome.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  VoidCallback? onGetStarted,
  VoidCallback? onSignIn,
  VoidCallback? onLanguageTap,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: OnboardingWelcomePage(
        onGetStarted: onGetStarted,
        onSignIn: onSignIn,
        onLanguageTap: onLanguageTap,
        onClose: onClose,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'welcome renders the header, identity and both actions in light',
    (tester) async {
      await _pump(tester);

      expect(find.text('Welcome'), findsOneWidget);
      expect(find.text('Your always-on personal agent.'), findsOneWidget);
      expect(find.text('STEP 1 OF 4'), findsOneWidget);
      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.byKey(const Key('welcome-language')), findsOneWidget);
    },
  );

  testWidgets('no hardcoded version pill is shown', (tester) async {
    await _pump(tester);

    // The version belongs to the build (kAppVersion), not to a string that
    // goes stale; the welcome step shows identity only.
    expect(find.text('Ovid 2.4'), findsNothing);
    expect(find.textContaining('Ovid 2.'), findsNothing);
  });

  testWidgets('welcome renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('Your always-on personal agent.'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('get started and sign in call their callbacks', (tester) async {
    var started = 0;
    var signedIn = 0;
    await _pump(
      tester,
      onGetStarted: () => started++,
      onSignIn: () => signedIn++,
    );

    await tester.ensureVisible(find.byKey(const Key('welcome-get-started')));
    await tester.tap(find.byKey(const Key('welcome-get-started')));
    await tester.pump();
    expect(started, 1);

    await tester.ensureVisible(find.byKey(const Key('welcome-sign-in')));
    await tester.tap(find.byKey(const Key('welcome-sign-in')));
    await tester.pump();
    expect(signedIn, 1);
  });

  testWidgets('language selector calls back', (tester) async {
    var taps = 0;
    await _pump(tester, onLanguageTap: () => taps++);

    await tester.tap(find.byKey(const Key('welcome-language')));
    await tester.pump();

    expect(taps, 1);
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
          child: OnboardingWelcomePage(
            onGetStarted: () {},
            onSignIn: () {},
            onLanguageTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Your always-on personal agent.'), findsOneWidget);
    // The language pill keeps its 48 dp target and grows with the text
    // instead of clipping the label.
    final pill = tester.getSize(find.byKey(const Key('welcome-language')));
    expect(pill.height, greaterThanOrEqualTo(48));
    expect(tester.getSize(find.text('English')).height, greaterThan(24));
    expect(find.byKey(const Key('welcome-get-started')), findsOneWidget);
  });

  testWidgets('controls meet the 48 dp target and carry labels', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      onGetStarted: () {},
      onSignIn: () {},
      onLanguageTap: () {},
      onClose: () {},
    );

    for (final key in const [
      Key('welcome-get-started'),
      Key('welcome-sign-in'),
      Key('welcome-language'),
    ]) {
      expect(
        tester.getSize(find.byKey(key)).height,
        greaterThanOrEqualTo(48),
        reason: '$key must be at least 48 dp tall',
      );
    }

    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    expect(find.bySemanticsLabel('Language, English'), findsOneWidget);
    expect(find.bySemanticsLabel('Get started'), findsWidgets);
    expect(find.bySemanticsLabel('Sign in'), findsWidgets);
    semantics.dispose();
  });

  testWidgets('unwired actions report a disabled state', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);

    final started = tester.getSemantics(
      find.byKey(const Key('welcome-get-started')),
    );
    expect(started.flagsCollection.isEnabled, Tristate.isFalse);

    semantics.dispose();
  });
}
