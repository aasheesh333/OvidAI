import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/timeline.dart';

import '_harness.dart';

DateTime _at(int minute) => DateTime(2026, 10, 22, 10, minute);

final _steps = <V2RunStep>[
  V2RunStep(
    id: 's1',
    title: 'You',
    detail: 'Build the landing page.',
    durationLabel: '0.2s',
    kind: V2RunStepKind.message,
    startedAt: _at(41),
  ),
  V2RunStep(
    id: 's2',
    title: 'Searched the web',
    detail: 'Read four pages.',
    durationLabel: '54.2s',
    kind: V2RunStepKind.search,
    startedAt: _at(42),
    status: V2RunStepStatus.running,
    toolName: 'web_search',
    expandedDetail: 'Kept the two matching pages.',
    sources: const [V2RunSource(label: 'tailwindcss.com')],
  ),
  V2RunStep(
    id: 's3',
    title: 'Wrote portfolio-index.html',
    detail: 'Wrote the landing page.',
    durationLabel: '1m 12s',
    kind: V2RunStepKind.write,
    startedAt: _at(43),
    status: V2RunStepStatus.failed,
    toolName: 'fs_write',
    fileName: 'portfolio-index.html',
    fileMeta: '12 KB',
    errorMessage: 'Permission denied writing portfolio-index.html.',
  ),
  V2RunStep(
    id: 's4',
    title: 'Run finished',
    detail: '',
    durationLabel: '2s',
    kind: V2RunStepKind.finish,
    startedAt: _at(44),
  ),
];

V2RunTrajectoryPageData _data({
  V2RunTrajectoryStatus status = V2RunTrajectoryStatus.ready,
  List<V2RunStep>? steps,
  List<V2SubagentLaunch> subagents = const [],
  String errorMessage = 'We could not load this run.',
}) {
  return V2RunTrajectoryPageData(
    title: 'Landing page redesign & build',
    runLabel: 'Run 18',
    steps: steps ?? _steps,
    subagents: subagents,
    status: status,
    errorMessage: errorMessage,
  );
}

List<V2RunStep> _manySteps(int count) => [
  for (var i = 0; i < count; i++)
    V2RunStep(
      id: 'm$i',
      title: 'Message $i',
      detail: '',
      durationLabel: '1s',
      startedAt: DateTime(2026, 10, 22, 9).add(Duration(seconds: i)),
    ),
];

List<V2RunStep> _completed(List<V2RunStep> steps) => [
  for (final step in steps)
    V2RunStep(
      id: step.id,
      title: step.title,
      detail: step.detail,
      durationLabel: step.durationLabel,
      kind: step.kind,
      sources: step.sources,
      fileName: step.fileName,
      fileMeta: step.fileMeta,
      expandedDetail: step.expandedDetail,
      startedAt: step.startedAt,
      status: V2RunStepStatus.completed,
      errorMessage: step.errorMessage,
      toolName: step.toolName,
    ),
];

