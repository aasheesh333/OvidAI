import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/diag.dart';

void main() {
  setUp(Diag.resetForTest);
  tearDown(Diag.resetForTest);

  test('swallow records context + error and is retrievable', () {
    Diag.swallow('mcp.connect', StateError('boom'));
    final recent = Diag.recent();
    expect(recent, hasLength(1));
    expect(recent.single.context, 'mcp.connect');
    expect(recent.single.error, contains('boom'));
  });

  test('ring buffer is bounded to 200 newest entries', () {
    for (var i = 0; i < 250; i++) {
      Diag.swallow('ctx', 'e$i');
    }
    final recent = Diag.recent();
    expect(recent.length, 200);
    expect(recent.last.error, contains('e249'));
    expect(recent.first.error, contains('e50'));
  });

  test('onSwallow hook fires for every swallow', () {
    final seen = <String>[];
    Diag.onSwallow = (entry) => seen.add(entry.context);
    Diag.swallow('a', 'x');
    Diag.swallow('b', 'y');
    expect(seen, ['a', 'b']);
  });

  test('a throwing onSwallow hook never propagates', () {
    Diag.onSwallow = (_) => throw StateError('hook blew up');
    expect(() => Diag.swallow('safe', 'e'), returnsNormally);
    expect(Diag.recent(), hasLength(1));
  });
}
