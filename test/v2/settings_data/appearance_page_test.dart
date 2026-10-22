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

V2AppearancePageData _data({
  ThemeMode themeMode = ThemeMode.system,
  bool memoryEnabled = true,
  bool shareSessionMemory = false,
  bool showReasoning = true,
  bool reduceMotion = false,
  bool followsSystem = true,
  bool highContrast = false,
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<double>? onTextScaleChanged,
  ValueChanged<bool>? onReduceMotionChanged,
  ValueChanged<bool>? onReduceMotionFollowsSystemChanged,
  ValueChanged<bool>? onHighContrastChanged,
  ValueChanged<bool>? onMemoryEnabledChanged,
  ValueChanged<bool>? onShareSessionMemoryChanged,
  ValueChanged<bool>? onShowReasoningChanged,
  ValueChanged<String>? onVoiceLanguageChanged,
  VoidCallback? onMemoryFilesTap,
}) {
  return V2AppearancePageData(
    themeMode: themeMode,
    textScale: 1,
    reduceMotion: reduceMotion,
    reduceMotionFollowsSystem: followsSystem,
    highContrast: highContrast,
    memoryEnabled: memoryEnabled,
    shareSessionMemory: shareSessionMemory,
    showReasoning: showReasoning,
    // Every control is wired by default so the render/layout tests exercise
    // the full screen. Tests that assert "no handler" use raw data instead.
    onThemeModeChanged: onThemeModeChanged ?? (_) {},
    onTextScaleChanged: onTextScaleChanged ?? (_) {},
    onVoiceLanguageChanged: onVoiceLanguageChanged ?? (_) {},
    onReduceMotionChanged: onReduceMotionChanged ?? (_) {},
    onReduceMotionFollowsSystemChanged:
        onReduceMotionFollowsSystemChanged ?? (_) {},
    onHighContrastChanged: onHighContrastChanged ?? (_) {},
    onMemoryEnabledChanged: onMemoryEnabledChanged ?? (_) {},
    onShareSessionMemoryChanged: onShareSessionMemoryChanged ?? (_) {},
    onShowReasoningChanged: onShowReasoningChanged ?? (_) {},
    onMemoryFilesTap: onMemoryFilesTap ?? () {},
  );
}

Switch _switch(WidgetTester tester, String key) =>
    tester.widget<Switch>(find.byKey(ValueKey<String>(key)));

void main() {
  testWidgets('renders one header and one line per control', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // One header, and the body does not repeat the title.
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('THEME'), findsOneWidget);
    expect(find.text('TEXT SIZE'), findsOneWidget);
    expect(find.text('VOICE'), findsOneWidget);
    expect(find.text('Voice language'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('MOTION'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('deleted sections are gone', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    // The preview, accent, density and code-font controls had no persisted
    // state, so they were deleted rather than hidden.
    expect(find.text('LIVE PREVIEW'), findsNothing);
    expect(find.text('Chat layout'), findsNothing);
    expect(find.text('ACCENT'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text('Code font'), findsNothing);
    expect(find.textContaining('apply to this device'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Appearance'), findsOneWidget);
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

  testWidgets('voice language reports the chosen language', (tester) async {
    String? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onVoiceLanguageChanged: (id) => next = id)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('voice-language-row')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('voice-language-row')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('voice-language-hi')));
    await tester.pumpAndSettle();
    expect(next, 'hi');
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

  testWidgets('reduce motion is disabled while following the device', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(followsSystem: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('reduce-motion-switch')),
    );
    expect(
      _switch(tester, 'reduce-motion-switch').onChanged,
      isNull,
      reason: 'the device owns the value while following it',
    );
  });

  testWidgets('high contrast reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onHighContrastChanged: (value) => next = value)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('high-contrast-switch')),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('high-contrast-switch')),
    );
    expect(next, isTrue);
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

    expect(
      find.text('Appearance settings could not load.'),
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
    expect(find.text('ACCENT'), findsNothing);
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    _useNarrowPhone(tester);
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _narrowApp(
          AppearancePage(
            data: V2AppearancePageData(
              onThemeModeChanged: (_) {},
              onTextScaleChanged: (_) {},
              onVoiceLanguageChanged: (_) {},
              onReduceMotionChanged: (_) {},
              onReduceMotionFollowsSystemChanged: (_) {},
              onHighContrastChanged: (_) {},
              onMemoryEnabledChanged: (_) {},
              onShareSessionMemoryChanged: (_) {},
              onShowReasoningChanged: (_) {},
              onMemoryFilesTap: () {},
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
    expect(find.text('VOICE'), findsNothing);
    expect(find.text('Global memory'), findsNothing);
    expect(find.text('Show reasoning'), findsNothing);
    expect(find.text('High contrast'), findsNothing);
    expect(find.text('Reduce motion'), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Dark theme')),
      isSemantics(label: 'Dark theme', isButton: true, isEnabled: false),
    );
    handle.dispose();
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

    expect(find.text('THEME'), findsOneWidget);
    expect(find.text('TEXT SIZE'), findsOneWidget);
    expect(find.text('VOICE'), findsOneWidget);
    expect(find.text('Voice language'), findsOneWidget);
    expect(find.text('MEMORY'), findsOneWidget);
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('MOTION'), findsOneWidget);
  });

  testWidgets('content is centred and capped at 600 dp', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byType(OCard).first);
    expect(card.width, lessThanOrEqualTo(640));
    expect(card.left, greaterThan(0));
    expect(card.right, lessThan(600));
  });

  testWidgets('content is centred and capped at 900 dp', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(find.byType(OCard).first);
    expect(card.width, lessThanOrEqualTo(720));
    expect(card.left, greaterThan(0));
    expect(card.right, lessThan(900));
  });
}
