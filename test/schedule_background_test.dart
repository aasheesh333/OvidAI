import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/device_control_service.dart';
import 'package:ovid_ai/core/schedule_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ovid/native');
  final notifier = AgentNotificationService.I;
  late AppState app;
  late List<String> calls;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    app = AppState.createForTest();
    calls = [];
    notifier.resetForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
  });
  tearDown(() {
    notifier.resetForTest();
    AppState.resetTestInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('Stop cancels pending notification debounce and pauses durable tasks', () async {
    final task = AgentService.I.schedules.create({'prompt': 'work', 'after_seconds': 10});
    final s = ChatSession(id: 'stop-schedule', title: 'S', model: 'm', schedules: [task]);
    app.sessions.add(s);
    await notifier.agentWorking('working', sessionId: s.id);
    await notifier.stopBackground();
    notifier.agentIdle();
    await notifier.agentWorking('late event', sessionId: s.id);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(calls, contains('backgroundStop'));
    expect(calls, isNot(contains('agentServiceStart')));
    expect(calls, isNot(contains('agentServiceUpdate')));
    expect(task['status'], 'paused');
    expect((await SharedPreferences.getInstance()).getBool('ovid_background_stopped'), isTrue);
    final roundTrip = ChatSession.fromJson(s.toJson());
    expect(roundTrip.schedules.single['status'], 'paused');
    AgentService.I.dropSessionRun(s.id);
  });

  test('late native success after Stop cannot reactivate notification state', () async {
    final result = Completer<bool>();
    final invoked = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'agentServiceStart') {
        invoked.complete();
        return result.future;
      }
      return true;
    });
    await notifier.agentWorking('starting');
    await invoked.future;
    await notifier.stopBackground();
    result.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(notifier.activeForTest, isFalse);
    expect(notifier.backgroundStopped, isTrue);
  });

  test('native persisted stop survives refresh until explicit Resume', () async {
    var nativeStopped = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'backgroundState') return {'stopped': nativeStopped};
      if (call.method == 'backgroundResume') nativeStopped = false;
      return true;
    });
    await notifier.refreshBackgroundState();
    expect(notifier.backgroundStopped, isTrue);
    notifier.agentIdle();
    expect(calls, isNot(contains('agentServiceUpdate')));
    await notifier.resumeBackground();
    await notifier.refreshBackgroundState();
    expect(notifier.backgroundStopped, isFalse);
  });

  test('agent schedule tool persists session ownership and cancellation history', () async {
    final a = ChatSession(id: 'schedule-a', title: 'A', model: 'm');
    final b = ChatSession(id: 'schedule-b', title: 'B', model: 'm');
    app.sessions.addAll([a, b]);
    app.activeSessionId = a.id;
    final response = await AgentService.I.dispatchForTest('schedule_create', {
      'prompt': 'Daily report', 'daily_at': '09:30',
    });
    expect(response, contains('saved'));
    expect(a.schedules, hasLength(1));
    expect(b.schedules, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    final restored = prefs.getStringList('ovid_sessions')!
        .map((s) => ChatSession.fromJson(jsonDecode(s))).firstWhere((s) => s.id == a.id);
    expect(restored.schedules.single['dailyAt'], '09:30');
    final id = a.schedules.single['id'];
    await AgentService.I.dispatchForTest('schedule_delete', {'id': id});
    expect(a.schedules.single['status'], 'cancelled');
    final listing = await AgentService.I.dispatchForTest('schedule_list', {});
    expect(listing, contains('cancelled'));
    AgentService.I.dropSessionRun(a.id);
    AgentService.I.dropSessionRun(b.id);
  });

  test('agent reports failed creation when session storage fails', () async {
    final s = ChatSession(id: 'schedule-write-fail', title: 'S', model: 'm');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    app.failNextSessionWriteForTest = true;
    final response = await AgentService.I.dispatchForTest('schedule_create', {
      'prompt': 'Must be durable', 'after_seconds': 60,
    });
    expect(response, contains('not created'));
    expect(s.schedules, isEmpty);
    AgentService.I.dropSessionRun(s.id);
  });

  test('new Stop wins over a delayed Resume reply', () async {
    final resume = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backgroundResume') return resume.future;
      return true;
    });
    final resuming = AgentService.I.resumeScheduledBackground();
    await Future<void>.delayed(Duration.zero);
    await notifier.stopBackground();
    resume.complete(true);
    await resuming;
    expect(notifier.backgroundStopped, isTrue);
    expect(AgentService.I.schedules.stopped, isTrue);
  });

  test('pausing a running Control schedule cancels pending native work immediately', () async {
    final agent = AgentService.I;
    final task = agent.schedules.create({'prompt': 'tap', 'after_seconds': 10});
    task['status'] = 'running';
    final session = ChatSession(id: 'scheduled-control', title: 'Control',
        model: 'm', mode: 'control', schedules: [task]);
    app.sessions.add(session);
    app.activeSessionId = session.id;
    final bucket = agent.runBucketForTest(session.id)
      ..activeRunId = 'scheduled-run'
      ..controlRun = true;
    final entered = Completer<void>();
    final reply = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'deviceTap') {
        entered.complete();
        return reply.future;
      }
      return true;
    });
    DeviceControlService.I.beginDeviceGeneration();
    final tap = DeviceControlService.I.tap(x: 10, y: 20);
    await entered.future;
    agent.enqueueMessage('tap again', sessionId: session.id);
    try {
      await agent.schedules.cancelTask(ScheduleEntry(session.id, task), pause: true);
      expect(await tap.timeout(const Duration(seconds: 1)),
          DeviceControlService.cancelledSupersededMessage);
      expect(task['status'], 'paused');
      expect(bucket.activeRunId, isNull);
      expect(bucket.queue, isEmpty);
      expect(calls, contains('deviceCancelActions'));
    } finally {
      reply.complete(true);
      agent.dropSessionRun(session.id);
    }
  });
}
