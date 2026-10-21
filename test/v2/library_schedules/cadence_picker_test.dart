import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/cadence_picker.dart';

/// Wednesday, 21 October 2026, 10:00 local. 9:00 has already passed today, so
/// the default weekday cadence next runs tomorrow.
final _now = DateTime(2026, 10, 21, 10, 0);

const _draft = V2CadenceDraft(
  frequency: V2CadenceFrequency.weekly,
  hour: 9,
  minute: 0,
  days: <int>{1, 2, 3, 4, 5},
  timezoneLabel: 'Asia/Kolkata (GMT +5:30)',
  timezoneShort: 'IST',
);

Widget _app(Widget child, {bool dark = false}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

bool _isEnabled(WidgetTester tester, Finder finder) {
  final data = tester.getSemantics(finder).getSemanticsData();
  return data.flagsCollection.isEnabled.toBoolOrNull() ?? true;
}

Finder _label(String label) => find.bySemanticsLabel(label).first;

void main() {
  group('rendering', () {
    testWidgets('renders the weekly cadence in light mode', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(CadencePicker(draft: _draft, now: _now)));
      await tester.pumpAndSettle();

      expect(find.text('Daily'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);

      expect(find.text('Run time'), findsOneWidget);
      expect(find.text('9:00 AM'), findsOneWidget);

      expect(find.text('REPEAT DAYS'), findsOneWidget);
      expect(find.text('Runs Mon – Fri'), findsOneWidget);
      expect(find.text('Runs on weekdays (Mon – Fri).'), findsOneWidget);

      expect(find.text('Timezone'), findsOneWidget);
      expect(find.text('Asia/Kolkata (GMT +5:30)'), findsOneWidget);
      expect(find.textContaining('Times use IST.'), findsOneWidget);

      expect(find.text('NEXT RUN'), findsOneWidget);
      expect(find.text('Tomorrow at 9:00 AM'), findsOneWidget);
      expect(find.text('Every weekday at 9:00 AM · IST'), findsOneWidget);
      expect(
        find.text('Runs in the cloud, even when your phone is off.'),
        findsOneWidget,
      );
    });

    testWidgets('renders the weekly cadence in dark mode', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(CadencePicker(draft: _draft, now: _now), dark: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('REPEAT DAYS'), findsOneWidget);
      expect(find.text('Tomorrow at 9:00 AM'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('daily hides weekday chips and updates the preview', (
      tester,
    ) async {
      _phone(tester);
      final changes = <V2CadenceDraft>[];
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft,
            now: _now,
            onChanged: changes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Daily'));
      await tester.pumpAndSettle();

      expect(changes.single.frequency, V2CadenceFrequency.daily);
      expect(find.text('REPEAT DAYS'), findsNothing);
      expect(find.text('Every day at 9:00 AM · IST'), findsOneWidget);
      expect(find.text('Tomorrow at 9:00 AM'), findsOneWidget);
    });

    testWidgets('an external draft reset updates the picker', (tester) async {
      _phone(tester);
      Widget build(V2CadenceDraft draft) =>
          _app(CadencePicker(draft: draft, now: _now));

      await tester.pumpWidget(build(_draft));
      await tester.pumpAndSettle();
      expect(find.text('Runs Mon – Fri'), findsOneWidget);

      await tester.pumpWidget(
        build(
          _draft.copyWith(
            frequency: V2CadenceFrequency.custom,
            customRule: '0 17 * * 5',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('cadence-custom-rule')),
      );
      expect(field.controller?.text, '0 17 * * 5');
      expect(find.text('Friday, 23 Oct at 5:00 PM'), findsOneWidget);
      expect(find.text('REPEAT DAYS'), findsNothing);
    });
  });

  group('weekly days', () {
    testWidgets('tapping a day reports it and rewrites the rule', (
      tester,
    ) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      final changes = <V2CadenceDraft>[];
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft,
            now: _now,
            onChanged: changes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Saturday'));
      await tester.pumpAndSettle();

      expect(changes.single.days, <int>{1, 2, 3, 4, 5, 6});
      expect(find.text('Runs 6 days a week'), findsOneWidget);
      expect(
        find.text(
          'Runs on Monday, Tuesday, Wednesday, Thursday, Friday and Saturday.',
        ),
        findsOneWidget,
      );

      // Sunday-only is the weekend.
      await tester.tap(find.bySemanticsLabel('Monday'));
      await tester.tap(find.bySemanticsLabel('Tuesday'));
      await tester.tap(find.bySemanticsLabel('Wednesday'));
      await tester.tap(find.bySemanticsLabel('Thursday'));
      await tester.tap(find.bySemanticsLabel('Friday'));
      await tester.tap(find.bySemanticsLabel('Sunday'));
      await tester.pumpAndSettle();

      expect(changes.last.days, <int>{6, 7});
      expect(find.text('Runs Sat – Sun'), findsOneWidget);
      expect(find.text('Every weekend at 9:00 AM · IST'), findsOneWidget);
      expect(find.text('Saturday, 24 Oct at 9:00 AM'), findsOneWidget);

      semantics.dispose();
    });

    testWidgets('an empty weekday set shows inline validation and recovers', (
      tester,
    ) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(days: const <int>{}),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pick at least one day for this to run.'), findsOneWidget);
      expect(find.text('Pick at least one day'), findsOneWidget);
      expect(find.text('Add the missing details'), findsOneWidget);
      expect(
        find.text('The next run appears once the cadence is complete.'),
        findsOneWidget,
      );
      expect(_isEnabled(tester, _label('Monday')), isTrue);

      await tester.tap(find.bySemanticsLabel('Monday'));
      await tester.pumpAndSettle();

      expect(find.text('Pick at least one day for this to run.'), findsNothing);
      expect(find.text('Every Monday at 9:00 AM · IST'), findsOneWidget);
      expect(find.text('Monday, 26 Oct at 9:00 AM'), findsOneWidget);

      semantics.dispose();
    });
  });

  group('custom cadence', () {
    testWidgets('requires a rule and reports what is typed', (tester) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      final changes = <V2CadenceDraft>[];
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft,
            now: _now,
            onChanged: changes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();

      expect(find.text('REPEAT DAYS'), findsNothing);
      expect(find.text('CUSTOM CADENCE'), findsOneWidget);
      expect(find.text('Describe when this should run.'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('Custom cadence rule')),
        findsOneWidget,
      );
      expect(changes.last.frequency, V2CadenceFrequency.custom);

      await tester.enterText(
        find.byKey(const ValueKey('cadence-custom-rule')),
        '0 18 * * 1',
      );
      await tester.pumpAndSettle();

      expect(find.text('Describe when this should run.'), findsNothing);
      expect(changes.last.customRule, '0 18 * * 1');
      expect(find.text('Monday, 26 Oct at 6:00 PM'), findsOneWidget);
      expect(find.text('Sends cron 0 18 * * 1'), findsOneWidget);

      semantics.dispose();
    });

    testWidgets('plain English is rejected with a cron example', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: 'Every other Monday at 6 PM',
            ),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Use a cron expression or RRULE, for example 0 9 * * 1-5.'),
        findsOneWidget,
      );
      expect(find.text('Add the missing details'), findsOneWidget);
    });

    testWidgets('an out-of-range cron field is rejected', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: '0 25 * * 1',
            ),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('That is not a valid cron or RRULE. Check the fields.'),
        findsOneWidget,
      );
    });

    testWidgets('a valid RRULE produces its cron equivalent', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: 'FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=7;BYMINUTE=30',
            ),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Sends RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=7;BYMINUTE=30',
        ),
        findsOneWidget,
      );
      expect(find.text('Add the missing details'), findsNothing);
    });

    testWidgets('a too-short custom rule is rejected', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: 'ab',
            ),
            now: _now,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Add a little more detail to the rule.'), findsOneWidget);
    });

    testWidgets('a sample chip fills the custom rule', (tester) async {
      _phone(tester);
      final changes = <V2CadenceDraft>[];
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft.copyWith(frequency: V2CadenceFrequency.custom),
            now: _now,
            onChanged: changes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Every Monday'));
      await tester.pumpAndSettle();

      expect(changes.last.customRule, '0 18 * * 1');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('cadence-custom-rule')),
      );
      expect(field.controller?.text, '0 18 * * 1');
    });
  });

  group('time and timezone', () {
    testWidgets('the host can own the time picker', (tester) async {
      _phone(tester);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          CadencePicker(draft: _draft, now: _now, onTimeTap: () => taps++),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run time'));
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(find.byType(TimePickerDialog), findsNothing);
    });

    testWidgets('without a host the standard time picker opens', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(_app(CadencePicker(draft: _draft, now: _now)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Run time'));
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsNothing);
    });

    testWidgets('the timezone note opens the timezone picker', (tester) async {
      _phone(tester);
      var taps = 0;
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft,
            now: _now,
            onTimezoneTap: () => taps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('a static timezone note is not announced as a button', (
      tester,
    ) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_app(CadencePicker(draft: _draft, now: _now)));
      await tester.pumpAndSettle();

      final note = _label('Timezone, Asia/Kolkata (GMT +5:30).');
      expect(note, findsWidgets);
      final data = tester.getSemantics(note).getSemanticsData();
      expect(data.hasAction(SemanticsAction.tap), isFalse);

      semantics.dispose();
    });
  });

  group('read only', () {
    testWidgets('announces read only and blocks every change', (tester) async {
      _phone(tester);
      final semantics = tester.ensureSemantics();
      var timeTaps = 0;
      var timezoneTaps = 0;
      final changes = <V2CadenceDraft>[];
      await tester.pumpWidget(
        _app(
          CadencePicker(
            draft: _draft,
            now: _now,
            enabled: false,
            onChanged: changes.add,
            onTimeTap: () => timeTaps++,
            onTimezoneTap: () => timezoneTaps++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Cadence is read only.'), findsOneWidget);
      expect(
        _isEnabled(tester, _label('Run time, 9:00 AM. Read only.')),
        isFalse,
      );
      expect(_isEnabled(tester, _label('Daily')), isFalse);
      expect(_isEnabled(tester, _label('Monday')), isFalse);

      await tester.tap(find.text('Run time'));
      await tester.tap(find.text('Daily'));
      await tester.tap(find.text('Timezone'));
      await tester.pumpAndSettle();

      expect(timeTaps, 0);
      expect(timezoneTaps, 0);
      expect(changes, isEmpty);
      expect(find.byType(TimePickerDialog), findsNothing);

      semantics.dispose();
    });
  });

  for (final dark in [false, true]) {
    testWidgets(
      'fits 320 dp at 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: CadencePicker(
                    draft: _draft,
                    now: _now,
                    onTimezoneTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // The segmented control stacks, so no label is truncated.
        for (final label in ['Daily', 'Weekly', 'Custom']) {
          final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '$label must stay readable at 320 dp / 200% text',
          );
        }

        // Weekday chips wrap instead of scrolling off screen.
        for (var day = 1; day <= 7; day++) {
          final chip = find.byKey(ValueKey('cadence-day-$day'));
          expect(chip, findsOneWidget);
          expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
        }

        expect(find.text('Tomorrow at 9:00 AM'), findsOneWidget);
        expect(find.text('Runs in the cloud, even when your phone is off.'), findsOneWidget);

        // The custom card holds a field and sample chips; both must lay out.
        await tester.tap(find.text('Custom'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('CUSTOM CADENCE'), findsOneWidget);
        final sample = find.byWidgetPredicate(
          (widget) => widget is OChip && widget.label == 'Every Monday',
        );
        expect(tester.getSize(sample).height, greaterThanOrEqualTo(48));
      },
    );
  }

  group('cadence helpers', () {
    test('formats times on a 12-hour clock', () {
      expect(formatCadenceTime(0, 0), '12:00 AM');
      expect(formatCadenceTime(9, 5), '9:05 AM');
      expect(formatCadenceTime(12, 0), '12:00 PM');
      expect(formatCadenceTime(23, 59), '11:59 PM');
    });

    test('nextRunAfter rolls daily cadences over midnight', () {
      const daily = V2CadenceDraft(
        frequency: V2CadenceFrequency.daily,
        hour: 9,
      );
      expect(
        daily.nextRunAfter(DateTime(2026, 10, 21, 8, 0)),
        DateTime(2026, 10, 21, 9, 0),
      );
      expect(
        daily.nextRunAfter(DateTime(2026, 10, 21, 9, 0)),
        DateTime(2026, 10, 22, 9, 0),
      );
      expect(
        daily.nextRunAfter(DateTime(2026, 10, 21, 10, 0)),
        DateTime(2026, 10, 22, 9, 0),
      );
    });

    test('nextRunAfter skips days that are not picked', () {
      const weekdays = V2CadenceDraft(
        frequency: V2CadenceFrequency.weekly,
        hour: 9,
        days: <int>{1, 2, 3, 4, 5},
      );
      // Wednesday 10:00 → Thursday.
      expect(
        weekdays.nextRunAfter(DateTime(2026, 10, 21, 10, 0)),
        DateTime(2026, 10, 22, 9, 0),
      );
      // Friday after 9:00 → Monday.
      expect(
        weekdays.nextRunAfter(DateTime(2026, 10, 23, 10, 0)),
        DateTime(2026, 10, 26, 9, 0),
      );

      const weekends = V2CadenceDraft(
        frequency: V2CadenceFrequency.weekly,
        hour: 9,
        days: <int>{6, 7},
      );
      expect(
        weekends.nextRunAfter(DateTime(2026, 10, 21, 10, 0)),
        DateTime(2026, 10, 24, 9, 0),
      );

      const empty = V2CadenceDraft(
        frequency: V2CadenceFrequency.weekly,
        days: <int>{},
      );
      expect(empty.nextRunAfter(_now), isNull);

      const custom = V2CadenceDraft(
        frequency: V2CadenceFrequency.custom,
        customRule: 'Every other Monday at 6 PM',
      );
      expect(custom.nextRunAfter(_now), isNull);
    });

    test('describes the cadence in plain English', () {
      expect(describeCadence(_draft), 'Every weekday at 9:00 AM');
      expect(
        describeCadence(_draft.copyWith(frequency: V2CadenceFrequency.daily)),
        'Every day at 9:00 AM',
      );
      expect(
        describeCadence(_draft.copyWith(days: const <int>{6, 7})),
        'Every weekend at 9:00 AM',
      );
      expect(
        describeCadence(_draft.copyWith(days: const <int>{1, 3, 4})),
        'Every Monday, Wednesday and Thursday at 9:00 AM',
      );
      expect(
        describeCadence(_draft.copyWith(days: const <int>{7})),
        'Every Sunday at 9:00 AM',
      );
      expect(
        describeCadence(_draft.copyWith(days: const <int>{})),
        'No days picked yet',
      );
      expect(
        describeCadence(
          _draft.copyWith(
            frequency: V2CadenceFrequency.custom,
            customRule: '  Every other Monday  ',
          ),
        ),
        'Custom: Every other Monday',
      );
      expect(
        describeCadence(_draft.copyWith(frequency: V2CadenceFrequency.custom)),
        'Custom schedule',
      );
    });

    test('describes the next run relative to now', () {
      expect(describeNextRun(_draft, _now), 'Tomorrow at 9:00 AM');
      expect(
        describeNextRun(
          _draft.copyWith(frequency: V2CadenceFrequency.daily),
          DateTime(2026, 10, 21, 8, 0),
        ),
        'Today at 9:00 AM',
      );
      expect(
        describeNextRun(_draft.copyWith(days: const <int>{6, 7}), _now),
        'Saturday, 24 Oct at 9:00 AM',
      );
      expect(
        describeNextRun(
          _draft.copyWith(frequency: V2CadenceFrequency.custom),
          _now,
        ),
        isNull,
      );
    });

    test('validation only asks for what is missing', () {
      expect(_draft.validationError, isNull);
      expect(
        _draft.copyWith(days: const <int>{}).validationError,
        'Pick at least one day for this to run.',
      );
      expect(
        _draft.copyWith(frequency: V2CadenceFrequency.custom).validationError,
        'Describe when this should run.',
      );
      expect(
        _draft
            .copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: 'ab',
            )
            .validationError,
        'Add a little more detail to the rule.',
      );
      expect(
        _draft
            .copyWith(
              frequency: V2CadenceFrequency.custom,
              customRule: 'x' * 121,
            )
            .validationError,
        'Keep the rule under 120 characters.',
      );
    });

    test('copyWith keeps drafts immutable and comparable', () {
      final copy = _draft.copyWith(days: const <int>{3});
      expect(copy, isNot(_draft));
      expect(copy.days, <int>{3});
      expect(
        () => copy.days.add(4),
        throwsUnsupportedError,
        reason: 'a copy must not expose a mutable day set',
      );
      expect(_draft.copyWith(), _draft);
    });
  });
}
