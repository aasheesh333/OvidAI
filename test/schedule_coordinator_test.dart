import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/schedule_coordinator.dart';

void main() {
  late DateTime now;
  late List<ScheduleEntry> entries;
  late String disk;
  late int runs;
  late ScheduleCoordinator scheduler;
  Future<void> save() async {
    disk = jsonEncode(entries.map((e) => e.task).toList());
  }

  setUp(() {
    now = DateTime.utc(2026, 10, 3, 10);
    entries = [];
    disk = '[]';
    runs = 0;
    scheduler = ScheduleCoordinator(
      entries: () => entries,
      clock: () => now,
      persist: save,
      isBusy: (_) => false,
      execute: (entry) async {
        expect(jsonDecode(disk)[0]['status'], 'running');
        runs++;
        return const ScheduleResult.completed();
      },
      cancel: (_) {},
      changed: () {},
    );
  });

  void add(Map<String, dynamic> args) {
    entries.add(ScheduleEntry('session-a', scheduler.create(args)));
  }

  test('persists claim before dispatch; concurrent ticks run once', () async {
    add({'prompt': 'work', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 1));
    await Future.wait([scheduler.tick(), scheduler.tick()]);
    await scheduler.settle();
    expect(runs, 1);
    expect(entries.single.task['status'], 'completed');
    await scheduler.tick();
    expect(runs, 1);
  });

  test('restart pauses persisted running claim instead of replaying', () async {
    final finish = Completer<ScheduleResult>();
    scheduler.execute = (_) { runs++; return finish.future; };
    add({'prompt': 'external side effect', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    entries = (jsonDecode(disk) as List)
        .map((t) => ScheduleEntry('session-a', Map<String, dynamic>.from(t)))
        .toList();
    await scheduler.recover();
    expect(entries.single.task['status'], 'paused');
    expect(entries.single.task['error'], contains('unknown'));
    await scheduler.tick();
    expect(runs, 1);
    finish.complete(const ScheduleResult.completed());
    await scheduler.settle();
    expect(entries.single.task['status'], 'paused');
  });

  test('failed persistence prevents execution', () async {
    scheduler.persist = () async => throw StateError('disk full');
    add({'prompt': 'work', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 2));
    await scheduler.tick();
    expect(runs, 0);
    expect(entries.single.task['status'], 'paused');
  });

  test('stop during claim prevents dispatch and stays stopped on ticks', () async {
    final barrier = Completer<void>();
    scheduler.persist = () => barrier.future;
    add({'prompt': 'work', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 1));
    final tick = scheduler.tick();
    final stop = scheduler.stop();
    barrier.complete();
    await Future.wait([tick, stop]);
    await scheduler.tick();
    expect(runs, 0);
    expect(scheduler.stopped, isTrue);
    expect(entries.single.task['status'], 'paused');
  });

  test('cancel in flight cannot be overwritten by late success', () async {
    final finish = Completer<ScheduleResult>();
    scheduler.execute = (_) => finish.future;
    add({'prompt': 'work', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    await scheduler.cancelTask(entries.single);
    finish.complete(const ScheduleResult.completed());
    await scheduler.settle();
    expect(entries.single.task['status'], 'cancelled');
  });

  test('interval remains aligned and skips missed occurrences', () async {
    add({'prompt': 'work', 'every_seconds': 300});
    now = now.add(const Duration(minutes: 17));
    await scheduler.tick();
    await scheduler.settle();
    expect(runs, 1);
    expect(entries.single.task['fireAt'], '2026-10-03T10:20:00.000Z');
    expect(entries.single.task['status'], 'pending');
    expect(entries.single.task['lastStatus'], 'completed');
  });

  test('safe pre-dispatch retries are bounded and back off', () async {
    scheduler.execute = (_) async {
      runs++;
      return const ScheduleResult.retryable('provider unavailable');
    };
    add({'prompt': 'work', 'after_seconds': 1, 'max_retries': 1});
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    await scheduler.settle();
    expect(entries.single.task['status'], 'pending');
    now = now.add(const Duration(seconds: 29));
    await scheduler.tick();
    expect(runs, 1);
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    await scheduler.settle();
    expect(runs, 2);
    expect(entries.single.task['status'], 'failed');
  });

  test('unsafe failures are never retried even with retry policy', () async {
    scheduler.execute = (_) async => const ScheduleResult.failed('tool failed');
    add({'prompt': 'work', 'after_seconds': 1, 'max_retries': 3});
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    await scheduler.settle();
    expect(entries.single.task['status'], 'failed');
  });

  test('timestamps preserve offset instant and reject normalized dates', () {
    add({'prompt': 'work', 'at': '2026-10-04T09:30:00+05:30'});
    expect(entries.single.task['fireAt'], '2026-10-04T04:00:00.000Z');
    expect(() => scheduler.create({'prompt': 'x', 'at': '2026-02-30 09:00'}),
        throwsFormatException);
    expect(() => scheduler.create({'prompt': 'x', 'daily_at': '25:00'}),
        throwsFormatException);
  });

  test('daily uses next local calendar date, not elapsed 24 hours', () {
    now = DateTime(2026, 10, 3, 10);
    add({'prompt': 'work', 'daily_at': '09:30'});
    expect(DateTime.parse(entries.single.task['fireAt']).toLocal(),
        DateTime(2026, 10, 4, 9, 30));
    expect(entries.single.task['timezone'], 'device-local');
  });

  test('offset change at a due daily task does not skip the occurrence', () async {
    now = DateTime(2026, 10, 3, 8);
    add({'prompt': 'work', 'daily_at': '09:30'});
    entries.single.task['zoneOffset'] = 999; // saved before a zone/offset change
    now = DateTime(2026, 10, 3, 9, 30);
    await scheduler.tick();
    await scheduler.settle();
    expect(runs, 1);
    expect(DateTime.parse(entries.single.task['fireAt']).toLocal(),
        DateTime(2026, 10, 4, 9, 30));
  });

  test('no wake-up when empty, stopped, or all tasks have finished', () async {
    expect(scheduler.nextWake, isNull);
    add({'prompt': 'work', 'after_seconds': 1});
    expect(scheduler.nextWake, now.add(const Duration(seconds: 1)));
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    await scheduler.settle();
    expect(scheduler.nextWake, isNull);
    add({'prompt': 'other', 'after_seconds': 5});
    await scheduler.stop();
    expect(scheduler.nextWake, isNull);
  });

  test('malformed legacy recurrence pauses rather than dividing by zero', () async {
    entries.add(ScheduleEntry('s', {'id': 'old', 'prompt': 'old task',
      'fireAt': now.toIso8601String(), 'every': 0}));
    await scheduler.recover();
    await scheduler.tick();
    expect(runs, 0);
    expect(entries.single.task['status'], 'paused');
  });

  test('file-backed cold recovery does not dispatch an already claimed run', () async {
    final dir = await Directory.systemTemp.createTemp('ovid-schedule-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/schedules.json');
    scheduler.persist = () async {
      await file.writeAsString(jsonEncode(entries.map((e) => e.task).toList()), flush: true);
    };
    final finish = Completer<ScheduleResult>();
    scheduler.execute = (_) { runs++; return finish.future; };
    add({'prompt': 'external effect', 'after_seconds': 1});
    now = now.add(const Duration(seconds: 1));
    await scheduler.tick();
    final restored = (jsonDecode(await file.readAsString()) as List)
        .map((t) => ScheduleEntry('session-a', Map<String, dynamic>.from(t))).toList();
    final cold = ScheduleCoordinator(
      entries: () => restored, clock: () => now,
      persist: () async { await file.writeAsString(jsonEncode(restored.map((e) => e.task).toList()), flush: true); },
      isBusy: (_) => false,
      execute: (_) async { runs++; return const ScheduleResult.completed(); },
      cancel: (_) {}, changed: () {},
    );
    await cold.recover();
    await cold.tick();
    expect(runs, 1);
    expect(jsonDecode(await file.readAsString())[0]['status'], 'paused');
    // Abandon the old in-memory claim just as process death would.
    entries = [];
    finish.complete(const ScheduleResult.completed());
    await scheduler.settle();
  });

  test('daily DST days use calendar boundaries', () {
    // Run this suite with TZ=America/New_York to exercise both transitions.
    final spring = DateTime(2026, 3, 7, 9, 30);
    final next = ScheduleCoordinator.nextDaily('09:30', spring);
    expect(next, DateTime(2026, 3, 8, 9, 30));
    if (spring.timeZoneOffset != next.timeZoneOffset) {
      expect(next.difference(spring), const Duration(hours: 23));
    }
    final autumn = DateTime(2026, 10, 31, 9, 30);
    final nextAutumn = ScheduleCoordinator.nextDaily('09:30', autumn);
    expect(nextAutumn, DateTime(2026, 11, 1, 9, 30));
    if (autumn.timeZoneOffset != nextAutumn.timeZoneOffset) {
      expect(nextAutumn.difference(autumn), const Duration(hours: 25));
    }
  });
}
