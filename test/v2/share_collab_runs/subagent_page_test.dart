import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_summary.dart';

const _logLines = [
  V2SubagentLogLine(time: '10:41:02', text: 'Initializing component tree'),
  V2SubagentLogLine(
    time: '10:41:38',
    text: 'Injected responsive breakpoint hooks',
  ),
  V2SubagentLogLine(
    time: '10:42:01',
    text: 'Unit tests passed (4/4)',
    tone: V2SubagentLogTone.success,
  ),
  V2SubagentLogLine(
    time: '10:42:14',
    text: 'Preparing a snapshot for the main agent…',
    tone: V2SubagentLogTone.accent,
  ),
];

V2SubagentPageData _data({
  V2SubagentStatus status = V2SubagentStatus.ready,
  bool working = true,
  bool withSummary = true,
}) {
  return V2SubagentPageData(
    name: 'Frontend builder',
    instanceLabel: 'Instance #A-402',
    stepLabel: 'Step 3 of 5 active',
    paceLabel: 'Fast pace',
    goal: 'Assembling the responsive navbar and hero section.',
    startedLabel: '10:41 AM',
    elapsedLabel: '4m 12s',
    timeLimitLabel: '8h max',
    remainingLabel: '7h 55m left',
    totalLogLines: 42,
    progress: 0.6,
    files: const ['Hero.tsx', 'Navbar.tsx', 'globals.css'],
    logLines: _logLines,
    logPath: '/workspace/.ovid/logs/subagent_a402.log',
    summary: withSummary
        ? const V2SubagentSummaryData(
            status: 'completed',
            filesModified: ['Hero.tsx', 'Navbar.tsx', 'globals.css'],
            artifactsCreated: ['preview-screenshot.png'],
            keyFindings: ['Breakpoints hold at 320 dp and 200 % text.'],
            errorIfAny: 'One test flaked once, then passed.',
          )
        : null,
    status: status,
    working: working,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  ThemeData theme, {
  Size size = const Size(390, 844),
  double textScale = 1,
  bool reduceMotion = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: inner!,
      ),
      home: child,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void _expectNoTextPastEdge(WidgetTester tester, double width) {
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final label = (element.widget as Text).data ?? '';
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '"$label" starts left of the screen',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(width + 0.5),
      reason: '"$label" paints past the right edge (${rect.right} > $width)',
    );
  }
}

