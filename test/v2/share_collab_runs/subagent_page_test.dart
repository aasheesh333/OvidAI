import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';

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
      await _pump(tester, SubagentPage(data: _data()), theme);

      expect(find.text('Subagent'), findsOneWidget);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('Overall progress'), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsOneWidget);
      expect(find.text('3 files'), findsOneWidget);
      expect(find.text('8h max'), findsOneWidget);
      expect(find.text('View full log (42 lines)'), findsOneWidget);
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

  testWidgets('file chip opens the file', (tester) async {
    String? opened;
    await _pump(
      tester,
      SubagentPage(data: _data(), onFileTap: (file) => opened = file),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Navbar.tsx'));
    await tester.pump();
    await tester.tap(find.text('Navbar.tsx'));
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

  testWidgets('stop is announced as disabled without a callback', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      SubagentPage(data: _data()),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Stop subagent'));
    await tester.pump(const Duration(milliseconds: 400));
    final semantics = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Stop subagent',
      ),
    );
    expect(semantics.properties.button, isTrue);
    expect(semantics.properties.enabled, isFalse);
    handle.dispose();
  });

  testWidgets('renders at 320 dp with 200% text without overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      SubagentPage(data: _data()),
      OTheme.dark(),
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Frontend builder'), findsOneWidget);
    expect(find.text('Stop subagent'), findsOneWidget);
    _expectNoTextPastEdge(tester, 320);
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
}
