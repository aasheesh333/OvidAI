import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/onboarding/language_goal_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/onboarding_prefs.dart';
import 'package:ovid_ai/ui/v2/onboarding/step_progress.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    expect(find.text('VOICE LANGUAGE'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('हिन्दी'), findsOneWidget);
    expect(find.text('Hinglish'), findsOneWidget);
    expect(find.text('ਪੰਜਾਬੀ'), findsOneWidget);
    expect(find.text('தமிழ்'), findsOneWidget);
    expect(find.text('Build something'), findsOneWidget);
    expect(find.text('Research'), findsOneWidget);
    expect(find.text('Write'), findsOneWidget);
    expect(find.text('Automate work'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('STEP 2 OF 4'), findsOneWidget);
    expect(find.byKey(const Key('language-goal-continue')), findsOneWidget);
  });

  testWidgets('language and goal survives 320 dp and 200 % text', (
    tester,
  ) async {
    await _pumpSmall(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);
  });

  testWidgets('language and goal renders correctly in dark', (tester) async {
    await _pump(tester, dark: true);

    expect(find.text('VOICE LANGUAGE'), findsOneWidget);
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
    expect(find.text('Pick a goal.'), findsOneWidget);

    // Tapping the disabled action must not continue.
    await tester.tap(
      find.byKey(const Key('language-goal-continue')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(continues, 0);
  });

  testWidgets('Continue persists both choices and they are read on reopen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final store = V2OnboardingStore();

    await _pump(
      tester,
      onContinue: (languageId, goalIds) async {
        await store.saveChoices(languageId: languageId, goalIds: goalIds);
      },
    );

    await tester.ensureVisible(find.text('தமிழ்'));
    await tester.tap(find.text('தமிழ்'));
    await tester.ensureVisible(find.text('Research'));
    await tester.tap(find.text('Research'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('language-goal-continue')));
    await tester.pumpAndSettle();

    final snapshot = await store.load(
      welcomeVersion: kV2OnboardingWelcomeVersion,
    );
    expect(snapshot.languageId, 'ta');
    expect(snapshot.goalIds, contains('research'));

    // A fresh mount reads the stored snapshot back into the same chips.
    await tester.pumpWidget(const SizedBox.shrink());
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      data: V2LanguageGoalData(
        selectedLanguageId: snapshot.languageId,
        selectedGoalIds: snapshot.goalIds,
      ),
      onContinue: (_, _) {},
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('தமிழ்')),
      isSemantics(
        label: 'தமிழ்',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('English')),
      isSemantics(
        label: 'English',
        isButton: true,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Research')),
      isSemantics(
        label: 'Research',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a stale saved language is not selected and cannot continue', (
    tester,
  ) async {
    var continues = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(selectedLanguageId: 'removed-language'),
      onContinue: (_, _) => continues++,
    );

    final button = tester.widget<OButton>(
      find.byKey(const Key('language-goal-continue')),
    );
    expect(button.onPressed, isNull);
    expect(find.text('Choose a voice language.'), findsOneWidget);
    expect(find.text('removed-language'), findsNothing);

    await tester.tap(
      find.byKey(const Key('language-goal-continue')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(continues, 0);
  });

  testWidgets('only one language chip is selected at a time', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onContinue: (_, _) {});

    await tester.ensureVisible(find.text('हिन्दी'));
    await tester.tap(find.text('हिन्दी'));
    await tester.pump();

    expect(
      tester.getSemantics(find.bySemanticsLabel('हिन्दी')).flagsCollection
          .isSelected,
      ui.Tristate.isTrue,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('English')).flagsCollection
          .isSelected,
      ui.Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('each section is a labelled header that groups its chips', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onContinue: (_, _) {});

    expect(find.bySemanticsLabel('Voice language'), findsOneWidget);
    expect(find.bySemanticsLabel('Goal'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Voice language')),
      isSemantics(label: 'Voice language', isHeader: true),
    );
    handle.dispose();
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

  testWidgets('a failed load shows the error and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(
        languages: [],
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

  testWidgets('a failed save keeps the choices visible and retries', (
    tester,
  ) async {
    var continues = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(
        error: 'We could not save your choices. Try again.',
      ),
      onContinue: (_, _) => continues++,
    );

    // The grid is still there: a save failure must not throw away the work.
    expect(find.text('हिन्दी'), findsOneWidget);
    expect(find.text('Build something'), findsOneWidget);
    expect(
      find.text('We could not save your choices. Try again.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('language-goal-continue')));
    await tester.pump();
    expect(continues, 1);
  });

  testWidgets('empty language state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      data: const V2LanguageGoalData(languages: []),
      onRetry: () => retries++,
    );

    expect(find.text('No voice languages yet'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retries, 1);
  });

  testWidgets('survives 320 dp and 200 % text in dark too', (tester) async {
    await _pumpSmall(tester, dark: true);

    expect(tester.takeException(), isNull);
    expect(find.text('GOAL'), findsOneWidget);
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
      tester.getSemantics(find.bySemanticsLabel('English')),
      isSemantics(
        label: 'English',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('हिन्दी')),
      isSemantics(
        label: 'हिन्दी',
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

  testWidgets('language chips share a row and stay at least 48 dp tall', (
    tester,
  ) async {
    await _pump(tester);

    final english = tester.getRect(find.bySemanticsLabel('English'));
    final hindi = tester.getRect(find.bySemanticsLabel('हिन्दी'));

    expect(english.top, hindi.top);
    expect(hindi.left, greaterThan(english.left));
    expect(english.height, greaterThanOrEqualTo(48));
    expect(hindi.height, greaterThanOrEqualTo(48));
  });

  testWidgets('the chip grid is 2-up at 360 dp and 3-up at 600 dp', (
    tester,
  ) async {
    Future<void> pumpAt(double width) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: OTheme.light(), home: const LanguageGoalPage()),
      );
      await tester.pumpAndSettle();
    }

    await pumpAt(360);
    var english = tester.getRect(find.bySemanticsLabel('English'));
    var hindi = tester.getRect(find.bySemanticsLabel('हिन्दी'));
    var hinglish = tester.getRect(find.bySemanticsLabel('Hinglish'));
    expect(english.top, hindi.top, reason: '2-up shares a row');
    expect(hinglish.top, greaterThan(english.top), reason: 'third wraps');

    await pumpAt(600);
    english = tester.getRect(find.bySemanticsLabel('English'));
    hindi = tester.getRect(find.bySemanticsLabel('हिन्दी'));
    hinglish = tester.getRect(find.bySemanticsLabel('Hinglish'));
    expect(english.top, hindi.top, reason: '3-up first row');
    expect(hindi.top, hinglish.top, reason: '3-up first row');
  });

  testWidgets('an empty goal list hides the section and still continues', (
    tester,
  ) async {
    Set<String>? goals;
    await _pump(
      tester,
      data: const V2LanguageGoalData(goals: []),
      onContinue: (_, ids) => goals = ids,
    );

    // No helper paragraph stands in for the missing section.
    expect(find.text('GOAL'), findsNothing);
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);

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
