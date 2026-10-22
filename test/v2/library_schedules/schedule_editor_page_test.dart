import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/cadence_picker.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_editor_page.dart';

const _data = V2ScheduleEditorData(
  prompt:
      'Check top Product Hunt launches every morning, summarize key features, and save a markdown artifact.',
  frequency: V2ScheduleFrequency.weekly,
  timeLabel: '9:00 AM',
  days: <int>{1, 2, 3, 4, 5},
  timezoneLabel: 'Asia/Kolkata (GMT +5:30)',
  timezoneShort: 'IST',
);

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

void _noopSave(V2ScheduleDraft draft) {}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  // The body is a lazy ListView: rows below the fold are not built yet, and the
  // scroll extent is only an estimate until they are. Drag from the right edge
  // so the gesture lands on the list and not on a text field, and keep dragging
  // until the row is built and can be brought fully on screen.
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  var guard = 0;
  while (finder.evaluate().isEmpty && guard < 40) {
    await tester.dragFrom(
      Offset(size.width - 6, size.height / 2),
      const Offset(0, -240),
    );
    await tester.pumpAndSettle();
    guard++;
  }
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('editor is prompt, cadence, time and one save', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Prompt'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);

    // The description, source-session, end-date and notify fields are gone.
    expect(find.text('Description'), findsNothing);
    expect(find.text('Source session'), findsNothing);
    expect(find.text('End date'), findsNothing);
    expect(find.text('Notify me when finished'), findsNothing);
    expect(find.text('Task prompt'), findsNothing);
    expect(find.text('Frequency'), findsNothing);
    expect(find.byIcon(Icons.auto_fix_high_rounded), findsNothing);

    await _scrollTo(tester, find.text('Run time'));
    expect(find.text('Run time'), findsOneWidget);

    await _scrollTo(tester, find.text('Save'));
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ScheduleEditorPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing schedule offers a create action', (tester) async {
    _phone(tester);
    var created = 0;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: const V2ScheduleEditorData(
            status: V2ScheduleEditorStatus.missing,
          ),
          onCreateNew: () => created++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedule not found'), findsOneWidget);
    await tester.tap(find.text('New schedule'));
    expect(created, 1);
  });

  testWidgets('error state shows the message and retries', (tester) async {
    _phone(tester);
    var retried = 0;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: const V2ScheduleEditorData(
            status: V2ScheduleEditorStatus.error,
          ),
          onRetry: () => retried++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'We could not open this schedule. Check your connection and try again.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('loading state shows the skeleton', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(
        const ScheduleEditorPage(
          data: V2ScheduleEditorData(status: V2ScheduleEditorStatus.loading),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Prompt'), findsNothing);
  });

  testWidgets('saving reports the draft', (tester) async {
    _phone(tester);
    V2ScheduleDraft? saved;
    await tester.pumpWidget(
      _app(ScheduleEditorPage(data: _data, onSave: (draft) => saved = draft)),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save'));
    await tester.tap(find.text('Save'));

    expect(saved, isNotNull);
    expect(saved!.prompt, contains('Product Hunt'));
    expect(saved!.frequency, V2ScheduleFrequency.weekly);
    expect(saved!.days, <int>{1, 2, 3, 4, 5});
  });

  testWidgets('the cadence section is the shared picker', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byType(CadencePicker), findsOneWidget);
    expect(find.text('REPEAT DAYS'), findsOneWidget);
  });

  testWidgets('cadence changes report frequency and day callbacks', (
    tester,
  ) async {
    _phone(tester);
    final frequencies = <V2ScheduleFrequency>[];
    final days = <int>[];
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: _data,
          onFrequencyChanged: frequencies.add,
          onDayToggle: days.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();
    expect(frequencies, <V2ScheduleFrequency>[V2ScheduleFrequency.daily]);

    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.byKey(const ValueKey('cadence-day-3')));
    await tester.tap(find.byKey(const ValueKey('cadence-day-3')));
    await tester.pumpAndSettle();
    expect(days, <int>[3]);
  });

  testWidgets('the cadence time row defers to the host picker', (tester) async {
    _phone(tester);
    var taps = 0;
    await tester.pumpWidget(
      _app(ScheduleEditorPage(data: _data, onTimeTap: () => taps++)),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Run time'));
    await tester.tap(find.text('Run time'));
    expect(taps, 1);
  });

  testWidgets('a custom cadence must be a cron or RRULE before saving', (
    tester,
  ) async {
    _phone(tester);
    V2ScheduleDraft? saved;
    await tester.pumpWidget(
      _app(ScheduleEditorPage(data: _data, onSave: (draft) => saved = draft)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNull, reason: 'an empty custom rule must not save');

    final rule = find.byKey(const ValueKey('cadence-custom-rule'));
    await _scrollTo(tester, rule);
    await tester.enterText(rule, '0 18 * * 1');
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved!.cron, '0 18 * * 1');
    expect(saved!.cadence!.frequency, V2CadenceFrequency.custom);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'editor fits 320 dp at 200% text (${dark ? 'dark' : 'light'})',
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
              child: ScheduleEditorPage(data: _data),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Walk the whole body so lazily built rows lay out at this size too.
        final position = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ListView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        var guard = 0;
        while (position.pixels < position.maxScrollExtent && guard < 60) {
          final next = position.pixels + 200;
          position.jumpTo(
            next > position.maxScrollExtent ? position.maxScrollExtent : next,
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          guard++;
        }

        expect(find.text('Save'), findsOneWidget);
      },
    );
  }

  testWidgets('narrow layout keeps the run time readable', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: ScheduleEditorPage(data: _data),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('9:00 AM'));
    final time = tester.renderObject<RenderParagraph>(find.text('9:00 AM'));
    expect(
      time.didExceedMaxLines,
      isFalse,
      reason: 'the run time must not be truncated at 320 dp / 200% text',
    );
  });

  testWidgets('an empty prompt is rejected inline and blocks the save', (
    tester,
  ) async {
    _phone(tester);
    var saves = 0;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: const V2ScheduleEditorData(prompt: ''),
          onSave: (_) => saves++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saves, 0, reason: 'the prompt is required');

    // The error sits under the prompt card, above the save button, so scroll
    // back up until the (lazy) row is built again.
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    var guard = 0;
    while (find.text('Write a prompt.').evaluate().isEmpty && guard < 40) {
      await tester.dragFrom(
        Offset(size.width - 6, size.height / 2),
        const Offset(0, 240),
      );
      await tester.pumpAndSettle();
      guard++;
    }
    expect(find.text('Write a prompt.'), findsOneWidget);
  });

  testWidgets('every control meets the 48 dp target and has a label', (
    tester,
  ) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: _data,
          onSave: _noopSave,
          onMore: () {},
          onTimeTap: () {},
          onDayToggle: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> check(String label, {double minHeight = 0}) async {
      final base = find.bySemanticsLabel(label);
      await _scrollTo(tester, base);
      expect(base, findsWidgets, reason: '$label must be announced');
      if (minHeight > 0) {
        expect(
          tester.getSize(base.first).height,
          greaterThanOrEqualTo(minHeight),
          reason: '$label must meet the touch target',
        );
      }
    }

    await check('More options', minHeight: 48);
    await check('Daily', minHeight: 48);
    await check('Monday', minHeight: 48);

    semantics.dispose();
  });
}
