import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/run_timeline.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_runs_page.dart';

const _data = V2ScheduleRunsData(
  scheduleTitle: 'Morning AI news briefing',
  total: 24,
  succeeded: 23,
  failed: 1,
  avgRuntimeLabel: '52s',
  groups: <V2RunGroup>[
    V2RunGroup(
      label: 'Today — May 18',
      runs: <V2ScheduleRun>[
        V2ScheduleRun(
          id: 'r1',
          timeLabel: '9:00 AM',
          durationLabel: '1m 12s',
          status: V2RunStatus.succeeded,
          summary: 'Summarized 12 news items into daily-brief.md.',
          resultPreview:
              '> Found 0 critical, 2 minor outdated packages. All audits passed clean.',
          artifactName: 'daily-brief.md',
        ),
        V2ScheduleRun(
          id: 'r2',
          timeLabel: '3:00 AM',
          durationLabel: '18s',
          status: V2RunStatus.failed,
          summary: 'Nightly backup did not finish.',
          failureTitle: 'Last run failed · Connector timeout',
          failureDetail:
              'Could not reach the storage connector. Your schedule rules are intact.',
        ),
      ],
    ),
    V2RunGroup(
      label: 'Yesterday — May 17',
      runs: <V2ScheduleRun>[
        V2ScheduleRun(
          id: 'r3',
          timeLabel: '9:00 AM',
          durationLabel: '1m 08s',
          status: V2RunStatus.succeeded,
          summary: 'Generated the daily dependency report.',
        ),
      ],
    ),
  ],
);

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Smallest supported phone with doubled text, the layout the screen was
/// hardened for. Any RenderFlex overflow surfaces as a caught exception.
void _smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _smallApp(Widget home, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 640),
      textScaler: TextScaler.linear(2),
    ),
    child: home,
  ),
);

