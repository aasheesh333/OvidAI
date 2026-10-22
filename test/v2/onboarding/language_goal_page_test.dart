import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/language_goal_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';

Future<void> _pump(
  WidgetTester tester, {
  bool dark = false,
  V2LanguageGoalData data = const V2LanguageGoalData(),
  ValueChanged<String>? onLanguageSelected,
  void Function(String goalId, bool selected)? onGoalToggled,
  V2LanguageGoalContinue? onContinue,
  VoidCallback? onRetry,
  VoidCallback? onClose,
  VoidCallback? onBack,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: LanguageGoalPage(
        data: data,
        onLanguageSelected: onLanguageSelected,
        onGoalToggled: onGoalToggled,
        onContinue: onContinue,
        onRetry: onRetry,
        onClose: onClose,
        onBack: onBack,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Smallest supported phone with doubled text: the layout must survive without
/// an overflow, a clipped label or a build exception.
Future<void> _pumpSmall(WidgetTester tester, {bool dark = false}) async {
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
        child: const LanguageGoalPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('language and goal renders the grid and chips in light', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('SPOKEN LANGUAGE'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('हिन्दी'), findsOneWidget);
    expect(find.text('Hinglish'), findsOneWidget);
    expect(find.text('ਪੰਜਾਬੀ'), findsOneWidget);
    expect(find.text('தமிழ்'), findsOneWidget);
    expect(find.text('Build something'), findsOneWidget);
    expect(find.text('Research'), findsOneWidget);
    expect(find.text('Write'), findsOneWidget);
    expect(find.text('Automate my work'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('STEP 2 OF 4'), findsOneWidget);
    expect(find.byKey(const Key('language-goal-continue')), findsOneWidget);
  });

  testWidgets('language and goal survives 320 dp and 200 % text', (
    tester,
  ) async {
    await _pumpSmall(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('SPOKEN LANGUAGE'), findsOneWidget);
  });

  testWidgets('language and goal renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('SPOKEN LANGUAGE'), findsOneWidget);
    expect(find.text('हिन्दी'), findsOneWidget);
    expect(find.byKey(const Key('language-goal-continue')), findsOneWidget);
  });

  testWidgets('selecting a language and continuing reports both choices', (
    tester,
  ) async {
    String? selectedLanguage;
    String? continuedLanguage;
    Set<String>? continuedGoals;
    await _pump(
      tester,
      onLanguageSelected: (id) => selectedLanguage = id,
      onContinue: (languageId, goalIds) {
        continuedLanguage = languageId;
        continuedGoals = goalIds;
      },
    );

    await tester.ensureVisible(find.text('हिन्दी'));
    await tester.tap(find.text('हिन्दी'));
    await tester.pump();

    expect(selectedLanguage, 'hi');

    await tester.tap(find.byKey(const Key('language-goal-continue')));
    await tester.pump();

    expect(continuedLanguage, 'hi');
    expect(continuedGoals, contains('build'));
  });

  testWidgets('goal chips toggle on and off', (tester) async {
    final events = <String>[];
    await _pump(
      tester,
      onGoalToggled: (id, selected) => events.add('$id:$selected'),
    );

    await tester.ensureVisible(find.text('Research'));
    await tester.tap(find.text('Research'));
    await tester.pump();
    expect(events, ['research:true']);

    await tester.tap(find.text('Research'));
    await tester.pump();
    expect(events, ['research:true', 'research:false']);
  });

  testWidgets('Continue is blocked until a goal is selected', (tester) async {
    var continues = 0;
    await _pump(tester, onContinue: (_, _) => continues++);

    // The default data starts with one goal selected.
    final button = tester.widget<OButton>(
      find.byKey(const Key('language-goal-continue')),
    );
    expect(button.onPressed, isNotNull);

    await tester.ensureVisible(find.text('Build something'));
    await tester.tap(find.text('Build something'));
    await tester.pumpAndSettle();

    final blocked = tester.widget<OButton>(
      find.byKey(const Key('language-goal-continue')),
    );
    expect(blocked.onPressed, isNull);
    expect(find.text('Pick at least one goal to continue.'), findsOneWidget);

    // Tapping the disabled action must not continue.
    await tester.tap(
      find.byKey(const Key('language-goal-continue')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(continues, 0);
  });

  testWidgets('back is only shown when wired and fires once', (tester) async {
    await _pump(tester);
    expect(find.byKey(const Key('language-goal-back')), findsNothing);

    var backs = 0;
    await _pump(tester, onBack: () => backs++);
    await tester.tap(find.byKey(const Key('language-goal-back')));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('the grid offers exactly the supported languages', (
    tester,
  ) async {
    await _pump(tester);

    expect(const V2LanguageGoalData().languages, hasLength(5));
    // No "40+ languages" promise while only five are offered.
    expect(find.textContaining('40+'), findsNothing);
    expect(find.text('See all 40+ languages'), findsNothing);
  });

  testWidgets('loading shows skeletons and hides the continue bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const LanguageGoalPage(data: V2LanguageGoalData(loading: true)),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.byKey(const Key('language-goal-continue')), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(
        error: 'We could not load your languages.',
      ),
      onRetry: () => retries++,
    );

    expect(find.text('We could not load your languages.'), findsOneWidget);
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('empty language state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(languages: []),
      onRetry: () => retries++,
    );

    expect(find.text('No languages yet'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('survives 320 dp and 200 % text in dark too', (tester) async {
    await _pumpSmall(tester, dark: true);

    expect(tester.takeException(), isNull);
    expect(find.text('FIRST GOAL'), findsOneWidget);
  });

  testWidgets('every goal chip stays reachable at 200 % text', (tester) async {
    final events = <String>[];
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
          child: LanguageGoalPage(
            onGoalToggled: (id, selected) => events.add('$id:$selected'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Explore'));
    await tester.tap(find.text('Explore'));
    await tester.pump();

    expect(events, ['explore:true']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('close button is only shown when wired and fires once', (
    tester,
  ) async {
    var closes = 0;
    await _pump(tester);
    expect(find.bySemanticsLabel('Close'), findsNothing);

    await _pump(tester, onClose: () => closes++);
    await tester.tap(find.bySemanticsLabel('Close'));
    await tester.pump();

    expect(closes, 1);
  });

  testWidgets('language choice and disabled continue are announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, onContinue: (_, _) {});

    expect(
      tester.getSemantics(find.bySemanticsLabel('English, Global')),
      isSemantics(
        label: 'English, Global',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('हिन्दी, Hindi')),
      isSemantics(
        label: 'हिन्दी, Hindi',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('language-goal-continue'))),
      isSemantics(
        label: 'Continue',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );

    handle.dispose();
  });

  testWidgets('continue is announced as disabled with no language', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(
      tester,
      data: const V2LanguageGoalData(selectedLanguageId: null),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('language-goal-continue'))),
      isSemantics(
        label: 'Continue',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    handle.dispose();
  });

  testWidgets('language cards stay two per row and at least 48 dp tall', (
    tester,
  ) async {
    await _pump(tester);

    final english = tester.getRect(find.bySemanticsLabel('English, Global'));
    final hindi = tester.getRect(find.bySemanticsLabel('हिन्दी, Hindi'));

    expect(english.width, hindi.width);
    expect(english.top, hindi.top);
    expect(hindi.left, greaterThan(english.left));
    expect(english.height, greaterThanOrEqualTo(48));
    expect(hindi.height, greaterThanOrEqualTo(48));
  });

  testWidgets('an empty goal list still lets the user continue', (
    tester,
  ) async {
    Set<String>? goals;
    await _pump(
      tester,
      data: const V2LanguageGoalData(goals: []),
      onContinue: (_, ids) => goals = ids,
    );

    expect(
      find.text(
        'No goals to pick yet. You can continue and change this later.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('language-goal-continue')));
    await tester.pump();

    expect(goals, isEmpty);
  });

  group('shared step frame', () {
    testWidgets('the header is the shared onboarding step progress', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      expect(find.byType(OnboardingStepProgress), findsOneWidget);
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
      expect(find.bySemanticsLabel('Step 2 of 4'), findsOneWidget);

      handle.dispose();
    });

    testWidgets('host step data drives the label and the bar count', (
      tester,
    ) async {
      Future<void> pumpWith(V2LanguageGoalData data) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: OTheme.light(),
            home: LanguageGoalPage(data: data),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pumpWith(const V2LanguageGoalData(step: 2, totalSteps: 4));
      expect(find.text('STEP 2 OF 4'), findsOneWidget);
      expect(find.text('STEP 1 OF 3'), findsNothing);

      await pumpWith(const V2LanguageGoalData(step: 9, totalSteps: 3));
      expect(find.text('STEP 3 OF 3'), findsOneWidget);

      await pumpWith(const V2LanguageGoalData(step: 0, totalSteps: 3));
      expect(find.text('STEP 1 OF 3'), findsOneWidget);
      expect(find.text('STEP 0 OF 3'), findsNothing);
    });

    testWidgets('step header fits 320 dp at 200 % text', (tester) async {
      await _pumpSmall(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(OnboardingStepProgress), findsOneWidget);
    });
  });
}
