import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/schedule_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Resume waits for delayed Stop persistence before clearing durable stop', () async {
    SharedPreferences.setMockInitialValues({});
    AppState.createForTest();
    final notifier = AgentNotificationService.I..resetForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.schedules.stopped = false;
    final entered = Completer<void>();
    final release = Completer<void>();
    const channel = MethodChannel('ovid/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backgroundStop') {
        entered.complete();
        await release.future;
      }
      return true;
    });
    addTearDown(() {
      notifier.resetForTest();
      AppState.resetTestInstance();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    final stop = notifier.stopBackground();
    await entered.future;
    final resume = notifier.resumeBackground();
    await Future<void>.delayed(Duration.zero);
    release.complete();
    await Future.wait([stop, resume]);
    expect(notifier.backgroundStopped, isFalse);
    expect((await SharedPreferences.getInstance()).getBool('ovid_background_stopped'), isFalse);
  });

  test('Stop during timezone save cannot restore a running claim', () async {
    final now = DateTime(2026, 10, 4, 12);
    final entered = Completer<void>();
    final release = Completer<void>();
    late ScheduleEntry entry;
    var saves = 0;
    var runs = 0;
    final coordinator = ScheduleCoordinator(
      entries: () => [ScheduleEntry(entry.sessionId, entry.task)],
      clock: () => now,
      persist: () async {
        if (++saves == 1) {
          entered.complete();
          await release.future;
        }
      },
      isBusy: (_) => false,
      execute: (_) async {
        runs++;
        return const ScheduleResult.completed();
      },
      cancel: (_) {},
      changed: () {},
    );
    entry = ScheduleEntry('a', coordinator.create({'prompt': 'run', 'daily_at': '09:00'}));
    entry.task['localDate'] = '2026-10-04';
    entry.task['zoneOffset'] = 10000;
    final tick = coordinator.tick();
    await entered.future;
    await coordinator.stop();
    release.complete();
    await tick;
    expect(entry.task['status'], 'paused');
    expect(runs, 0);
  });

  test('failed recurring result persistence pauses before another dispatch', () async {
    var now = DateTime.utc(2026, 10, 4);
    late ScheduleEntry entry;
    var saves = 0;
    var runs = 0;
    final coordinator = ScheduleCoordinator(
      entries: () => [ScheduleEntry(entry.sessionId, entry.task)],
      clock: () => now,
      persist: () async {
        if (++saves == 2) throw StateError('full disk');
      },
      isBusy: (_) => false,
      execute: (_) async {
        runs++;
        return const ScheduleResult.completed();
      },
      cancel: (_) {},
      changed: () {},
    );
    entry = ScheduleEntry('a', coordinator.create({'prompt': 'run', 'every_seconds': 300}));
    entry.task['fireAt'] = now.toIso8601String();
    await coordinator.tick();
    await coordinator.settle();
    expect(entry.task['status'], 'paused');
    now = now.add(const Duration(hours: 1));
    await coordinator.tick();
    await coordinator.settle();
    expect(runs, 1);
  });

  test('Stop preserves completed history in the active session', () async {
    final now = DateTime.utc(2026, 10, 4);
    final result = Completer<ScheduleResult>();
    final history = ScheduleEntry('a', {'status': 'completed', 'id': 'old'});
    late ScheduleEntry entry;
    final coordinator = ScheduleCoordinator(
      entries: () => [history, ScheduleEntry(entry.sessionId, entry.task)],
      clock: () => now,
      persist: () async {},
      isBusy: (_) => false,
      execute: (_) => result.future,
      cancel: (_) {},
      changed: () {},
    );
    entry = ScheduleEntry('a', coordinator.create({'prompt': 'run', 'after_seconds': 1}));
    entry.task['fireAt'] = now.toIso8601String();
    await coordinator.tick();
    await coordinator.stop();
    result.complete(const ScheduleResult.completed());
    await coordinator.settle();
    expect(history.task['status'], 'completed');
    expect(entry.task['status'], 'paused');
  });

  test('global stop survives a late failed result persistence', () async {
    final now = DateTime.utc(2026, 10, 4);
    final result = Completer<ScheduleResult>();
    final persisted = Completer<void>();
    final release = Completer<void>();
    late ScheduleCoordinator coordinator;
    late ScheduleEntry entry;
    var saves = 0;
    coordinator = ScheduleCoordinator(
      entries: () => [entry],
      clock: () => now,
      persist: () async {
        saves++;
        if (saves == 2) {
          persisted.complete();
          await release.future;
          throw StateError('full disk');
        }
      },
      isBusy: (_) => false,
      execute: (_) => result.future,
      cancel: (_) {},
      changed: () {},
    );
    entry = ScheduleEntry(
      'a',
      coordinator.create({'prompt': 'run', 'after_seconds': 1}),
    );
    entry.task['fireAt'] = now.toIso8601String();
    await coordinator.tick();
    result.complete(const ScheduleResult.completed());
    await persisted.future;
    await coordinator.stop();
    release.complete();
    await coordinator.settle();
    expect(entry.task['status'], 'paused');
    expect(entry.task['error'], 'Background execution stopped by user');
    expect(coordinator.nextWake, isNull);
  });
}
