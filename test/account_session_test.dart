import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_session.dart';

void main() {
  test('identity cannot enter app until server acknowledges login', () async {
    final session = AccountSession();
    final ack = Completer<void>();
    final pending = session.bind('alice', () => ack.future);
    expect(session.ready, isFalse);
    ack.complete();
    await pending;
    expect(session.ready, isTrue);
  });
  test(
    'failed cancellation never grants access and retry can recover',
    () async {
      final session = AccountSession();
      await session.bind('alice', () async => throw Exception('offline'));
      expect(session.ready, isFalse);
      expect(session.error, isNotNull);
      await session.bind('alice', () async {});
      expect(session.ready, isTrue);
      expect(session.error, isNull);
    },
  );
  test(
    'late response after sign-out or account switch cannot restore old UID',
    () async {
      final session = AccountSession();
      final old = Completer<void>();
      final pending = session.bind('alice', () => old.future);
      session.clear();
      await session.bind('bob', () async => throw Exception('offline'));
      old.complete();
      await pending;
      expect(session.ready, isFalse);
      expect(session.uid, 'bob');
    },
  );
}
