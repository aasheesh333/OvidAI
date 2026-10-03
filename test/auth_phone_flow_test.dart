import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';

class PhoneHarness {
  final requests = <PhoneCallbacks>[];
  final tokens = <int?>[];
  final applied = <AuthCredential>[];
  String? uid;
  Completer<void>? pending;
  Object? failure;
  late final flow = PhoneAuthFlow(
    currentUid: () => uid,
    verify: (number, token, callbacks) async {
      tokens.add(token);
      requests.add(callbacks);
    },
    apply: (credential) async {
      applied.add(credential);
      if (failure != null) throw failure!;
      await pending?.future;
    },
  );
}

void main() {
  testWidgets(
    'disposing during SDK submission discards result and further automatic callbacks',
    (tester) async {
      final h = PhoneHarness()..pending = Completer<void>();
      await h.flow.send('+14155550100');
      final callbacks = h.requests.single;
      callbacks.completed(
        PhoneAuthProvider.credential(verificationId: 'auto', smsCode: '123456'),
      );
      await tester.pump();
      expect(h.applied, hasLength(1));
      h.flow.dispose();
      h.pending!.complete();
      callbacks.completed(
        PhoneAuthProvider.credential(verificationId: 'late', smsCode: '654321'),
      );
      await tester.pump();
      expect(h.applied, hasLength(1));
      expect(h.flow.succeeded, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cancellation from submitting notification prevents SDK submission',
    (tester) async {
      final h = PhoneHarness();
      await h.flow.send('+14155550100');
      var cancelled = false;
      h.flow.addListener(() {
        if (h.flow.submitting && !cancelled) {
          cancelled = true;
          h.flow.cancel();
        }
      });
      h.requests.single.completed(
        PhoneAuthProvider.credential(verificationId: 'auto', smsCode: '123456'),
      );
      await tester.pump();
      expect(h.applied, isEmpty);
      expect(h.flow.submitting, isFalse);
      h.flow.dispose();
    },
  );
  testWidgets(
    'signout and return to same UID invalidates previous session OTP',
    (tester) async {
      var session = 0;
      late PhoneCallbacks callbacks;
      var applied = 0;
      final flow = PhoneAuthFlow(
        currentUid: () => 'alice',
        currentSession: () => session,
        verify: (_, _, cb) async {
          callbacks = cb;
        },
        apply: (_) async {
          applied++;
        },
      );
      await flow.send('+14155550100');
      session += 2;
      callbacks.completed(
        PhoneAuthProvider.credential(
          verificationId: 'old-session',
          smsCode: '123456',
        ),
      );
      await tester.pump();
      expect(applied, 0);
      expect(flow.error, contains('account changed'));
      flow.dispose();
    },
  );
  testWidgets(
    'cancel during credential submission cannot start overlapping work',
    (tester) async {
      final h = PhoneHarness()..pending = Completer<void>();
      await h.flow.send('+14155550100');
      h.requests.single.codeSent('first', 1);
      final pending = h.flow.submit('123456');
      h.flow.cancel();
      await h.flow.send('+14155550101');
      expect(h.requests, hasLength(1));
      h.pending!.complete();
      await pending;
      expect(h.flow.succeeded, isFalse);
      expect(h.flow.submitting, isFalse);
      h.flow.dispose();
    },
  );
  testWidgets('disposed flow and failed verifier reject every late callback', (
    tester,
  ) async {
    late PhoneCallbacks callbacks;
    var applied = 0;
    final flow = PhoneAuthFlow(
      currentUid: () => null,
      verify: (_, _, cb) async {
        callbacks = cb;
        throw FirebaseAuthException(code: 'network-request-failed');
      },
      apply: (_) async {
        applied++;
      },
    );
    await flow.send('+14155550100');
    callbacks.completed(
      PhoneAuthProvider.credential(verificationId: 'late', smsCode: '123456'),
    );
    await tester.pump();
    expect(applied, 0);
    flow.dispose();
    callbacks.codeSent('late', 1);
    callbacks.timedOut('late');
    callbacks.failed(FirebaseAuthException(code: 'quota-exceeded'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'five wrong attempts require a fresh code; SMS sends are bounded',
    (tester) async {
      final h = PhoneHarness();
      await h.flow.send('+14155550100');
      h.requests.single.codeSent('first', 1);
      h.failure = FirebaseAuthException(code: 'invalid-verification-code');
      for (var i = 0; i < 6; i++) {
        await h.flow.submit('123456');
      }
      expect(h.applied, hasLength(5));
      expect(h.flow.hasCode, isFalse);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 60));
        await h.flow.resend();
        h.requests.last.codeSent('resend', 1);
      }
      expect(h.requests, hasLength(5));
      h.flow.dispose();
    },
  );

  testWidgets('cancel and number change invalidate late automatic callbacks', (
    tester,
  ) async {
    final h = PhoneHarness();
    await h.flow.send('+14155550100');
    final old = h.requests.single;
    h.flow.cancel();
    await h.flow.send('+14155550101');
    old.completed(
      PhoneAuthProvider.credential(verificationId: 'old', smsCode: '123456'),
    );
    old.codeSent('old', 11);
    await tester.pump();
    expect(h.applied, isEmpty);
    expect(h.flow.hasCode, isFalse);
    h.flow.dispose();
  });

  testWidgets('resend waits, reuses token, and rejects previous request', (
    tester,
  ) async {
    final h = PhoneHarness();
    await h.flow.send('+14155550100');
    h.requests[0].codeSent('first', 42);
    await h.flow.resend();
    expect(h.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 60));
    await h.flow.resend();
    expect(h.tokens, [null, 42]);
    h.requests[0].codeSent('stale', 99);
    expect(h.flow.hasCode, isFalse);
    h.requests[1].codeSent('second', 43);
    await h.flow.submit('123456');
    expect((h.applied.single as PhoneAuthCredential).verificationId, 'second');
    expect(h.flow.succeeded, isTrue);
    h.flow.dispose();
  });

  testWidgets(
    'auto retrieval timeout still allows manual code; completion is single-flight',
    (tester) async {
      final h = PhoneHarness()..pending = Completer<void>();
      await h.flow.send('+14155550100');
      h.requests.single.timedOut('manual');
      final manual = h.flow.submit('123456');
      h.requests.single.completed(
        PhoneAuthProvider.credential(verificationId: 'auto', smsCode: '123456'),
      );
      await tester.pump();
      expect(h.applied, hasLength(1));
      h.pending!.complete();
      await manual;
      expect(h.flow.succeeded, isTrue);
      h.flow.dispose();
    },
  );

  testWidgets('expiry and account switch prevent credential application', (
    tester,
  ) async {
    final h = PhoneHarness()..uid = 'alice';
    await h.flow.send('+14155550100');
    h.requests.single.codeSent('first', null);
    h.uid = 'bob';
    await h.flow.submit('123456');
    expect(h.applied, isEmpty);
    expect(h.flow.succeeded, isFalse);
    h.flow.dispose();
    final expired = PhoneHarness();
    await expired.flow.send('+14155550100');
    expired.requests.single.codeSent('first', null);
    await tester.pump(const Duration(minutes: 5));
    await expired.flow.submit('123456');
    expect(expired.applied, isEmpty);
    expect(expired.flow.error, contains('expired'));
    expired.flow.dispose();
  });

  testWidgets('wrong code remains retryable; disabled provider is truthful', (
    tester,
  ) async {
    final h = PhoneHarness();
    await h.flow.send('+14155550100');
    h.requests.single.codeSent('first', null);
    h.failure = FirebaseAuthException(code: 'invalid-verification-code');
    await h.flow.submit('123456');
    expect(h.flow.hasCode, isTrue);
    expect(h.flow.error, contains('code'));
    h.failure = null;
    await h.flow.submit('654321');
    expect(h.flow.succeeded, isTrue);
    h.flow.dispose();
    final disabled = PhoneHarness();
    await disabled.flow.send('+14155550100');
    disabled.requests.single.failed(
      FirebaseAuthException(code: 'operation-not-allowed'),
    );
    expect(disabled.flow.error, contains('not enabled'));
    expect(disabled.flow.succeeded, isFalse);
    disabled.flow.dispose();
  });
}
