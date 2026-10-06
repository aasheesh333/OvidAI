import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

void main() {
  test(
    'caller cancels actual long cron work while event loop stays responsive',
    () async {
      final token = UtilityCancellation();
      final pending = CronDesignerCapability().callTool('next_runs', {
        'expression': '* * 31 2 *',
        'start_time': '2026-01-01T00:00:00Z',
        'timezone': 'device-local',
        'horizon_days': 2928,
      }, cancellation: token);
      final check = expectLater(
        pending,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('cancelled'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await check;
      expect(
        await JsonVisualizerCapability().callTool('minify', {
          'json_string': ' [1] ',
        }),
        '[1]',
      );
    },
  );
  test(
    'aggregate utility concurrency refuses fifth job and recovers',
    () async {
      final tokens = List.generate(4, (_) => UtilityCancellation());
      final checks = [
        for (final token in tokens)
          expectLater(
            runBoundedUtility(() {
              while (true) {}
            }, cancellation: token),
            throwsFormatException,
          ),
      ];
      await expectLater(
        runBoundedUtility(() => 'overflow'),
        throwsFormatException,
      );
      for (final token in tokens) {
        token.cancel();
      }
      await Future.wait(checks);
      // Late isolate spawns retain their slot until spawn completion.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await runBoundedUtility(() => 'recovered'), 'recovered');
    },
  );
  test(
    'utility deadline terminates CPU work and permits subsequent operations',
    () async {
      final clock = Stopwatch()..start();
      await expectLater(
        runBoundedUtility(() {
          while (true) {}
        }, timeoutMs: 50),
        throwsFormatException,
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
      expect(await runBoundedUtility(() => 'ok'), 'ok');
    },
  );
}
