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

  test(
    'overlapping binds for the same UID share one acknowledgement',
    () async {
      final session = AccountSession();
      final acknowledgement = Completer<void>();
      var calls = 0;

      final first = session.bind('alice', () {
        calls++;
        return acknowledgement.future;
      });
      final second = session.bind('alice', () {
        calls++;
        return acknowledgement.future;
      });

      expect(calls, 1);
      acknowledgement.complete();
      await Future.wait([first, second]);
      expect(session.ready, isTrue);
      expect(session.uid, 'alice');
    },
  );

  test('a stale same-UID bind cannot clear a newer auth revision', () async {
    final session = AccountSession();
    final oldAck = Completer<void>();
    final newAck = Completer<void>();
    final old = session.bind('alice', () => oldAck.future);
    session.clear();
    final current = session.bind('alice', () => newAck.future);

    oldAck.complete();
    await old;
    expect(session.ready, isFalse);
    newAck.complete();
    await current;
    expect(session.ready, isTrue);
  });
}
