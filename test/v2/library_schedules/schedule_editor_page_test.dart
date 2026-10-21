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
  description: 'A daily roundup of the launches worth a look.',
  frequency: V2ScheduleFrequency.weekly,
  timeLabel: '9:00 AM',
  days: <int>{1, 2, 3, 4, 5},
  timezoneLabel: 'Asia/Kolkata (GMT +5:30)',
  timezoneShort: 'IST',
  sourceSessionTitle: 'AI news research',
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
  testWidgets('renders the editor in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('Schedule editor'), findsOneWidget);
    expect(find.text('Task prompt'), findsOneWidget);
    expect(find.text('Description'), findsOneWidget);
    expect(
      find.text('A daily roundup of the launches worth a look.'),
      findsOneWidget,
    );
    expect(find.text('Source session'), findsOneWidget);
    expect(find.text('AI news research'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);

    await _scrollTo(tester, find.text('Run time'));
    expect(find.text('Run time'), findsOneWidget);

    await _scrollTo(tester, find.text('Notify me when finished'));
    expect(find.text('Timezone'), findsOneWidget);
    expect(find.text('Notify me when finished'), findsOneWidget);

    await _scrollTo(tester, find.text('Every weekday at 9:00 AM · IST'));
    expect(find.text('Every weekday at 9:00 AM · IST'), findsOneWidget);
  });

  testWidgets('renders the editor in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ScheduleEditorPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedule editor'), findsOneWidget);
    expect(find.text('Frequency'), findsOneWidget);

    await _scrollTo(tester, find.text('Every weekday at 9:00 AM · IST'));
    expect(find.text('Every weekday at 9:00 AM · IST'), findsOneWidget);
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
    await tester.tap(find.text('Create a schedule'));
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
    expect(find.text('Task prompt'), findsNothing);
  });

  testWidgets('saving reports the draft', (tester) async {
    _phone(tester);
    V2ScheduleDraft? saved;
    await tester.pumpWidget(
      _app(ScheduleEditorPage(data: _data, onSave: (draft) => saved = draft)),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save schedule'));
    await tester.tap(find.text('Save schedule'));

    expect(saved, isNotNull);
    expect(saved!.prompt, contains('Product Hunt'));
    expect(saved!.description, 'A daily roundup of the launches worth a look.');
    expect(saved!.frequency, V2ScheduleFrequency.weekly);
    expect(saved!.days, <int>{1, 2, 3, 4, 5});
    expect(saved!.notify, isTrue);
  });

  testWidgets('the frequency and time section is the shared cadence picker', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.byType(CadencePicker), findsOneWidget);
    expect(find.text('NEXT RUN'), findsOneWidget);
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

  testWidgets('a custom cadence must be described before saving', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(ScheduleEditorPage(data: _data, onSave: _noopSave)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save schedule'));
    expect(
      tester
          .widget<OButton>(find.widgetWithText(OButton, 'Save schedule'))
          .onPressed,
      isNull,
    );

    final rule = find.byKey(const ValueKey('cadence-custom-rule'));
    await _scrollTo(tester, rule);
    await tester.enterText(rule, 'Every other Monday at 6 PM');
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save schedule'));
    expect(
      tester
          .widget<OButton>(find.widgetWithText(OButton, 'Save schedule'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('frequency segment updates the preview sentence', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();

    expect(find.text('Every day at 9:00 AM · IST'), findsOneWidget);
    expect(find.text('REPEAT DAYS'), findsNothing);
    expect(find.textContaining('Every weekday'), findsNothing);
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

        expect(find.text('Save schedule'), findsOneWidget);
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

  testWidgets('save is disabled and announced when the prompt is empty', (
    tester,
  ) async {
    _phone(tester);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const ScheduleEditorPage(
          data: V2ScheduleEditorData(prompt: ''),
          onSave: _noopSave,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Save schedule'));
    final save = tester.getSemantics(find.text('Save schedule'));
    expect(
      save.getSemanticsData().flagsCollection.isEnabled.toBoolOrNull(),
      isFalse,
    );

    semantics.dispose();
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
          onImprovePrompt: () {},
          onTimeTap: () {},
          onTimezoneTap: () {},
          onDayToggle: (_) {},
          onNotifyChanged: (_) {},
          onOpenSourceSession: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> check(
      String label, {
      double minHeight = 0,
      bool tappable = false,
      bool toggled = false,
    }) async {
      final finder = find.bySemanticsLabel(label).first;
      await _scrollTo(tester, finder);
      expect(finder, findsWidgets, reason: '$label must be announced');
      if (minHeight > 0) {
        expect(
          tester.getSize(finder).height,
          greaterThanOrEqualTo(minHeight),
          reason: '$label must meet the touch target',
        );
      }
      if (tappable || toggled) {
        final data = tester.getSemantics(finder).getSemanticsData();
        if (tappable) {
          expect(
            data.hasAction(SemanticsAction.tap),
            isTrue,
            reason: '$label must be tappable from a screen reader',
          );
        }
        if (toggled) {
          expect(
            data.flagsCollection.isToggled.toBoolOrNull(),
            isTrue,
            reason: '$label must announce its on state',
          );
        }
      }
    }

    // App bar and the prompt card stay reachable without scrolling.
    await check('More options', minHeight: 48);
    await check('Improve prompt', minHeight: 48);
    await check('Source session, AI news research. Open chat.', tappable: true);
    await check('Daily', minHeight: 48, tappable: true);
    await check('Run time, 9:00 AM. Change.');
    await check('Monday', minHeight: 48, tappable: true);
    await check('Timezone, Asia/Kolkata (GMT +5:30). Change.');
    await check(
      'Notify me when finished. Send a push alert with a short summary.',
      tappable: true,
      toggled: true,
    );

    semantics.dispose();
  });

  testWidgets('notification toggle reports the new value', (tester) async {
    _phone(tester);
    bool? notify;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: _data,
          onNotifyChanged: (value) => notify = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.byType(Switch));
    await tester.tap(find.byType(Switch));
    expect(notify, isFalse);
  });

  testWidgets('description edits are reported and saved', (tester) async {
    _phone(tester);
    String? described;
    V2ScheduleDraft? saved;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: _data,
          onDescriptionChanged: (value) => described = value,
          onSave: (draft) => saved = draft,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('schedule-description'));
    await _scrollTo(tester, field);
    await tester.enterText(field, 'Fresh note about this schedule.');
    expect(described, 'Fresh note about this schedule.');

    await _scrollTo(tester, find.text('Save schedule'));
    await tester.tap(find.text('Save schedule'));
    expect(saved?.description, 'Fresh note about this schedule.');
  });

  testWidgets('source session opens the chat', (tester) async {
    _phone(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(data: _data, onOpenSourceSession: () => opened++),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('Source session'));
    await tester.tap(find.text('Source session'));
    expect(opened, 1);
  });

  testWidgets('source session without a chat is not tappable', (tester) async {
    _phone(tester);
    var opened = 0;
    await tester.pumpWidget(
      _app(
        ScheduleEditorPage(
          data: const V2ScheduleEditorData(prompt: 'Check the news.'),
          onOpenSourceSession: () => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No chat linked.'), findsOneWidget);
    await tester.tap(find.text('Source session'));
    expect(opened, 0);
  });
}
