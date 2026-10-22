import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/schedules/run_timeline.dart';

const _data = V2RunTimelineData(
  runs: <V2TimelineRun>[
    V2TimelineRun(
      id: 'r1',
      dayLabel: 'Today — May 18',
      timeLabel: '9:00 AM',
      durationLabel: '1m 12s',
      outcome: V2RunOutcome.succeeded,
      summary: 'Summarized 12 news items into the daily brief.',
      artifactName: 'daily-brief.md',
    ),
    V2TimelineRun(
      id: 'r2',
      dayLabel: 'Today — May 18',
      timeLabel: '3:00 AM',
      durationLabel: '18s',
      outcome: V2RunOutcome.failed,
      summary: 'Nightly backup did not finish.',
      failureDetail:
          'Could not reach the storage connector. Your schedule rules are intact.',
    ),
    V2TimelineRun(
      id: 'r3',
      dayLabel: 'Yesterday — May 17',
      timeLabel: '9:00 AM',
      durationLabel: '1m 08s',
      outcome: V2RunOutcome.succeeded,
      summary: 'Generated the daily dependency report.',
      artifactName: 'dependency-report.md',
    ),
  ],
);

Widget _app(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(OSpace.l),
      child: child,
    ),
  ),
);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Smallest supported phone with doubled text.
void _smallPhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _smallApp(Widget child, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 640),
      textScaler: TextScaler.linear(2),
    ),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(OSpace.l),
        child: child,
      ),
    ),
  ),
);

void main() {
  testWidgets('groups runs by day and shows the rail metadata', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const RunTimeline(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('YESTERDAY — MAY 17'), findsOneWidget);
    expect(find.text('2 runs'), findsOneWidget);
    expect(find.text('1 run'), findsOneWidget);

    expect(find.text('9:00 AM'), findsNWidgets(2));
    expect(find.text('1m 12s'), findsOneWidget);
    expect(find.text('18s'), findsOneWidget);
    expect(
      find.text('Summarized 12 news items into the daily brief.'),
      findsOneWidget,
    );
    expect(find.text('daily-brief.md'), findsOneWidget);
    expect(find.text('dependency-report.md'), findsOneWidget);

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

  testWidgets('renders in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const RunTimeline(data: _data), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('Retry run'), findsOneWidget);
    expect(find.text('daily-brief.md'), findsOneWidget);
  });

  testWidgets('only a failed run offers retry, and it fires', (tester) async {
    _phone(tester);
    V2TimelineRun? retried;
    await tester.pumpWidget(
      _app(RunTimeline(data: _data, onRetryRun: (run) => retried = run)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry run'), findsOneWidget);
    await tester.ensureVisible(find.text('Retry run'));
    await tester.tap(find.text('Retry run'));
    expect(retried?.id, 'r2');
  });

  testWidgets('artifact link names the file and opens that run', (
    tester,
  ) async {
    _phone(tester);
    V2TimelineRun? opened;
    await tester.pumpWidget(
      _app(RunTimeline(data: _data, onOpenArtifact: (run) => opened = run)),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel('Open artifact daily-brief.md'),
      findsOneWidget,
    );
    await tester.tap(find.text('daily-brief.md'));
    expect(opened?.id, 'r1');
  });

  testWidgets('announces disabled retry and artifact actions', (tester) async {
    final handle = tester.ensureSemantics();
    _phone(tester);
    await tester.pumpWidget(_app(const RunTimeline(data: _data)));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('Retry run')),
      isSemantics(isButton: true, isEnabled: false),
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Open artifact daily-brief.md'),
      ),
      isSemantics(isButton: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('every action is at least 48 dp tall', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        RunTimeline(data: _data, onOpenArtifact: (_) {}, onRetryRun: (_) {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(OButton)).height,
      greaterThanOrEqualTo(OSpace.touch),
    );
    expect(
      tester
          .getSize(find.bySemanticsLabel('Open artifact daily-brief.md'))
          .height,
      greaterThanOrEqualTo(OSpace.touch),
    );
  });

  testWidgets('empty history offers a way back', (tester) async {
    _phone(tester);
    var back = 0;
    await tester.pumpWidget(
      _app(
        RunTimeline(
          data: const V2RunTimelineData(status: V2RunTimelineStatus.empty),
          onBackToSchedule: () => back++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No runs yet'), findsOneWidget);
    await tester.tap(find.text('Back to schedule'));
    expect(back, 1);
  });

  testWidgets('content with no runs falls back to the empty state', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        RunTimeline(
          data: const V2RunTimelineData(runs: <V2TimelineRun>[]),
          onBackToSchedule: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No runs yet'), findsOneWidget);
  });

  testWidgets('loading state shows skeleton rows, not empty copy', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const RunTimeline(
          data: V2RunTimelineData(status: V2RunTimelineStatus.loading),
        ),
      ),
    );
    // The skeleton shimmer never settles while it is on screen.
    await tester.pump();

    expect(find.byType(OSkeleton), findsWidgets);
    expect(find.text('No runs yet'), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    _phone(tester);
    var retries = 0;
    await tester.pumpWidget(
      _app(
        RunTimeline(
          data: const V2RunTimelineData(status: V2RunTimelineStatus.error),
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

  testWidgets('a failure prints its reason once', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const RunTimeline(
          data: V2RunTimelineData(
            runs: <V2TimelineRun>[
              V2TimelineRun(
                id: 'r1',
                dayLabel: 'Today — May 18',
                timeLabel: '9:00 AM',
                durationLabel: '18s',
                outcome: V2RunOutcome.failed,
                summary: '',
                failureDetail: 'The connector timed out.',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('The connector timed out.'), findsOneWidget);
    // The detail is the summary; the row does not add a second line.
    expect(find.text('Failed without a summary.'), findsNothing);
  });

  testWidgets('a failure with no detail still says so', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const RunTimeline(
          data: V2RunTimelineData(
            runs: <V2TimelineRun>[
              V2TimelineRun(
                id: 'r1',
                dayLabel: 'Today — May 18',
                timeLabel: '9:00 AM',
                outcome: V2RunOutcome.failed,
                summary: '',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed without a summary.'), findsOneWidget);
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
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(OSpace.l),
              child: const RunTimeline(data: _data),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('Retry run'), findsOneWidget);
    expect(find.text('daily-brief.md'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('survives 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      _smallPhone(tester);
      V2TimelineRun? retried;
      await tester.pumpWidget(
        _smallApp(
          RunTimeline(
            data: _data,
            onRetryRun: (run) => retried = run,
            onOpenArtifact: (_) {},
          ),
          dark: dark,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('TODAY — MAY 18'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Retry run'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The error line and retry action stay readable when everything wraps.
      expect(find.textContaining('storage connector'), findsOneWidget);
      await tester.tap(find.text('Retry run'));
      expect(retried?.id, 'r2');
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'empty state survives 320 dp at 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _smallPhone(tester);
        await tester.pumpWidget(
          _smallApp(
            RunTimeline(
              data: const V2RunTimelineData(status: V2RunTimelineStatus.empty),
              onBackToSchedule: () {},
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
