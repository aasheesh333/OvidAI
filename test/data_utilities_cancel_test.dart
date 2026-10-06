import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

void main() {
  test(
    'cancelling a long regex call aborts promptly instead of waiting for timeout',
    () async {
      final token = UtilityCancellation();
      final clock = Stopwatch()..start();
      final pending = RegexBuilderCapability().callTool('test', {
        'pattern': r'(a+)+$',
        'text': '${'a' * 30}b',
        'timeout_ms': 2000,
      }, cancellation: token);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      token.cancel();
      await assertion;
      // The 2000 ms regex deadline was never reached; cancellation won.
      expect(clock.elapsed, lessThan(const Duration(milliseconds: 1500)));
      // The caller stays responsive for subsequent utility calls.
      expect(
        await JsonVisualizerCapability().callTool('minify', {
          'json_string': '[1,2,3]',
        }),
        '[1,2,3]',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('pre-cancelled synchronous utilities abort before doing work', () async {
    final token = UtilityCancellation()..cancel();
    Future<void> expectCancelled(Future<String> call) => expectLater(
      call,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );
    await expectCancelled(
      SqlFormatterCapability().callTool('format', {
        'sql': 'select a from b where c = 1',
      }, cancellation: token),
    );
    await expectCancelled(
      ColorPaletteGenCapability().callTool('from_hex', {
        'hex': '#3366ff',
      }, cancellation: token),
    );
  });

  test('null cancellation preserves existing behavior', () async {
    expect(
      await SqlFormatterCapability().callTool('format', {
        'sql': 'select a from b where c = 1',
      }),
      isNotEmpty,
    );
    expect(
      await ColorPaletteGenCapability().callTool('from_hex', {
        'hex': '#3366ff',
      }),
      contains('complementary'),
    );
    expect(
      await RegexBuilderCapability().callTool('test', {
        'pattern': 'x+',
        'text': 'xxx',
      }),
      contains('"count":1'),
    );
  });
}
