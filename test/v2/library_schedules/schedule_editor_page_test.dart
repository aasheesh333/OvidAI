import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
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

Widget _app(Widget home, {bool dark = false}) => MaterialApp(
  theme: dark ? OTheme.dark() : OTheme.light(),
  home: home,
);

void _noopSave(V2ScheduleDraft draft) {}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('renders the editor in light mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    expect(find.text('Schedule editor'), findsOneWidget);
    expect(find.text('Task prompt'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Run time'), findsOneWidget);
    expect(find.text('Timezone'), findsOneWidget);
    expect(find.text('Notify me when finished'), findsOneWidget);
    expect(find.textContaining('every weekday'), findsOneWidget);
  });

  testWidgets('renders the editor in dark mode', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(const ScheduleEditorPage(data: _data), dark: true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Schedule editor'), findsOneWidget);
    expect(find.text('Frequency'), findsOneWidget);
    expect(find.textContaining('every weekday'), findsOneWidget);
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
      _app(
        ScheduleEditorPage(data: _data, onSave: (draft) => saved = draft),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Save schedule'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save schedule'));

    expect(saved, isNotNull);
    expect(saved!.prompt, contains('Product Hunt'));
    expect(saved!.frequency, V2ScheduleFrequency.weekly);
    expect(saved!.days, <int>{1, 2, 3, 4, 5});
    expect(saved!.notify, isTrue);
  });

  testWidgets('frequency segment updates the preview sentence', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(const ScheduleEditorPage(data: _data)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();

    expect(find.textContaining('every day at'), findsOneWidget);
    expect(find.text('REPEAT DAYS'), findsNothing);
    expect(find.textContaining('every weekday'), findsNothing);
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

    final time = tester.renderObject<RenderParagraph>(
      find.text('9:00 AM'),
    );
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

    await tester.scrollUntilVisible(
      find.text('Save schedule'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in const [
      'More options',
      'Improve prompt',
      'Run time, 9:00 AM. Change.',
      'Timezone, Asia/Kolkata (GMT +5:30). Change.',
      'Notify me when finished. Send a push alert with a short summary.',
      'Monday',
      'Daily',
    ]) {
      expect(
        find.bySemanticsLabel(label),
        findsWidgets,
        reason: '$label must be announced',
      );
    }

    // The day, frequency and notify controls must expose one actionable node,
    // not a labelled node with a separate, unlabeled tap target.
    for (final label in const [
      'Monday',
      'Daily',
      'Notify me when finished. Send a push alert with a short summary.',
    ]) {
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: '$label must be tappable from a screen reader',
      );
    }
    expect(
      tester
          .getSemantics(
            find.bySemanticsLabel(
              'Notify me when finished. Send a push alert with a short summary.',
            ),
          )
          .getSemanticsData()
          .flagsCollection
          .isToggled
          .toBoolOrNull(),
      isTrue,
    );

    expect(tester.getSize(find.bySemanticsLabel('More options').first).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.bySemanticsLabel('Improve prompt').first).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.bySemanticsLabel('Daily').first).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.bySemanticsLabel('Monday').first).height,
        greaterThanOrEqualTo(48));

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

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    expect(notify, isFalse);
  });
}
