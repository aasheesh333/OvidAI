import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/push_registration_coordinator.dart';
import 'package:ovid_ai/core/diag.dart';

class _Store implements PushRegistrationStore {
  PushRegistrationRecord? value;
  Completer<void>? writeGate;
  Completer<void>? writeStarted;
  final writes = <PushRegistrationRecord>[];

  @override
  Future<PushRegistrationRecord?> read() async => value;

  @override
  Future<void> write(PushRegistrationRecord record) async {
    if (writeStarted?.isCompleted == false) writeStarted!.complete();
    await writeGate?.future;
    value = record;
    writes.add(record);
  }
}

class _Messaging {
  _Messaging(this.token);

  String? token;
  int deleteCount = 0;
  final events = <String>[];

  Future<String?> getToken() async => token;

  Future<void> deleteToken() async {
    deleteCount++;
    events.add('delete');
    token = 'fresh-token-$deleteCount';
  }
}

class _Gateway {
  String? authUid;
  int failuresBeforeSuccess = 0;
  bool alwaysFail = false;
  int active = 0;
  int maxActive = 0;
  Completer<void>? firstRegisterGate;
  void Function(String uid)? afterUnregister;

  final calls =
      <({String operation, String uid, String token, String? authUid})>[];
  final acknowledgedPairs = <({String uid, String token})>[];

  Future<void> register(String uid, String token) async {
    active++;
    if (active > maxActive) maxActive = active;
    calls.add((
      operation: 'register',
      uid: uid,
      token: token,
      authUid: authUid,
    ));
    try {
      if (calls.where((c) => c.operation == 'register').length == 1) {
        await firstRegisterGate?.future;
      }
      if (authUid != uid) throw StateError('Authenticated account changed.');
      if (alwaysFail || failuresBeforeSuccess > 0) {
        if (failuresBeforeSuccess > 0) failuresBeforeSuccess--;
        throw CloudApiException(
          status: 503,
          code: 'unavailable',
          message: 'Registration failed for $token',
        );
      }
      acknowledgedPairs.removeWhere((pair) => pair.token == token);
      acknowledgedPairs.add((uid: uid, token: token));
    } finally {
      active--;
    }
  }

  Future<void> unregister(String uid, String token) async {
    calls.add((
      operation: 'unregister',
      uid: uid,
      token: token,
      authUid: authUid,
    ));
    if (authUid != uid) throw StateError('Authenticated account changed.');
    acknowledgedPairs.removeWhere(
      (pair) => pair.uid == uid && pair.token == token,
    );
    afterUnregister?.call(uid);
  }
}

class _Harness {
  _Harness() {
    gateway.authUid = 'uid-a';
  }

  final store = _Store();
  final messaging = _Messaging('token-a-1');
  final gateway = _Gateway();
  final delays = <Duration>[];
  late final PushRegistrationCoordinator coordinator;

  Future<void> open({
    int attempts = 3,
    Duration initialBackoff = const Duration(milliseconds: 20),
    Duration maxBackoff = const Duration(milliseconds: 50),
  }) async {
    coordinator = await PushRegistrationCoordinator.open(
      register: gateway.register,
      unregister: gateway.unregister,
      getToken: messaging.getToken,
      deleteToken: messaging.deleteToken,
      store: store,
      maxAttempts: attempts,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      delay: (duration) async => delays.add(duration),
    );
  }
}

