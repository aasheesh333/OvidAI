import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_cancellation_bridge.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

void main() {
  final bridge = UtilityCancellationBridge.I;

  tearDown(bridge.resetForTest);

  test('Stop signal cancels an in-flight utility cancellation token', () async {
    final pending = bridge.run('session-stop', (token) {
      return CronDesignerCapability().callTool('next_runs', {
        'expression': '* * 31 2 *',
        'start_time': '2026-01-01T00:00:00Z',
        'timezone': 'device-local',
        'horizon_days': 2928,
      }, cancellation: token);
    });
    final cancelled = expectLater(
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
    expect(bridge.inFlightCountForTest('session-stop'), 1);

    // The app's Stop signal for this run.
    bridge.signalStop('session-stop');

    await cancelled;
    // The finally in run() closed the settled token.
    expect(bridge.inFlightCountForTest('session-stop'), 0);
  });

  test('Stop signal does not affect a completed token', () async {
    UtilityCancellation? completed;
    final result = await bridge.run('session-done', (token) {
      completed = token;
      return JsonVisualizerCapability().callTool('minify', {
        'json_string': ' [1] ',
      }, cancellation: token);
    });
    expect(result, '[1]');
    expect(completed, isNotNull);
    expect(completed!.isCancelled, isFalse);
    expect(bridge.inFlightCountForTest('session-done'), 0);

    // A late Stop for the same run is a no-op for the finished call.
    bridge.signalStop('session-done');
    expect(completed!.isCancelled, isFalse);
  });

  test('Stop signal is scoped to its own run key', () async {
    final stopped = bridge.open('run-a');
    final other = bridge.open('run-b');

    bridge.signalStop('run-a');

    expect(stopped.isCancelled, isTrue);
    expect(other.isCancelled, isFalse);
    expect(bridge.inFlightCountForTest('run-b'), 1);

    bridge.close('run-b', other);
    expect(bridge.inFlightCountForTest('run-b'), 0);
  });
}
