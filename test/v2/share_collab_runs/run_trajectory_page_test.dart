import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';

import '_harness.dart';

const _steps = [
  V2RunStep(
    id: 's1',
    title: 'Read your message',
    detail: 'Parsed the request and picked a plan.',
    durationLabel: '0.2s',
    kind: V2RunStepKind.message,
  ),
  V2RunStep(
    id: 's2',
    title: 'Searched the web',
    detail: 'Read four pages.',
    durationLabel: '54.2s',
    kind: V2RunStepKind.search,
    sources: [V2RunSource(label: 'tailwindcss.com')],
    expandedDetail: 'Kept the two pages that matched.',
  ),
  V2RunStep(
    id: 's3',
    title: 'Wrote portfolio-index.html',
    detail: 'Wrote the landing page.',
    durationLabel: '1m 12s',
    kind: V2RunStepKind.write,
    fileName: 'portfolio-index.html',
    fileMeta: '12 KB',
  ),
];

V2RunTrajectoryPageData _data({
  V2RunTrajectoryStatus status = V2RunTrajectoryStatus.ready,
  List<V2RunStep> steps = _steps,
}) {
  return V2RunTrajectoryPageData(
    title: 'Landing page redesign & build',
    runLabel: 'Run 18',
    prompt: 'Redesign the landing page',
    model: 'Flash 2.5',
    tokensLabel: '18.4k tokens',
    durationLabel: '2m 10s',
    steps: steps,
    status: status,
  );
}

void main() {
  testWidgets('shows the ordered steps, one line each with duration', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        RunTrajectoryPage(data: _data(), onShareRun: () {}),
        dark: dark,
      );

      expect(find.text('Run trajectory'), findsOneWidget);
      for (final step in _steps) {
        expect(find.text(step.title), findsOneWidget);
        expect(find.text(step.durationLabel), findsOneWidget);
      }

      final first = tester.getTopLeft(find.text('Read your message')).dy;
      final second = tester.getTopLeft(find.text('Searched the web')).dy;
      final third = tester
          .getTopLeft(find.text('Wrote portfolio-index.html'))
          .dy;
      expect(first, lessThan(second));
      expect(second, lessThan(third));

      // Prose, sources and the old overview are gone.
      expect(find.text('Redesign the landing page'), findsNothing);
      expect(find.text('Flash 2.5'), findsNothing);
      expect(find.text('18.4k tokens'), findsNothing);
      expect(find.text('Parsed the request and picked a plan.'), findsNothing);
      expect(find.text('tailwindcss.com'), findsNothing);
      expect(find.text('portfolio-index.html'), findsNothing);
      expect(find.text('View details'), findsNothing);
      expect(find.text('Open preview'), findsNothing);
    }
  });

  testWidgets('the header carries the one share action', (tester) async {
    var shares = 0;
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(), onShareRun: () => shares++),
    );

    await tester.tap(find.bySemanticsLabel('Share run'));
    await tester.pump();
    expect(shares, 1);
  });

  testWidgets('an unwired share offers no control', (tester) async {
    await pumpAt(tester, RunTrajectoryPage(data: _data()));
    expect(find.bySemanticsLabel('Share run'), findsNothing);
  });

  testWidgets('empty, error and loading states are wired', (tester) async {
    var retries = 0;
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(steps: const []),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('No steps yet'), findsOneWidget);
    await tester.tap(find.text('Reload'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(status: V2RunTrajectoryStatus.error),
        onRetry: () {},
      ),
    );
    expect(find.text('We could not load this run.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(status: V2RunTrajectoryStatus.loading)),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        RunTrajectoryPage(data: _data(), onShareRun: () {}),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Read your message'), findsOneWidget);
    }
  });

  testWidgets('caps and centres the steps at 720 dp', (tester) async {
    await pumpTablet(tester, RunTrajectoryPage(data: _data()));

    final steps = find.byType(ListView);
    expect(widthOf(tester, steps), 720);
    expect(tester.getTopLeft(steps).dx, closeTo((900 - 720) / 2, 0.5));
  });
}
