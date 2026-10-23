import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/v2/app/v2_run_routes.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/timeline.dart';

import '_harness.dart';

DateTime _at(int minute) => DateTime(2026, 10, 22, 10, minute);

V2SubagentLaunch _launch(
  String id, {
  required String agentName,
  required String taskSummary,
  required DateTime startedAt,
  String durationLabel = '1m',
  V2SubagentLaunchStatus status = V2SubagentLaunchStatus.completed,
  int toolCount = 0,
}) {
  final local = startedAt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return V2SubagentLaunch(
    id: id,
    agentName: agentName,
    taskSummary: taskSummary,
    timeLabel: '$hh:$mm',
    durationLabel: durationLabel,
    startedAt: startedAt,
    status: status,
    toolCount: toolCount,
  );
}

final _launches = <V2SubagentLaunch>[
  _launch(
    'sub1',
    agentName: 'Explorer',
    taskSummary: 'Found every AuthService.signIn caller.',
    startedAt: _at(43),
    durationLabel: '2m 10s',
    status: V2SubagentLaunchStatus.running,
    toolCount: 4,
  ),
  _launch(
    'sub2',
    agentName: 'QA runner',
    taskSummary: 'Ran the regression suite.',
    startedAt: _at(45),
    durationLabel: '30s',
    status: V2SubagentLaunchStatus.failed,
    toolCount: 2,
  ),
  _launch(
    'sub3',
    agentName: 'Pricing research',
    taskSummary: 'Compared the three plans.',
    startedAt: _at(47),
    durationLabel: '1m',
  ),
];

V2RunTrajectoryPageData _data({
  V2RunTrajectoryStatus status = V2RunTrajectoryStatus.ready,
  List<V2SubagentLaunch>? subagents,
  DateTime? startedAt,
  DateTime? endedAt,
  String errorMessage = 'We could not load this run.',
}) {
  return V2RunTrajectoryPageData(
    title: 'Landing page redesign & build',
    runLabel: 'Run 18',
    subagents: subagents ?? _launches,
    startedAt: startedAt,
    endedAt: endedAt,
    status: status,
    errorMessage: errorMessage,
  );
}

List<V2SubagentLaunch> _manyLaunches(int count) => [
  for (var i = 0; i < count; i++)
    _launch(
      'w$i',
      agentName: 'Worker $i',
      taskSummary: 'Task $i',
      startedAt: DateTime(2026, 10, 22, 9).add(Duration(seconds: i)),
      durationLabel: '1s',
    ),
];

List<V2SubagentLaunch> _completed(List<V2SubagentLaunch> launches) => [
  for (final launch in launches)
    _launch(
      launch.id,
      agentName: launch.agentName,
      taskSummary: launch.taskSummary,
      startedAt: launch.startedAt!,
      durationLabel: launch.durationLabel,
      toolCount: launch.toolCount,
    ),
];

/// A root chat with the main agent's own messages and tool calls.
ChatSession _rootSession() {
  final session = ChatSession(
    id: 'root',
    title: 'Build landing page',
    model: 'deepseek-chat',
    createdAt: _at(41),
  );
  session.messages.addAll([
    Message(role: 'user', content: 'Build the landing page.', time: _at(41)),
    Message(role: 'assistant', content: 'The page is ready.', time: _at(42)),
    Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: 'fs_edit',
      toolTitle: 'Edit lib/app.dart',
      toolSummary: '+12 −3',
      toolState: 'ok',
      toolInput: '{"path":"lib/app.dart"}',
      time: _at(43),
    ),
  ]);
  return session;
}

ChatSession _childSession({String id = 'sub1'}) {
  final child = ChatSession(
    id: id,
    title: 'Find every AuthService.signIn caller.',
    model: 'deepseek-chat',
    parentId: 'root',
    agentLabel: 'Explorer',
    agentState: 'running',
    createdAt: _at(44),
  );
  child.messages.add(
    Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: 'workspace_search',
      toolTitle: 'Search signIn',
      toolSummary: '4 call sites',
      toolState: 'ok',
      time: _at(45),
    ),
  );
  return child;
}

