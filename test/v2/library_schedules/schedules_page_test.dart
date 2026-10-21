import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_page.dart';

const _schedules = <V2ScheduleItem>[
  V2ScheduleItem(
    id: 's1',
    title: 'Morning AI news briefing',
    description: 'Browses 5 top tech sites and writes a short summary.',
    rule: 'Every weekday at 9:00 AM',
    nextRun: 'Tomorrow, 9:00 AM',
  ),
  V2ScheduleItem(
    id: 's2',
    title: 'Nightly website check',
    description: 'Captures scores and saves a report.',
    rule: 'Daily at 2:00 AM',
    enabled: false,
  ),
  V2ScheduleItem(
    id: 's3',
    title: 'Backup Studio files',
    description: 'Packages a daily snapshot.',
    rule: 'Every 6 hours',
    lastRunFailed: true,
    failureMessage: 'Last run failed · Connector disconnected',
  ),
];

Widget _app(Widget home, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: home,
);

/// Fails when any laid-out text paints past the horizontal edges, which is the
/// usual symptom of a squeezed row even when nothing throws.
void _expectNoTextPastEdges(WidgetTester tester, double width) {
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final text = (element.widget as Text).data ?? '';
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '"$text" paints past the left edge',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(width + 0.5),
      reason: '"$text" paints past the right edge',
    );
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('renders schedules in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const SchedulesPage(data: V2SchedulesData(schedules: _schedules))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedules'), findsOneWidget);
    expect(find.text('Ovid can work while you sleep'), findsOneWidget);
    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('Every weekday at 9:00 AM'), findsOneWidget);
    expect(find.text('Tomorrow, 9:00 AM'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('Action needed'), findsOneWidget);
  });

  testWidgets('renders schedules in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const SchedulesPage(data: V2SchedulesData(schedules: _schedules)),
        dark: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ovid can work while you sleep'), findsOneWidget);
    expect(find.text('Morning AI news briefing'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('empty state creates a schedule', (tester) async {
    _phone(tester);
    var created = 0;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(status: V2SchedulesStatus.empty),
          onCreate: () => created++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No schedules yet'), findsOneWidget);
    await tester.tap(find.text('Create a schedule'));
    expect(created, 1);
  });

  testWidgets('tapping a card opens the schedule', (tester) async {
    _phone(tester);
    V2ScheduleItem? opened;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onScheduleTap: (schedule) => opened = schedule,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Morning AI news briefing'));
    expect(opened?.id, 's1');
  });

  testWidgets('toggle reports the new enabled state', (tester) async {
    _phone(tester);
    V2ScheduleItem? toggled;
    bool? value;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onToggle: (schedule, enabled) {
            toggled = schedule;
            value = enabled;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(toggled?.id, 's1');
    expect(value, isFalse);
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200% text (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? OTheme.dark() : OTheme.light(),
          home: const MediaQuery(
            data: MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: SchedulesPage(data: V2SchedulesData(schedules: _schedules)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Schedules'), findsOneWidget);
      expect(find.text('Ovid can work while you sleep'), findsOneWidget);
      _expectNoTextPastEdges(tester, 320);

      // Walk the whole list: a lazy ListView only lays out what is visible, so
      // overflow in a lower card would otherwise go unnoticed.
      final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
      for (var step = 1; step <= 24; step++) {
        state.position.jumpTo((step * 200).toDouble());
        await tester.pump();
        expect(tester.takeException(), isNull);
        _expectNoTextPastEdges(tester, 320);
        if (state.position.pixels >= state.position.maxScrollExtent) break;
      }

      state.position.jumpTo(0);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Morning AI news briefing'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Morning AI news briefing'), findsOneWidget);
    });
  }

  testWidgets('shows the skeleton while loading', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const SchedulesPage(data: V2SchedulesData(status: V2SchedulesStatus.loading))),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('No schedules yet'), findsNothing);
  });

  testWidgets('error state retries', (tester) async {
    _phone(tester);
    var retried = 0;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(status: V2SchedulesStatus.error),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('We could not load your schedules. Check your connection and try again.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('empty and error states fit 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in [
      V2SchedulesStatus.empty,
      V2SchedulesStatus.error,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2),
            ),
            child: SchedulesPage(
              data: V2SchedulesData(status: status),
              onCreate: () {},
              onRetry: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('switch announces its state and card is labelled', (tester) async {
    _phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onToggle: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byType(Switch).first),
      isSemantics(
        label: 'Turn Morning AI news briefing on or off',
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasToggledState: true,
        isToggled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('failed schedule retry fires its callback', (tester) async {
    _phone(tester);
    V2ScheduleItem? retried;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onRetryRun: (schedule) => retried = schedule,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OButton, 'Retry'));
    expect(retried?.id, 's3');
  });
}
