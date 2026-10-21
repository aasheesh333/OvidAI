// Wiring tests for the Schedules flow: the list persists toggles and deletes,
// the next run is computed from the cadence, the editor validates, and the run
// history tells the truth about status and duration.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/schedules/cadence_picker.dart';
import 'package:ovid_ai/ui/v2/schedules/run_timeline.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_editor_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_gateway.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_runs_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_controller.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_flow.dart';
import 'package:ovid_ai/ui/v2/schedules/schedules_page.dart';

/// Wednesday, 21 October 2026, 10:00 local.
final _now = DateTime(2026, 10, 21, 10, 0);

Map<String, dynamic> _scheduleJson({
  String id = 's1',
  String title = 'Morning briefing',
  String description = 'Summarise the news.',
  Map<String, dynamic> trigger = const {
    'kind': 'daily_at',
    'time': '09:00',
    'tz': 'UTC',
  },
  String status = 'pending',
  String? nextRunAt = '2026-10-22T09:00:00.000Z',
}) {
  return <String, dynamic>{
    'id': id,
    'sessionId': 'chat-1',
    'title': title,
    'description': description,
    'trigger': trigger,
    'autonomy': 'safe',
    'status': status,
    'maxRetries': 0,
    'nextRunAt': nextRunAt,
  };
}

class _FakeGateway implements ScheduleGateway {
  _FakeGateway(List<Map<String, dynamic>> rows) : rows = [...rows];

  List<Map<String, dynamic>> rows;
  List<Map<String, dynamic>> runRows = <Map<String, dynamic>>[];
  final List<Map<String, Object?>> updates = <Map<String, Object?>>[];
  final List<String> deletes = <String>[];
  final List<ScheduleTrigger> createdTriggers = <ScheduleTrigger>[];
  int runNowCalls = 0;
  int listCalls = 0;
  Object? failUpdateWith;
  Object? failDeleteWith;

  /// Blocks an update until completed, so a test can inspect the optimistic
  /// state before the service answers.
  Completer<void>? holdUpdate;

  @override
  Future<List<ScheduleDto>> list() async {
    listCalls++;
    return [for (final row in rows) ScheduleDto.fromJson(row)];
  }

  @override
  Future<ScheduleDto> create({
    required String title,
    required String description,
    required ScheduleTrigger trigger,
    String? sessionId,
    int maxRetries = 0,
  }) async {
    createdTriggers.add(trigger);
    final row = _scheduleJson(
      id: 'new-${rows.length + 1}',
      title: title,
      description: description,
      trigger: trigger.toJson(),
      nextRunAt: null,
    );
    rows = [...rows, row];
    return ScheduleDto.fromJson(row);
  }

  @override
  Future<ScheduleDto> update(
    String id, {
    String? title,
    String? description,
    ScheduleTrigger? trigger,
    String? status,
  }) async {
    updates.add(<String, Object?>{
      'id': id,
      'status': ?status,
      'trigger': ?trigger?.toJson(),
    });
    final hold = holdUpdate;
    if (hold != null) await hold.future;
    final failure = failUpdateWith;
    if (failure != null) throw failure;
    rows = [
      for (final row in rows)
        if (row['id'] == id)
          <String, dynamic>{...row, 'status': ?status}
        else
          row,
    ];
    return ScheduleDto.fromJson(
      rows.firstWhere((row) => row['id'] == id),
    );
  }

  @override
  Future<void> delete(String id) async {
    final failure = failDeleteWith;
    if (failure != null) throw failure;
    deletes.add(id);
    rows = [
      for (final row in rows)
        if (row['id'] != id) row,
    ];
  }

  @override
  Future<void> runNow(String id) async => runNowCalls++;

  @override
  Future<List<ScheduleRunDto>> runs(String id) async => [
        for (final row in runRows) ScheduleRunDto.fromJson(row),
      ];
}

Widget _app(Widget home, {bool dark = false, TextScaler? scaler}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: scaler == null
          ? home
          : MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                textScaler: scaler,
              ),
              child: home,
            ),
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<SchedulesController> _loaded(_FakeGateway gateway) async {
  final controller = SchedulesController(gateway: gateway, clock: () => _now);
  await controller.load();
  return controller;
}

