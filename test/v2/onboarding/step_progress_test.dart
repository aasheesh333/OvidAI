import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  V2OnboardingStepData step = const V2OnboardingStepData(),
  String? title,
  VoidCallback? onBack,
  VoidCallback? onClose,
  VoidCallback? onSkip,
  String primaryLabel = 'Continue',
  VoidCallback? onPrimary,
  bool primaryEnabled = true,
  bool primaryLoading = false,
  String? footerNote,
  String? error,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: OnboardingStepScaffold(
        step: step,
        title: title,
        onBack: onBack,
        onClose: onClose,
        onSkip: onSkip,
        primaryLabel: primaryLabel,
        onPrimary: onPrimary,
        primaryEnabled: primaryEnabled,
        primaryLoading: primaryLoading,
        footerNote: footerNote,
        error: error,
        child: const Text('Step body'),
      ),
    ),
  );
  if (primaryLoading) {
    // The button spinner never settles, so pump fixed frames instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  } else {
    await tester.pumpAndSettle();
  }
}

/// Smallest supported phone with doubled text.
Future<void> _pumpSmall(
  WidgetTester tester, {
  bool dark = false,
  bool primaryLoading = false,
}) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: OnboardingStepScaffold(
          title: 'Language & goal',
          onBack: () {},
          onClose: () {},
          onSkip: () {},
          onPrimary: () {},
          primaryLoading: primaryLoading,
          child: const Text('Step body'),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('renders the step, title, body and footer action', (
    tester,
  ) async {
    await _pump(tester, title: 'Language & goal', onPrimary: () {});

    expect(find.text('STEP 1 OF 4'), findsOneWidget);
    // The default chrome names no step: the header already does.
    expect(find.text('Setup'), findsNothing);
    expect(find.text('Language & goal'), findsOneWidget);
    expect(find.text('Step body'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-primary')), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, dark: true, title: 'Language & goal', onPrimary: () {});

    expect(find.text('STEP 1 OF 4'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, OColors.dark.bg);
  });

  testWidgets('clamps out-of-range steps instead of painting extra bars', (
    tester,
  ) async {
    await _pump(
      tester,
      step: const V2OnboardingStepData(step: 0, totalSteps: 3),
    );
    expect(find.text('STEP 1 OF 3'), findsOneWidget);

    await _pump(
      tester,
      step: const V2OnboardingStepData(step: 9, totalSteps: 3),
    );
    expect(find.text('STEP 3 OF 3'), findsOneWidget);

    await _pump(
      tester,
      step: const V2OnboardingStepData(step: 1, totalSteps: 0),
    );
    expect(find.text('STEP 1 OF 1'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(OnboardingStepProgress),
        matching: find.byType(AnimatedContainer),
      ),
      findsOneWidget,
    );
  });

  testWidgets('indicator announces one step label and fills done steps', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const Scaffold(
          body: OnboardingStepProgress(
            data: V2OnboardingStepData(
              step: 2,
              totalSteps: 3,
              trailingLabel: 'Preferences',
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Step 2 of 3'), findsOneWidget);
    // The decorative text must not be announced a second time.
    expect(find.bySemanticsLabel('STEP 2 OF 3'), findsNothing);

    final bars = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(OnboardingStepProgress),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .map((bar) => (bar.decoration! as BoxDecoration).color)
        .toList();
    expect(bars, [
      OColors.light.accentFill,
      OColors.light.accentFill,
      OColors.light.surfaceRaised,
    ]);

    handle.dispose();
  });

  testWidgets('back, close and skip are hidden until wired', (tester) async {
    await _pump(tester);

    expect(find.byKey(const Key('onboarding-back')), findsNothing);
    expect(find.byKey(const Key('onboarding-close')), findsNothing);
    expect(find.byKey(const Key('onboarding-skip')), findsNothing);
  });

  testWidgets('back, close and skip fire once when wired', (tester) async {
    var backs = 0;
    var closes = 0;
    var skips = 0;
    await _pump(
      tester,
      onBack: () => backs++,
      onClose: () => closes++,
      onSkip: () => skips++,
    );

    await tester.tap(find.byKey(const Key('onboarding-back')));
    await tester.tap(find.byKey(const Key('onboarding-close')));
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pump();

    expect(backs, 1);
    expect(closes, 1);
    expect(skips, 1);
  });

  testWidgets('primary is announced disabled when unwired', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    expect(
      tester.getSemantics(find.byKey(const Key('onboarding-primary'))),
      isSemantics(
        label: 'Continue',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    handle.dispose();
  });

  testWidgets('an invalid step disables the primary without hiding it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await _pump(
      tester,
      onPrimary: () => taps++,
      primaryEnabled: false,
      footerNote: 'Pick at least one goal to continue.',
    );

    expect(find.text('Continue'), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('onboarding-primary'))),
      isSemantics(
        label: 'Continue',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    expect(find.text('Pick at least one goal to continue.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('onboarding-primary')));
    await tester.pump();
    expect(taps, 0);

    handle.dispose();
  });

  testWidgets('loading disables the footer and announces progress', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    var skips = 0;
    await _pump(
      tester,
      onPrimary: () => taps++,
      onSkip: () => skips++,
      primaryLoading: true,
    );

    expect(
      find.descendant(
        of: find.byKey(const Key('onboarding-primary')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byKey(const Key('onboarding-primary'))),
      isSemantics(
        label: 'Continue, loading',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    expect(find.text('Saving…'), findsOneWidget);

    // Skip cannot race the save.
    expect(
      tester.getSemantics(find.byKey(const Key('onboarding-skip'))),
      isSemantics(
        label: 'Skip',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    await tester.tap(find.byKey(const Key('onboarding-primary')));
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pump();
    expect(taps, 0);
    expect(skips, 0);

    handle.dispose();
  });

  testWidgets('loading replaces the footer note and announces it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      onPrimary: () {},
      primaryLoading: true,
      footerNote: 'You can change this later.',
    );

    expect(find.text('You can change this later.'), findsNothing);
    expect(find.text('Saving…'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('Saving…')).flagsCollection.isLiveRegion,
      isTrue,
    );

    handle.dispose();
  });

  testWidgets('an error is shown above the action and announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      onPrimary: () {},
      error: 'We could not save your choices.',
    );

    expect(find.text('We could not save your choices.'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.text('We could not save your choices.'))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );

    handle.dispose();
  });

  testWidgets('primary honours a custom label and icon', (tester) async {
    await _pump(
      tester,
      primaryLabel: 'Finish setup',
      onPrimary: () {},
      footerNote: 'Step 1 of 3 · You can fine-tune this in settings.',
    );

    expect(find.text('Finish setup'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward_rounded), findsOneWidget);
    expect(
      find.text('Step 1 of 3 · You can fine-tune this in settings.'),
      findsOneWidget,
    );
  });

  testWidgets('survives 320 dp and 200 % text in light', (tester) async {
    await _pumpSmall(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Language & goal'), findsOneWidget);
    expect(find.text('STEP 1 OF 4'), findsOneWidget);
    expect(find.text('Continue'), findsOneWidget);

    for (final key in const [
      Key('onboarding-back'),
      Key('onboarding-close'),
      Key('onboarding-skip'),
      Key('onboarding-primary'),
    ]) {
      expect(
        tester.getSize(find.byKey(key)).height,
        greaterThanOrEqualTo(OSpace.touch),
        reason: '$key must stay a 48 dp target at 200 % text',
      );
    }
  });

  testWidgets('survives 320 dp and 200 % text in dark while loading', (
    tester,
  ) async {
    await _pumpSmall(tester, dark: true, primaryLoading: true);

    expect(tester.takeException(), isNull);
    expect(find.text('Saving…'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-primary')), findsOneWidget);
  });

  testWidgets('body scrolls while the footer stays pinned', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: OnboardingStepScaffold(
            title: 'Language & goal',
            onPrimary: () {},
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (var i = 0; i < 20; i++) Text('Row $i')],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final footer = tester.getRect(find.byKey(const Key('onboarding-primary')));
    expect(footer.bottom, lessThanOrEqualTo(640));

    await tester.drag(find.text('Row 0'), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('onboarding-primary')), findsOneWidget);
  });

  testWidgets('controls carry semantic labels', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      title: 'Language & goal',
      onBack: () {},
      onClose: () {},
      onSkip: () {},
      onPrimary: () {},
    );

    expect(find.bySemanticsLabel('Back'), findsOneWidget);
    expect(find.bySemanticsLabel('Close'), findsOneWidget);
    // The button's own node and the platform button node both carry the label.
    expect(find.bySemanticsLabel('Skip'), findsWidgets);
    expect(find.bySemanticsLabel('Step 1 of 4'), findsOneWidget);
    expect(find.bySemanticsLabel('Continue'), findsWidgets);

    handle.dispose();
  });
}
