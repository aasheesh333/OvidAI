import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/dev_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

Matcher _cancelled() => throwsA(
  isA<FormatException>().having(
    (e) => e.message,
    'reason',
    contains('cancelled'),
  ),
);

void main() {
  test('cancelling a long Env Manager merge aborts in-flight work', () async {
    final base = List.generate(6000, (i) => 'KEY$i=base').join('\n');
    final override = List.generate(6000, (i) => 'KEY$i=override').join('\n');
    final token = UtilityCancellation();
    final pending = EnvManagerCapability().callTool('merge', {
      'base_env': base,
      'override_env': override,
    }, cancellation: token);
    final assertion = expectLater(pending, _cancelled());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel();
    await assertion;
  });

  test('pre-cancelled token aborts before Log Analyzer work starts', () async {
    final token = UtilityCancellation()..cancel();
    await expectLater(
      LogAnalyzerCapability().callTool('parse', {
        'log_text': 'INFO up\nERROR down',
      }, cancellation: token),
      _cancelled(),
    );
  });

  test('pre-cancelled token aborts a Password Vault storage call', () async {
    final token = UtilityCancellation()..cancel();
    await expectLater(
      PasswordVaultCapability().callTool('get', {
        'key': 'missing',
      }, cancellation: token),
      _cancelled(),
    );
  });

  test('null cancellation preserves Env Manager merge', () async {
    final out = await EnvManagerCapability().callTool('merge', {
      'base_env': 'A=1\nB=2\n',
      'override_env': 'B=3\nC=4\n',
    });
    expect(out, contains('A=1'));
    expect(out, contains('B=3'));
    expect(out, isNot(contains('B=2')));
    expect(out, contains('C=4'));
  });

  test('null cancellation preserves Log Analyzer parse', () async {
    final out = await LogAnalyzerCapability().callTool('parse', {
      'log_text': 'INFO up\nERROR down',
    });
    expect(out, contains('"ERROR"'));
  });

  test('null cancellation preserves Password Vault generate', () async {
    final out = await PasswordVaultCapability().callTool('generate', {
      'length': 24,
    });
    expect(out, hasLength(24));
  });
}