void main() {
  group('list wiring', () {
    test('a toggle reflects immediately and persists the new status', () async {
      final gateway = _FakeGateway([_scheduleJson()]);
      final controller = await _loaded(gateway);
      gateway.holdUpdate = Completer<void>();

      final pending = controller.setEnabled(controller.items.single, false);

      // Before the service answers the row is already paused.
      expect(controller.items.single.enabled, isFalse);

      gateway.holdUpdate!.complete();
      expect(await pending, isTrue);
      expect(gateway.updates.single, {'id': 's1', 'status': 'paused'});
      expect(controller.items.single.enabled, isFalse);
      expect(controller.notice, contains('Paused'));
    });

    test('a rejected toggle rolls the row back and explains why', () async {
      final gateway = _FakeGateway([_scheduleJson()])
        ..failUpdateWith = CloudApiException(
          status: 500,
          code: 'internal',
          message: 'The scheduler is offline.',
        );
      final controller = await _loaded(gateway);

      final ok = await controller.setEnabled(controller.items.single, false);

      expect(ok, isFalse);
      expect(controller.items.single.enabled, isTrue, reason: 'rolled back');
      expect(controller.notice, contains('The scheduler is offline.'));
    });

    test('a schedule is enabled only while its status is pending', () async {
      final gateway = _FakeGateway([
        _scheduleJson(id: 'a'),
        _scheduleJson(id: 'b', status: 'paused'),
        _scheduleJson(id: 'c', status: 'completed'),
      ]);
      final controller = await _loaded(gateway);

      expect(
        {for (final item in controller.items) item.id: item.enabled},
        {'a': true, 'b': false, 'c': false},
      );
    });

    test('a failed last run marks the card without claiming it is active',
        () async {
      final row = _scheduleJson(id: 'a', status: 'failed')
        ..['lastResult'] = {
          'status': 'failed',
          'message': 'Model setup required',
          'ranLate': false,
        };
      final controller = await _loaded(_FakeGateway([row]));

      expect(controller.items.single.lastRunFailed, isTrue);
      expect(controller.items.single.enabled, isFalse);
      expect(controller.items.single.failureMessage, 'Model setup required');
    });

    testWidgets('deleting asks first, then removes the row and persists', (
      tester,
    ) async {
      _phone(tester);
      final gateway = _FakeGateway([_scheduleJson(title: 'Nightly backup')]);
      final controller = await _loaded(gateway);
      await tester.pumpWidget(
        _app(SchedulesScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nightly backup'), findsOneWidget);

      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is OIconButton &&
              widget.semanticLabel == 'More options for Nightly backup',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete “Nightly backup”?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(gateway.deletes, ['s1']);
      expect(find.text('Nightly backup'), findsNothing);
      expect(find.text('No schedules yet'), findsOneWidget);
    });

    testWidgets('a failed delete restores the row', (tester) async {
      _phone(tester);
      final gateway = _FakeGateway([_scheduleJson(title: 'Keep me')])
        ..failDeleteWith = CloudApiException(
          status: 503,
          code: 'unavailable',
          message: 'Try again later.',
        );
      final controller = await _loaded(gateway);
      await tester.pumpWidget(
        _app(SchedulesScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byWidgetPredicate(
          (widget) =>
              widget is OIconButton &&
              widget.semanticLabel == 'More options for Keep me',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('Keep me'), findsOneWidget);
      expect(gateway.deletes, isEmpty);
    });
  });

  group('next run', () {
    testWidgets('is computed from the cadence, never from the old label', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          SchedulesPage(
            data: V2SchedulesData(
              now: _now,
              schedules: [
                V2ScheduleItem(
                  id: 's1',
                  title: 'Weekly report',
                  description: 'Writes the report.',
                  rule: 'Every Monday at 9:00 AM',
                  // A stale, hardcoded label that must not be trusted.
                  nextRun: 'in 2 hours',
                  cadence: const V2CadenceDraft(
                    frequency: V2CadenceFrequency.weekly,
                    hour: 9,
                    days: <int>{1},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Next: Monday, 26 Oct at 9:00 AM'), findsOneWidget);
      expect(find.textContaining('in 2 hours'), findsNothing);
    });

    testWidgets('a passed server timestamp is not shown as upcoming', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          SchedulesPage(
            data: V2SchedulesData(
              now: _now,
              schedules: [
                V2ScheduleItem(
                  id: 's1',
                  title: 'Stale schedule',
                  description: 'No cadence.',
                  rule: 'Every day at 9:00 AM',
                  nextRunAt: DateTime(2026, 10, 20, 9),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Next:'), findsNothing);
    });

    testWidgets('a paused schedule has no next run', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          SchedulesPage(
            data: V2SchedulesData(
              now: _now,
              schedules: [
                V2ScheduleItem(
                  id: 's1',
                  title: 'Paused one',
                  description: 'Paused.',
                  rule: 'Every day at 9:00 AM',
                  enabled: false,
                  nextRun: 'in 2 hours',
                  cadence: const V2CadenceDraft(
                    frequency: V2CadenceFrequency.daily,
                    hour: 9,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Next:'), findsNothing);
    });
  });

  group('cadence contract', () {
    test('daily and weekly produce valid cron expressions', () {
      const daily = V2CadenceDraft(
        frequency: V2CadenceFrequency.daily,
        hour: 9,
        minute: 5,
      );
      expect(daily.cronExpression, '5 9 * * *');
      expect(isValidCron(daily.cronExpression), isTrue);

      const weekly = V2CadenceDraft(
        frequency: V2CadenceFrequency.weekly,
        hour: 18,
        days: <int>{1, 3, 5},
      );
      expect(weekly.cronExpression, '0 18 * * 1,3,5');
      expect(isValidCron(weekly.cronExpression), isTrue);
      expect(
        weekly.rrule,
        'FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=18;BYMINUTE=0',
      );
    });

    test('a custom cron is validated and round-trips through a trigger', () {
      const custom = V2CadenceDraft(
        frequency: V2CadenceFrequency.custom,
        customRule: '0 8 1 * *',
        timezoneId: 'Asia/Kolkata',
      );
      expect(custom.isValid, isTrue);
      expect(custom.scheduleExpression, 'cron 0 8 1 * *');

      final trigger = triggerFromDraft(
        const V2ScheduleDraft(
          prompt: 'Monthly report',
          frequency: V2ScheduleFrequency.custom,
          timeLabel: '8:00 AM',
          days: <int>{},
          timezoneLabel: 'Asia/Kolkata',
          notify: true,
          cadence: custom,
        ),
      );
      expect(trigger?.kind, 'cron');
      expect(trigger?.expr, '0 8 1 * *');
      expect(trigger?.tz, 'Asia/Kolkata');
    });

    test('an invalid cron is rejected inline', () {
      const broken = V2CadenceDraft(
        frequency: V2CadenceFrequency.custom,
        customRule: '0 25 * * 1',
      );
      expect(broken.isValid, isFalse);
      expect(broken.validationError, contains('not a valid cron or RRULE'));
      expect(triggerFromDraft(
        const V2ScheduleDraft(
          prompt: 'x',
          frequency: V2ScheduleFrequency.custom,
          timeLabel: '9:00 AM',
          days: <int>{},
          timezoneLabel: 'UTC',
          notify: true,
          cadence: broken,
        ),
      ), isNull);
    });

    test('a saved cron becomes an editable weekly cadence', () {
      final cadence = cadenceFromCron('0 9 * * 1,2,3,4,5', timezoneId: 'UTC');
      expect(cadence?.frequency, V2CadenceFrequency.weekly);
      expect(cadence?.days, <int>{1, 2, 3, 4, 5});
      expect(cadence?.hour, 9);
    });

    test('a saved daily trigger becomes a daily cadence', () {
      final cadence = cadenceFromTrigger(
        ScheduleTrigger.dailyAt('07:30', tz: 'America/New_York'),
      );
      expect(cadence?.frequency, V2CadenceFrequency.daily);
      expect(cadence?.hour, 7);
      expect(cadence?.minute, 30);
      expect(cadence?.timezoneId, 'America/New_York');
    });

    test('creating a schedule sends the cron the picker produced', () async {
      final gateway = _FakeGateway([]);
      final controller = SchedulesController(
        gateway: gateway,
        clock: () => _now,
      );
      await controller.load();

      final error = await controller.create(
        const V2ScheduleDraft(
          prompt: 'Summarise the news.',
          frequency: V2ScheduleFrequency.weekly,
          timeLabel: '9:00 AM',
          days: <int>{1, 2, 3, 4, 5},
          timezoneLabel: 'Asia/Kolkata',
          timezoneId: 'Asia/Kolkata',
          notify: true,
          cadence: V2CadenceDraft(
            frequency: V2CadenceFrequency.weekly,
            hour: 9,
            days: <int>{1, 2, 3, 4, 5},
            timezoneId: 'Asia/Kolkata',
          ),
        ),
      );

      expect(error, isNull);
      expect(gateway.createdTriggers.single.kind, 'cron');
      expect(gateway.createdTriggers.single.expr, '0 9 * * 1,2,3,4,5');
      expect(gateway.createdTriggers.single.tz, 'Asia/Kolkata');
      expect(controller.items, hasLength(1));
    });
  });

  group('editor validation', () {
    testWidgets('an end date before the first run is rejected inline', (
      tester,
    ) async {
      _phone(tester);
      var saves = 0;
      await tester.pumpWidget(
        _app(
          ScheduleEditorPage(
            data: V2ScheduleEditorData(
              prompt: 'Summarise the news.',
              frequency: V2ScheduleFrequency.daily,
              timeLabel: '9:00 AM',
              days: const <int>{},
              now: _now,
              // Before tomorrow's 9:00 run.
              endsAt: DateTime(2026, 10, 21, 12),
            ),
            onSave: (_) => saves++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Save schedule'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The end date must be after the first run'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(saves, 0);
    });

    testWidgets('a valid end date saves with the draft', (tester) async {
      _phone(tester);
      V2ScheduleDraft? saved;
      await tester.pumpWidget(
        _app(
          ScheduleEditorPage(
            data: V2ScheduleEditorData(
              prompt: 'Summarise the news.',
              frequency: V2ScheduleFrequency.daily,
              timeLabel: '9:00 AM',
              days: const <int>{},
              now: _now,
              endsAt: DateTime(2026, 12, 31, 23, 59),
            ),
            onSave: (draft) => saved = draft,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Save schedule'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();

      expect(saved, isNotNull);
      expect(saved!.endsAt, DateTime(2026, 12, 31, 23, 59));
      expect(saved!.cron, '0 9 * * *');
    });

    testWidgets('the end date row opens the date picker', (tester) async {
      _phone(tester);
      DateTime? endsAt;
      await tester.pumpWidget(
        _app(
          ScheduleEditorPage(
            data: V2ScheduleEditorData(prompt: 'Summarise.', now: _now),
            onEndsAtChanged: (value) => endsAt = value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('End date'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('End date'));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(endsAt, isNull, reason: 'cancelling keeps the schedule open ended');
    });

    testWidgets('a save failure is shown inline', (tester) async {      _phone(tester);
      await tester.pumpWidget(
        _app(
          const ScheduleEditorPage(
            data: V2ScheduleEditorData(
              prompt: 'Summarise the news.',
              saveError: 'The scheduler is offline.',
            ),
            onSave: _noop,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('schedule-save-error')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('The scheduler is offline.'), findsOneWidget);
    });
  });

  group('run history', () {
    test('a running run is not reported as completed', () {
      final run = V2ScheduleRun.fromDto(
        ScheduleRunDto.fromJson(<String, dynamic>{
          'id': 'r1',
          'scheduleId': 's1',
          'scheduledFor': '2026-10-21T09:00:00.000Z',
          'status': 'running',
          'attempt': 1,
          'ranLate': false,
          'startedAt': '2026-10-21T09:00:00.000Z',
        }),
        now: DateTime.parse('2026-10-21T09:02:10.000Z'),
      );

      expect(run.status, V2RunStatus.running);
      expect(run.durationText(DateTime.parse('2026-10-21T09:02:10.000Z')), '2m 10s');
      expect(run.summaryText, 'Still running.');
    });

    test('a finished run takes its duration from the timestamps', () {
      final run = V2ScheduleRun.fromDto(
        ScheduleRunDto.fromJson(<String, dynamic>{
          'id': 'r1',
          'scheduleId': 's1',
          'scheduledFor': '2026-10-21T09:00:00.000Z',
          'status': 'succeeded',
          'attempt': 1,
          'ranLate': false,
          'startedAt': '2026-10-21T09:00:00.000Z',
          'finishedAt': '2026-10-21T09:01:12.000Z',
        }),
      );
      expect(run.durationLabel, '1m 12s');
    });

    test('an unknown status never looks successful', () {
      final run = V2ScheduleRun.fromDto(
        ScheduleRunDto.fromJson(<String, dynamic>{
          'id': 'r1',
          'scheduleId': 's1',
          'status': 'mystery',
          'attempt': 1,
          'ranLate': false,
        }),
      );
      expect(run.status, V2RunStatus.unknown);
      expect(run.summaryText, 'No result was recorded for this run.');
      expect(run.durationText(_now), isNull);
    });

    testWidgets('a run with no result shows no tick and no invented duration', (
      tester,
    ) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          const RunTimeline(
            data: V2RunTimelineData(
              runs: <V2TimelineRun>[
                V2TimelineRun(
                  id: 'r1',
                  dayLabel: 'Today — Oct 21',
                  timeLabel: '9:00 AM',
                  outcome: V2RunOutcome.unknown,
                  summary: '',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No result'), findsOneWidget);
      expect(find.text('No result was recorded for this run.'), findsOneWidget);
      expect(find.text('Not recorded'), findsOneWidget);
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('run-status-r1')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsNothing,
      );
    });

    testWidgets('the runs page shows a running run as Running', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _app(
          ScheduleRunsPage(
            data: V2ScheduleRunsData.fromRuns(
              [
                ScheduleRunDto.fromJson(<String, dynamic>{
                  'id': 'r1',
                  'scheduleId': 's1',
                  'scheduledFor': '2026-10-21T09:00:00.000Z',
                  'status': 'running',
                  'attempt': 1,
                  'ranLate': false,
                  'startedAt': '2026-10-21T09:00:00.000Z',
                }),
              ],
              scheduleTitle: 'Morning briefing',
              now: DateTime.parse('2026-10-21T09:02:00.000Z'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Running'), findsOneWidget);
      expect(find.text('2m'), findsOneWidget);
      expect(find.text('Retry run'), findsNothing);
      expect(find.text('1 runs · 0 succeeded · 0 failed'), findsOneWidget);
    });

    test('counts and the average runtime come from the rows', () {
      final data = V2ScheduleRunsData.fromRuns(
        [
          ScheduleRunDto.fromJson(<String, dynamic>{
            'id': 'a',
            'scheduleId': 's1',
            'scheduledFor': '2026-10-21T09:00:00.000Z',
            'status': 'succeeded',
            'attempt': 1,
            'ranLate': false,
            'startedAt': '2026-10-21T09:00:00.000Z',
            'finishedAt': '2026-10-21T09:01:00.000Z',
          }),
          ScheduleRunDto.fromJson(<String, dynamic>{
            'id': 'b',
            'scheduleId': 's1',
            'scheduledFor': '2026-10-20T09:00:00.000Z',
            'status': 'failed',
            'attempt': 2,
            'ranLate': true,
            'error': 'model_terminal',
            'startedAt': '2026-10-20T09:00:00.000Z',
            'finishedAt': '2026-10-20T09:00:30.000Z',
          }),
        ],
        now: DateTime.parse('2026-10-21T12:00:00.000Z'),
      );

      expect(data.total, 2);
      expect(data.succeeded, 1);
      expect(data.failed, 1);
      expect(data.avgRuntimeLabel, '45s');
      expect(data.groups, hasLength(2));
    });

    testWidgets('the wired flow opens the history for a schedule', (
      tester,
    ) async {
      _phone(tester);
      final gateway = _FakeGateway([_scheduleJson(title: 'Morning briefing')])
        ..runRows = [
          <String, dynamic>{
            'id': 'r1',
            'scheduleId': 's1',
            'scheduledFor': '2026-10-21T09:00:00.000Z',
            'status': 'succeeded',
            'attempt': 1,
            'ranLate': false,
            'startedAt': '2026-10-21T09:00:00.000Z',
            'finishedAt': '2026-10-21T09:01:12.000Z',
          },
        ];
      final controller = await _loaded(gateway);
      await tester.pumpWidget(
        _app(SchedulesScreen(controller: controller)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Morning briefing'));
      await tester.pumpAndSettle();

      expect(find.text('Schedule runs'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('1m 12s'), findsOneWidget);
    });
  });

  group('small screen', () {
    for (final dark in [false, true]) {
      testWidgets(
        'the wired list fits 320 dp at 200% text (${dark ? 'dark' : 'light'})',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final gateway = _FakeGateway([
            _scheduleJson(title: 'A very long schedule title that must wrap'),
          ]);
          final controller = await _loaded(gateway);
          await tester.pumpWidget(
            _app(
              SchedulesScreen(controller: controller),
              dark: dark,
              scaler: const TextScaler.linear(2),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          final position = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          var guard = 0;
          while (position.pixels < position.maxScrollExtent && guard < 40) {
            position.jumpTo(position.pixels + 200);
            await tester.pump();
            expect(tester.takeException(), isNull);
            guard++;
          }
        },
      );

      testWidgets(
        'the editor with an end date fits 320 dp at 200% text '
        '(${dark ? 'dark' : 'light'})',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            _app(
              ScheduleEditorPage(
                data: V2ScheduleEditorData(
                  prompt: 'Summarise the news.',
                  endsAt: DateTime(2026, 12, 31),
                  now: _now,
                ),
              ),
              dark: dark,
              scaler: const TextScaler.linear(2),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

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
            position.jumpTo(position.pixels + 200);
            await tester.pump();
            expect(tester.takeException(), isNull);
            guard++;
          }
        },
      );
    }
  });
}

void _noop(V2ScheduleDraft draft) {}
