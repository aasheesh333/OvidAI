import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_runs_page.dart';

const _data = V2ScheduleRunsData(
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

Widget _app(Widget home, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: home,
);

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

    expect(find.text('Schedule runs'), findsOneWidget);
    expect(
      find.text('24 runs · 23 succeeded · 1 failed'),
      findsOneWidget,
    );
    expect(find.text('95.8% success'), findsOneWidget);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('Completed'), findsWidgets);
    expect(find.text('Failed'), findsOneWidget);
  });

  testWidgets('renders the run history in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ScheduleRunsPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedule runs'), findsOneWidget);
    expect(find.text('24 runs · 23 succeeded · 1 failed'), findsOneWidget);
    expect(find.text('Today — May 18'), findsNothing);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
  });

  testWidgets('empty history offers a way back', (tester) async {
    _phone(tester);
    var back = 0;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(
          data: const V2ScheduleRunsData(
            status: V2ScheduleRunsStatus.empty,
          ),
          onBackToSchedule: () => back++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No runs yet'), findsOneWidget);
    await tester.tap(find.text('Back to schedule'));
    expect(back, 1);
  });

  testWidgets('Open chat fires for a completed run', (tester) async {
    _phone(tester);
    V2ScheduleRun? opened;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(data: _data, onOpenChat: (run) => opened = run),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Open chat'));
    // Normal text keeps the reference layout: both actions share one row.
    expect(
      tester.getCenter(find.text('Open chat')).dy,
      moreOrLessEquals(tester.getCenter(find.text('View artifact')).dy),
    );
    await tester.tap(find.text('Open chat'));
    expect(opened?.id, 'r1');
  });

  testWidgets('failed run expands and retries', (tester) async {
    _phone(tester);
    V2ScheduleRun? retried;
    await tester.pumpWidget(
      _app(
        ScheduleRunsPage(data: _data, onRetryRun: (run) => retried = run),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry now'), findsNothing);
    await tester.ensureVisible(find.text('Show details'));
    await tester.tap(find.text('Show details'));
    await tester.pumpAndSettle();

    expect(find.text('What happened'), findsOneWidget);
    expect(find.textContaining('storage connector'), findsOneWidget);
    expect(find.text('Retry now'), findsOneWidget);

    await tester.ensureVisible(find.text('Retry now'));
    await tester.tap(find.text('Retry now'));
    expect(retried?.id, 'r2');
  });

  testWidgets('filter chips show only failed runs', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleRunsPage(data: _data)));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Failed (1)'));
    await tester.tap(find.text('Failed (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Show details'), findsOneWidget);
    expect(find.text('Open chat'), findsNothing);
    expect(find.text('Failed (1)'), findsOneWidget);
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
          data: const V2ScheduleRunsData(
            status: V2ScheduleRunsStatus.error,
          ),
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

    expect(find.text('Schedule runs'), findsOneWidget);
    expect(find.text('95.8% success'), findsOneWidget);
    expect(find.text('TODAY — MAY 18'), findsOneWidget);
    expect(find.text('Open chat'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'survives 320 dp and 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        _smallPhone(tester);
        await tester.pumpWidget(
          _smallApp(const ScheduleRunsPage(data: _data), dark: dark),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // The two card actions must stay readable: at this width the row
        // layout squeezes each label to a few characters, so they stack.
        await tester.scrollUntilVisible(
          find.text('Open chat'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final openChat = tester.renderObject<RenderParagraph>(
          find.text('Open chat'),
        );
        // The test font is a square fallback, so the label still needs an
        // ellipsis there; what matters is that the button now owns the whole
        // card width instead of a ~52 dp sliver.
        expect(openChat.size.width, greaterThan(150));
        expect(
          tester.getTopLeft(find.text('View artifact')).dy,
          greaterThan(tester.getBottomLeft(find.text('Open chat')).dy),
        );
        expect(tester.takeException(), isNull);

        // Expand the failed run: the detail box and its actions are the
        // densest part of the card. The card starts below the fold at this
        // size, so scroll it into view first.
        await tester.scrollUntilVisible(
          find.text('Show details'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Show details'));
        await tester.pumpAndSettle();

        expect(find.text('What happened'), findsOneWidget);
        expect(tester.takeException(), isNull);

        // Filter chips and their empty state also have to survive.
        await tester.scrollUntilVisible(
          find.text('Failed (1)'),
          -160,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Failed (1)'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

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
