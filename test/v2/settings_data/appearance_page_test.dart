import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/appearance_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

Widget _narrowApp(Widget home, {required ThemeData theme}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

void _useNarrowPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

const _preview = V2AppearancePreview(
  sessionLabel: 'Session #408',
  statusLabel: 'Ready',
  userMessage: 'Can you analyze this repo structure?',
  assistantMessage: 'I indexed 14 components and prepared the build spec.',
);

V2AppearancePageData _data({
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<String>? onAccentChanged,
  ValueChanged<double>? onTextScaleChanged,
  ValueChanged<bool>? onReduceMotionChanged,
  ValueChanged<bool>? onReduceMotionFollowsSystemChanged,
  ValueChanged<String>? onDensityChanged,
  ValueChanged<String>? onCodeFontChanged,
  ValueChanged<String>? onVoiceLanguageChanged,
  String voiceLanguageId = 'en',
  VoidCallback? onRefreshPreview,
}) {
  return V2AppearancePageData(
    themeMode: ThemeMode.system,
    accentId: 'violet',
    textScale: 1,
    voiceLanguageId: voiceLanguageId,
    preview: _preview,
    onThemeModeChanged: onThemeModeChanged,
    onAccentChanged: onAccentChanged,
    onTextScaleChanged: onTextScaleChanged,
    onReduceMotionChanged: onReduceMotionChanged,
    onReduceMotionFollowsSystemChanged: onReduceMotionFollowsSystemChanged,
    onDensityChanged: onDensityChanged,
    onCodeFontChanged: onCodeFontChanged,
    onVoiceLanguageChanged: onVoiceLanguageChanged,
    onRefreshPreview: onRefreshPreview,
  );
}

void main() {
  testWidgets('renders theme controls and preview in light mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('Density'), findsOneWidget);
    expect(find.text('Code font'), findsOneWidget);
    expect(find.text('Follow device setting'), findsOneWidget);
    expect(find.text('LIVE PREVIEW'), findsOneWidget);
    expect(find.text('Can you analyze this repo structure?'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Reduce motion'), findsOneWidget);
    expect(find.text('High contrast'), findsOneWidget);
  });

  testWidgets('empty preview offers a refresh action', (tester) async {
    var refreshed = false;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: V2AppearancePageData(onRefreshPreview: () => refreshed = true),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No preview yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Show preview'));
    await tester.tap(find.text('Show preview'));
    expect(refreshed, isTrue);
  });

  testWidgets('choosing dark reports the new theme mode', (tester) async {
    ThemeMode? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onThemeModeChanged: (mode) => next = mode)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    expect(next, ThemeMode.dark);
  });

  testWidgets('accent dot reports the chosen colour', (tester) async {
    String? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onAccentChanged: (id) => next = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('accent-green')));
    expect(next, 'green');
  });

  testWidgets('text size slider covers 75 to 180 percent', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.min, 0.75);
    expect(slider.max, 1.8);
    expect(slider.divisions, 21);
  });

  testWidgets('density choice reports the selected value', (tester) async {
    String? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onDensityChanged: (id) => next = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('density-compact')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('density-compact')));
    expect(next, 'compact');
  });

  testWidgets('code font choice reports the selected value', (tester) async {
    String? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onCodeFontChanged: (id) => next = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('code-font-fira')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('code-font-fira')));
    expect(next, 'fira');
  });

  testWidgets('reduce motion can follow the device setting', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(
            onReduceMotionFollowsSystemChanged: (value) => next = value,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('follow-device-switch')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('follow-device-switch')),
    );
    expect(next, isFalse);
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

  testWidgets('loading state renders skeletons', (tester) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(data: const V2AppearancePageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Accent color'), findsNothing);
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    _useNarrowPhone(tester);
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrowApp(
          AppearancePage(
            data: V2AppearancePageData(
              preview: _preview,
              onThemeModeChanged: (_) {},
              onAccentChanged: (_) {},
              onTextScaleChanged: (_) {},
              onReduceMotionChanged: (_) {},
              onReduceMotionFollowsSystemChanged: (_) {},
              onHighContrastChanged: (_) {},
              onDensityChanged: (_) {},
              onCodeFontChanged: (_) {},
              onPreviewSend: () {},
              onRefreshPreview: () {},
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disabled controls are announced as disabled', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // No callbacks are injected, so every control is read-only.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Dark theme')),
      isSemantics(label: 'Dark theme', isButton: true, isEnabled: false),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('density-compact')),
      ),
      isSemantics(label: 'Compact', isButton: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('voice language lists the five dictation languages', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Voice language'));
    expect(find.text('Voice language'), findsOneWidget);
    for (final label in ['English', 'Hindi', 'Hinglish', 'Punjabi', 'Tamil']) {
      expect(find.text(label), findsOneWidget);
    }
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('voice-language-en')),
      ),
      isSemantics(label: 'English', isSelected: true, isButton: true),
    );
    handle.dispose();
  });

  testWidgets('choosing a voice language reports the id', (tester) async {
    String? picked;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(onVoiceLanguageChanged: (id) => picked = id),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final punjabi = find.byKey(const ValueKey<String>('voice-language-pa'));
    await tester.ensureVisible(punjabi);
    await tester.tap(punjabi);
    await tester.pumpAndSettle();

    expect(picked, 'pa');
  });

  testWidgets('voice language row fits 320 dp at 200% text light and dark', (
    tester,
  ) async {
    _useNarrowPhone(tester);
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrowApp(
          AppearancePage(
            data: _data(
              voiceLanguageId: 'hinglish',
              onVoiceLanguageChanged: (_) {},
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Voice language'));
      expect(tester.takeException(), isNull);
      expect(find.text('Voice language'), findsOneWidget);
    }
  });

  testWidgets('reduced motion keeps every section visible', (tester) async {
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
    await tester.pump();

    expect(find.text('THEME MODE'), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);
    expect(find.text('Text size'), findsOneWidget);
    expect(find.text('CHAT LAYOUT'), findsOneWidget);
    expect(find.text('ACCESSIBILITY & MOTION'), findsOneWidget);
    expect(find.text('Can you analyze this repo structure?'), findsOneWidget);
  });
}