void main() {
  testWidgets('renders real steps in start order with status and duration', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        RunTrajectoryPage(
          data: _data(steps: [_steps[2], _steps[0], _steps[3], _steps[1]]),
          onShareRun: () {},
        ),
        dark: dark,
      );

      expect(find.text('Run trajectory'), findsOneWidget);
      for (final step in _steps) {
        expect(find.text(step.title), findsOneWidget);
        expect(find.text(step.durationLabel), findsOneWidget);
      }

      final you = tester.getTopLeft(find.text('You')).dy;
      final searched = tester.getTopLeft(find.text('Searched the web')).dy;
      final wrote = tester
          .getTopLeft(find.text('Wrote portfolio-index.html'))
          .dy;
      final finished = tester.getTopLeft(find.text('Run finished')).dy;
      expect(you, lessThan(searched));
      expect(searched, lessThan(wrote));
      expect(wrote, lessThan(finished));

      expect(find.text('10:41'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);

      // The header no longer restates the old overview card.
      expect(find.text('Redesign the landing page'), findsNothing);
      expect(find.text('Flash 2.5'), findsNothing);
      expect(find.text('18.4k tokens'), findsNothing);
      expect(find.text('Read four pages.'), findsOneWidget);
      expect(find.text('Kept the two matching pages.'), findsNothing);
      expect(find.text('tailwindcss.com'), findsNothing);
    }
  });

  group('steps are ordered by real start time', () {
    test('sorts when every step has a timestamp', () {
      final data = _data(steps: [_steps[2], _steps[0], _steps[3], _steps[1]]);
      expect(data.orderedSteps.map((step) => step.id), [
        's1',
        's2',
        's3',
        's4',
      ]);
    });

    test('keeps caller order when a timestamp is missing', () {
      final data = _data(
        steps: [
          _steps[2],
          V2RunStep(
            id: 'undated',
            title: 'Tool',
            detail: '',
            durationLabel: '',
          ),
          _steps[0],
        ],
      );
      expect(data.orderedSteps.map((step) => step.id), ['s3', 'undated', 's1']);
    });
  });

  testWidgets('expands tool name, detail, result, file and source', (
    tester,
  ) async {
    String? opened;
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(), onOpenSource: (label) => opened = label),
    );

    expect(find.text('web_search'), findsNothing);
    await tester.tap(find.text('Searched the web'));
    await tester.pump();
    expect(find.text('web_search'), findsOneWidget);
    expect(find.text('Kept the two matching pages.'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('tailwindcss.com'), findsOneWidget);
    // The visible summary is not repeated inside the panel.
    expect(find.text('Read four pages.'), findsOneWidget);
    expect(find.text('Detail'), findsNothing);

    await tester.tap(find.text('tailwindcss.com'));
    await tester.pump();
    expect(opened, 'tailwindcss.com');

    await tester.tap(find.text('Wrote portfolio-index.html'));
    await tester.pump();
    expect(find.text('fs_write'), findsOneWidget);
    expect(find.text('File'), findsOneWidget);
    expect(find.text('portfolio-index.html · 12 KB'), findsOneWidget);
  });

  testWidgets('a step with no hidden detail is not expandable', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(tester, RunTrajectoryPage(data: _data()));

    // s1 only has the summary that is already visible under the title, and s4
    // has nothing at all: neither may offer an expansion.
    for (final id in ['s1', 's4']) {
      final row = find.byKey(ValueKey<String>('run-step-$id'));
      expect(
        find.descendant(
          of: row,
          matching: find.byIcon(Icons.chevron_right_rounded),
        ),
        findsNothing,
      );
    }
    expect(
      tester
          .getSemantics(find.bySemanticsLabel(RegExp('Step 1 of 4')))
          .getSemanticsData()
          .flagsCollection
          .isButton,
      isFalse,
    );

    await tester.tap(find.text('Run finished'));
    await tester.pump();
    expect(find.text('Detail'), findsNothing);
    handle.dispose();
  });

  testWidgets('a failure marks its step and shows the error once', (
    tester,
  ) async {
    const error = 'Permission denied writing portfolio-index.html.';
    await pumpAt(tester, RunTrajectoryPage(data: _data()));

    expect(find.text('Failed'), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text(error), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('run-step-s3')),
        matching: find.text(error),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Wrote portfolio-index.html'));
    await tester.pump();
    expect(find.text('File'), findsOneWidget);
    expect(find.text(error), findsOneWidget);
  });

  testWidgets('only a running step animates', (tester) async {
    var steps = _steps;
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(steps: steps));
        },
      ),
    );

    expect(find.byType(OPulse), findsOneWidget);

    setHost(() => steps = _completed(_steps));
    await tester.pump();
    expect(find.byType(OPulse), findsNothing);
  });

  testWidgets('semantics announce position, status, duration and expansion', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(tester, RunTrajectoryPage(data: _data()));

    expect(
      find.bySemanticsLabel(RegExp('Step 1 of 4, 10:41, You, Completed, 0.2s')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp('Step 2 of 4, 10:42, Searched the web, Running, 54.2s'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(
          'Step 3 of 4, 10:43, Wrote portfolio-index.html, Failed, 1m 12s, '
          'Permission denied',
        ),
      ),
      findsOneWidget,
    );

    final row = find.bySemanticsLabel(
      RegExp('Step 2 of 4, 10:42, Searched the web'),
    );
    await tester.tap(row);
    await tester.pump();
    final data = tester.getSemantics(row).getSemanticsData();
    expect(data.flagsCollection.isExpanded, Tristate.isTrue);
    expect(data.hint, 'Hide details');
    handle.dispose();
  });

  testWidgets('new steps keep the reading position mid-history', (
    tester,
  ) async {
    var steps = _manySteps(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(steps: steps));
        },
      ),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    final controller = tester.widget<ListView>(list).controller!;
    await tester.drag(list, const Offset(0, -700));
    await tester.pump();

    final before = controller.position.pixels;
    expect(before, greaterThan(0));
    expect(controller.position.extentAfter, greaterThan(48));

    steps = _manySteps(61);
    setHost(() {});
    await tester.pump();
    expect(controller.position.pixels, closeTo(before, 0.5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.position.pixels, closeTo(before, 0.5));
  });

  testWidgets('new steps follow the tail only while the reader is there', (
    tester,
  ) async {
    var steps = _manySteps(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(steps: steps));
        },
      ),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    final controller = tester.widget<ListView>(list).controller!;
    await tester.drag(list, const Offset(0, -100000));
    await tester.pump();
    expect(controller.position.extentAfter, lessThanOrEqualTo(48));

    steps = _manySteps(61);
    setHost(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1),
    );
  });

  testWidgets('a run that opens at the top never jumps on a new step', (
    tester,
  ) async {
    var steps = _manySteps(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(steps: steps));
        },
      ),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.position.pixels, 0);
    expect(controller.position.extentAfter, greaterThan(48));

    steps = _manySteps(61);
    setHost(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.position.pixels, 0);
  });

  testWidgets('a running step with no duration still says Running', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(
          steps: [
            const V2RunStep(
              id: 'live',
              title: 'Editing auth_service.dart',
              detail: '',
              durationLabel: '',
              kind: V2RunStepKind.write,
              status: V2RunStepStatus.running,
              toolName: 'fs_edit',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Running'), findsOneWidget);
    expect(find.byType(OPulse), findsOneWidget);
    expect(
      find.bySemanticsLabel('Step 1 of 1, Editing auth_service.dart, Running'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('500 steps stay lazy and reachable', (tester) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(steps: _manySteps(500))),
    );

    expect(find.byType(V2TimelineRow).evaluate().length, lessThan(100));
    expect(find.text('Message 499'), findsNothing);

    final list = tester.widget<ListView>(
      find.byKey(const ValueKey('run-trajectory-list')),
    );
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());

    final controller = list.controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('Message 499'), findsOneWidget);
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

  testWidgets('subagents form a separate ordered section', (tester) async {
    final launches = [
      V2SubagentLaunch(
        id: 'sub2',
        agentName: 'QA runner',
        taskSummary: 'Ran the regression suite.',
        timeLabel: '10:45',
        durationLabel: '30s',
        startedAt: _at(45),
        status: V2SubagentLaunchStatus.failed,
      ),
      V2SubagentLaunch(
        id: 'sub1',
        agentName: 'Explorer',
        taskSummary: 'Found every caller.',
        timeLabel: '10:43',
        durationLabel: '2m 10s',
        startedAt: _at(43),
        status: V2SubagentLaunchStatus.running,
      ),
    ];
    String? opened;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(
          steps: [
            _completed([_steps.first]).first,
          ],
          subagents: launches,
        ),
        onOpenSubagent: (id) => opened = id,
      ),
    );

    expect(find.text('SUBAGENTS'), findsOneWidget);
    expect(find.text('2 subagents'), findsOneWidget);
    expect(find.text('Explorer'), findsOneWidget);
    expect(find.text('QA runner'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Explorer')).dy,
      lessThan(tester.getTopLeft(find.text('QA runner')).dy),
    );

    final explorer = find.bySemanticsLabel(
      RegExp('Subagent 1 of 2, 10:43, Explorer, Running, 2m 10s'),
    );
    expect(explorer, findsOneWidget);
    expect(
      tester.getSemantics(explorer).getSemanticsData().hint,
      'Open subagent',
    );

    await tester.tap(find.text('Explorer'));
    await tester.pump();
    expect(opened, 'sub1');
    handle.dispose();
  });

  testWidgets('subagent launches survive a run with no recorded steps', (
    tester,
  ) async {
    final launches = [
      V2SubagentLaunch(
        id: 'sub1',
        agentName: 'Explorer',
        taskSummary: 'Found every caller.',
        timeLabel: '10:43',
        durationLabel: '2m 10s',
        startedAt: _at(43),
        status: V2SubagentLaunchStatus.running,
      ),
    ];
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(
          status: V2RunTrajectoryStatus.empty,
          steps: const [],
          subagents: launches,
        ),
      ),
    );

    expect(find.text('No steps yet'), findsNothing);
    expect(find.text('SUBAGENTS'), findsOneWidget);
    expect(find.text('Explorer'), findsOneWidget);
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

  testWidgets('fits 320 dp at 200 % text with long tool names', (tester) async {
    const longName =
        'run_shell_with_a_very_long_tool_name_that_must_wrap_instead_of_clip';
    final longStep = V2RunStep(
      id: 'long',
      title: longName,
      detail: 'A long summary that has to wrap or ellipsize without overflow.',
      durationLabel: '1m 12s',
      kind: V2RunStepKind.write,
      toolName: longName,
      errorMessage: 'The command could not start because the path was invalid.',
      status: V2RunStepStatus.failed,
    );
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        RunTrajectoryPage(
          key: ValueKey<String>('long-$dark'),
          data: _data(steps: [longStep]),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text(longName));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text(longName), findsWidgets);
    }
  });

  testWidgets('caps and centres the steps at 720 dp', (tester) async {
    await pumpTablet(tester, RunTrajectoryPage(data: _data()));

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    expect(widthOf(tester, list), 720);
    expect(tester.getTopLeft(list).dx, closeTo((900 - 720) / 2, 0.5));
  });

  testWidgets('keeps the 720 dp cap on a 1280 dp window', (tester) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data()),
      size: const Size(1280, 900),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    expect(widthOf(tester, list), 720);
    expect(tester.getTopLeft(list).dx, closeTo((1280 - 720) / 2, 0.5));
  });

  testWidgets('fits 320 dp at 100 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        RunTrajectoryPage(key: ValueKey<String>('narrow-$dark'), data: _data()),
        size: const Size(320, 640),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('You'), findsOneWidget);
    }
  });
}
