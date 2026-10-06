import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/prompt_framework.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

class _GreetCapability extends NativePromptCapability {
  @override
  String get pluginName => 'Greet Test';

  @override
  String get taskSystemPrompt => 'You are a test helper.';

  @override
  List<NativePluginConfigField> get configFields => const [];

  @override
  List<NativePluginTool> get tools => const [
        NativePluginTool(
          name: 'greet',
          description: 'Greet someone.',
          inputSchema: {'type': 'object'},
        ),
      ];

  @override
  Future<void> configure(Map<String, String> values) async {}

  @override
  String buildPrompt(String toolName, Map<String, dynamic> args) => 'Greet.';
}

void main() {
  tearDown(() {
    NativePromptCapability.executor = null;
  });

  test('null cancellation preserves the wrapped execution', () async {
    expect(
      await runPromptWithCancellation(() async => 'done'),
      'done',
    );
  });

  test('an already-cancelled token aborts before the body starts', () async {
    final token = UtilityCancellation()..cancel();
    var started = false;
    await expectLater(
      runPromptWithCancellation(() async {
        started = true;
        return 'never';
      }, cancellation: token),
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', contains('cancel')),
      ),
    );
    expect(started, isFalse);
  });

  test('a long call + cancel aborts promptly, without waiting for the body',
      () async {
    final token = UtilityCancellation();
    var completed = false;
    final clock = Stopwatch()..start();
    final pending = runPromptWithCancellation(() async {
      await Future<void>.delayed(const Duration(seconds: 10));
      completed = true;
      return 'late';
    }, cancellation: token);
    final check = expectLater(
      pending,
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', contains('cancel')),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await check;
    expect(completed, isFalse);
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('callTool runs the injected executor under the token and aborts',
      () async {
    final token = UtilityCancellation();
    UtilityCancellation? seen;
    var completed = false;
    NativePromptCapability.executor = (
      capability,
      toolName,
      args, {
      cancellation,
    }) async {
      seen = cancellation;
      await Future<void>.delayed(const Duration(seconds: 10));
      completed = true;
      return 'model-text';
    };
    final cap = _GreetCapability();
    final pending = cap.callTool('greet', {'name': 'Ada'}, cancellation: token);
    final check = expectLater(
      pending,
      throwsA(
        isA<FormatException>()
            .having((e) => e.message, 'message', contains('cancel')),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await check;
    expect(seen, same(token));
    expect(completed, isFalse);
  });

  test('callTool returns the executor result when not cancelled', () async {
    NativePromptCapability.executor = (
      capability,
      toolName,
      args, {
      cancellation,
    }) async =>
        'HELLO-${args['name']}';
    expect(
      await _GreetCapability().callTool('greet', {'name': 'Ada'}),
      'HELLO-Ada',
    );
  });

  test('callTool keeps its refusal when no executor is installed', () async {
    final out = await _GreetCapability().callTool('greet', {'name': 'Ada'});
    expect(out, contains('through the agent'));
  });
}
