import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_summary.dart';

import '_harness.dart';

const _summary = V2SubagentSummaryData(
  status: 'completed',
  filesModified: ['Hero.tsx', 'Navbar.tsx'],
  artifactsCreated: ['preview-screenshot.png'],
  keyFindings: ['Breakpoints hold at 320 dp.', 'All tests pass.'],
);

const _longFinding =
    'The retry path keeps the original failure, retries exactly once and then '
    'surfaces the server message unchanged, which means the caller can still '
    'distinguish a network drop from a rejected token without parsing prose. '
    'The old code swallowed the second error and reported a generic failure, '
    'so this is the part worth reading twice before the branch merges.';

void main() {
  testWidgets('renders the strict five fields', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        const SubagentSummaryCard(summary: _summary),
        dark: dark,
      );

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('FILES MODIFIED'), findsOneWidget);
      expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      expect(find.text('ERROR IF ANY'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsOneWidget);
      expect(find.text('preview-screenshot.png'), findsOneWidget);
      expect(find.text('All tests pass.'), findsOneWidget);

      // No raw JSON toggle, no token badge, no explanatory paragraph.
      expect(find.text('Show raw JSON'), findsNothing);
      expect(find.text('≤300 tokens'), findsNothing);
      expect(find.textContaining('What the subagent returned'), findsNothing);
      expect(find.textContaining('"files_modified"'), findsNothing);
    }
  });

  testWidgets('missing contract keys read as a dash, not invented text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      const SubagentSummaryCard(summary: V2SubagentSummaryData(reported: {})),
    );
    expect(find.text(v2SubagentMissingValue), findsNWidgets(5));
    expect(find.text('None'), findsNothing);
    expect(find.text('Not reported'), findsNothing);

    // The dash is spoken as a value, so a label + value is still read.
    expect(find.bySemanticsLabel('Status: Not reported'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Files modified: Not reported'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Artifacts created: Not reported'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Key findings: Not reported'), findsOneWidget);
    expect(find.bySemanticsLabel('Error if any: Not reported'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('reported but empty fields read None', (tester) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(
        summary: V2SubagentSummaryData(status: 'completed'),
      ),
    );
    expect(find.text('None'), findsNWidgets(4));
    expect(find.text(v2SubagentMissingValue), findsNothing);
  });

  testWidgets('a status outside the contract is shown verbatim', (
    tester,
  ) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(
        summary: V2SubagentSummaryData(status: 'partial'),
      ),
    );
    expect(find.text('partial'), findsOneWidget);
    expect(find.text('Completed'), findsNothing);
  });

  testWidgets('empty and error states retry', (tester) async {
    var retries = 0;
    await pumpAt(
      tester,
      SubagentSummaryCard(
        status: V2SubagentSummaryStatus.empty,
        onRetry: () => retries++,
      ),
    );
    expect(find.text('No summary yet'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      SubagentSummaryCard(
        status: V2SubagentSummaryStatus.error,
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load the summary.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 2);
  });

  testWidgets('loading shows a skeleton and no fields', (tester) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(status: V2SubagentSummaryStatus.loading),
    );
    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.text('STATUS'), findsNothing);
  });

  testWidgets('files and artifacts open when wired', (tester) async {
    String? file;
    String? artifact;
    await pumpAt(
      tester,
      SubagentSummaryCard(
        summary: _summary,
        onFileTap: (value) => file = value,
        onArtifactTap: (value) => artifact = value,
      ),
    );

    await tester.ensureVisible(find.text('Hero.tsx'));
    await tester.pump();
    await tester.tap(find.text('Hero.tsx'));
    await tester.pump();
    expect(file, 'Hero.tsx');

    await tester.ensureVisible(find.text('preview-screenshot.png'));
    await tester.pump();
    await tester.tap(find.text('preview-screenshot.png'));
    await tester.pump();
    expect(artifact, 'preview-screenshot.png');
  });

  testWidgets('an error field reads in the danger colour, not a box', (
    tester,
  ) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(
        summary: V2SubagentSummaryData(
          status: 'failed',
          errorIfAny: 'The build failed.',
        ),
      ),
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('The build failed.'), findsOneWidget);
  });

  testWidgets('a long finding is capped until it is expanded', (tester) async {
    await pumpAt(
      tester,
      const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: SubagentSummaryCard(
          summary: V2SubagentSummaryData(
            status: 'completed',
            keyFindings: [_longFinding],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final preview = tester.widget<Text>(find.text(_longFinding));
    expect(preview.maxLines, 3);
    expect(find.text('Show more'), findsOneWidget);

    await tester.ensureVisible(find.text('Show more'));
    await tester.pump();
    await tester.tap(find.text('Show more'));
    await tester.pump();

    expect(find.text('Show less'), findsOneWidget);
    expect(tester.widget<Text>(find.text(_longFinding)).maxLines, isNull);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: SubagentSummaryCard(
            summary: V2SubagentSummaryData(
              status: 'completed',
              filesModified: ['a/very/long/path/that/keeps/going/Hero.tsx'],
              artifactsCreated: ['preview-screenshot-with-a-long-name.png'],
              keyFindings: [_longFinding],
            ),
          ),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
    }
  });
}
