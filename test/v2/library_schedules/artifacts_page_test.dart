import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';

final _now = DateTime(2026, 5, 18, 12);

final _artifacts = <V2ArtifactItem>[
  V2ArtifactItem(
    id: 'a1',
    name: 'portfolio-index.html',
    kind: V2ArtifactKind.code,
    createdAt: DateTime(2026, 5, 18, 10, 24),
    sizeLabel: '14.2 KB',
    live: true,
  ),
  V2ArtifactItem(
    id: 'a2',
    name: 'market-analysis-q2.pdf',
    kind: V2ArtifactKind.document,
    createdAt: DateTime(2026, 5, 17),
    sizeLabel: '1.8 MB',
    badge: 'PDF',
  ),
  V2ArtifactItem(
    id: 'a3',
    name: 'token-usage-breakdown.png',
    kind: V2ArtifactKind.image,
    createdAt: DateTime(2026, 5, 15),
    sizeLabel: '480 KB',
  ),
  V2ArtifactItem(
    id: 'a4',
    name: 'launch-metrics.csv',
    kind: V2ArtifactKind.data,
    createdAt: DateTime(2026, 5, 12),
    sizeLabel: '86 KB',
  ),
];

V2ArtifactsData _data({
  V2ArtifactsStatus status = V2ArtifactsStatus.content,
  List<V2ArtifactItem>? artifacts,
}) => V2ArtifactsData(
  status: status,
  artifacts: artifacts ?? _artifacts,
  now: _now,
);

Widget _app(Widget home, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
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

void main() {
  testWidgets('renders the library in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('RECENT ARTIFACTS'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('New artifact'), findsOneWidget);
  });

  testWidgets('renders the library in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data()), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('New artifact'), findsOneWidget);
  });

  testWidgets('empty state offers a way to see what Ovid can make', (
    tester,
  ) async {
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

    expect(find.text('Nothing here yet'), findsOneWidget);
    await tester.tap(find.text('See what Ovid can make'));
    expect(seeIdeas, 1);
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

  testWidgets('filter chips narrow the grid', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Images'));
    await tester.pumpAndSettle();

    expect(find.text('token-usage-breakdown.png'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);
    expect(find.text('1 item'), findsOneWidget);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text('portfolio-index.html'), findsOneWidget);
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

  testWidgets('fits a 320 dp screen at 200 % text', (tester) async {
    _smallPhone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data()), textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Artifacts Library'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
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
    expect(find.text('Nothing here yet'), findsOneWidget);

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

  testWidgets('filtered empty state clears the filter', (tester) async {
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
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Code'));
    await tester.pumpAndSettle();
    expect(find.text('No code yet'), findsOneWidget);

    await tester.tap(find.text('Show all artifacts'));
    await tester.pumpAndSettle();
    expect(find.text('hero.png'), findsOneWidget);
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

    expect(find.text('Nothing here yet'), findsOneWidget);
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
}
