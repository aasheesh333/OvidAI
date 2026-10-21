import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/library/artifact_filters.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';

final _now = DateTime(2026, 5, 18, 12);

final _artifacts = <V2ArtifactItem>[
  V2ArtifactItem(
    id: 'a1',
    name: 'portfolio-index.html',
    kind: V2ArtifactKind.code,
    createdAt: DateTime(2026, 5, 18, 10, 24),
    sizeLabel: '14.2 KB',
    sizeBytes: 14540,
    sessionTitle: 'Landing page redesign',
    live: true,
  ),
  V2ArtifactItem(
    id: 'a2',
    name: 'market-analysis-q2.pdf',
    kind: V2ArtifactKind.document,
    createdAt: DateTime(2026, 5, 17),
    sizeLabel: '1.8 MB',
    sizeBytes: 1887437,
    sessionTitle: 'Q2 market review',
    badge: 'PDF',
  ),
  V2ArtifactItem(
    id: 'a3',
    name: 'token-usage-breakdown.png',
    kind: V2ArtifactKind.image,
    createdAt: DateTime(2026, 5, 15),
    sizeLabel: '480 KB',
    sizeBytes: 491520,
    source: V2ArtifactSource.uploaded,
  ),
  V2ArtifactItem(
    id: 'a4',
    name: 'launch-metrics.csv',
    kind: V2ArtifactKind.data,
    createdAt: DateTime(2026, 5, 12),
    sizeLabel: '86 KB',
    sizeBytes: 88064,
    sessionTitle: 'Launch metrics',
  ),
];

V2ArtifactsData _data({
  V2ArtifactsStatus status = V2ArtifactsStatus.content,
  List<V2ArtifactItem>? artifacts,
  String? totalSizeLabel,
}) => V2ArtifactsData(
  status: status,
  artifacts: artifacts ?? _artifacts,
  totalSizeLabel: totalSizeLabel,
  now: _now,
);

