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

void _screen(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.search_rounded),
    ),
  );
  await tester.pumpAndSettle();
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

void main() {
  testWidgets('renders one calm header and the artifact cards', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsWidgets);

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('Code · HTML'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Document · PDF'), findsOneWidget);

    // Removed copy: no library summary, no "what Ovid can make" callout.
    expect(find.text('Your lifetime library'), findsNothing);
    expect(find.text('See what Ovid can make'), findsNothing);
    expect(find.text('New artifact'), findsNothing);
  });

  testWidgets('renders the library in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data()), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Artifacts'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty library is one line with no dead action', (tester) async {
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
    expect(
      find.text('Files you make and upload appear here.'),
      findsOneWidget,
    );
    expect(find.text('See what Ovid can make'), findsNothing);
    expect(find.byType(OButton), findsNothing);
  });

  testWidgets('search icon focuses the field and narrows by file name', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'portfolio');
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsOneWidget);
    expect(find.text('market-analysis-q2.pdf'), findsNothing);
    expect(find.text('1 of 4 files · 2.4 MB'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
  });

  testWidgets('search matches the session name', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'q2 market');
    await tester.pumpAndSettle();

    expect(find.text('market-analysis-q2.pdf'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);
  });

  testWidgets('filters still narrow the grid and clear together', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_typeKey('image')));
    await tester.pumpAndSettle();
    expect(find.text('token-usage-breakdown.png'), findsOneWidget);
    expect(find.text('portfolio-index.html'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey<String>('artifact-filter-clear')),
    );
    await tester.pumpAndSettle();
    expect(find.text('portfolio-index.html'), findsOneWidget);
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

    await _pickSource(tester, 'Any source');
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('uses the shared filter bar', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    expect(find.byType(ArtifactFilterBar), findsOneWidget);
    expect(find.text('4 files · 2.4 MB'), findsOneWidget);
  });

  testWidgets('grid is one column under 600, two at 600, three at 1000', (
    tester,
  ) async {
    Future<void> pumpAt(double width) async {
      _screen(tester, width);
      await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
      await tester.pumpAndSettle();
    }

    await pumpAt(599);
    final one = tester.getTopLeft(find.text('portfolio-index.html'));
    final oneNext = tester.getTopLeft(find.text('market-analysis-q2.pdf'));
    expect(oneNext.dx, closeTo(one.dx, 1));

    await pumpAt(600);
    final two = tester.getTopLeft(find.text('portfolio-index.html'));
    final twoNext = tester.getTopLeft(find.text('market-analysis-q2.pdf'));
    expect(twoNext.dy, closeTo(two.dy, 1));
    expect(twoNext.dx, greaterThan(two.dx));

    await pumpAt(1000);
    final three = tester.getTopLeft(find.text('portfolio-index.html'));
    final third = tester.getTopLeft(find.text('token-usage-breakdown.png'));
    expect(third.dy, closeTo(three.dy, 1));
    expect(third.dx, greaterThan(three.dx));
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

  testWidgets('tapping a card opens the detail route without a host', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await tester.tap(find.text('portfolio-index.html'));
    await tester.pumpAndSettle();

    expect(find.text('portfolio-index.html'), findsWidgets);
    expect(find.text('Artifact detail'), findsNothing);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Code'), findsWidgets);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ArtifactsPage(data: _data(status: V2ArtifactsStatus.loading))),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('No artifacts yet'), findsNothing);
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
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('fits a 320 dp screen at 200 % text in light and dark', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      _smallPhone(tester);
      await tester.pumpWidget(
        _app(ArtifactsPage(data: _data()), dark: dark, textScale: 2),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Artifacts'), findsOneWidget);

      await _scrollTo(tester, find.text('portfolio-index.html'));
      expect(find.text('portfolio-index.html'), findsOneWidget);
      expect(find.text('Code · HTML'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
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
    await tester.pumpWidget(_app(ArtifactsPage(data: _data())));
    await tester.pumpAndSettle();

    await _openSearch(tester);
    await tester.enterText(find.byType(TextField), 'nothing matches this');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
    expect(
      find.text('Try another search or clear the filters.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('portfolio-index.html'), findsOneWidget);
  });

  testWidgets('card menu copies the file name without opening the card', (
    tester,
  ) async {
    _phone(tester);
    String? copied;
    V2ArtifactItem? opened;
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
      _app(
        ArtifactsPage(
          data: _data(artifacts: [_artifacts.first]),
          onArtifactTap: (item) => opened = item,
        ),
      ),
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
    expect(opened, isNull);
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
                  sessionTitle:
                      'A very long session title that also has to fit',
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
}