void main() {
  testWidgets('renders the subagent progress and log in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        SubagentPage(
          data: _data(),
          onStop: () {},
          onViewLog: () {},
          onReadFullLog: (_) {},
        ),
        theme,
      );

      expect(find.text('Subagent'), findsOneWidget);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Overall progress'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      // Hero.tsx shows in both the files-touched chips and the summary card.
      expect(find.text('Hero.tsx'), findsNWidgets(2));
      expect(find.text('3 files'), findsNWidgets(2));
      expect(find.text('8h max'), findsOneWidget);
      expect(find.text('View full log (42 lines)'), findsOneWidget);
      expect(find.text('Read full log'), findsOneWidget);
      expect(
        find.text('/workspace/.ovid/logs/subagent_a402.log'),
        findsOneWidget,
      );
      expect(find.text('JSON summary'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('preview-screenshot.png'), findsOneWidget);
      expect(
        find.text('Breakpoints hold at 320 dp and 200 % text.'),
        findsOneWidget,
      );
      expect(find.text('One test flaked once, then passed.'), findsOneWidget);
      expect(find.text('Stop subagent'), findsOneWidget);
      expect(
        find.text('Subagents cannot start other subagents.'),
        findsOneWidget,
      );
      _expectNoTextPastEdge(tester, 390);
    }
  });

  testWidgets('empty state returns to chat', (tester) async {
    var backs = 0;
    await _pump(
      tester,
      SubagentPage(
        data: _data(status: V2SubagentStatus.empty),
        onBackToChat: () => backs++,
      ),
      OTheme.light(),
    );

    expect(find.text('No subagent is running'), findsOneWidget);
    await tester.tap(find.text('Back to chat'));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('stop subagent callback fires', (tester) async {
    var stops = 0;
    await _pump(
      tester,
      SubagentPage(data: _data(), onStop: () => stops++),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Stop subagent'));
    await tester.pump();
    await tester.tap(find.text('Stop subagent'));
    await tester.pump();
    expect(stops, 1);
  });

  testWidgets('view full log callback fires', (tester) async {
    var views = 0;
    await _pump(
      tester,
      SubagentPage(data: _data(), onViewLog: () => views++),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('View full log (42 lines)'));
    await tester.pump();
    await tester.tap(find.text('View full log (42 lines)'));
    await tester.pump();
    expect(views, 1);
  });

  testWidgets('read full log opens the log path', (tester) async {
    String? opened;
    await _pump(
      tester,
      SubagentPage(data: _data(), onReadFullLog: (path) => opened = path),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Read full log'));
    await tester.pump();
    await tester.tap(find.text('Read full log'));
    await tester.pump();
    expect(opened, '/workspace/.ovid/logs/subagent_a402.log');
  });

  testWidgets('the strict JSON summary renders and reveals raw JSON', (
    tester,
  ) async {
    await _pump(tester, SubagentPage(data: _data()), OTheme.light());

    await tester.ensureVisible(find.text('JSON summary'));
    await tester.pump();
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('FILES MODIFIED'), findsOneWidget);
    expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
    expect(find.text('KEY FINDINGS'), findsOneWidget);
    expect(find.text('ERROR IF ANY'), findsOneWidget);
    expect(find.textContaining('"files_modified"'), findsNothing);

    await tester.ensureVisible(find.text('Show raw JSON'));
    await tester.pump();
    await tester.tap(find.text('Show raw JSON'));
    await tester.pump();

    expect(find.textContaining('"files_modified"'), findsOneWidget);
    expect(find.textContaining('"artifacts_created"'), findsOneWidget);
    expect(find.textContaining('"key_findings"'), findsOneWidget);
    expect(find.textContaining('"error_if_any"'), findsOneWidget);

    await tester.ensureVisible(find.text('Hide raw JSON'));
    await tester.pump();
    await tester.tap(find.text('Hide raw JSON'));
    await tester.pump();
    expect(find.textContaining('"files_modified"'), findsNothing);
  });

  testWidgets('file chip opens the file', (tester) async {
    String? opened;
    await _pump(
      tester,
      SubagentPage(data: _data(), onFileTap: (file) => opened = file),
      OTheme.light(),
    );

    // The first Navbar.tsx chip is the files-touched one above the summary.
    await tester.ensureVisible(find.text('Navbar.tsx').first);
    await tester.pump();
    await tester.tap(find.text('Navbar.tsx').first);
    await tester.pump();
    expect(opened, 'Navbar.tsx');
  });

  testWidgets('error state shows the message and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      SubagentPage(
        data: _data(status: V2SubagentStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load this subagent.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('loading state shows skeleton rows', (tester) async {
    await _pump(
      tester,
      SubagentPage(data: _data(status: V2SubagentStatus.loading)),
      OTheme.light(),
    );

    expect(find.text('Subagent'), findsOneWidget);
    expect(find.text('Frontend builder'), findsNothing);
  });

  testWidgets('paused subagent shows Paused pills', (tester) async {
    await _pump(
      tester,
      SubagentPage(data: _data(working: false)),
      OTheme.light(),
    );

    expect(find.text('Working'), findsNothing);
    expect(find.text('Paused'), findsNWidgets(2));
  });

  testWidgets('stop is hidden when the host has no stop action', (
    tester,
  ) async {
    await _pump(tester, SubagentPage(data: _data()), OTheme.light());
    expect(find.text('Stop subagent'), findsNothing);
  });

  testWidgets('renders at 320 dp with 200% text in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        SubagentPage(data: _data(), onStop: () {}),
        theme,
        size: const Size(320, 700),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('JSON summary'), findsOneWidget);
      expect(find.text('Stop subagent'), findsOneWidget);
      _expectNoTextPastEdge(tester, 320);
    }
  });

  testWidgets('long name and many files fit at 320 dp with 200% text', (
    tester,
  ) async {
    final data = V2SubagentPageData(
      name: 'Frontend builder for the marketing site',
      instanceLabel: 'Instance #A-4027',
      stepLabel: 'Step 3 of 5 active',
      paceLabel: 'Fast pace',
      goal: 'Assembling the responsive navbar and hero section.',
      startedLabel: '10:41 AM',
      elapsedLabel: '4m 12s',
      timeLimitLabel: '8h max',
      remainingLabel: '7h 55m left',
      totalLogLines: 42,
      files: const [
        'components/marketing/HeroSection.tsx',
        'Navbar.tsx',
        'globals.css',
      ],
      logLines: _logLines,
    );
    await _pump(
      tester,
      SubagentPage(data: data),
      OTheme.light(),
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    _expectNoTextPastEdge(tester, 320);
  });

  testWidgets('empty state fits at 320 dp with 200% text', (tester) async {
    await _pump(
      tester,
      SubagentPage(
        data: _data(status: V2SubagentStatus.empty),
        onBackToChat: () {},
      ),
      OTheme.light(),
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No subagent is running'), findsOneWidget);
    _expectNoTextPastEdge(tester, 320);
  });

  testWidgets('reduced motion keeps every line visible', (tester) async {
    await _pump(
      tester,
      SubagentPage(data: _data()),
      OTheme.light(),
      reduceMotion: true,
    );

    expect(find.text('Frontend builder'), findsOneWidget);
    expect(find.text('Overall progress'), findsOneWidget);
    expect(find.text('Log preview'), findsOneWidget);
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(
        of: find.text('Frontend builder'),
        matching: find.byType(FadeTransition),
      ),
    );
    for (final fade in fades) {
      expect(fade.opacity.value, 1);
    }
  });

  testWidgets('the JSON summary block is the shared SubagentSummaryCard', (
    tester,
  ) async {
    await _pump(tester, SubagentPage(data: _data()), OTheme.light());

    final card = tester.widget<SubagentSummaryCard>(
      find.byType(SubagentSummaryCard),
    );
    expect(card.status, V2SubagentSummaryStatus.ready);
    expect(card.summary?.status, 'completed');
    expect(card.summary?.filesModified, [
      'Hero.tsx',
      'Navbar.tsx',
      'globals.css',
    ]);
    expect(card.summary?.artifactsCreated, ['preview-screenshot.png']);
    expect(card.summary?.keyFindings, [
      'Breakpoints hold at 320 dp and 200 % text.',
    ]);
    expect(card.summary?.errorIfAny, 'One test flaked once, then passed.');

    // A subagent that has not reported yet shows the card's empty state.
    await _pump(
      tester,
      SubagentPage(data: _data(withSummary: false)),
      OTheme.dark(),
    );
    final empty = tester.widget<SubagentSummaryCard>(
      find.byType(SubagentSummaryCard),
    );
    expect(empty.summary, isNull);
    expect(empty.status, V2SubagentSummaryStatus.empty);
    expect(find.text('No summary yet'), findsOneWidget);
  });

  testWidgets('unknown progress is hidden, not shown as 0 %', (tester) async {
    await _pump(
      tester,
      SubagentPage(
        data: V2SubagentPageData(
          name: 'Frontend builder',
          instanceLabel: 'deepseek-chat',
          stepLabel: 'Working',
          paceLabel: '',
          goal: 'Build the navbar.',
          startedLabel: '10:41',
          elapsedLabel: '2m',
          timeLimitLabel: 'Not reported',
          remainingLabel: '',
          totalLogLines: 0,
          progressKnown: false,
        ),
      ),
      OTheme.light(),
    );

    expect(find.text('Overall progress'), findsNothing);
    expect(find.text('0%'), findsNothing);
  });
}
