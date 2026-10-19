// Wave 5 — Schedules: create, run now, run history, all chats, failed-state
// recovery, title-only edits, truthful status, live updates, time zone.
// Findings: FE-012, FE-013, FE-017, FE-018, FE-019, CT-014, EM-020.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/schedule_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/schedule_fake.dart';

const _localChat = 'local-1';
const _serverChat = '018f3b0e-7a2c-7c4d-9e5f-123456789abc';
const _otherChat = '018f3b0e-7a2c-7c4d-9e5f-0000000000bb';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

class _FakeLinkWs extends WsMultiplexer {
  _FakeLinkWs() : super(mintTicket: () async => 'ticket');

  final WsLinkState _link = WsLinkState.online;

  @override
  WsLinkState get linkState => _link;
}

void main() {
  late AppState app;
  late FakeScheduleGateway fake;
  late StreamController<Map<String, dynamic>> raw;
  late List<Map<String, Object?>> wsSent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    ScheduleClient.timeZoneOverrideForTest = 'UTC';
    app = AppState.createForTest();
    app.sessions.add(ChatSession(id: _localChat, title: 'Work chat', model: 'm'));
    app.activeSessionId = _localChat;
    fake = FakeScheduleGateway([]);
    ScheduleClient.installForTest(fake.client);
    CloudSessionStore.installForTest(
      CloudSessionStore.forTest(idMap: const {_localChat: _serverChat}),
    );
    wsSent = <Map<String, Object?>>[];
  });

  tearDown(() {
    ScheduleClient.timeZoneOverrideForTest = null;
    CloudSessionStore.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpScreen(WidgetTester tester, {String? sessionId = _localChat}) async {
    raw = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(raw.close);
    final feed = ScheduleLiveFeed(
      ws: _FakeLinkWs(),
      rawFramesOverride: raw.stream,
      sendOverride: (frame) async => wsSent.add(frame),
    );
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: ScheduleScreen(sessionId: sessionId, liveFeed: feed)),
    );
    await _settle(tester);
  }

  Future<void> menu(WidgetTester tester, String choice, {int index = 0}) async {
    await tester.tap(find.byTooltip('Task actions').at(index));
    await _settle(tester);
    await tester.tap(find.text(choice).last);
    await _settle(tester);
  }

  testWidgets('FE-012: lists ALL schedules, grouped by chat, with a This chat filter',
      (tester) async {
    fake.schedules.addAll([
      scheduleJson(id: 'a', sessionId: _serverChat, title: 'Mine'),
      scheduleJson(id: 'b', sessionId: _otherChat, title: 'From another chat'),
    ]);
    await pumpScreen(tester);

    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('From another chat'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-group-$_serverChat')), findsOneWidget);
    expect(find.text('This chat'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-scope-chat')));
    await _settle(tester);
    expect(find.text('Mine'), findsOneWidget);
    expect(find.text('From another chat'), findsNothing);
  });

  testWidgets('a screen with no chat still lists everything and can create',
      (tester) async {
    fake.schedules.add(scheduleJson(id: 'b', sessionId: _otherChat, title: 'Elsewhere'));
    await pumpScreen(tester, sessionId: null);
    expect(find.text('Elsewhere'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-new')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-scope-chat')), findsNothing);
  });

  testWidgets('FE-012: New schedule with the Every hour preset into a new chat',
      (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const ValueKey('schedule-new-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-new')));
    await _settle(tester);
    expect(find.text('New schedule'), findsWidgets);
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'Inbox sweep');
    await tester.enterText(find.byKey(const ValueKey('schedule-prompt')), 'Summarise new mail');
    await tester.tap(find.byKey(const ValueKey('schedule-target-new')));
    await tester.tap(find.byKey(const ValueKey('schedule-preset-hourly')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
    await tester.tap(find.byKey(const ValueKey('schedule-save')));
    await _settle(tester);

    expect(fake.createCalls, 1);
    expect(fake.lastCreateBody, <String, Object?>{
      'title': 'Inbox sweep',
      'description': 'Summarise new mail',
      'trigger': {'kind': 'every', 'seconds': 3600},
      'autonomy': 'safe',
      'maxRetries': 0,
    });
    expect(find.text('Inbox sweep'), findsOneWidget, reason: 'the list reloaded');
  });

  testWidgets('FE-012/FE-019: a daily schedule in THIS chat uses the device time zone',
      (tester) async {
    ScheduleClient.timeZoneOverrideForTest = 'America/New_York';
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-new')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'Standup');
    await tester.enterText(find.byKey(const ValueKey('schedule-prompt')), 'Draft my standup');
    expect(find.byKey(const ValueKey('schedule-target-chat')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-preset-daily')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
    await tester.tap(find.byKey(const ValueKey('schedule-save')));
    await _settle(tester);

    expect(fake.lastCreateBody!['sessionId'], _serverChat);
    expect(fake.lastCreateBody!['trigger'], {
      'kind': 'daily_at',
      'time': '09:00',
      'tz': 'America/New_York',
    });
  });

  testWidgets('FE-012: Run now claims a run, shows Running, and the history lists it',
      (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat, title: 'Report'));
    await pumpScreen(tester);

    await menu(tester, 'Run now');
    expect(fake.runNowCalls, 1);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('Started.'), findsOneWidget);

    await tester.tap(find.text('Show details'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('schedule-history')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-run-occ1')), findsOneWidget);
  });

  testWidgets('a busy chat answers Run now with readable feedback', (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat));
    fake.failRunNowStatus = 409;
    await pumpScreen(tester);
    await menu(tester, 'Run now');
    expect(find.textContaining('already running a task'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
  });

  testWidgets('FE-012: run history shows past runs with their outcome',
      (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat));
    fake.runs['sc1'] = [
      {
        'id': 'r-ok',
        'scheduleId': 'sc1',
        'scheduledFor': '2026-10-18T09:00:00.000Z',
        'runId': 'run-1',
        'status': 'succeeded',
        'attempt': 1,
        'ranLate': false,
        'error': null,
        'startedAt': '2026-10-18T09:00:01.000Z',
        'finishedAt': '2026-10-18T09:00:31.000Z',
      },
      {
        'id': 'r-bad',
        'scheduleId': 'sc1',
        'scheduledFor': '2026-10-17T09:00:00.000Z',
        'runId': 'run-0',
        'status': 'failed',
        'attempt': 2,
        'ranLate': true,
        'error': 'model_terminal',
        'startedAt': '2026-10-17T09:00:01.000Z',
        'finishedAt': '2026-10-17T09:00:02.000Z',
      },
    ];
    await pumpScreen(tester);
    await tester.tap(find.text('Show details'));
    await _settle(tester);

    expect(find.textContaining('Succeeded · took 30s'), findsOneWidget);
    expect(find.textContaining('Failed'), findsWidgets);
    expect(find.textContaining('attempt 2'), findsOneWidget);
    expect(find.text('model_terminal'), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-open-chat')), findsOneWidget);
  });

  testWidgets('FE-013: a failed schedule offers Edit, Resume and Run once — Resume works',
      (tester) async {
    fake.schedules.add(scheduleJson(
      id: 'sc1',
      sessionId: _serverChat,
      status: 'failed',
      lastResult: lastResultJson(status: 'failed', message: 'Model setup required'),
    ));
    await pumpScreen(tester);

    expect(find.byKey(const ValueKey('schedule-recover-edit')), findsOneWidget);
    expect(find.byKey(const ValueKey('schedule-recover-run')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-recover-resume')));
    await _settle(tester);
    expect(fake.lastPatchBody, {'status': 'pending'});
    expect(find.text('Active'), findsOneWidget);
  });

  testWidgets('FE-013: Edit is enabled on a failed schedule', (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat, status: 'failed'));
    await pumpScreen(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-recover-edit')));
    await _settle(tester);
    expect(find.text('Edit schedule'), findsOneWidget);
  });

  testWidgets('FE-017: renaming sends ONLY the title (the next run stays put)',
      (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat, title: 'Old name'));
    await pumpScreen(tester);
    await menu(tester, 'Edit');
    await tester.enterText(find.byKey(const ValueKey('schedule-title')), 'New name');
    await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
    await tester.tap(find.byKey(const ValueKey('schedule-save')));
    await _settle(tester);
    expect(fake.lastPatchBody, {'title': 'New name'});
  });

  testWidgets('FE-019: Use device zone switches a daily task to the device zone',
      (tester) async {
    ScheduleClient.timeZoneOverrideForTest = 'America/New_York';
    fake.schedules.add(scheduleJson(
      id: 'sc1',
      sessionId: _serverChat,
      trigger: {'kind': 'daily_at', 'time': '08:00', 'tz': 'Europe/Berlin'},
    ));
    await pumpScreen(tester);
    await menu(tester, 'Edit');
    expect(find.text('Time zone: Europe/Berlin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-use-device-zone')));
    await _settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('schedule-save')));
    await tester.tap(find.byKey(const ValueKey('schedule-save')));
    await _settle(tester);
    expect(fake.lastPatchBody, {
      'trigger': {'kind': 'daily_at', 'time': '08:00', 'tz': 'America/New_York'},
    });
  });

  testWidgets('FE-018/EM-020: a load error never shows a green "active" strip',
      (tester) async {
    fake.failListStatus = 500;
    await pumpScreen(tester);
    expect(find.text('Cloud scheduling active'), findsNothing);
    expect(find.text("Couldn't reach cloud scheduling"), findsOneWidget);
    expect(find.text('Could not load schedules'), findsOneWidget);
  });

  testWidgets('FE-018: the strip counts what needs attention', (tester) async {
    fake.schedules.addAll([
      scheduleJson(id: 'a', sessionId: _serverChat),
      scheduleJson(id: 'b', sessionId: _serverChat, status: 'failed'),
    ]);
    await pumpScreen(tester);
    expect(find.text('Cloud scheduling active'), findsOneWidget);
    expect(find.textContaining('1 active · 1 need review'), findsOneWidget);
  });

  testWidgets('CT-014: subscribes to the system channel and reloads on schedule events',
      (tester) async {
    fake.schedules.add(scheduleJson(id: 'sc1', sessionId: _serverChat, title: 'Live'));
    await pumpScreen(tester);
    expect(wsSent.where((f) => f['op'] == 'subscribe_system'), hasLength(1));
    final before = fake.listCalls;

    raw.add(<String, dynamic>{
      'op': 'system',
      'event': <String, dynamic>{
        'type': 'schedule_run_started',
        'scheduleId': 'sc1',
        'ts': '2026-10-19T10:00:00.000Z',
        'payload': <String, dynamic>{},
      },
    });
    await tester.pump();
    expect(find.text('Running'), findsOneWidget);

    fake.byId('sc1')!['lastResult'] = lastResultJson(message: 'All done');
    raw.add(<String, dynamic>{
      'op': 'system',
      'event': <String, dynamic>{
        'type': 'schedule_run_succeeded',
        'scheduleId': 'sc1',
        'ts': '2026-10-19T10:01:00.000Z',
        'payload': <String, dynamic>{},
      },
    });
    await _settle(tester);
    expect(fake.listCalls, greaterThan(before));
    expect(find.text('Running'), findsNothing);
    expect(find.textContaining('All done'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(wsSent.last['op'], 'unsubscribe_system');
  });
}