Widget _app(Widget home, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

ValueKey<String> _typeKey(String name) =>
    ValueKey<String>('artifact-type-$name');

Future<void> _pickSource(WidgetTester tester, String label) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('artifact-filter-source')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _tapChip(WidgetTester tester, String name) async {
  final chip = find.byKey(_typeKey(name));
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the lifetime library in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data(), onNewArtifact: () {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('Your lifetime library'), findsOneWidget);
    expect(find.text('4 files · 2.4 MB stored'), findsOneWidget);
    expect(find.text('RECENT ARTIFACTS'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('From Landing page redesign'), findsOneWidget);
    expect(find.text('New artifact'), findsOneWidget);
  });

  testWidgets('renders the lifetime library in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactsPage(data: _data(), onNewArtifact: () {}),
        dark: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('Your lifetime library'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('New artifact'), findsOneWidget);
  });

  testWidgets('total size can come pre-formatted from the wiring layer', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data(totalSizeLabel: '3.1 GB'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('4 files · 3.1 GB stored'), findsOneWidget);
  });

  testWidgets('empty state says deleting frees storage', (tester) async {
    _phone(tester);
    var seeIdeas = 0;
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(
            status: V2ArtifactsStatus.empty,
            artifacts: const <V2ArtifactItem>[],
          ),
          onSeeIdeas: () => seeIdeas++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No artifacts yet'), findsOneWidget);
    expect(find.textContaining('Deleting an artifact frees'), findsOneWidget);
    expect(find.textContaining('Studio drafts stay in Studio'), findsOneWidget);
    await tester.tap(find.text('See what Ovid can make'));
    expect(seeIdeas, 1);
  });

  testWidgets('the empty library offers no dead action without a host', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(
            status: V2ArtifactsStatus.empty,
            artifacts: const <V2ArtifactItem>[],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No artifacts yet'), findsOneWidget);
    // No "See what Ovid can make" button, no FAB: nothing the page cannot do.
    expect(find.text('See what Ovid can make'), findsNothing);
    expect(find.text('New artifact'), findsNothing);
  });

  testWidgets('New artifact fires the primary callback', (tester) async {
    _phone(tester);
    var created = 0;
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data(), onNewArtifact: () => created++)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New artifact'));
    expect(created, 1);
  });

  testWidgets('search narrows by file name', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'portfolio');
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('market-analysis-q2.pdf'), findsNothing);
    expect(find.text('MATCHING ARTIFACTS'), findsOneWidget);
    expect(find.text('1 item'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('RECENT ARTIFACTS'), findsOneWidget);
  });

  testWidgets('search matches the session name, not just the file name', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'q2 market');
    await tester.pumpAndSettle();

    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);
    expect(find.text('From Q2 market review'), findsOneWidget);
  });

  testWidgets('source filter shows generated and uploaded files', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await _pickSource(tester, 'Uploaded');
    expect(find.text('token-usage-breakdown.png'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);
    expect(find.text('1 item'), findsOneWidget);

    await _pickSource(tester, 'Generated');
    expect(find.text('token-usage-breakdown.png'), findsNothing);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('3 items'), findsOneWidget);

    await _pickSource(tester, 'Any source');
    expect(find.text('4 items'), findsOneWidget);
  });

  testWidgets('kind chips narrow the grid', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_typeKey('image')));
    await tester.pumpAndSettle();

    expect(find.text('token-usage-breakdown.png'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);
    expect(find.text('1 item'), findsOneWidget);

    // "All" clears the family filter.
    await tester.tap(find.byKey(_typeKey('all')));
    await tester.pumpAndSettle();
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('uses the shared filter bar with a size summary', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    expect(find.byType(ArtifactFilterBar), findsOneWidget);
    expect(find.text('4 files · 2.4 MB'), findsOneWidget);
    expect(find.byKey(_typeKey('image')), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('artifact-filter-source')),
      findsOneWidget,
    );
  });

  testWidgets('session filter narrows to one chat', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('artifact-filter-session')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Landing page redesign').last);
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('market-analysis-q2.pdf'), findsNothing);
    expect(find.text('1 of 4 files · 2.4 MB'), findsOneWidget);
  });

  testWidgets('sort options reorder the grid', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('artifact-filter-sort')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name A–Z'));
    await tester.pumpAndSettle();

    // Alphabetically the first row is launch-metrics.csv, market-analysis-q2.pdf.
    final launch = tester.getTopLeft(find.text('launch-metrics.csv'));
    final market = tester.getTopLeft(find.text('market-analysis-q2.pdf'));
    expect(launch.dy, closeTo(market.dy, 1));
    expect(launch.dx, lessThan(market.dx));
  });

  testWidgets('the filter bar clear action resets every filter', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_typeKey('image')));
    await tester.pumpAndSettle();
    expect(find.text('1 item'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('artifact-filter-clear')),
    );
    await tester.pumpAndSettle();
    expect(find.text('4 items'), findsOneWidget);
    expect(find.text('4 files · 2.4 MB'), findsOneWidget);
  });

  testWidgets('tapping a card reports the artifact', (tester) async {
    _phone(tester);
    V2ArtifactItem? opened;
    await tester.pumpWidget(
      _app(
        ArtifactsPage(data: _data(), onArtifactTap: (item) => opened = item),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('portfolio-index.html'));
    expect(opened?.id, 'a1');
  });

  testWidgets('loading state shows skeletons and no action', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data(status: V2ArtifactsStatus.loading))),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('New artifact'), findsNothing);
  });

  testWidgets('error state offers retry', (tester) async {
    _phone(tester);
    var retried = 0;
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(status: V2ArtifactsStatus.error),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('New artifact'), findsNothing);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('fits a 320 dp screen at 200 % text in light', (tester) async {
    _smallPhone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data()), textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('Your lifetime library'), findsOneWidget);

    await _scrollTo(tester, find.text('portfolio-index.html'));
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('From Landing page redesign'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a 320 dp screen at 200 % text in dark', (tester) async {
    _smallPhone(tester);
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data()), dark: true, textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Artifacts Library'), findsOneWidget);

    await _scrollTo(tester, find.text('portfolio-index.html'));
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('From Landing page redesign'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    _smallPhone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(
            status: V2ArtifactsStatus.empty,
            artifacts: const <V2ArtifactItem>[],
          ),
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('No artifacts yet'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(status: V2ArtifactsStatus.error),
          onRetry: () {},
        ),
        textScale: 2,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('filtered empty state clears every filter', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(
            artifacts: <V2ArtifactItem>[
              V2ArtifactItem(
                id: 'only-image',
                name: 'hero.png',
                kind: V2ArtifactKind.image,
                createdAt: DateTime(2026, 5, 18),
                sizeLabel: '20 KB',
                sizeBytes: 20480,
                source: V2ArtifactSource.uploaded,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    expect(find.textContaining('No artifacts match these filters'), findsOneWidget);

    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('hero.png'), findsOneWidget);
    expect(find.text('RECENT ARTIFACTS'), findsOneWidget);
  });

  testWidgets('content with no artifacts offers the next action', (
    tester,
  ) async {
    _phone(tester);
    var created = 0;
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(artifacts: const <V2ArtifactItem>[]),
          onNewArtifact: () => created++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No artifacts yet'), findsOneWidget);
    await tester.tap(find.text('New artifact').last);
    expect(created, 1);
  });

  testWidgets('card menu fires without opening the card', (tester) async {
    _phone(tester);
    V2ArtifactItem? menu;
    V2ArtifactItem? opened;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        ArtifactsPage(
          data: _data(artifacts: <V2ArtifactItem>[_artifacts.first]),
          onArtifactMenu: (item) => menu = item,
          onArtifactTap: (item) => opened = item,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final menuButton = find.ancestor(
      of: find.byIcon(Icons.more_vert_rounded),
      matching: find.byType(OIconButton),
    );
    expect(menuButton, findsOneWidget);
    final size = tester.getSize(menuButton);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(
      find.bySemanticsLabel(RegExp('More options for portfolio-index.html')),
      findsWidgets,
    );

    await tester.tap(menuButton);
    await tester.pumpAndSettle();
    expect(menu?.id, 'a1');
    expect(opened, isNull);
    handle.dispose();
  });

  testWidgets('reduced motion still shows every card', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: ArtifactsPage(data: _data()),
      ),
    );
    await tester.pump();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('launch-metrics.csv'), findsOneWidget);
  });

  group('wiring', () {
    testWidgets('Page matches HTML artifacts and Doc excludes them', (
      tester,
    ) async {
      _phone(tester);
      final artifacts = <V2ArtifactItem>[
        V2ArtifactItem(
          id: 'html',
          name: 'portfolio-index.html',
          kind: V2ArtifactKind.document,
          createdAt: DateTime(2026, 5, 18),
          sizeLabel: '14 KB',
        ),
        V2ArtifactItem(
          id: 'pdf',
          name: 'market-analysis-q2.pdf',
          kind: V2ArtifactKind.document,
          createdAt: DateTime(2026, 5, 18),
          sizeLabel: '1.8 MB',
        ),
      ];
      await tester.pumpWidget(
        _app(ArtifactsPage(data: _data(artifacts: artifacts))),
      );
      await tester.pumpAndSettle();

      await _tapChip(tester, 'page');
      expect(find.text('portfolio-index.html'), findsOneWidget);
      expect(find.text('market-analysis-q2.pdf'), findsNothing);
      expect(find.text('1 item'), findsOneWidget);

      await _tapChip(tester, 'doc');
      expect(find.text('portfolio-index.html'), findsNothing);
      expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    });

    testWidgets('the date filter really narrows by added date', (tester) async {
      _phone(tester);
      final dated = <V2ArtifactItem>[
        for (final (id, name, days) in <(String, String, int)>[
          ('d0', 'today.html', 0),
          ('d1', 'yesterday.pdf', 1),
          ('d3', 'three-days.png', 3),
          ('d20', 'twenty-days.csv', 20),
        ])
          V2ArtifactItem(
            id: id,
            name: name,
            kind: V2ArtifactKind.data,
            createdAt: _now.subtract(Duration(days: days)),
            sizeLabel: '1 KB',
            sizeBytes: 1024,
          ),
      ];
      await tester.pumpWidget(
        _app(ArtifactsPage(data: _data(artifacts: dated))),
      );
      await tester.pumpAndSettle();

      Future<void> pickDate(String label) async {
        await tester.tap(
          find.byKey(const ValueKey<String>('artifact-filter-date')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await pickDate('Today');
      expect(find.text('1 item'), findsOneWidget);
      expect(find.text('today.html'), findsOneWidget);
      expect(find.text('yesterday.pdf'), findsNothing);

      await pickDate('Last 7 days');
      expect(find.text('3 items'), findsOneWidget);
      expect(find.text('today.html'), findsOneWidget);
      expect(find.text('yesterday.pdf'), findsOneWidget);

      await pickDate('Last 30 days');
      expect(find.text('4 items'), findsOneWidget);

      await pickDate('Any time');
      expect(find.text('4 items'), findsOneWidget);
    });

    testWidgets('an unknown session id matches nothing instead of everything', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('artifact-filter-session')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Landing page redesign').last);
      await tester.pumpAndSettle();
      expect(find.text('1 of 4 files · 2.4 MB'), findsOneWidget);

      // The host replaces the list; the filter id no longer exists.
      await tester.pumpWidget(
        _app(
          ArtifactsPage(
            data: _data(
              artifacts: <V2ArtifactItem>[
                V2ArtifactItem(
                  id: 'other',
                  name: 'hero.png',
                  kind: V2ArtifactKind.image,
                  createdAt: DateTime(2026, 5, 18),
                  sizeLabel: '20 KB',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('hero.png'), findsNothing);
      expect(find.text('No matches'), findsOneWidget);
    });

    testWidgets('an empty library and a filtered miss read differently', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          ArtifactsPage(
            data: _data(artifacts: const <V2ArtifactItem>[]),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No artifacts yet'), findsOneWidget);
      expect(find.text('No matches'), findsNothing);

      await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'no such file');
      await tester.pumpAndSettle();
      expect(find.text('No matches'), findsOneWidget);
      expect(find.text('No artifacts yet'), findsNothing);
    });

    testWidgets('app bar chrome is only drawn when the host handles it', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.menu_rounded), findsNothing);
      expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
      expect(find.bySemanticsLabel('Search artifacts'), findsNothing);
      expect(find.text('New artifact'), findsNothing);
    });

    testWidgets('tapping a card opens the detail route without a host', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
      await tester.pumpAndSettle();

      await tester.tap(find.text('portfolio-index.html'));
      await tester.pumpAndSettle();

      expect(find.text('Artifact detail'), findsOneWidget);
      expect(find.text('portfolio-index.html'), findsWidgets);
      // HTML pages preview as real code, not as an image placeholder.
      expect(find.text('Image preview unavailable'), findsNothing);
    });

    testWidgets('the card menu copies the file name without a host', (
      tester,
    ) async {
      _phone(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(
        _app(ArtifactsPage(data: _data(artifacts: [_artifacts.first]))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Copy file name'), findsOneWidget);
      expect(find.text('Download'), findsNothing);

      await tester.tap(find.text('Copy file name'));
      await tester.pumpAndSettle();
      expect(copied, 'portfolio-index.html');
      expect(find.text('File name copied'), findsOneWidget);
    });

    testWidgets('long file names ellipsize at 320 dp and 200 % text', (
      tester,
    ) async {
      const longName =
          'quarterly-revenue-and-retention-breakdown-for-every-region-'
          'final-final-v12-approved.xlsx';
      for (final dark in <bool>[false, true]) {
        _smallPhone(tester);
        await tester.pumpWidget(
          _app(
            ArtifactsPage(
              data: _data(
                artifacts: <V2ArtifactItem>[
                  V2ArtifactItem(
                    id: 'long',
                    name: longName,
                    kind: V2ArtifactKind.data,
                    createdAt: DateTime(2026, 5, 18),
                    sizeLabel: '2.1 MB',
                    sessionTitle: 'A very long session title that also has to fit',
                  ),
                ],
              ),
            ),
            dark: dark,
            textScale: 2,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        await _scrollTo(tester, find.text(longName));
        final name = tester.widget<Text>(find.text(longName));
        expect(name.maxLines, 1);
        expect(name.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      }
    });
  });
}
