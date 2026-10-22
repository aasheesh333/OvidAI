import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
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
    expect(find.text('Retry run'), findsOneWidget);

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

  testWidgets('failed run shows its detail and retries', (tester) async {
    _phone(tester);
    V2ScheduleRun? retried;
    await tester.pumpWidget(
      _app(ScheduleRunsPage(data: _data, onRetryRun: (run) => retried = run)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('storage connector'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Retry run'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Retry run'));
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

      // The failed run's detail and retry action are the densest part.
      await tester.scrollUntilVisible(
        find.text('Retry run'),
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
}
