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
  ThemeMode themeMode = ThemeMode.system,
  bool memoryEnabled = true,
  bool shareSessionMemory = false,
  bool showReasoning = true,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<String>? onAccentChanged,
  ValueChanged<double>? onTextScaleChanged,
  ValueChanged<bool>? onReduceMotionChanged,
  ValueChanged<bool>? onReduceMotionFollowsSystemChanged,
  ValueChanged<String>? onDensityChanged,
  ValueChanged<String>? onCodeFontChanged,
  ValueChanged<String>? onVoiceLanguageChanged,
  ValueChanged<bool>? onMemoryEnabledChanged,
  ValueChanged<bool>? onShareSessionMemoryChanged,
  ValueChanged<bool>? onShowReasoningChanged,
  VoidCallback? onMemoryFilesTap,
  String voiceLanguageId = 'en',
  VoidCallback? onRefreshPreview,
}) {
  return V2AppearancePageData(
    themeMode: themeMode,
    accentId: 'violet',
    textScale: 1,
    voiceLanguageId: voiceLanguageId,
    memoryEnabled: memoryEnabled,
    shareSessionMemory: shareSessionMemory,
    showReasoning: showReasoning,
    preview: _preview,
    // Every control is wired by default so the render/layout tests exercise
    // the full screen. Tests that assert "no handler" use raw data instead.
    onThemeModeChanged: onThemeModeChanged ?? (_) {},
    onAccentChanged: onAccentChanged ?? (_) {},
    onTextScaleChanged: onTextScaleChanged ?? (_) {},
    onReduceMotionChanged: onReduceMotionChanged ?? (_) {},
    onReduceMotionFollowsSystemChanged:
        onReduceMotionFollowsSystemChanged ?? (_) {},
    onDensityChanged: onDensityChanged ?? (_) {},
    onCodeFontChanged: onCodeFontChanged ?? (_) {},
    onVoiceLanguageChanged: onVoiceLanguageChanged ?? (_) {},
    onMemoryEnabledChanged: onMemoryEnabledChanged ?? (_) {},
    onShareSessionMemoryChanged: onShareSessionMemoryChanged ?? (_) {},
    onShowReasoningChanged: onShowReasoningChanged ?? (_) {},
    onMemoryFilesTap: onMemoryFilesTap ?? () {},
    onRefreshPreview: onRefreshPreview ?? () {},
  );
}

Switch _switch(WidgetTester tester, String key) =>
    tester.widget<Switch>(find.byKey(ValueKey<String>(key)));

void main() {
  testWidgets('renders the personalization controls in light mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('Global memory'), findsOneWidget);
    expect(find.text('Share session memory'), findsOneWidget);
    expect(find.text('Memory files'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('Show reasoning'), findsOneWidget);
    expect(find.text('Chat text size'), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);
    expect(find.text('LIVE PREVIEW'), findsOneWidget);
    expect(find.text('Can you analyze this repo structure?'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Personalization'), findsOneWidget);
    expect(find.text('Global memory'), findsOneWidget);
    expect(find.text('Show reasoning'), findsOneWidget);
    expect(find.text('Reduce motion'), findsOneWidget);
    expect(find.text('High contrast'), findsOneWidget);
  });

  testWidgets('defaults keep memory and reasoning on, sharing off', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(_switch(tester, 'global-memory-switch').value, isTrue);
    expect(_switch(tester, 'share-session-memory-switch').value, isFalse);
    expect(_switch(tester, 'show-reasoning-switch').value, isTrue);
  });

  testWidgets('global memory switch reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(onMemoryEnabledChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('global-memory-switch')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('global-memory-switch')));
    expect(next, isFalse);
  });

  testWidgets('share session memory switch reports the new value', (
    tester,
  ) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(onShareSessionMemoryChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('share-session-memory-switch')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('share-session-memory-switch')),
    );
    expect(next, isTrue);
  });

  testWidgets('show reasoning switch reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(
          data: _data(onShowReasoningChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('show-reasoning-switch')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('show-reasoning-switch')));
    expect(next, isFalse);
  });

  testWidgets('show reasoning off persists when the page rebuilds', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(showReasoning: false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(_switch(tester, 'show-reasoning-switch').value, isFalse);

    // Rebuilding with the saved value must keep the switch off.
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(showReasoning: false)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(_switch(tester, 'show-reasoning-switch').value, isFalse);
  });

  testWidgets('memory files row opens the files screen', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onMemoryFilesTap: () => opened++)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey<String>('memory-files-row'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('no preview section is drawn without a preview', (
    tester,
  ) async {
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

    // The old "Show preview" action re-opened this same screen (a fake). With
    // no preview data there is no section and no dead button.
    expect(find.text('LIVE PREVIEW'), findsNothing);
    expect(find.text('Show preview'), findsNothing);
    expect(refreshed, isFalse);
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

  testWidgets('chat text size slider covers 75 to 180 percent', (tester) async {
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
            errorMessage: 'Personalization settings could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Personalization settings could not load.'),
      findsOneWidget,
    );
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
              onMemoryEnabledChanged: (_) {},
              onShareSessionMemoryChanged: (_) {},
              onShowReasoningChanged: (_) {},
              onMemoryFilesTap: () {},
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

  testWidgets('controls without a handler are not rendered', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const AppearancePage(data: V2AppearancePageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // No callbacks are injected: the page omits the sections it cannot wire
    // instead of drawing dead controls.
    expect(find.text('Accent color'), findsNothing);
    expect(find.text('Global memory'), findsNothing);
    expect(find.text('Show reasoning'), findsNothing);
    expect(find.text('Chat layout'), findsNothing);
    expect(find.text('High contrast'), findsNothing);
    expect(find.text('Reduce motion'), findsNothing);
    expect(
      find.textContaining('reduce-motion setting'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Dark theme')),
      isSemantics(label: 'Dark theme', isButton: true, isEnabled: false),
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

  testWidgets('choosing a theme applies on the same frame', (tester) async {
    ThemeMode? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onThemeModeChanged: (mode) => next = mode)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.bySemanticsLabel('System theme')),
      isSemantics(label: 'System theme', isSelected: true),
    );

    await tester.tap(find.text('Dark'));
    await tester.pump();

    expect(next, ThemeMode.dark);
    // No parent rebuild supplied new data: the page itself must move the
    // selection so the choice is visible immediately.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Dark theme')),
      isSemantics(label: 'Dark theme', isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('System theme')),
      isSemantics(label: 'System theme', isSelected: false),
    );
    handle.dispose();
  });

  testWidgets('choosing a voice language applies on the same frame', (
    tester,
  ) async {
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
    await tester.pump();

    expect(picked, 'pa');
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(punjabi),
      isSemantics(label: 'Punjabi', isSelected: true, isButton: true),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('voice-language-en')),
      ),
      isSemantics(label: 'English', isSelected: false, isButton: true),
    );
    handle.dispose();
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
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('CHAT LAYOUT'), findsOneWidget);
    expect(find.text('ACCESSIBILITY & MOTION'), findsOneWidget);
    expect(find.text('Can you analyze this repo structure?'), findsOneWidget);
  });
}
