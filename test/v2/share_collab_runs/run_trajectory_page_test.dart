import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/timeline.dart';

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

final _launches = <V2SubagentLaunch>[
  V2SubagentLaunch(
    id: 'sub-a',
    agentName: 'Frontend builder',
    taskSummary: 'Built the responsive navbar and hero section.',
    timeLabel: '10:41',
    durationLabel: '4m 12s',
    startedAt: DateTime(2026, 10, 21, 10, 41),
    status: V2SubagentLaunchStatus.completed,
  ),
  V2SubagentLaunch(
    id: 'sub-b',
    agentName: 'Research scout',
    taskSummary: 'Compared three component libraries for the hero.',
    timeLabel: '10:43',
    durationLabel: '2m 05s',
    startedAt: DateTime(2026, 10, 21, 10, 43),
    status: V2SubagentLaunchStatus.running,
  ),
  V2SubagentLaunch(
    id: 'sub-c',
    agentName: 'QA runner',
    taskSummary: 'Checked the page at 320 dp and 200 % text.',
    timeLabel: '10:45',
    durationLabel: '1m 30s',
    startedAt: DateTime(2026, 10, 21, 10, 45),
    status: V2SubagentLaunchStatus.failed,
  ),
];

V2RunTrajectoryPageData _data({
  V2RunTrajectoryStatus status = V2RunTrajectoryStatus.ready,
  List<V2RunStep> steps = _steps,
  List<V2SubagentLaunch>? subagents,
}) {
  return V2RunTrajectoryPageData(
    title: 'Landing page redesign & build',
    runLabel: 'Run #4092 · Finished in 2m 14s',
    prompt: '"Build me a clean dark mode portfolio landing page"',
    model: 'Flash 2.5',
    tokensLabel: '18.4k tokens',
    durationLabel: '2m 14s',
    steps: steps,
    subagents: subagents ?? _launches,
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
      await _pump(
        tester,
        RunTrajectoryPage(data: _data(), onShareRun: () {}),
        theme,
      );

      expect(find.text('Run trajectory'), findsOneWidget);
      expect(find.text('Landing page redesign & build'), findsOneWidget);
      expect(find.text('Read your message'), findsOneWidget);
      expect(find.text('Searched the web'), findsOneWidget);
      expect(find.text('tailwindcss.com'), findsOneWidget);
      expect(find.text('portfolio-index.html'), findsOneWidget);
      expect(find.text('Flash 2.5'), findsOneWidget);
      expect(find.text('18.4k tokens'), findsOneWidget);
      expect(find.text('Share run'), findsOneWidget);
      expect(find.text('3 subagents'), findsOneWidget);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('4m 12s'), findsOneWidget);
      // Without an onOpenSubagent callback the rows are not tappable, so the
      // "View details" hint is absent.
      expect(find.text('View details'), findsNothing);
    }
  });

  test('orderedSubagents sorts dated launches and keeps undated order', () {
    final data = V2RunTrajectoryPageData(
      title: 'Run',
      runLabel: '',
      prompt: '',
      model: 'Auto',
      tokensLabel: '',
      durationLabel: '',
      subagents: [
        V2SubagentLaunch(
          id: 'late',
          agentName: 'Late',
          taskSummary: '',
          timeLabel: '10:50',
          durationLabel: '1m',
          startedAt: DateTime(2026, 10, 21, 10, 50),
        ),
        V2SubagentLaunch(
          id: 'undated-1',
          agentName: 'Undated one',
          taskSummary: '',
          timeLabel: '10:40',
          durationLabel: '1m',
        ),
        V2SubagentLaunch(
          id: 'early',
          agentName: 'Early',
          taskSummary: '',
          timeLabel: '10:30',
          durationLabel: '1m',
          startedAt: DateTime(2026, 10, 21, 10, 30),
        ),
        V2SubagentLaunch(
          id: 'undated-2',
          agentName: 'Undated two',
          taskSummary: '',
          timeLabel: '10:35',
          durationLabel: '1m',
        ),
      ],
    );

    expect(
      [for (final launch in data.orderedSubagents) launch.id],
      ['early', 'late', 'undated-1', 'undated-2'],
    );
  });

  testWidgets('subagent launches render oldest first on the timeline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(
      tester,
      RunTrajectoryPage(
        data: _data(
          subagents: [
            V2SubagentLaunch(
              id: 'later',
              agentName: 'Research scout',
              taskSummary: 'Compared component libraries.',
              timeLabel: '10:44',
              durationLabel: '2m 05s',
              startedAt: DateTime(2026, 10, 21, 10, 44),
            ),
            V2SubagentLaunch(
              id: 'earlier',
              agentName: 'Frontend builder',
              taskSummary: 'Built the navbar.',
              timeLabel: '10:41',
              durationLabel: '4m 12s',
              startedAt: DateTime(2026, 10, 21, 10, 41),
            ),
          ],
        ),
      ),
      OTheme.light(),
    );

    final first = tester.getTopLeft(find.text('Frontend builder')).dy;
    final second = tester.getTopLeft(find.text('Research scout')).dy;
    expect(first, lessThan(second));
    expect(find.text('10:41'), findsOneWidget);
    expect(find.text('10:44'), findsOneWidget);
  });

  testWidgets('a subagent row opens the subagent detail', (tester) async {
    String? opened;
    await _pump(
      tester,
      RunTrajectoryPage(data: _data(), onOpenSubagent: (id) => opened = id),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Frontend builder'));
    await tester.pump();
    await tester.tap(find.text('Frontend builder'));
    await tester.pump();
    expect(opened, 'sub-a');
  });

  testWidgets('a run without subagents shows a zero count and no section', (
    tester,
  ) async {
    await _pump(
      tester,
      RunTrajectoryPage(data: _data(subagents: const [])),
      OTheme.light(),
    );

    expect(find.text('0 subagents'), findsOneWidget);
    expect(find.textContaining('SUBAGENTS'), findsNothing);
  });

  testWidgets('lays out at 320 dp with 200 % text without clipping', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      RunTrajectoryPage(
        data: _data(),
        onShareRun: () {},
        onOpenPreview: () {},
      ),
    );

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

    await tester.ensureVisible(find.text('Searched the web'));
    await tester.pump();
    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(detail), findsOneWidget);

    await tester.ensureVisible(find.text('Searched the web'));
    await tester.pump();
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

    await _pump(
      tester,
      RunTrajectoryPage(data: _data(), onShareRun: () {}),
      OTheme.light(),
    );

    expect(find.text('Read your message'), findsOneWidget);
    expect(find.text('Share run'), findsOneWidget);
  });

  testWidgets('the subagent launch list is the shared V2Timeline', (
    tester,
  ) async {
    await _pump(
      tester,
      RunTrajectoryPage(data: _data(), onOpenSubagent: (_) {}),
      OTheme.light(),
    );

    final timeline = tester.widget<V2Timeline>(find.byType(V2Timeline));
    expect(
      [for (final item in timeline.items) item.id],
      ['sub-a', 'sub-b', 'sub-c'],
    );
    expect(timeline.items.first.title, 'Frontend builder');
    expect(
      timeline.items.first.description,
      'Built the responsive navbar and hero section.',
    );
    expect(timeline.items.first.timeLabel, '10:41');
    expect(timeline.items.first.durationLabel, '4m 12s');
    expect(
      [for (final item in timeline.items) item.status],
      [
        V2TimelineStatus.success,
        V2TimelineStatus.running,
        V2TimelineStatus.danger,
      ],
    );
    expect(
      [for (final item in timeline.items) item.statusLabel],
      ['Completed', 'Running', 'Failed'],
    );
    // Tapping a launch still reports the subagent id.
    expect(timeline.onItemTap, isNotNull);
    expect(find.text('View details'), findsNWidgets(3));
  });
}
