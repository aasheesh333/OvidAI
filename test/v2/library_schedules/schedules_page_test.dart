import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_screen.dart';
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
  ),
];

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

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
  testWidgets('renders one header and minimal schedule cards', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const SchedulesPage(
          data: V2SchedulesData(schedules: _schedules),
          onCreate: _ignoreVoid,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedules'), findsOneWidget);
    expect(find.bySemanticsLabel('New schedule'), findsOneWidget);

    expect(
      find.text('Browses 5 top tech sites and writes a short summary.'),
      findsOneWidget,
    );
    // Cadence and next run share one line.
    expect(
      find.text('Every weekday at 9:00 AM · Tomorrow, 9:00 AM'),
      findsOneWidget,
    );
    expect(find.text('Next Tomorrow, 9:00 AM'), findsNothing);

    // Removed copy: explainer, section headers, run counts and status lines.
    expect(find.text('Ovid can work while you sleep'), findsNothing);
    expect(find.text('ACTIVE SCHEDULES (2)'), findsNothing);
    expect(find.text('PAUSED (1)'), findsNothing);
    expect(find.text('12 of 30 runs'), findsNothing);
    expect(find.text('From AI news research'), findsNothing);
    expect(find.text('Created May 12, 2026'), findsNothing);
    expect(find.text('Action needed'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('renders in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const SchedulesPage(data: V2SchedulesData(schedules: _schedules)),
        dark: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedules'), findsOneWidget);
    expect(
      find.text('Browses 5 top tech sites and writes a short summary.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('one summary line counts schedules and the next run', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: V2SchedulesData(
            now: DateTime(2026, 10, 22, 9),
            schedules: [
              V2ScheduleItem(
                id: 'late',
                title: 'Evening report',
                description: 'Evening report.',
                rule: 'Daily at 5:00 PM',
                nextRunAt: DateTime(2026, 10, 22, 17),
              ),
              V2ScheduleItem(
                id: 'off',
                title: 'Aardvark check',
                description: 'Aardvark check.',
                rule: 'Daily at 8:00 AM',
                enabled: false,
                nextRunAt: DateTime(2026, 10, 22, 10),
              ),
              V2ScheduleItem(
                id: 'soon',
                title: 'Midday digest',
                description: 'Midday digest.',
                rule: 'Daily at 1:00 PM',
                nextRunAt: DateTime(2026, 10, 22, 13),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Two enabled rows; the paused row's earlier timestamp never wins.
    expect(find.text('3 schedules · next in 4h'), findsOneWidget);

    // Next to run first, then the later one, then the paused row.
    final soon = tester.getTopLeft(find.text('Midday digest.')).dy;
    final late = tester.getTopLeft(find.text('Evening report.')).dy;
    final off = tester.getTopLeft(find.text('Aardvark check.')).dy;
    expect(soon, lessThan(late));
    expect(late, lessThan(off));
  });

  testWidgets('the summary says all paused when nothing is enabled', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: V2SchedulesData(
            now: DateTime(2026, 10, 22, 9),
            schedules: [
              for (final id in ['a', 'b'])
                V2ScheduleItem(
                  id: id,
                  title: 'Paused $id',
                  description: 'Paused $id.',
                  rule: 'Daily at 9:00 AM',
                  enabled: false,
                  nextRunAt: DateTime(2026, 10, 22, 10),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 schedules · all paused'), findsOneWidget);
  });

  testWidgets('the header add action creates a schedule', (tester) async {
    _phone(tester);
    var created = 0;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onCreate: () => created++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('New schedule'));
    expect(created, 1);
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
    expect(find.text('Set a task to run on its own.'), findsOneWidget);
    await tester.tap(find.text('New schedule').last);
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

    await tester.tap(
      find.text('Browses 5 top tech sites and writes a short summary.'),
    );
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

    await tester.tap(
      _switchFor('Browses 5 top tech sites and writes a short summary.'),
    );
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
      _expectNoTextPastEdges(tester, 320);

      // Walk the whole list: a lazy ListView only lays out what is visible, so
      // overflow in a lower card would otherwise go unnoticed.
      final state = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      for (var step = 1; step <= 24; step++) {
        state.position.jumpTo((step * 200).toDouble());
        await tester.pump();
        expect(tester.takeException(), isNull);
        _expectNoTextPastEdges(tester, 320);
        if (state.position.pixels >= state.position.maxScrollExtent) break;
      }

      state.position.jumpTo(0);
      await tester.pump();
      expect(
        find.text('Browses 5 top tech sites and writes a short summary.'),
        findsOneWidget,
      );
    });
  }

  testWidgets('the list stays single column and caps at 720', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(const SchedulesPage(data: V2SchedulesData(schedules: _schedules))),
    );
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(
      find.text('Browses 5 top tech sites and writes a short summary.'),
    );
    final second = tester.getTopLeft(
      find.text('Captures scores and saves a report.'),
    );
    expect(second.dx, closeTo(first.dx, 1));
    expect(second.dy, greaterThan(first.dy));

    final card = tester.getSize(
      find
          .ancestor(
            of: find.text(
              'Browses 5 top tech sites and writes a short summary.',
            ),
            matching: find.byType(OCard),
          )
          .first,
    );
    expect(card.width, lessThanOrEqualTo(720));
  });

  testWidgets('shows the skeleton while loading', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const SchedulesPage(
          data: V2SchedulesData(status: V2SchedulesStatus.loading),
        ),
      ),
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

    expect(
      find.text(
        'We could not load your schedules. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('empty and error states fit 320 dp at 200% text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in [V2SchedulesStatus.empty, V2SchedulesStatus.error]) {
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

  testWidgets('switch announces its state and card is labelled', (
    tester,
  ) async {
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
      tester.getSemantics(
        _switchFor('Browses 5 top tech sites and writes a short summary.'),
      ),
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

  testWidgets('card menu holds edit, run now and delete', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onEdit: _ignore,
          onToggle: _ignoreToggle,
          onRunNow: _ignore,
          onDelete: _ignore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_menuButton('Morning AI news briefing'));
    await tester.pumpAndSettle();

    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Run now'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    // The card's switch owns pausing; the menu does not repeat it.
    expect(find.text('Pause'), findsNothing);
    expect(find.text('Resume'), findsNothing);
  });

  testWidgets('a menu without handlers is not offered', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const SchedulesPage(
          data: V2SchedulesData(schedules: _schedules),
          onToggle: _ignoreToggle,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_menuButton('Morning AI news briefing'), findsNothing);
  });

  testWidgets('card menu runs a schedule now', (tester) async {
    _phone(tester);
    V2ScheduleItem? ran;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onRunNow: (schedule) => ran = schedule,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_menuButton('Morning AI news briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run now'));
    await tester.pumpAndSettle();

    expect(ran?.id, 's1');
  });

  testWidgets('card menu edits and deletes', (tester) async {
    _phone(tester);
    V2ScheduleItem? edited;
    V2ScheduleItem? deleted;
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onEdit: (schedule) => edited = schedule,
          onDelete: (schedule) => deleted = schedule,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(_menuButton('Morning AI news briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(edited?.id, 's1');

    await tester.tap(_menuButton('Morning AI news briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Deleting is destructive: the dialog must come first.
    expect(deleted, isNull);
    expect(find.text('Delete “Morning AI news briefing”?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Keep'));
    await tester.pumpAndSettle();
    expect(deleted, isNull, reason: 'Keep must not delete');

    await tester.tap(_menuButton('Morning AI news briefing'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(deleted?.id, 's1');
  });

  for (final dark in [false, true]) {
    testWidgets(
      'menu survives 320 dp and 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
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
              child: SchedulesPage(
                data: V2SchedulesData(schedules: _schedules),
                onEdit: _ignore,
                onToggle: _ignoreToggle,
                onRunNow: _ignore,
                onDelete: _ignore,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final menu = _menuButton('Morning AI news briefing');
        var guard = 0;
        while (menu.evaluate().isEmpty && guard < 20) {
          await tester.dragFrom(const Offset(314, 320), const Offset(0, -240));
          await tester.pumpAndSettle();
          guard++;
        }
        await tester.ensureVisible(menu);
        await tester.pumpAndSettle();
        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Run now'), findsOneWidget);
        expect(find.text('Delete'), findsOneWidget);
      },
    );
  }

  testWidgets('a row announces its prompt, cadence, next run and pause', (
    tester,
  ) async {
    _phone(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        SchedulesPage(
          data: const V2SchedulesData(schedules: _schedules),
          onScheduleTap: _ignore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        RegExp(
          r'^Browses 5 top tech sites and writes a short summary\. '
          r'Every weekday at 9:00 AM\. Next run, Tomorrow, 9:00 AM',
        ),
      ),
      findsOneWidget,
    );
    // The paused row says so instead of leaving the state to the switch alone.
    expect(
      find.bySemanticsLabel(
        RegExp(
          r'^Captures scores and saves a report\. Daily at 2:00 AM\. '
          r'Paused',
        ),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets(
      'centres and caps the list from 600 to 1280 (${dark ? 'dark' : 'light'})',
      (tester) async {
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
                  child: const SchedulesPage(
                    data: V2SchedulesData(schedules: _schedules),
                  ),
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
              reason: '$reason: the list is wider than its band cap',
            );
            expect(
              left,
              closeTo((width - size.width) / 2, 1),
              reason: '$reason: the list is not centred',
            );
          }
        }
      },
    );
  }
}

void _ignoreVoid() {}

void _ignore(V2ScheduleItem item) {}

void _ignoreToggle(V2ScheduleItem item, bool enabled) {}

Finder _menuButton(String title) => find.byWidgetPredicate(
  (widget) =>
      widget is OIconButton &&
      widget.semanticLabel == 'More options for $title',
);

/// The switch inside the card whose prompt is [prompt]. The list is ordered by
/// next run, so a card is addressed by its content rather than by position.
Finder _switchFor(String prompt) => find.descendant(
  of: find
      .ancestor(of: find.text(prompt), matching: find.byType(OCard))
      .first,
  matching: find.byType(Switch),
);
