import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/appearance_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

Widget _scaledApp(
  Widget home, {
  required ThemeData theme,
  required double textScale,
}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: home,
);

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

V2AppearancePageData _data({
  ThemeMode themeMode = ThemeMode.system,
  double textScale = 1,
  String voiceLanguageId = 'en',
  FutureOr<void> Function(ThemeMode)? onThemeModeChanged,
  FutureOr<void> Function(double)? onTextScaleChanged,
  FutureOr<void> Function(String)? onVoiceLanguageChanged,
  FutureOr<void> Function(bool)? onReduceMotionChanged,
}) {
  return V2AppearancePageData(
    themeMode: themeMode,
    textScale: textScale,
    voiceLanguageId: voiceLanguageId,
    // Every remaining control is wired by default so the render/layout tests
    // exercise the full screen. Tests that assert "no handler" use raw data.
    onThemeModeChanged: onThemeModeChanged ?? (_) {},
    onTextScaleChanged: onTextScaleChanged ?? (_) {},
    onVoiceLanguageChanged: onVoiceLanguageChanged ?? (_) {},
    onReduceMotionChanged: onReduceMotionChanged,
  );
}

void main() {
  setUp(() {
    // Every test starts with an empty, working preference store: the motion
    // toggle reads and writes it for real.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'renders one header, three theme radios, a slider and both rows',
    (tester) async {
      await tester.pumpWidget(
        _app(AppearancePage(data: _data()), theme: OTheme.light()),
      );
      await tester.pumpAndSettle();

      // One header, and the body does not repeat the title.
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('THEME'), findsOneWidget);
      expect(find.text('TEXT SIZE'), findsOneWidget);
      expect(find.text('VOICE'), findsOneWidget);
      expect(find.text('MOTION'), findsOneWidget);
      expect(find.text('Voice language'), findsOneWidget);
      expect(find.text('Dictation only'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('appearance-text-preview')),
        findsOneWidget,
      );
    },
  );

  testWidgets('deleted sections are gone', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // The live-preview, accent, density and code-font controls had no
    // persisted state, so they were deleted rather than hidden.
    expect(find.text('LIVE PREVIEW'), findsNothing);
    expect(find.text('Chat layout'), findsNothing);
    expect(find.text('ACCENT'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text('Code font'), findsNothing);
    expect(find.textContaining('apply to this device'), findsNothing);

    // Memory and reasoning live on their own pages.
    expect(find.text('MEMORY'), findsNothing);
    expect(find.text('CHAT'), findsNothing);
    expect(find.text('Global memory'), findsNothing);
    expect(find.text('Share chat memory'), findsNothing);
    expect(find.text('Show reasoning'), findsNothing);
    expect(find.text('High contrast'), findsNothing);
    expect(find.text('Follow device setting'), findsNothing);
    expect(find.text('Memory files'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Voice language'), findsOneWidget);
  });

  testWidgets('theme is a radio group with a checked member', (tester) async {
    final handle = tester.ensureSemantics();
    ThemeMode? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onThemeModeChanged: (mode) => next = mode)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-system')),
      ),
      isSemantics(
        label: 'System theme',
        isInMutuallyExclusiveGroup: true,
        isChecked: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-dark')),
      ),
      isSemantics(
        label: 'Dark theme',
        isInMutuallyExclusiveGroup: true,
        isChecked: false,
      ),
    );

    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(next, ThemeMode.dark);
    // No parent rebuild supplied new data: the page itself must move the
    // checked state so the choice is visible immediately.
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-dark')),
      ),
      isSemantics(label: 'Dark theme', isChecked: true),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-system')),
      ),
      isSemantics(label: 'System theme', isChecked: false),
    );
    handle.dispose();
  });

  testWidgets('a failed theme write rolls back, reports and can retry', (
    tester,
  ) async {
    var fail = true;
    ThemeMode? saved;
    Future<void> save(ThemeMode mode) async {
      if (fail) throw StateError('disk full');
      saved = mode;
    }

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onThemeModeChanged: save)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(saved, isNull);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-system')),
      ),
      isSemantics(label: 'System theme', isChecked: true),
    );
    expect(find.text('Theme not saved.'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('appearance-save-error')),
      findsOneWidget,
    );

    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(saved, ThemeMode.dark);
    expect(
      find.byKey(const ValueKey<String>('appearance-save-error')),
      findsNothing,
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-dark')),
      ),
      isSemantics(label: 'Dark theme', isChecked: true),
    );
    handle.dispose();
  });

  testWidgets('text size slider has 21 steps and announces its value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(AppearancePage(data: _data(textScale: 1.25)), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0.75);
    expect(slider.max, 1.8);
    expect(slider.divisions, 21);
    expect(slider.value, closeTo(1.25, 0.001));

    expect(
      tester.getSemantics(find.byType(Slider)),
      isSemantics(label: 'Text size', value: '125%', isSlider: true),
    );
    handle.dispose();
  });

  testWidgets('text size applies to the preview on the same frame and saves', (
    tester,
  ) async {
    double? saved;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(onTextScaleChanged: (value) => saved = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final preview = find.byKey(
      const ValueKey<String>('appearance-text-preview'),
    );
    final before = tester.getSize(preview).height;

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();

    expect(saved, isNotNull);
    expect(saved, greaterThan(1));
    expect(tester.getSize(preview).height, greaterThan(before));
    expect(find.text('100%'), findsNothing);
  });

  testWidgets('a failed text-size write rolls back and reports', (
    tester,
  ) async {
    Future<void> save(double value) async => throw StateError('disk full');

    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onTextScaleChanged: save)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(find.text('100%'), findsOneWidget);
    expect(find.text('Text size not saved.'), findsWidgets);
  });

  testWidgets('an unset voice language is not shown as a choice', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(voiceLanguageId: '')),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The row says nothing has been chosen; it does not claim English.
    expect(find.text('Not set'), findsOneWidget);
    expect(find.text('English'), findsNothing);
    expect(find.text('Dictation only'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('voice-language-row')));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('voice-language-en')),
      ),
      isSemantics(
        label: 'English',
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });

  testWidgets(
    'voice language reports the chosen language and updates the row',
    (tester) async {
      String? next;
      await tester.pumpWidget(
        _app(
          AppearancePage(
            data: _data(onVoiceLanguageChanged: (id) => next = id),
          ),
          theme: OTheme.light(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('voice-language-row')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('voice-language-hi')));
      await tester.pumpAndSettle();

      expect(next, 'hi');
      expect(find.text('हिन्दी'), findsOneWidget);
      expect(find.text('Not set'), findsNothing);
    },
  );

  testWidgets('a failed voice write rolls back and reports', (tester) async {
    Future<void> save(String id) async => throw StateError('disk full');

    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onVoiceLanguageChanged: save)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('voice-language-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('voice-language-hi')));
    await tester.pumpAndSettle();

    expect(find.text('English'), findsOneWidget);
    expect(find.text('हिन्दी'), findsNothing);
    expect(find.text('Voice language not saved.'), findsWidgets);
  });

  testWidgets('reduced motion persists and disables animation', (tester) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(key: UniqueKey(), data: _data()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('appearance-reduce-motion-switch'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);

    AnimatedContainer tile() => tester.widget<AnimatedContainer>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('appearance-theme-system')),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(tile().duration, OMotion.fast);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(toggle).value, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(V2MotionPreference.key), isTrue);
    expect(
      MediaQuery.maybeDisableAnimationsOf(
        tester.element(
          find.byKey(const ValueKey<String>('appearance-reduce-motion')),
        ),
      ),
      isTrue,
    );
    expect(tile().duration, Duration.zero);

    // A fresh page reads the stored preference: the choice survives a
    // restart rather than living only in this widget's state.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      _app(
        AppearancePage(key: UniqueKey(), data: _data()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey<String>('appearance-reduce-motion-switch'),
            ),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('reduced motion announces its state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-reduce-motion-switch')),
      ),
      isSemantics(
        label: 'Reduce motion',
        hasToggledState: true,
        isToggled: false,
        isEnabled: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a failed motion write rolls back and reports', (tester) async {
    Future<void> save(bool value) async => throw StateError('disk full');

    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onReduceMotionChanged: save)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('appearance-reduce-motion-switch'),
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.text('Motion not saved.'), findsWidgets);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: V2AppearancePageData(
            errorMessage: 'Appearance settings could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance settings could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('loading state renders skeletons, never unset choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(data: const V2AppearancePageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('THEME'), findsNothing);
    expect(find.text('Not set'), findsNothing);
  });

  testWidgets('controls without a handler are not rendered', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const AppearancePage(data: V2AppearancePageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // No voice callback: the section is omitted instead of drawing a dead
    // control. Theme tiles stay as a disabled radio group.
    expect(find.text('VOICE'), findsNothing);
    expect(find.text('Voice language'), findsNothing);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('appearance-theme-dark')),
      ),
      isSemantics(
        label: 'Dark theme',
        isChecked: false,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets(
    'fits 320 dp at 200% text in light and dark, 3-up without clipping',
    (tester) async {
      _useSize(tester, const Size(320, 640));
      for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
        await tester.pumpWidget(
          _scaledApp(
            AppearancePage(key: UniqueKey(), data: _data()),
            theme: theme,
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        final system = tester.getRect(
          find.byKey(const ValueKey<String>('appearance-theme-system')),
        );
        final light = tester.getRect(
          find.byKey(const ValueKey<String>('appearance-theme-light')),
        );
        final dark = tester.getRect(
          find.byKey(const ValueKey<String>('appearance-theme-dark')),
        );
        // Three tiles, one row, in order.
        expect(system.top, closeTo(light.top, 0.5));
        expect(light.top, closeTo(dark.top, 0.5));
        expect(system.left, lessThan(light.left));
        expect(light.left, lessThan(dark.left));
        expect(dark.right, lessThanOrEqualTo(320));
        expect(system.width, greaterThan(0));

        // Every label is fully laid out, not clipped by the tile edge.
        for (final label in <String>['System', 'Light', 'Dark']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(label),
          );
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '$label is clipped at 320 dp / 200 % text',
          );
        }

        expect(find.text('Voice language'), findsOneWidget);
        expect(find.text('Reduce motion'), findsOneWidget);
      }
    },
  );

  testWidgets('every band 320→1280 at 100% and 200% text, light and dark', (
    tester,
  ) async {
    const widths = <double>[320, 360, 412, 600, 800, 1024, 1280];
    for (final width in widths) {
      for (final scale in <double>[1, 2]) {
        for (final dark in <bool>[false, true]) {
          _useSize(tester, Size(width, 900));
          await tester.pumpWidget(
            _scaledApp(
              AppearancePage(key: UniqueKey(), data: _data()),
              theme: dark ? OTheme.dark() : OTheme.light(),
              textScale: scale,
            ),
          );
          await tester.pumpAndSettle();

          expect(
            tester.takeException(),
            isNull,
            reason: '$width dp at ${scale}x, ${dark ? 'dark' : 'light'}',
          );

          final section = tester.getRect(find.byType(OSection).first);
          final cap = width >= 600 ? 640.0 : width;
          expect(
            section.width,
            lessThanOrEqualTo(cap),
            reason: 'content is wider than the $cap dp band cap',
          );
          expect(section.left, greaterThan(0));
        }
      }
    }
  });

  testWidgets('content is centred and capped at 600 dp', (tester) async {
    _useSize(tester, const Size(600, 900));

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final section = tester.getRect(find.byType(OSection).first);
    expect(section.width, lessThanOrEqualTo(640));
    expect(section.left, greaterThan(0));
    expect(section.right, lessThan(600));
  });

  testWidgets('content is centred and capped at 900 dp', (tester) async {
    _useSize(tester, const Size(900, 900));

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final section = tester.getRect(find.byType(OSection).first);
    expect(section.width, lessThanOrEqualTo(640));
    expect(section.left, greaterThan(0));
    expect(section.right, lessThan(900));
    // Centred: the same margin on both sides.
    expect(section.left, closeTo(900 - section.right, 0.5));
  });

  testWidgets('the platform reduced-motion setting keeps every section', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppearancePage(data: _data()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('THEME'), findsOneWidget);
    expect(find.text('TEXT SIZE'), findsOneWidget);
    expect(find.text('VOICE'), findsOneWidget);
    expect(find.text('MOTION'), findsOneWidget);
    expect(find.text('Voice language'), findsOneWidget);
  });
}
