import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/model_failure.dart';

void main() {
  test('empty response reports only known facts', () {
    final f = ModelFailure.fromError('empty response from auto');
    expect(f.kind, ModelFailureKind.emptyResponse);
    expect(f.message.toLowerCase(), contains('no content'));
    expect(f.message, isNot(contains('timeout')));
    expect(f.action.toLowerCase(), contains('retry'));
  });
  test('HTTP causes offer distinct actions without guessing credentials', () {
    final auth = ModelFailure.fromError('HTTP 401 Proxy · auto');
    final denied = ModelFailure.fromError('HTTP 403 Proxy · auto');
    final limited = ModelFailure.fromError('HTTP 429 Proxy · auto');
    expect(auth.kind, ModelFailureKind.authentication);
    expect(auth.action, contains('credentials'));
    expect(denied.kind, ModelFailureKind.permission);
    expect(denied.message, isNot(contains('expired')));
    expect(limited.kind, ModelFailureKind.rateLimit);
    expect(limited.action, contains('Wait'));
  });
  test('timeout advice is limited to a real response timeout', () {
    final f = ModelFailure.fromError(
      'stream error: TimeoutException: model stream idle for 120s',
    );
    expect(f.kind, ModelFailureKind.timeout);
    expect(f.action, contains('AI response timeout'));
    final network = ModelFailure.fromError(
      'stream error: SocketException: Connection refused',
    );
    expect(network.kind, ModelFailureKind.network);
    expect(network.action, isNot(contains('AI response timeout')));
  });
  test('unknown detail is deduplicated without inventing a diagnosis', () {
    final f = ModelFailure.fromError('custom failure\ncustom failure');
    expect(f.kind, ModelFailureKind.unknown);
    expect('custom failure'.allMatches(f.transcript).length, 1);
    expect(f.transcript, isNot(contains('timeout')));
  });
}
