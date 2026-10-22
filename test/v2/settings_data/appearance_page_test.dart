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
  ValueChanged<ThemeMode>? onThemeModeChanged,
  ValueChanged<double>? onTextScaleChanged,
  ValueChanged<String>? onVoiceLanguageChanged,
}) {
  return V2AppearancePageData(
    themeMode: themeMode,
    textScale: 1,
    // Every remaining control is wired by default so the render/layout tests
    // exercise the full screen. Tests that assert "no handler" use raw data.
    onThemeModeChanged: onThemeModeChanged ?? (_) {},
    onTextScaleChanged: onTextScaleChanged ?? (_) {},
    onVoiceLanguageChanged: onVoiceLanguageChanged ?? (_) {},
  );
}

void main() {
  testWidgets('renders one header, theme tiles, one slider, one voice row', (
    tester,
  ) async {
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
    expect(find.text('English'), findsOneWidget);
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

    // Memory, reasoning and motion live on their own pages now.
    expect(find.text('MEMORY'), findsNothing);
    expect(find.text('CHAT'), findsNothing);
    expect(find.text('MOTION'), findsNothing);
    expect(find.text('Global memory'), findsNothing);
    expect(find.text('Share chat memory'), findsNothing);
    expect(find.text('Show reasoning'), findsNothing);
    expect(find.text('Reduce motion'), findsNothing);
    expect(find.text('Follow device setting'), findsNothing);
    expect(find.text('High contrast'), findsNothing);
    expect(find.text('Memory files'), findsNothing);
    expect(find.byType(Switch), findsNothing);
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

  testWidgets('the voice row carries the current language as its value', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey<String>('voice-language-row'));
    expect(
      find.descendant(of: row, matching: find.text('English')),
      findsOneWidget,
    );
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

  testWidgets('text size slider reports the new value', (tester) async {
    double? next;
    await tester.pumpWidget(
      _app(
        AppearancePage(data: _data(onTextScaleChanged: (value) => next = value)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider), const Offset(60, 0));
    await tester.pump();

    expect(next, isNotNull);
    expect(next, greaterThan(1));
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
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Voice language'), findsOneWidget);
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
    expect(find.text('Voice language'), findsNothing);
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
  });

  testWidgets('content is centred and capped at 600 dp', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final slider = tester.getRect(find.byType(Slider));
    expect(slider.width, lessThanOrEqualTo(640));
    expect(slider.left, greaterThan(0));
    expect(slider.right, lessThan(600));
  });

  testWidgets('content is centred and capped at 900 dp', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(AppearancePage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    final slider = tester.getRect(find.byType(Slider));
    expect(slider.width, lessThanOrEqualTo(720));
    expect(slider.left, greaterThan(0));
    expect(slider.right, lessThan(900));
  });
}
