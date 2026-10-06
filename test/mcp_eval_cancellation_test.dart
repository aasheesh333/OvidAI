import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    McpService.rpcTimeoutSecondsForTest = null;
  });

  tearDown(() {
    McpService.rpcTimeoutSecondsForTest = null;
  });

  test('a stalled MCP tool call is aborted when the token is cancelled', () async {
    final token = UtilityCancellation();
    final stopwatch = Stopwatch()..start();

    // No canned replies: the call stalls until the cancellation token fires.
    final pending = McpService.callToolForTest(
      replies: const [],
      timeout: const Duration(seconds: 30),
      cancellation: token,
    );

    await Future<void>.delayed(const Duration(milliseconds: 30));
    token.cancel();

    final result = await pending;
    stopwatch.stop();

    expect(result.toLowerCase(), contains('cancel'));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'cancellation must abort the stalled call, not wait for timeout',
    );
  });

  test('an already-cancelled token short-circuits the call', () async {
    final token = UtilityCancellation()..cancel();
    final stopwatch = Stopwatch()..start();

    final result = await McpService.callToolForTest(
      replies: const [],
      timeout: const Duration(seconds: 30),
      cancellation: token,
    );
    stopwatch.stop();

    expect(result.toLowerCase(), contains('cancel'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('a call without cancellation still resolves normally', () async {
    final result = await McpService.callToolForTest(
      replies: const [
        '{"jsonrpc":"2.0","id":1,"result":{"content":['
            '{"type":"text","text":"hello"}]}}',
      ],
    );

    expect(result, 'hello');
  });
}
