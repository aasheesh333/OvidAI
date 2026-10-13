import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/schedule_coordinator.dart';

/// Background scheduling logic: next fire time, re-registration on runtime
/// start (boot / restart after Android killed Ovid) and the missed-run
/// catch-up policy.
void main() {
  late DateTime now;
  late List<ScheduleEntry> entries;
  late List<String> executed;
  late List<(String, String, bool)> results;
  late ScheduleCoordinator scheduler;
  ScheduleResult Function(ScheduleEntry) outcome = (_) =>
      const ScheduleResult.completed();

  setUp(() {
    now = DateTime(2026, 10, 13, 12);
    entries = [];
    executed = [];
    results = [];
    outcome = (_) => const ScheduleResult.completed();
    scheduler = ScheduleCoordinator(
      entries: () => entries,
      clock: () => now,
      persist: () async {},
      isBusy: (_) => false,
      execute: (e) async {
        executed.add(e.task['id'] as String);
        return outcome(e);
      },
      cancel: (_) {},
      changed: () {},
      onResult: (e, r, retry) =>
          results.add((e.task['id'] as String, r.status, retry)),
    );
  });

  Map<String, dynamic> add(Map<String, dynamic> args, {String id = 't'}) {
    final task = scheduler.create(args)..['id'] = id;
    entries.add(ScheduleEntry('s1', task));
    return task;
  }

  group('next fire time', () {
    test('daily_at picks today when still ahead, otherwise tomorrow', () {
      expect(
        ScheduleCoordinator.nextDaily('13:30', DateTime(2026, 10, 13, 12)),
        DateTime(2026, 10, 13, 13, 30),
      );
      expect(
        ScheduleCoordinator.nextDaily('08:00', DateTime(2026, 10, 13, 12)),
        DateTime(2026, 10, 14, 8),
      );
      // Exactly now is not "after": the next one is tomorrow.
      expect(
        ScheduleCoordinator.nextDaily('12:00', DateTime(2026, 10, 13, 12)),
        DateTime(2026, 10, 14, 12),
      );
    });

    test('nextWake is the earliest pending due time (the alarm deadline)', () {
      add({'prompt': 'later', 'after_seconds': 3600}, id: 'a');
      add({'prompt': 'sooner', 'after_seconds': 600}, id: 'b');
      final paused = add({'prompt': 'paused', 'after_seconds': 60}, id: 'c');
      paused['status'] = 'paused';
      expect(
        scheduler.nextWake!.isAtSameMomentAs(now.add(const Duration(minutes: 10))),
        isTrue,
      );
    });

    test('a stopped scheduler arms nothing', () {
      add({'prompt': 'x', 'after_seconds': 60});
      scheduler.stopped = true;
      expect(scheduler.nextWake, isNull);
    });

    test('interval next slot skips every missed period', () {
      final due = DateTime(2026, 10, 13, 9);
      final task = {'every': 3600};
      expect(
        MissedRunPolicy.nextSlot(task, due, DateTime(2026, 10, 13, 12, 10)),
        DateTime(2026, 10, 13, 13),
      );
    });
  });

  group('missed-run catch-up policy', () {
    test('within tolerance is on time', () {
      final due = now.subtract(const Duration(minutes: 1));
      expect(MissedRunPolicy.decide({}, due, now), CatchUp.onTime);
    });

    test('one-off: late runs once within a day, else paused for review', () {
      expect(
        MissedRunPolicy.decide({}, now.subtract(const Duration(hours: 3)), now),
        CatchUp.runNow,
      );
      expect(
        MissedRunPolicy.decide({}, now.subtract(const Duration(days: 2)), now),
        CatchUp.pauseForReview,
      );
    });

    test('recurring: grace is half the interval, capped at 6 h', () {
      expect(MissedRunPolicy.graceFor({'every': 3600}),
          const Duration(minutes: 30));
      expect(MissedRunPolicy.graceFor({'every': 86400}),
          const Duration(hours: 6));
      expect(MissedRunPolicy.graceFor({'dailyAt': '08:00'}),
          const Duration(hours: 6));
      expect(
        MissedRunPolicy.decide(
          {'every': 3600},
          now.subtract(const Duration(minutes: 20)),
          now,
        ),
        CatchUp.runNow,
      );
      expect(
        MissedRunPolicy.decide(
          {'dailyAt': '08:00'},
          now.subtract(const Duration(hours: 10)),
          now,
        ),
        CatchUp.skipToNext,
      );
    });
  });

  group('re-register on runtime start (boot)', () {
    test('a one-off missed by hours runs exactly once after recovery', () async {
      final t = add({'prompt': 'send report', 'after_seconds': 60});
      now = now.add(const Duration(hours: 4)); // phone was off
      await scheduler.recover();
      expect(t['status'], 'pending');
      expect(scheduler.nextWake!.isBefore(now), isTrue,
          reason: 'past deadline: the native alarm is re-armed immediately');
      await scheduler.tick();
      await scheduler.settle();
      await scheduler.tick();
      await scheduler.settle();
      expect(executed, ['t']);
      expect(t['status'], 'completed');
      expect(results, [('t', 'completed', false)]);
    });

    test('a one-off missed by days is paused, never fired by surprise', () async {
      final t = add({'prompt': 'pay invoice', 'after_seconds': 60});
      now = now.add(const Duration(days: 3));
      await scheduler.recover();
      expect(t['status'], 'paused');
      expect(t['error'], contains('Missed while Ovid was not running'));
      await scheduler.tick();
      expect(executed, isEmpty);
      expect(scheduler.nextWake, isNull);
    });

    test('a daily task missed beyond grace skips to its next slot', () async {
      final t = add({'prompt': 'morning brief', 'daily_at': '08:00'});
      // Created 12:00 → first run tomorrow 08:00; device off until 19:00.
      now = DateTime(2026, 10, 14, 19);
      await scheduler.recover();
      expect(t['status'], 'pending');
      expect(t['lastStatus'], 'skipped');
      expect(scheduler.nextWake, DateTime(2026, 10, 15, 8));
      await scheduler.tick();
      expect(executed, isEmpty);
    });

    test('an interval task missed several times catches up once', () async {
      final t = add({'prompt': 'check inbox', 'every_seconds': 3600});
      // First due 13:00; device off until 13:20 → one late run, not three.
      now = DateTime(2026, 10, 13, 13, 20);
      await scheduler.recover();
      await scheduler.tick();
      await scheduler.settle();
      expect(executed, ['t']);
      expect(t['status'], 'pending');
      expect(DateTime.parse(t['fireAt'] as String).toLocal(),
          DateTime(2026, 10, 13, 14));
      await scheduler.tick();
      await scheduler.settle();
      expect(executed, ['t'], reason: 'collapsed into a single catch-up run');
    });

    test('future tasks keep their deadline across recovery', () async {
      add({'prompt': 'later', 'after_seconds': 7200});
      final before = scheduler.nextWake;
      await scheduler.recover();
      expect(scheduler.nextWake, before);
    });
  });

  group('result notifications hook', () {
    test('retries are reported as willRetry, the final failure is not', () async {
      outcome = (_) => const ScheduleResult.retryable('offline');
      final t = add({'prompt': 'sync', 'after_seconds': 1, 'max_retries': 1});
      now = now.add(const Duration(seconds: 2));
      await scheduler.tick();
      await scheduler.settle();
      expect(results.single, ('t', 'failed', true));
      now = DateTime.parse(t['fireAt'] as String).add(const Duration(seconds: 1));
      await scheduler.tick();
      await scheduler.settle();
      expect(results.last, ('t', 'failed', false));
      expect(t['status'], 'failed');
    });

    test('an observer that throws never breaks dispatch', () async {
      scheduler.onResult = (_, _, _) => throw StateError('boom');
      final t = add({'prompt': 'x', 'after_seconds': 1});
      now = now.add(const Duration(seconds: 2));
      await scheduler.tick();
      await scheduler.settle();
      expect(t['status'], 'completed');
    });
  });
}
