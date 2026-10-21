import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';

const _steps = [
  V2RunStep(
    id: 's1',
    title: 'Read your message',
    detail: 'Parsed user requirements and design constraints',
    durationLabel: '0.2s',
    kind: V2RunStepKind.message,
    expandedDetail:
        'Read the prompt and picked out the layout and colour goals.',
  ),
  V2RunStep(
    id: 's2',
    title: 'Searched the web',
    detail: 'Retrieved modern layout conventions & components',
    durationLabel: '4.8s',
    kind: V2RunStepKind.search,
    sources: [
      V2RunSource(label: 'tailwindcss.com'),
      V2RunSource(label: 'lucide.dev', icon: Icons.category_rounded),
    ],
    expandedDetail: 'Opened 4 pages about responsive layout systems.',
  ),
  V2RunStep(
    id: 's3',
    title: 'Wrote portfolio-index.html',
    detail: 'Generated the semantic responsive layout',
    durationLabel: '54.2s',
    kind: V2RunStepKind.write,
    fileName: 'portfolio-index.html',
    fileMeta: '486 lines · 14.2 KB',
  ),
  V2RunStep(
    id: 's4',
    title: 'Ran live sandbox preview',
    detail: 'Deployed to a sandboxed web view',
    durationLabel: '12.0s',
    kind: V2RunStepKind.preview,
    previewLabel: 'localhost:3000',
    previewStatus: 'HTTP 200 OK',
  ),
  V2RunStep(
    id: 's5',
    title: 'Finished run',
    detail: 'All assets bundled and tested',
    durationLabel: '2m 14s total',
    kind: V2RunStepKind.finish,
  ),
];

V2RunTrajectoryPageData _data({
  V2RunTrajectoryStatus status = V2RunTrajectoryStatus.ready,
  List<V2RunStep> steps = _steps,
}) {
  return V2RunTrajectoryPageData(
    title: 'Landing page redesign & build',
    runLabel: 'Run #4092 · Finished in 2m 14s',
    prompt: '"Build me a clean dark mode portfolio landing page"',
    model: 'Flash 2.5',
    tokensLabel: '18.4k tokens',
    durationLabel: '2m 14s',
    steps: steps,
    status: status,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(MaterialApp(theme: theme, home: child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

/// Pumps at 320 dp wide with 200 % text, the smallest supported combination.
Future<void> _pumpNarrow(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(320, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

/// Text that paints past the left or right edge of the screen.
List<String> _offScreenText(WidgetTester tester) {
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final off = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (rect.left < -0.5 || rect.right > width + 0.5) {
      off.add('"${(element.widget as Text).data}" $rect');
    }
  }
  return off;
}

void main() {
  testWidgets('renders the timeline and footer in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, RunTrajectoryPage(data: _data()), theme);

      expect(find.text('Run trajectory'), findsOneWidget);
      expect(find.text('Landing page redesign & build'), findsOneWidget);
      expect(find.text('Read your message'), findsOneWidget);
      expect(find.text('Searched the web'), findsOneWidget);
      expect(find.text('tailwindcss.com'), findsOneWidget);
      expect(find.text('portfolio-index.html'), findsOneWidget);
      expect(find.text('Flash 2.5'), findsOneWidget);
      expect(find.text('18.4k tokens'), findsOneWidget);
      expect(find.text('Share run'), findsOneWidget);
    }
  });

  testWidgets('lays out at 320 dp with 200 % text without clipping', (
    tester,
  ) async {
    await _pumpNarrow(tester, RunTrajectoryPage(data: _data()));

    final ctx = tester.element(find.text('Landing page redesign & build'));
    expect(MediaQuery.textScalerOf(ctx).scale(12), 24);

    // Walk the whole page so every step, chip and card is laid out narrow.
    final scrollable = find.byType(Scrollable).first;
    for (var i = 0; i < 24; i++) {
      await tester.drag(scrollable, const Offset(0, -240));
      await tester.pump();
    }

    expect(find.text('Share run'), findsOneWidget);
    expect(find.text('Open preview'), findsOneWidget);
    expect(
      find.text('Shared runs never include your files or connectors.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    expect(_offScreenText(tester), isEmpty);

    // The empty and error paths have to fit the same narrow width.
    await _pumpNarrow(
      tester,
      RunTrajectoryPage(
        data: _data(status: V2RunTrajectoryStatus.empty, steps: const []),
        onRetry: () {},
      ),
    );
    expect(find.text('No steps to show'), findsOneWidget);
    expect(_offScreenText(tester), isEmpty);

    await _pumpNarrow(
      tester,
      RunTrajectoryPage(
        data: _data(status: V2RunTrajectoryStatus.error),
        onRetry: () {},
      ),
    );
    expect(find.text('We could not load this run.'), findsOneWidget);
    expect(_offScreenText(tester), isEmpty);
  });

  testWidgets('empty state reloads the run', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      RunTrajectoryPage(
        data: _data(status: V2RunTrajectoryStatus.empty, steps: const []),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('No steps to show'), findsOneWidget);
    await tester.tap(find.text('Reload run'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      RunTrajectoryPage(
        data: _data(status: V2RunTrajectoryStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load this run.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('share run callback fires', (tester) async {
    var shares = 0;
    await _pump(
      tester,
      RunTrajectoryPage(data: _data(), onShareRun: () => shares++),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Share run'));
    await tester.pump();
    await tester.tap(find.text('Share run'));
    await tester.pump();
    expect(shares, 1);
  });

  testWidgets('a step expands and collapses its plain-English detail', (
    tester,
  ) async {
    await _pump(tester, RunTrajectoryPage(data: _data()), OTheme.light());

    const detail = 'Opened 4 pages about responsive layout systems.';
    expect(find.text(detail), findsNothing);

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(detail), findsOneWidget);

    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(detail), findsNothing);
  });

  testWidgets('source and file rows call out with their label', (tester) async {
    String? openedSource;
    String? openedFile;
    await _pump(
      tester,
      RunTrajectoryPage(
        data: _data(),
        onOpenSource: (label) => openedSource = label,
        onOpenFile: (name) => openedFile = name,
      ),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('tailwindcss.com'));
    await tester.pump();
    await tester.tap(find.text('tailwindcss.com'));
    await tester.pump();
    expect(openedSource, 'tailwindcss.com');

    await tester.ensureVisible(find.text('portfolio-index.html'));
    await tester.pump();
    await tester.tap(find.text('portfolio-index.html'));
    await tester.pump();
    expect(openedFile, 'portfolio-index.html');
  });

  testWidgets('reduced motion keeps every step visible', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);

    await _pump(tester, RunTrajectoryPage(data: _data()), OTheme.light());

    expect(find.text('Read your message'), findsOneWidget);
    expect(find.text('Share run'), findsOneWidget);
  });
}
