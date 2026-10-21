import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/search_page.dart';

const _chat = V2SearchChat(
  id: 'c1',
  title: 'Landing page redesign',
  modelLabel: 'Auto',
  timeLabel: '2h ago',
  snippet: 'Build me a clean dark mode landing page with animations',
);

const _project = V2SearchProject(
  id: 'pr1',
  name: 'Mobile App Redesign',
  chatCount: 3,
  detail: 'Includes landing page spec',
);

const _artifact = V2SearchArtifact(
  id: 'a1',
  name: 'portfolio-index.html',
  meta: '14.2 KB · landing page · HTML',
);

const _brandProject = V2SearchProject(
  id: 'pr2',
  name: 'Brand Voice Guidelines',
  chatCount: 4,
  detail: 'Tone and words',
);

V2SearchData _resultsData() => const V2SearchData(
  initialQuery: 'landing',
  chats: <V2SearchChat>[_chat],
  projects: <V2SearchProject>[_project, _brandProject],
  artifacts: <V2SearchArtifact>[_artifact],
);

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: child);

/// Phone-width surface at 200 % text, the accessibility stress case.
Widget _narrow(Widget child, {ThemeData? theme, double textScale = 2}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child,
      ),
    ),
  );
}

void _useNarrowScreen(WidgetTester tester, {double height = 640}) {
  tester.view.physicalSize = Size(320, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('search page renders grouped highlighted results in light', (
    tester,
  ) async {
    await tester.pumpWidget(_app(SearchPage(data: _resultsData())));
    await tester.pumpAndSettle();

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('CHATS (1)'), findsOneWidget);
    expect(find.text('PROJECTS (1)'), findsOneWidget);
    expect(find.text('ARTIFACTS (1)'), findsOneWidget);
    expect(find.text('Landing page redesign'), findsOneWidget);
    expect(find.text('Mobile App Redesign'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('search page renders in dark', (tester) async {
    await tester.pumpWidget(
      _app(SearchPage(data: _resultsData()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('CHATS (1)'), findsOneWidget);
    expect(find.text('Landing page redesign'), findsOneWidget);
  });

  testWidgets('empty search offers a suggestion that runs a search', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SearchPage(
          data: V2SearchData(
            chats: <V2SearchChat>[
              V2SearchChat(
                id: 'c2',
                title: 'Portfolio site',
                modelLabel: 'Auto',
                timeLabel: 'Today',
              ),
            ],
            suggestions: <String>['portfolio'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search Ovid Si'), findsOneWidget);
    await tester.tap(find.text('portfolio'));
    await tester.pumpAndSettle();

    expect(find.text('Portfolio site'), findsOneWidget);
  });

  testWidgets('tapping a chat result reports it to the caller', (tester) async {
    V2SearchChat? tapped;
    await tester.pumpWidget(
      _app(
        SearchPage(data: _resultsData(), onChatTap: (chat) => tapped = chat),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Landing page redesign'));
    expect(tapped?.id, 'c1');
  });

  testWidgets('artifact preview reports the artifact to the caller', (
    tester,
  ) async {
    V2SearchArtifact? tapped;
    await tester.pumpWidget(
      _app(
        SearchPage(
          data: _resultsData(),
          onArtifactTap: (artifact) => tapped = artifact,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    expect(tapped?.id, 'a1');
  });

  testWidgets('long model and time labels wrap at 200 % text', (tester) async {
    _useNarrowScreen(tester, height: 1200);
    await tester.pumpWidget(
      _narrow(
        const SearchPage(
          data: V2SearchData(
            initialQuery: 'landing',
            chats: <V2SearchChat>[
              V2SearchChat(
                id: 'c4',
                title: 'Landing page redesign',
                modelLabel: 'Claude Sonnet 4.5 thinking',
                timeLabel: 'Yesterday at 11:45 PM',
                snippet: 'Build me a clean dark mode landing page',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Landing page redesign'), findsOneWidget);
  });

  testWidgets('typing filters the grouped results', (tester) async {
    await tester.pumpWidget(_app(SearchPage(data: _resultsData())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'brand');
    await tester.pumpAndSettle();

    expect(find.text('Brand Voice Guidelines'), findsOneWidget);
    expect(find.text('Landing page redesign'), findsNothing);
    expect(find.text('PROJECTS (1)'), findsOneWidget);
  });

  testWidgets('results fit a 320 dp screen at 200 % text', (tester) async {
    // Tall enough that all three result groups build, not just the first.
    _useNarrowScreen(tester, height: 1400);
    await tester.pumpWidget(_narrow(SearchPage(data: _resultsData())));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('CHATS (1)'), findsOneWidget);
    expect(find.text('PROJECTS (1)'), findsOneWidget);
    expect(find.text('ARTIFACTS (1)'), findsOneWidget);
  });

  testWidgets('browse with recents fits a 320 dp screen at 200 % text', (
    tester,
  ) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(
      _narrow(
        const SearchPage(
          data: V2SearchData(
            recentSearches: <String>[
              'landing page redesign for the portfolio site',
              'scripts',
            ],
            suggestions: <String>['portfolio', 'landing page'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('RECENT SEARCHES'), findsOneWidget);
  });

  testWidgets('empty browse state fits a 320 dp screen at 200 % text', (
    tester,
  ) async {
    _useNarrowScreen(tester);
    await tester.pumpWidget(
      _narrow(
        const SearchPage(
          data: V2SearchData(
            suggestions: <String>['portfolio', 'landing page', 'scripts'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Search Ovid Si'), findsOneWidget);
  });

  testWidgets('loading state shows a skeleton list', (tester) async {
    await tester.pumpWidget(
      _app(
        const SearchPage(data: V2SearchData(status: V2SearchStatus.loading)),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('error state retries through the caller', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      _app(
        SearchPage(
          data: const V2SearchData(
            status: V2SearchStatus.error,
            errorMessage: 'Offline.',
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search did not load'), findsOneWidget);
    expect(find.text('Offline.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('recent search can be removed and cleared', (tester) async {
    final semantics = tester.ensureSemantics();
    final removed = <String>[];
    var cleared = 0;
    await tester.pumpWidget(
      _app(
        SearchPage(
          data: const V2SearchData(
            recentSearches: <String>['landing', 'scripts'],
            suggestions: <String>['portfolio'],
          ),
          onRemoveRecent: removed.add,
          onClearRecents: () => cleared++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Remove landing from recent searches'));
    await tester.pumpAndSettle();
    expect(removed, <String>['landing']);
    expect(find.text('landing'), findsNothing);

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(cleared, 1);
    expect(find.text('RECENT SEARCHES'), findsNothing);

    semantics.dispose();
  });

  testWidgets('suggestion chips come from injected content, not demo copy', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const SearchPage(
          data: V2SearchData(
            chats: <V2SearchChat>[
              V2SearchChat(
                id: 'c3',
                title: 'Portfolio site',
                modelLabel: 'Auto',
                timeLabel: 'Today',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(RegExp('Search for Portfolio site')),
      findsOneWidget,
    );
    final chip = find
        .ancestor(
          of: find.text('Portfolio site'),
          matching: find.byType(OPressable),
        )
        .first;
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    expect(find.text('landing page'), findsNothing);
    expect(find.text('scripts'), findsNothing);

    semantics.dispose();
  });

  testWidgets('an empty index explains there is nothing to search yet', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const SearchPage(data: V2SearchData())));
    await tester.pumpAndSettle();

    expect(find.text('Nothing to search yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion leaves no content hidden', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: true),
            child: SearchPage(data: _resultsData()),
          ),
        ),
      ),
    );
    await tester.pump();

    // The page body still fades in, but no list row is left transparent.
    expect(find.byType(OFadeSlide), findsOneWidget);
    final hidden = tester
        .widgetList<AnimatedOpacity>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .where((widget) => widget.opacity == 0);
    expect(hidden, isEmpty);
    expect(find.text('Landing page redesign'), findsOneWidget);
  });
}
