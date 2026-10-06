import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_cancellation_bridge.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

void main() {
  final bridge = UtilityCancellationBridge.I;

  tearDown(bridge.resetForTest);

  test('signalStop cancels every in-flight token for its run key', () {
    final a = bridge.open('session-stop');
    final b = bridge.open('session-stop');
    expect(a.isCancelled, isFalse);
    expect(b.isCancelled, isFalse);
    expect(bridge.inFlightCountForTest('session-stop'), 2);

    bridge.signalStop('session-stop');

    expect(a.isCancelled, isTrue);
    expect(b.isCancelled, isTrue);
    expect(bridge.inFlightCountForTest('session-stop'), 0);

    // Idempotent: a second Stop for the same run is a harmless no-op.
    bridge.signalStop('session-stop');

    // A token opened AFTER the Stop is a new generation and stays live.
    final after = bridge.open('session-stop');
    expect(after.isCancelled, isFalse);
    bridge.close('session-stop', after);
    expect(bridge.inFlightCountForTest('session-stop'), 0);
  });

  test(
      'an in-flight capability call is aborted by the run Stop signal',
      () async {
    final pending = bridge.run('session-live', (token) {
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
    expect(bridge.inFlightCountForTest('session-live'), 1);

    // The app's Stop signal for this run.
    bridge.signalStop('session-live');

    await cancelled;
    // The finally in run() closed the settled token.
    expect(bridge.inFlightCountForTest('session-live'), 0);
  });

  test('a closed/completed token is never reached by a later Stop', () async {
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

    // close() removes ONLY its own token while a sibling stays in-flight.
    final closed = bridge.open('session-mixed');
    final live = bridge.open('session-mixed');
    bridge.close('session-mixed', closed);
    expect(bridge.inFlightCountForTest('session-mixed'), 1);

    bridge.signalStop('session-mixed');
    expect(closed.isCancelled, isFalse, reason: 'closed token was removed');
    expect(live.isCancelled, isTrue, reason: 'open sibling is cancelled');
    expect(bridge.inFlightCountForTest('session-mixed'), 0);
  });

  test('run() closes its token even when the body throws', () async {
    UtilityCancellation? seen;
    await expectLater(
      bridge.run('session-err', (token) {
        seen = token;
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(seen, isNotNull);
    expect(seen!.isCancelled, isFalse);
    expect(bridge.inFlightCountForTest('session-err'), 0);

    bridge.signalStop('session-err');
    expect(seen!.isCancelled, isFalse);
  });

  test('Stop is scoped to its own run key and leaves other runs untouched',
      () async {
    final stopped = bridge.open('run-a');
    final other = bridge.open('run-b');

    bridge.signalStop('run-a');

    expect(stopped.isCancelled, isTrue);
    expect(other.isCancelled, isFalse);
    expect(bridge.inFlightCountForTest('run-a'), 0);
    expect(bridge.inFlightCountForTest('run-b'), 1);

    // Stopping run-b later must not retroactively affect anything.
    bridge.close('run-b', other);
    expect(bridge.inFlightCountForTest('run-b'), 0);
    bridge.signalStop('run-b');
    expect(other.isCancelled, isFalse);
  });
}
