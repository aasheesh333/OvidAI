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

const _longFinding =
    'The retry path keeps the original failure, retries exactly once and then '
    'surfaces the server message unchanged, which means the caller can still '
    'distinguish a network drop from a rejected token without parsing prose. '
    'The old code swallowed the second error and reported a generic failure, '
    'so this is the part worth reading twice before the branch merges.';

V2SubagentPageData _data({
  V2SubagentStatus status = V2SubagentStatus.ready,
  bool working = false,
  V2SubagentSummaryData? summary = _summary,
  String stepLabel = 'Finished',
  String startedLabel = '10:41',
  String elapsedLabel = '6m',
  String logPath = '/workspace/.ovid/logs/subagent_a402.log',
  String name = 'Frontend builder',
  List<String> files = const <String>[],
  List<V2SubagentLogLine> logLines = const <V2SubagentLogLine>[],
}) {
  return V2SubagentPageData(
    name: name,
    instanceLabel: 'subagent_a402',
    stepLabel: stepLabel,
    goal: 'Rebuild the landing page.',
    startedLabel: startedLabel,
    elapsedLabel: elapsedLabel,
    timeLimitLabel: '8 h',
    remainingLabel: '',
    totalLogLines: 42,
    files: files,
    logLines: logLines,
    logPath: logPath,
    summary: summary,
    working: working,
    status: status,
  );
}

