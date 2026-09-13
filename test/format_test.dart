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
}
