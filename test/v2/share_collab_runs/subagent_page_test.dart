import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_summary.dart';

import '_harness.dart';

const _summary = V2SubagentSummaryData(
  status: 'completed',
  filesModified: ['Hero.tsx', 'Navbar.tsx'],
  artifactsCreated: ['preview-screenshot.png'],
  keyFindings: ['Breakpoints hold at 320 dp.'],
);

V2SubagentPageData _data({
  V2SubagentStatus status = V2SubagentStatus.ready,
  bool working = true,
  V2SubagentSummaryData? summary = _summary,
}) {
  return V2SubagentPageData(
    name: 'Frontend builder',
    instanceLabel: 'subagent_a402',
    stepLabel: 'Step 4 of 7',
    paceLabel: 'On pace',
    goal: 'Rebuild the landing page.',
    startedLabel: '10:41',
    elapsedLabel: '6m',
    timeLimitLabel: '8h max',
    remainingLabel: '7h 54m left',
    totalLogLines: 42,
    logPath: '/workspace/.ovid/logs/subagent_a402.log',
    logLines: const [
      V2SubagentLogLine(time: '10:41', text: 'Starting'),
    ],
    summary: summary,
    working: working,
    status: status,
  );
}

void main() {
  testWidgets('shows the status, five contract fields and one log action', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        SubagentPage(
          data: _data(),
          onStop: () {},
          onViewLog: () {},
          onReadFullLog: (_) {},
          onFileTap: (_) {},
        ),
        dark: dark,
      );

      expect(find.text('Subagent'), findsOneWidget);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('FILES MODIFIED'), findsOneWidget);
      expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      expect(find.text('ERROR IF ANY'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsOneWidget);
      expect(find.text('preview-screenshot.png'), findsOneWidget);
      expect(find.text('View log'), findsOneWidget);

      // Progress, goal, timers and the log preview are gone.
      expect(find.text('Overall progress'), findsNothing);
      expect(find.text('60%'), findsNothing);
      expect(find.text('Current goal'), findsNothing);
      expect(find.text('8h max'), findsNothing);
      expect(find.text('Log preview'), findsNothing);
      expect(find.text('Starting'), findsNothing);
      expect(find.textContaining('cannot start other subagents'), findsNothing);
      expect(find.textContaining('Stopping pauses'), findsNothing);
    }
  });

  testWidgets('the stop control is offered only while working', (tester) async {
    var stops = 0;
    await pumpAt(
      tester,
      SubagentPage(data: _data(), onStop: () => stops++),
    );
    await tester.tap(find.bySemanticsLabel('Stop subagent'));
    await tester.pump();
    expect(stops, 1);

    await pumpAt(
      tester,
      SubagentPage(data: _data(working: false), onStop: () {}),
    );
    expect(find.bySemanticsLabel('Stop subagent'), findsNothing);
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('one log action prefers the in-app viewer', (tester) async {
    var views = 0;
    String? readPath;
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(),
        onViewLog: () => views++,
        onReadFullLog: (path) => readPath = path,
      ),
    );

    await tester.tap(find.text('View log'));
    await tester.pump();
    expect(views, 1);
    expect(readPath, isNull);

    await pumpAt(
      tester,
      SubagentPage(data: _data(), onReadFullLog: (path) => readPath = path),
    );
    await tester.tap(find.text('View log'));
    await tester.pump();
    expect(readPath, '/workspace/.ovid/logs/subagent_a402.log');
  });

  testWidgets('a modified file opens from the summary', (tester) async {
    String? opened;
    await pumpAt(
      tester,
      SubagentPage(data: _data(), onFileTap: (file) => opened = file),
    );

    await tester.ensureVisible(find.text('Hero.tsx'));
    await tester.pump();
    await tester.tap(find.text('Hero.tsx'));
    await tester.pump();
    expect(opened, 'Hero.tsx');
  });

  testWidgets('empty, error and loading states are wired', (tester) async {
    var backs = 0;
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(status: V2SubagentStatus.empty),
        onBackToChat: () => backs++,
      ),
    );
    expect(find.text('No subagent is running'), findsOneWidget);
    await tester.tap(find.text('Back to chat'));
    await tester.pump();
    expect(backs, 1);

    var retries = 0;
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(status: V2SubagentStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load this subagent.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      SubagentPage(data: _data(status: V2SubagentStatus.loading)),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('no summary is one short state, not a paragraph', (tester) async {
    await pumpAt(
      tester,
      SubagentPage(data: _data(summary: null), onRetry: () {}),
    );
    expect(find.text('No summary yet'), findsOneWidget);
    expect(find.text('STATUS'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        SubagentPage(
          data: _data(),
          onStop: () {},
          onViewLog: () {},
          onFileTap: (_) {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Frontend builder'), findsOneWidget);
    }
  });

  testWidgets('caps and centres the run at 720 dp', (tester) async {
    await pumpTablet(tester, SubagentPage(data: _data(), onViewLog: () {}));

    final body = find.byType(ListView);
    expect(widthOf(tester, body), 720);
    expect(tester.getTopLeft(body).dx, closeTo((900 - 720) / 2, 0.5));
  });
}
