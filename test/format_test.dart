import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/format.dart';

/// P1: long counts are shortened everywhere (usage, time, chat stats).
void main() {
  group('formatCompactCount', () {
    test('leaves sub-thousand values raw', () {
      expect(formatCompactCount(0), '0');
      expect(formatCompactCount(999), '999');
    });

    test('uses K/M/B with one decimal, trimming .0', () {
      expect(formatCompactCount(1000), '1K');
      expect(formatCompactCount(1500), '1.5K');
      expect(formatCompactCount(25708), '25.7K');
      expect(formatCompactCount(2500000), '2.5M');
      expect(formatCompactCount(25708000), '25.7M');
      expect(formatCompactCount(2500000000), '2.5B');
    });

    test('never emits the raw "25708k" form', () {
      expect(formatCompactCount(25708000), isNot(contains('25708')));
      expect(formatCompactCount(25708000).toLowerCase(), isNot(endsWith('k')));
    });

    test('handles negatives', () {
      expect(formatCompactCount(-1500), '-1.5K');
    });
  });

  group('formatCompactDuration', () {
    test('formats sub-minute durations with second precision', () {
      expect(formatCompactDuration(const Duration(milliseconds: 400)), '0.4s');
      expect(formatCompactDuration(const Duration(seconds: 12)), '12s');
      expect(formatCompactDuration(const Duration(seconds: 59)), '59s');
    });

    test('formats 567 seconds as minutes and seconds, never raw 567s', () {
      expect(formatCompactDuration(const Duration(seconds: 567)), '9m 27s');
      expect(formatCompactDuration(const Duration(seconds: 567)),
          isNot(contains('567s')));
    });

    test('formats hours cleanly', () {
      expect(
          formatCompactDuration(const Duration(hours: 2, minutes: 5, seconds: 12)),
          '2h 5m');
    });
  });

  group('local date/time (SH-016, SH-022)', () {
    final now = DateTime(2026, 10, 19, 8, 0);

    test('formats wall-clock time without ISO noise', () {
      expect(formatLocalDateTime(DateTime(2026, 10, 19, 13, 45), now: now),
          'Oct 19, 1:45 PM');
      expect(formatLocalDateTime(DateTime(2026, 10, 20, 0, 5), now: now),
          'Oct 20, 12:05 AM');
      expect(formatLocalDateTime(DateTime(2027, 1, 2, 9, 0), now: now),
          'Jan 2, 2027, 9:00 AM');
      expect(formatLocalDay(DateTime(2026, 10, 18), now: now), 'Oct 18');
    });

    test('time until is coarse and human', () {
      expect(formatTimeUntil(now.add(const Duration(hours: 5, minutes: 12)),
          now: now), 'in 5 h 12 m');
      expect(formatTimeUntil(now.add(const Duration(minutes: 12)), now: now),
          'in 12 m');
      expect(formatTimeUntil(now.add(const Duration(seconds: 20)), now: now),
          'in under a minute');
      expect(formatTimeUntil(now.add(const Duration(days: 2, hours: 3)),
          now: now), 'in 2 d 3 h');
      expect(formatTimeUntil(now.subtract(const Duration(minutes: 1)),
          now: now), 'now');
    });

    test('reset label and deadline combine both', () {
      final at = DateTime(2026, 10, 19, 13, 45);
      expect(formatResetLabel(at, now: now), 'Resets in 5 h 45 m · Oct 19, 1:45 PM');
      expect(formatDeadline(at, now: now), 'Oct 19, 1:45 PM (in 5 h 45 m)');
    });
  });
}
