import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_summary.dart';

const _summary = V2SubagentSummaryData(
  status: 'completed',
  filesModified: ['lib/ui/v2/runs/subagent_summary.dart', 'Hero.tsx'],
  artifactsCreated: ['preview-screenshot.png'],
  keyFindings: [
    'Breakpoints hold at 320 dp and 200 % text.',
    'All tests pass.',
  ],
  errorIfAny: 'One flaky test passed on retry.',
);

const _longSummary = V2SubagentSummaryData(
  status: 'timeout',
  filesModified: [
    'lib/ui/v2/runs/a_very_long_component_name_that_keeps_going/subagent_summary.dart',
    'components/marketing/HeroSection.tsx',
    'globals.css',
  ],
  artifactsCreated: [
    'artifacts/2026-10-21/subagent-summary-320dp-preview-screenshot.png',
  ],
  keyFindings: [
    'The summary card stays inside the viewport at 320 dp with 200 % text, including every chip and the raw JSON block.',
    'No horizontal scrolling is needed anywhere in the card.',
  ],
  errorIfAny:
      'The run timed out while uploading the final artifact. Everything before that step is saved.',
);

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
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: KeyedSubtree(key: UniqueKey(), child: child),
        ),
      ),
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

Future<void> _revealRaw(WidgetTester tester) async {
  final toggle = find.text('Show raw JSON');
  await tester.ensureVisible(toggle);
  await tester.pump();
  await tester.tap(toggle);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  testWidgets('renders all five contract fields in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, const SubagentSummaryCard(summary: _summary), theme);

      expect(find.text('JSON summary'), findsOneWidget);
      expect(find.text('≤300 tokens'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('FILES MODIFIED'), findsOneWidget);
      expect(find.text('2 files'), findsOneWidget);
      expect(find.text('lib/ui/v2/runs/subagent_summary.dart'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsOneWidget);
      expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
      expect(find.text('1 artifact'), findsOneWidget);
      expect(find.text('preview-screenshot.png'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      expect(find.text('2 findings'), findsOneWidget);
      expect(
        find.text('Breakpoints hold at 320 dp and 200 % text.'),
        findsOneWidget,
      );
      expect(find.text('All tests pass.'), findsOneWidget);
      expect(find.text('ERROR IF ANY'), findsOneWidget);
      expect(find.text('One flaky test passed on retry.'), findsOneWidget);
      expect(find.text('Show raw JSON'), findsOneWidget);
      expect(find.textContaining('"files_modified"'), findsNothing);
      _expectNoTextPastEdge(tester, 390);
    }
  });

  testWidgets('status pill follows the runtime status', (tester) async {
    const cases = [
      ('completed', 'Completed', OPillTone.success),
      ('failed', 'Failed', OPillTone.danger),
      ('timeout', 'Timed out', OPillTone.warn),
      ('cancelled', 'Cancelled', OPillTone.neutral),
      ('needs_review', 'needs_review', OPillTone.neutral),
    ];

    for (final (status, label, tone) in cases) {
      await _pump(
        tester,
        SubagentSummaryCard(summary: V2SubagentSummaryData(status: status)),
        OTheme.light(),
      );

      final pill = tester.widget<OPill>(
        find.byWidgetPredicate((w) => w is OPill && w.label == label),
      );
      expect(pill.tone, tone, reason: 'status "$status" should be $tone');
    }
  });

  testWidgets('raw JSON stays hidden until the toggle is used', (tester) async {
    await _pump(
      tester,
      const SubagentSummaryCard(summary: _summary),
      OTheme.light(),
    );

    expect(find.textContaining('"files_modified"'), findsNothing);
    expect(find.textContaining('"error_if_any"'), findsNothing);

    await _revealRaw(tester);

    expect(find.text('Hide raw JSON'), findsOneWidget);
    expect(find.textContaining('"status": "completed"'), findsOneWidget);
    expect(find.textContaining('"files_modified"'), findsOneWidget);
    expect(find.textContaining('"artifacts_created"'), findsOneWidget);
    expect(find.textContaining('"key_findings"'), findsOneWidget);
    expect(find.textContaining('"error_if_any"'), findsOneWidget);
    expect(
      find.textContaining('"One flaky test passed on retry."'),
      findsOneWidget,
    );

    final toggle = find.text('Hide raw JSON');
    await tester.ensureVisible(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    expect(find.textContaining('"files_modified"'), findsNothing);
    expect(find.text('Show raw JSON'), findsOneWidget);
  });

  testWidgets('file and artifact chips call their callbacks', (tester) async {
    String? openedFile;
    String? openedArtifact;
    await _pump(
      tester,
      SubagentSummaryCard(
        summary: _summary,
        onFileTap: (file) => openedFile = file,
        onArtifactTap: (artifact) => openedArtifact = artifact,
      ),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Hero.tsx'));
    await tester.pump();
    await tester.tap(find.text('Hero.tsx'));
    await tester.pump();
    expect(openedFile, 'Hero.tsx');

    await tester.ensureVisible(find.text('preview-screenshot.png'));
    await tester.pump();
    await tester.tap(find.text('preview-screenshot.png'));
    await tester.pump();
    expect(openedArtifact, 'preview-screenshot.png');
  });

  testWidgets('chips without callbacks are not announced as buttons', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const SubagentSummaryCard(summary: _summary),
      OTheme.light(),
    );

    final chip = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'file Hero.tsx',
      ),
    );
    expect(chip.properties.button, isNot(isTrue));
    handle.dispose();
  });

  testWidgets('status and raw toggle expose semantic context', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const SubagentSummaryCard(summary: _summary),
      OTheme.light(),
    );

    final status = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Status: Completed',
      ),
    );
    expect(status.properties.label, 'Status: Completed');

    final toggle = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Show raw JSON',
      ),
    );
    expect(toggle.properties.button, isTrue);
    expect(toggle.properties.enabled, isTrue);
    handle.dispose();
  });

  testWidgets('empty state explains what happens next and can retry', (
    tester,
  ) async {
    var checks = 0;
    await _pump(
      tester,
      SubagentSummaryCard(
        status: V2SubagentSummaryStatus.empty,
        onRetry: () => checks++,
      ),
      OTheme.light(),
    );

    expect(find.text('JSON summary'), findsOneWidget);
    expect(find.text('No summary yet'), findsOneWidget);
    expect(
      find.text('A subagent sends its JSON summary when it finishes.'),
      findsOneWidget,
    );
    expect(find.text('Show raw JSON'), findsNothing);

    await tester.tap(find.text('Check again'));
    await tester.pump();
    expect(checks, 1);
  });

  testWidgets('error state shows the message and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      SubagentSummaryCard(
        status: V2SubagentSummaryStatus.error,
        onRetry: () => retries++,
        errorMessage: 'The summary could not be read.',
      ),
      OTheme.light(),
    );

    expect(find.text('The summary could not be read.'), findsOneWidget);
    expect(find.text('Show raw JSON'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('loading state shows skeletons and no summary fields', (
    tester,
  ) async {
    await _pump(
      tester,
      const SubagentSummaryCard(
        status: V2SubagentSummaryStatus.loading,
        summary: _summary,
      ),
      OTheme.light(),
    );

    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.text('JSON summary'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
    expect(find.text('Hero.tsx'), findsNothing);
    expect(find.text('Show raw JSON'), findsNothing);
  });

  testWidgets('renders at 320 dp with 200% text in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        const SubagentSummaryCard(summary: _longSummary),
        theme,
        size: const Size(320, 700),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('JSON summary'), findsOneWidget);
      expect(find.text('Timed out'), findsOneWidget);
      expect(find.text('globals.css'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      _expectNoTextPastEdge(tester, 320);

      await _revealRaw(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('"artifacts_created"'), findsOneWidget);
      _expectNoTextPastEdge(tester, 320);
    }
  });

  testWidgets('long labels and findings fit at 320 dp with 200% text', (
    tester,
  ) async {
    final summary = V2SubagentSummaryData(
      status: 'failed',
      filesModified: const [
        'a/very/long/path/that/keeps/going/and/going/subagent_summary.dart',
      ],
      artifactsCreated: const [
        'a/very/long/artifact/path/that/keeps/going/and/going/final-preview.png',
      ],
      keyFindings: const [
        'A very long finding that has to wrap over several lines without pushing past the right edge of a 320 dp screen at 200 percent text.',
        'Short finding.',
      ],
      errorIfAny:
          'A very long error message that also has to wrap cleanly at 320 dp with 200 percent text without clipping.',
    );
    await _pump(
      tester,
      SubagentSummaryCard(summary: summary),
      OTheme.dark(),
      size: const Size(320, 700),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Failed'), findsOneWidget);
    _expectNoTextPastEdge(tester, 320);
  });

  testWidgets('reduced motion keeps the summary and raw JSON visible', (
    tester,
  ) async {
    await _pump(
      tester,
      const SubagentSummaryCard(summary: _summary),
      OTheme.light(),
      reduceMotion: true,
    );

    expect(find.text('JSON summary'), findsOneWidget);
    expect(find.text('Key findings'.toUpperCase()), findsOneWidget);

    await _revealRaw(tester);
    expect(find.textContaining('"files_modified"'), findsOneWidget);
  });
}