void main() {
  testWidgets('a finished run shows the five contract fields', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        SubagentPage(data: _data(), onViewLog: () {}, onFileTap: (_) {}),
        dark: dark,
      );

      expect(find.text('Subagent'), findsOneWidget);
      expect(find.text('Frontend builder'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('FILES MODIFIED'), findsOneWidget);
      expect(find.text('ARTIFACTS CREATED'), findsOneWidget);
      expect(find.text('KEY FINDINGS'), findsOneWidget);
      expect(find.text('ERROR IF ANY'), findsOneWidget);
      expect(find.text('Hero.tsx'), findsOneWidget);
      expect(find.text('preview-screenshot.png'), findsOneWidget);
      expect(find.text('Started 10:41 · 6m'), findsOneWidget);
      expect(find.text('View log'), findsOneWidget);

      // The old invented states and duplicated copy are gone.
      expect(find.text('Working'), findsNothing);
      expect(find.text('Paused'), findsNothing);
      expect(find.text('Overall progress'), findsNothing);
      expect(find.text('Current goal'), findsNothing);
      expect(find.text('Log preview'), findsNothing);
    }
  });

  testWidgets('a running run shows Running, the clock and one stop control', (
    tester,
  ) async {
    var stops = 0;
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(working: true, summary: null, stepLabel: 'Working'),
        onStop: () => stops++,
      ),
    );

    expect(find.text('Running'), findsOneWidget);
    expect(find.text('No summary yet'), findsOneWidget);
    expect(find.text('STATUS'), findsOneWidget);
    expect(find.text('FILES MODIFIED'), findsNothing);
    expect(find.text('Completed'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Stop subagent'));
    await tester.pump();
    expect(stops, 1);
  });

  testWidgets('a finished run without a summary is never shown as completed', (
    tester,
  ) async {
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(working: false, summary: null, stepLabel: 'Finished'),
        onStop: () {},
      ),
    );

    expect(find.text('Completed'), findsNothing);
    expect(find.text('No summary yet'), findsOneWidget);
    expect(find.text(v2SubagentMissingValue), findsWidgets);
    expect(find.bySemanticsLabel('Stop subagent'), findsNothing);
  });

  testWidgets('failed and cancelled runs carry their own status', (
    tester,
  ) async {
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(
          stepLabel: 'Failed',
          summary: const V2SubagentSummaryData(
            status: 'failed',
            errorIfAny: 'The build failed.',
          ),
        ),
      ),
    );
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('The build failed.'), findsOneWidget);

    await pumpAt(
      tester,
      SubagentPage(
        data: _data(
          stepLabel: 'Stopped',
          summary: const V2SubagentSummaryData(status: 'cancelled'),
        ),
      ),
    );
    expect(find.text('Cancelled'), findsOneWidget);
  });

  testWidgets('a run past the 8 h ceiling is timed out, not running', (
    tester,
  ) async {
    var stops = 0;
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(
          working: true,
          summary: null,
          stepLabel: 'Working',
          elapsedLabel: '8h 3m',
        ),
        onStop: () => stops++,
      ),
    );

    expect(find.text('Timed out'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.bySemanticsLabel('Stop subagent'), findsNothing);
    expect(stops, 0);
  });

  testWidgets('elapsed time ticks while running and freezes on finish', (
    tester,
  ) async {
    var now = DateTime(2026, 10, 22, 10, 0);
    DateTime clock() => now;

    await pumpAt(
      tester,
      SubagentPage(
        data: _data(working: true, summary: null, stepLabel: 'Working'),
        clock: clock,
      ),
    );
    expect(find.text('Started 10:41 · 6m'), findsOneWidget);

    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Started 10:41 · 6m 5s'), findsOneWidget);

    // The run ends: the value freezes at the last real reading.
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(working: false, summary: null, stepLabel: 'Finished'),
        clock: clock,
      ),
    );
    expect(find.text('Started 10:41 · 6m 5s'), findsOneWidget);

    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(minutes: 2));
    expect(find.text('Started 10:41 · 6m 5s'), findsOneWidget);
  });

  testWidgets('one log action prefers the in-app viewer and never goes dead', (
    tester,
  ) async {
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

    // No log path and no viewer: no control at all.
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(logPath: ''),
        onReadFullLog: (_) {},
      ),
    );
    expect(find.text('View log'), findsNothing);

    await pumpAt(tester, SubagentPage(data: _data()));
    expect(find.text('View log'), findsNothing);
  });

  testWidgets('a running run shows one live progress line', (tester) async {
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(working: true, summary: null, stepLabel: 'Working'),
      ),
    );

    // The step and the real tool-row count, on one line.
    expect(find.text('Working · 42 tool rows'), findsOneWidget);
  });

  testWidgets('the goal, the files touched and the log tail are rendered', (
    tester,
  ) async {
    await pumpAt(
      tester,
      SubagentPage(
        data: _data(
          summary: null,
          files: const <String>[
            'lib/core/auth_service.dart',
            'lib/ui/v2/chat/chat_page.dart',
          ],
          logLines: const <V2SubagentLogLine>[
            V2SubagentLogLine(
              time: '10:43',
              text: 'Opened the workspace tree.',
            ),
            V2SubagentLogLine(time: '10:45', text: 'Found 4 call sites.'),
          ],
        ),
        onViewLog: () {},
      ),
    );

    expect(find.text('GOAL'), findsOneWidget);
    expect(find.text('Rebuild the landing page.'), findsOneWidget);
    expect(find.text('FILES'), findsOneWidget);
    expect(find.text('lib/core/auth_service.dart'), findsOneWidget);
    expect(find.text('lib/ui/v2/chat/chat_page.dart'), findsOneWidget);
    expect(find.text('LOG'), findsOneWidget);
    // The tail says what it is a tail of: the real recorded row count.
    expect(find.text('Last 2 of 42 rows'), findsOneWidget);
    expect(find.text('[10:43] Opened the workspace tree.'), findsOneWidget);
    expect(find.text('[10:45] Found 4 call sites.'), findsOneWidget);
    expect(find.text('View log'), findsOneWidget);
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

  testWidgets('status, each field and the log action are announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await pumpAt(
      tester,
      SubagentPage(
        data: _data(summary: const V2SubagentSummaryData(status: 'completed')),
        onFileTap: (_) {},
        onViewLog: () {},
      ),
    );

    expect(
      find.bySemanticsLabel(
        RegExp(r'^Status: Completed\. Started at 10:41\. Elapsed 6m$'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Files modified: None'), findsOneWidget);
    expect(find.bySemanticsLabel('Artifacts created: None'), findsOneWidget);
    expect(find.bySemanticsLabel('Key findings: None'), findsOneWidget);
    expect(find.bySemanticsLabel('Error if any: None'), findsOneWidget);
    expect(find.bySemanticsLabel('View subagent log'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('no nesting is stated once and nothing implies it', (
    tester,
  ) async {
    await pumpAt(tester, SubagentPage(data: _data(), onViewLog: () {}));

    expect(
      find.text('A subagent cannot dispatch another subagent.'),
      findsOneWidget,
    );
    // The only action on the screen is the log.
    expect(find.byType(OButton), findsOneWidget);
    expect(find.bySemanticsLabel('Start subagent'), findsNothing);
    expect(find.bySemanticsLabel('Dispatch subagent'), findsNothing);
  });

  testWidgets('a long finding wraps at 320 dp without overflow', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        SubagentPage(
          data: _data(
            name: 'A subagent name long enough to need ellipsis',
            summary: const V2SubagentSummaryData(
              status: 'completed',
              keyFindings: [_longFinding],
            ),
          ),
          onStop: () {},
          onViewLog: () {},
          onFileTap: (_) {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('STATUS'), findsOneWidget);
      expect(find.text('Show more'), findsOneWidget);
    }
  });

  testWidgets('holds every width from 320 to 1280 at 1x and 2x', (
    tester,
  ) async {
    const widths = <double>[320, 360, 412, 600, 800, 1024, 1280];
    for (final width in widths) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          await pumpAt(
            tester,
            SubagentPage(
              data: _data(
                summary: const V2SubagentSummaryData(
                  status: 'completed',
                  filesModified: ['a/very/long/path/that/keeps/going/Hero.tsx'],
                  keyFindings: [_longFinding],
                ),
              ),
              onViewLog: () {},
              onFileTap: (_) {},
            ),
            size: Size(width, 900),
            textScale: scale,
            dark: dark,
          );
          final where = '$width dp @ $scale';
          expect(tester.takeException(), isNull, reason: where);
          final expected = width > 640 ? 640.0 : width;
          final body = find.byType(ListView);
          expect(widthOf(tester, body), expected, reason: where);
          expect(
            tester.getTopLeft(body).dx,
            closeTo((width - expected) / 2, 0.5),
            reason: where,
          );
          expect(find.text('STATUS'), findsOneWidget, reason: where);
        }
      }
    }
  });

  testWidgets('caps and centres the run at 640 dp', (tester) async {
    await pumpTablet(tester, SubagentPage(data: _data(), onViewLog: () {}));

    final body = find.byType(ListView);
    expect(widthOf(tester, body), 640);
    expect(tester.getTopLeft(body).dx, closeTo((900 - 640) / 2, 0.5));

    await pumpAt(
      tester,
      SubagentPage(data: _data(), onViewLog: () {}),
      size: const Size(1280, 900),
    );
    final wide = find.byType(ListView);
    expect(widthOf(tester, wide), 640);
    expect(tester.getTopLeft(wide).dx, closeTo((1280 - 640) / 2, 0.5));
  });
}