void main() {
  testWidgets('renders the workers in launch order with every label', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        RunTrajectoryPage(
          // Supplied out of order on purpose: the screen orders by launch.
          data: _data(subagents: [_launches[2], _launches[0], _launches[1]]),
          onShareRun: () {},
        ),
        dark: dark,
      );

      expect(find.text('Run trajectory'), findsOneWidget);
      expect(find.text('SUBAGENTS'), findsOneWidget);
      expect(find.text('3 subagents'), findsOneWidget);

      // Agent type, prompt/description, status and duration all survive.
      for (final launch in _launches) {
        expect(find.text(launch.agentName), findsOneWidget);
        expect(find.text(launch.taskSummary), findsOneWidget);
        expect(find.text(launch.durationLabel), findsOneWidget);
      }
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);

      final explorer = tester.getTopLeft(find.text('Explorer')).dy;
      final qa = tester.getTopLeft(find.text('QA runner')).dy;
      final pricing = tester.getTopLeft(find.text('Pricing research')).dy;
      expect(explorer, lessThan(qa));
      expect(qa, lessThan(pricing));

      expect(find.byType(V2TimelineRow), findsNWidgets(3));
    }
  });

  testWidgets('the main agent\'s own steps never become rows', (tester) async {
    // The trajectory answers "what are my workers doing?". The main agent's
    // text and tool calls are the conversation the person is already having,
    // so none of them may appear here.
    final root = _rootSession();
    final child = _childSession();
    final data = V2RunRoutes.trajectoryDataFor(
      root,
      allSessions: [root, child],
    );

    await pumpAt(tester, RunTrajectoryPage(data: data));

    expect(find.text('Build the landing page.'), findsNothing);
    expect(find.text('The page is ready.'), findsNothing);
    expect(find.text('Edit lib/app.dart'), findsNothing);
    expect(find.text('fs_edit'), findsNothing);
    expect(find.text('You'), findsNothing);
    expect(find.text('Assistant'), findsNothing);

    // The worker is the only row, and it is the real child session.
    expect(find.byType(V2TimelineRow), findsOneWidget);
    expect(find.text('Explorer'), findsOneWidget);
    expect(find.text('Find every AuthService.signIn caller.'), findsOneWidget);
    expect(find.text('SUBAGENTS'), findsOneWidget);
    expect(find.text('1 subagent'), findsOneWidget);
  });

  testWidgets('a run with steps but no workers shows the no-workers state', (
    tester,
  ) async {
    // A root chat that did work but dispatched nothing is empty here: its
    // steps belong to the chat, not to this screen.
    final root = _rootSession();
    final data = V2RunRoutes.trajectoryDataFor(root, allSessions: [root]);

    await pumpAt(tester, RunTrajectoryPage(data: data));

    expect(find.text('No subagents yet'), findsOneWidget);
    expect(find.text('No steps yet'), findsNothing);
    expect(find.text('Build the landing page.'), findsNothing);
    expect(find.text('Edit lib/app.dart'), findsNothing);
    expect(find.byType(V2TimelineRow), findsNothing);
    expect(find.byType(OSectionTitle), findsNothing);
  });

  testWidgets('the empty state talks about workers, not steps', (tester) async {
    var retries = 0;
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(subagents: const []),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('No subagents yet'), findsOneWidget);
    expect(find.text('No steps yet'), findsNothing);
    expect(
      find.text(
        'Workers appear here when Ovid dispatches one. The main agent\'s '
        'own steps stay in the chat.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Reload'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('a worker keeps its drill-down, status and position', (
    tester,
  ) async {
    String? opened;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(), onOpenSubagent: (id) => opened = id),
    );

    final qa = find.bySemanticsLabel(
      RegExp('Subagent 2 of 3, 10:45, QA runner, Failed, 30s'),
    );
    expect(qa, findsOneWidget);
    expect(tester.getSemantics(qa).getSemanticsData().hint, 'Open subagent');

    await tester.tap(find.text('QA runner'));
    await tester.pump();
    expect(opened, 'sub2');
    handle.dispose();
  });

  testWidgets('only a running worker animates', (tester) async {
    var launches = _launches;
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(subagents: launches));
        },
      ),
    );

    expect(find.byType(OPulse), findsOneWidget);

    setHost(() => launches = _completed(_launches));
    await tester.pump();
    expect(find.byType(OPulse), findsNothing);
  });

  testWidgets('timed-out and cancelled workers say so', (tester) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(
          subagents: [
            _launch(
              't',
              agentName: 'Slow worker',
              taskSummary: 'Never finished.',
              startedAt: _at(43),
              status: V2SubagentLaunchStatus.timedOut,
            ),
            _launch(
              'c',
              agentName: 'Stopped worker',
              taskSummary: 'You stopped it.',
              startedAt: _at(44),
              status: V2SubagentLaunchStatus.cancelled,
            ),
          ],
        ),
      ),
    );

    expect(find.text('Timed out'), findsOneWidget);
    expect(find.text('Cancelled'), findsOneWidget);
  });

  group('workers are ordered by real launch time', () {
    test('sorts when every worker has a timestamp', () {
      final data = _data(subagents: [_launches[2], _launches[0], _launches[1]]);
      expect(data.orderedSubagents.map((launch) => launch.id), [
        'sub1',
        'sub2',
        'sub3',
      ]);
    });

    test('keeps caller order for undated workers, after the dated ones', () {
      final mixed = _data(
        subagents: [
          const V2SubagentLaunch(
            id: 'undated',
            agentName: 'Tool',
            taskSummary: '',
            timeLabel: '',
            durationLabel: '',
          ),
          _launches[1],
        ],
      );
      expect(mixed.orderedSubagents.map((launch) => launch.id), [
        'sub2',
        'undated',
      ]);
    });
  });

  testWidgets('new workers keep the reading position mid-history', (
    tester,
  ) async {
    var launches = _manyLaunches(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(subagents: launches));
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

    launches = _manyLaunches(61);
    setHost(() {});
    await tester.pump();
    expect(controller.position.pixels, closeTo(before, 0.5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.position.pixels, closeTo(before, 0.5));
  });

  testWidgets('new workers follow the tail only while the reader is there', (
    tester,
  ) async {
    var launches = _manyLaunches(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(subagents: launches));
        },
      ),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    final controller = tester.widget<ListView>(list).controller!;
    await tester.drag(list, const Offset(0, -100000));
    await tester.pump();
    // A lazily built list estimates the extent of rows it has not laid out,
    // so land on the real bottom before the append.
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(controller.position.extentAfter, lessThanOrEqualTo(48));

    launches = _manyLaunches(61);
    setHost(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      controller.position.pixels,
      closeTo(controller.position.maxScrollExtent, 1),
    );
  });

  testWidgets('a run that opens at the top never jumps on a new worker', (
    tester,
  ) async {
    var launches = _manyLaunches(60);
    late StateSetter setHost;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          setHost = setState;
          return RunTrajectoryPage(data: _data(subagents: launches));
        },
      ),
    );

    final list = find.byKey(const ValueKey('run-trajectory-list'));
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.position.pixels, 0);
    expect(controller.position.extentAfter, greaterThan(48));

    launches = _manyLaunches(61);
    setHost(() {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.position.pixels, 0);
  });

  testWidgets('500 workers stay lazy and reachable', (tester) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(data: _data(subagents: _manyLaunches(500))),
    );

    expect(find.byType(V2TimelineRow).evaluate().length, lessThan(100));
    expect(find.text('Worker 499'), findsNothing);

    final listFinder = find.byKey(const ValueKey('run-trajectory-list'));
    final list = tester.widget<ListView>(listFinder);
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());

    // A lazily built list estimates the extent of rows it has not laid out,
    // so the bottom moves as more rows are built. Jump until it settles.
    final controller = list.controller!;
    for (var i = 0; i < 100; i++) {
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      if (find.text('Worker 499').evaluate().isNotEmpty) break;
    }
    expect(find.text('Worker 499'), findsOneWidget);
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

  testWidgets('error and loading states are wired', (tester) async {
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

  testWidgets('fits 320 dp at 200 % text with a long worker name', (
    tester,
  ) async {
    const longName =
        'run_shell_with_a_very_long_agent_name_that_must_wrap_instead_of_clip';
    final longLaunch = _launch(
      'long',
      agentName: longName,
      taskSummary:
          'A long summary that has to wrap or ellipsize without '
          'overflow.',
      startedAt: _at(43),
      durationLabel: '1m 12s',
      status: V2SubagentLaunchStatus.failed,
    );
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        RunTrajectoryPage(
          key: ValueKey<String>('long-$dark'),
          data: _data(subagents: [longLaunch]),
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text(longName), findsOneWidget);
    }
  });

  testWidgets('caps and centres the worker list at 720 dp', (tester) async {
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
      expect(find.text('Explorer'), findsOneWidget);
    }
  });

  testWidgets('a settled run summarises workers, their tools and duration', (
    tester,
  ) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(
          subagents: _completed(_launches),
          startedAt: _at(41),
          endedAt: _at(41).add(const Duration(seconds: 41)),
        ),
      ),
    );

    // 3 workers, 6 tool calls across them, 41 s from the real clock.
    expect(find.text('3 subagents · 6 tools · 41s'), findsOneWidget);
    // The main agent's step count is not part of this screen's summary.
    expect(find.textContaining('steps'), findsNothing);
  });

  testWidgets('a running run counts workers so far and prints no duration', (
    tester,
  ) async {
    await pumpAt(
      tester,
      RunTrajectoryPage(
        data: _data(startedAt: _at(41), subagents: _launches),
      ),
    );

    expect(find.text('3 subagents so far'), findsOneWidget);
    expect(find.textContaining('41s'), findsNothing);
  });

  testWidgets(
    'the strip reads as one sentence and shows a dash when the end is unknown',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpAt(
        tester,
        RunTrajectoryPage(data: _data(subagents: _completed(_launches))),
      );

      expect(find.text('3 subagents · 6 tools · —'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Run summary, 3 subagents, 6 tools, duration not reported',
        ),
        findsOneWidget,
      );
      handle.dispose();
    },
  );
}