void main() {
  testWidgets('renders the run history in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleRunsPage(data: _data)));
    await tester.pumpAndSettle();

    // The header is the schedule itself, not a generic page name.
    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('Schedule runs'), findsNothing);
    // One summary line; the card, the bar and the filter chips are gone.
    expect(find.text('95.8 % · 24 runs'), findsOneWidget);
    expect(find.text('24 runs · 23 succeeded · 1 failed'), findsNothing);
    expect(find.text('95.8% success'), findsNothing);
    expect(find.text('Avg runtime 52s'), findsNothing);
    expect(find.text('Failed (1)'), findsNothing);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('YESTERDAY — MAY 17'), findsOneWidget);
    expect(find.text('daily-brief.md'), findsOneWidget);
    expect(
      find.text('Summarized 12 news items into daily-brief.md.'),
      findsOneWidget,
    );
    expect(find.text('Run now'), findsOneWidget);

    // Status is more than colour: each dot carries a check or a cross.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('run-status-r1')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('run-status-r2')),
        matching: find.byIcon(Icons.close_rounded),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders the run history in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ScheduleRunsPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('95.8 % · 24 runs'), findsOneWidget);
    expect(find.text('Today — May 18'), findsNothing);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
  });

  testWidgets('empty history offers a way back', (tester) async {
    _phone(tester);
    var back = 0;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(
          data: const V2ScheduleRunsData(status: V2ScheduleRunsStatus.empty),
          onBackToSchedule: () => back++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No runs yet'), findsOneWidget);
    await tester.tap(find.text('Back to schedule'));
    expect(back, 1);
  });

  testWidgets('empty history keeps the schedule in the header', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const ScheduleRunsPage(
          data: V2ScheduleRunsData(
            status: V2ScheduleRunsStatus.empty,
            scheduleTitle: 'Morning AI news briefing',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('No runs yet'), findsOneWidget);
  });

  testWidgets('the artifact link fires for a completed run', (tester) async {
    _phone(tester);
    V2ScheduleRun? opened;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(data: _data, onViewArtifact: (run) => opened = run),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('daily-brief.md'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('daily-brief.md'));
    expect(opened?.id, 'r1');
  });

  testWidgets('failed run shows its detail and starts a new run', (
    tester,
  ) async {
    _phone(tester);
    V2ScheduleRun? retried;
    await tester.pumpWidget(
      _app(ScheduleRunsPage(data: _data, onRunNow: (run) => retried = run)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('storage connector'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Run now'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Run now'));
    expect(retried?.id, 'r2');
  });

  testWidgets('history is rendered by the shared run timeline', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleRunsPage(data: _data)));
    await tester.pumpAndSettle();

    final timeline = tester.widget<RunTimeline>(find.byType(RunTimeline));
    expect(timeline.data.days.length, 2);
    expect(timeline.data.days.first.label, 'Today — May 18');
    expect(timeline.data.days.first.runs.first.id, 'r1');
    expect(timeline.data.days.last.label, 'Yesterday — May 17');
    expect(find.byKey(const ValueKey<String>('run-status-r2')), findsOneWidget);
  });

  testWidgets('loading state shows skeletons', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const ScheduleRunsPage(
          data: V2ScheduleRunsData(status: V2ScheduleRunsStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('No runs yet'), findsNothing);
  });

  testWidgets('error state offers a retry', (tester) async {
    _phone(tester);
    var retries = 0;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(
          data: const V2ScheduleRunsData(status: V2ScheduleRunsStatus.error),
          onRetry: () => retries++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.textContaining('could not load'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retries, 1);
  });

  testWidgets('reduced motion hides no content', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(430, 932),
            disableAnimations: true,
          ),
          child: const ScheduleRunsPage(data: _data),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('95.8 % · 24 runs'), findsOneWidget);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('daily-brief.md'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('survives 320 dp and 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      _smallPhone(tester);
      await tester.pumpWidget(
        _smallApp(const ScheduleRunsPage(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // The timeline must lay out at this width: the run meta, summary,
      // failure detail and artifact link all wrap instead of overflowing.
      await tester.scrollUntilVisible(
        find.text('daily-brief.md'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The failed run's detail and run-now action are the densest part.
      await tester.scrollUntilVisible(
        find.text('Run now'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('storage connector'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The one summary line also has to survive.
      await tester.scrollUntilVisible(
        find.text('95.8 % · 24 runs'),
        -160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'empty state survives 320 dp and 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _smallPhone(tester);
        await tester.pumpWidget(
          _smallApp(
            const ScheduleRunsPage(
              data: V2ScheduleRunsData(status: V2ScheduleRunsStatus.empty),
            ),
            dark: dark,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('No runs yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a failed run states its reason once', (tester) async {
    _phone(tester);
    final data = V2ScheduleRunsData.fromRuns(
      [
        ScheduleRunDto.fromJson(<String, dynamic>{
          'id': 'r1',
          'scheduleId': 's1',
          'scheduledFor': '2026-10-21T09:00:00.000Z',
          'status': 'failed',
          'attempt': 1,
          'ranLate': false,
          'error': 'The connector timed out.',
          'startedAt': '2026-10-21T09:00:00.000Z',
          'finishedAt': '2026-10-21T09:00:30.000Z',
        }),
      ],
      scheduleTitle: 'Morning briefing',
      now: DateTime.parse('2026-10-21T12:00:00.000Z'),
    );

    await tester.pumpWidget(_app(ScheduleRunsPage(data: data)));
    await tester.pumpAndSettle();

    expect(find.text('Failed'), findsOneWidget);
    // The reason appears in the failure line, not again as the summary.
    expect(find.text('The connector timed out.'), findsOneWidget);
    expect(find.text('Failed without a summary.'), findsNothing);
  });

  testWidgets('a run row announces its status and duration', (tester) async {
    _phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const ScheduleRunsPage(data: _data)));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        RegExp(r'^Completed run at 9:00 AM, took 1m 12s\.'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Failed run at 3:00 AM, took 18s\.')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('each day heading is one header node', (tester) async {
    _phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_app(const ScheduleRunsPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Today — May 18, 2 runs'), findsOneWidget);
    expect(find.bySemanticsLabel('Yesterday — May 17, 1 run'), findsOneWidget);
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets('centres and caps the history from 600 to 1280 '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;

      for (final width in const [600.0, 800.0, 1024.0, 1280.0]) {
        for (final scale in const [1.0, 2.0]) {
          tester.view.physicalSize = Size(width, 900);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 900),
                  textScaler: TextScaler.linear(scale),
                ),
                child: const ScheduleRunsPage(data: _data),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final reason = '$width dp at ${scale}x';
          expect(tester.takeException(), isNull, reason: reason);

          final list = find.byType(ListView).first;
          final size = tester.getSize(list);
          final left = tester.getTopLeft(list).dx;
          final cap = OBreakpoints.contentMaxWidth(width);
          expect(
            size.width,
            lessThanOrEqualTo(cap + 0.5),
            reason: '$reason: the history is wider than its band cap',
          );
          expect(
            left,
            closeTo((width - size.width) / 2, 1),
            reason: '$reason: the history is not centred',
          );
        }
      }
    });
  }
}