void main() {
  setUp(Diag.resetForTest);
  tearDown(Diag.resetForTest);

  test(
    'unacknowledged bind retries with bounded exponential backoff',
    () async {
      final h = _Harness();
      await h.open(attempts: 3);
      h.gateway.failuresBeforeSuccess = 2;

      await h.coordinator.bindAccount('uid-a');

      expect(h.gateway.acknowledgedPairs, hasLength(1));
      expect(h.delays, [
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 40),
      ]);
      expect(h.coordinator.health.registered, isTrue);
      expect(h.coordinator.health.retryPending, isFalse);
      expect(h.coordinator.health.retryCount, 0);
    },
  );

  test(
    'same-account rebind retries an exhausted unacknowledged registration',
    () async {
      final h = _Harness();
      await h.open(attempts: 2, initialBackoff: Duration.zero);
      h.gateway.alwaysFail = true;
      await h.coordinator.bindAccount('uid-a');
      expect(h.coordinator.health.registered, isFalse);
      expect(
        h.gateway.calls.where((c) => c.operation == 'register'),
        hasLength(2),
      );

      h.gateway.alwaysFail = false;
      await h.coordinator.bindAccount('uid-a');

      expect(
        h.gateway.calls.where((c) => c.operation == 'register'),
        hasLength(3),
      );
      expect(h.coordinator.health.registered, isTrue);
    },
  );

  test(
    'non-2xx with a token is unregistered and diagnostics redact the token',
    () async {
      final h = _Harness();
      await h.open(attempts: 1);
      h.gateway.alwaysFail = true;

      await h.coordinator.bindAccount('uid-a');

      final health = h.coordinator.health;
      expect(health.tokenAvailable, isTrue);
      expect(health.registered, isFalse);
      expect(health.acknowledgedUid, isNull);
      expect(health.lastError, contains('503'));
      expect(health.lastError, isNot(contains('token-a-1')));
      expect(
        Diag.recent().map((d) => d.error).join('\n'),
        isNot(contains('token-a-1')),
      );
    },
  );

  test('late callbacks cannot cross account generations', () async {
    final h = _Harness();
    await h.open(attempts: 1);
    final oldGeneration = await h.coordinator.bindAccount('uid-a');
    h.gateway.afterUnregister = (uid) {
      if (uid == 'uid-a') h.gateway.authUid = 'uid-b';
    };

    await h.coordinator.switchAccount('uid-a', 'uid-b');
    await h.coordinator.refreshToken(
      'late-token-for-a',
      generation: oldGeneration,
    );
    await h.coordinator.drain();

    expect(h.gateway.acknowledgedPairs.map((p) => p.uid).toSet(), {'uid-b'});
    expect(
      h.gateway.acknowledgedPairs.any((p) => p.token == 'late-token-for-a'),
      isFalse,
    );
    expect(h.coordinator.health.registered, isTrue);
    expect(h.coordinator.health.acknowledgedUid, 'uid-b');
  });

  test(
    'unbind uses A auth before sign-out and only then invalidates the token',
    () async {
      final h = _Harness();
      await h.open(attempts: 1);
      await h.coordinator.bindAccount('uid-a');
      h.gateway.afterUnregister = (uid) {
        if (uid == 'uid-a') h.gateway.authUid = null;
      };

      await h.coordinator.unbindAccount();

      final unregister = h.gateway.calls.singleWhere(
        (c) => c.operation == 'unregister',
      );
      expect(unregister.uid, 'uid-a');
      expect(unregister.authUid, 'uid-a');
      expect(h.gateway.authUid, isNull);
      expect(h.messaging.events, ['delete']);
      expect(h.coordinator.health.registered, isFalse);
    },
  );

  test(
    'queued B cannot suppress outgoing A cleanup and reuse its token',
    () async {
      final h = _Harness();
      await h.open(attempts: 1);
      await h.coordinator.bindAccount('uid-a');
      h.store.writeGate = Completer<void>();
      h.store.writeStarted = Completer<void>();
      final unbinding = h.coordinator.unbindAccount();
      await h.store.writeStarted!.future;
      expect(h.coordinator.health.desiredUid, isNull);

      h.gateway.authUid = 'uid-b';
      final binding = h.coordinator.bindAccount('uid-b');
      h.store.writeGate!.complete();
      await Future.wait([unbinding, binding]);
      await h.coordinator.drain();

      expect(h.messaging.deleteCount, 1);
      expect(h.messaging.events, ['delete']);
      expect(
        h.gateway.acknowledgedPairs
            .where((pair) => pair.uid == 'uid-b')
            .map((pair) => pair.token),
        ['fresh-token-1'],
      );
      expect(
        h.gateway.acknowledgedPairs.any(
          (pair) => pair.uid == 'uid-b' && pair.token == 'token-a-1',
        ),
        isFalse,
      );
      expect(h.coordinator.health.desiredUid, 'uid-b');
      expect(h.coordinator.health.acknowledgedUid, 'uid-b');
      expect(h.coordinator.health.registered, isTrue);
    },
  );

  test('replacement is acknowledged before superseded-token cleanup', () async {
    final h = _Harness();
    await h.open(attempts: 1);
    final generation = await h.coordinator.bindAccount('uid-a');
    h.gateway.calls.clear();

    await h.coordinator.refreshToken('token-a-2', generation: generation);

    expect(h.gateway.calls.map((c) => c.operation), ['register', 'unregister']);
    expect(h.gateway.calls.first.token, 'token-a-2');
    expect(h.gateway.calls.last.token, 'token-a-1');
    expect(
      h.messaging.deleteCount,
      0,
      reason: 'deleting FCM would invalidate the replacement',
    );
    expect(h.coordinator.health.acknowledgedToken, 'token-a-2');
    expect(h.coordinator.health.registered, isTrue);
  });

  test(
    'same-account rebind cleans a superseded token after replacement ack',
    () async {
      final h = _Harness();
      await h.open(attempts: 1);
      await h.coordinator.bindAccount('uid-a');
      h.messaging.token = 'token-a-2';
      h.gateway.calls.clear();

      await h.coordinator.bindAccount('uid-a');

      expect(h.gateway.calls.map((c) => c.operation), [
        'register',
        'unregister',
      ]);
      expect(h.gateway.calls.first.token, 'token-a-2');
      expect(h.gateway.calls.last.token, 'token-a-1');
      expect(h.coordinator.health.registered, isTrue);
    },
  );

  test('bind refresh and cleanup share one serialized queue', () async {
    final h = _Harness();
    await h.open(attempts: 1);
    h.gateway.firstRegisterGate = Completer<void>();

    final binding = h.coordinator.bindAccount('uid-a');
    await Future<void>.delayed(Duration.zero);
    final generation = h.coordinator.health.generation;
    final refreshing = h.coordinator.refreshToken(
      'token-a-2',
      generation: generation,
    );
    await Future<void>.delayed(Duration.zero);
    expect(h.gateway.active, 1);
    expect(h.gateway.calls, hasLength(1));

    h.gateway.firstRegisterGate!.complete();
    await binding;
    await refreshing;
    await h.coordinator.drain();

    expect(h.gateway.maxActive, 1);
    expect(h.coordinator.health.acknowledgedToken, 'token-a-2');
  });

  test(
    'desired and acknowledged identity and generation survive reopening',
    () async {
      final h = _Harness();
      await h.open(attempts: 1);
      final generation = await h.coordinator.bindAccount('uid-a');
      final registrationsBefore = h.gateway.acknowledgedPairs.length;

      final reopened = await PushRegistrationCoordinator.open(
        register: h.gateway.register,
        unregister: h.gateway.unregister,
        getToken: h.messaging.getToken,
        deleteToken: h.messaging.deleteToken,
        store: h.store,
        maxAttempts: 1,
        delay: (_) async {},
      );
      expect(reopened.health.desiredUid, 'uid-a');
      expect(reopened.health.acknowledgedUid, 'uid-a');
      expect(reopened.health.generation, generation);
      expect(
        reopened.health.registered,
        isFalse,
        reason: 'token availability is not restored as a fact',
      );

      await reopened.bindAccount('uid-a');
      expect(reopened.health.registered, isTrue);
      expect(h.gateway.acknowledgedPairs, hasLength(registrationsBefore));
      expect(reopened.health.generation, greaterThan(generation));
    },
  );
}
