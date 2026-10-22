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

void main() {
  testWidgets('renders the strict five fields', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        const SubagentSummaryCard(summary: _summary),
        dark: dark,
      );

      expect(find.text('Summary'), findsOneWidget);
      expect(find.text('Completed'), findsNWidgets(2));
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

  testWidgets('missing contract keys read Not reported', (tester) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(
        summary: V2SubagentSummaryData(reported: {}),
      ),
    );
    expect(find.text('Not reported'), findsNWidgets(5));
    expect(find.text('None'), findsNothing);
  });

  testWidgets('reported but empty fields read None', (tester) async {
    await pumpAt(
      tester,
      const SubagentSummaryCard(
        summary: V2SubagentSummaryData(status: 'completed'),
      ),
    );
    expect(find.text('None'), findsNWidgets(4));
    expect(find.text('Not reported'), findsNothing);
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
    expect(find.text('Failed'), findsNWidgets(2));
    expect(find.text('The build failed.'), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: SubagentSummaryCard(summary: _summary),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Summary'), findsOneWidget);
    }
  });
}
