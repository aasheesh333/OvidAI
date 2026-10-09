import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';

void main() {
  test(
    'account switch while obtaining attestation cannot submit deletion',
    () async {
      var uid = 'alice';
      var calls = 0;
      final service = AccountService(
        enabled: true,
        currentUid: () => uid,
        idToken: (_) async => 'alice-token',
        appCheck: () async {
          uid = 'bob';
          return 'attested';
        },
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.requestDeletion('request-0001'),
        throwsA(isA<AccountException>()),
      );
      expect(calls, 0);
    },
  );
  test('request uses fresh token and attestation without a client UID', () async {
    var refreshed = false;
    final service = AccountService(
      enabled: true,
      idToken: (force) async {
        refreshed = force;
        return 'identity';
      },
      appCheck: () async => 'attested',
      client: MockClient((request) async {
        expect(request.url.path, '/account/deletion');
        expect(request.headers['Authorization'], 'Bearer identity');
        expect(request.headers['X-Firebase-AppCheck'], 'attested');
        expect(jsonDecode(request.body), {'request_id': 'request-0001'});
        return http.Response(
          '{"state":"pending","delete_after":87400,"request_id":"request-0001"}',
          200,
        );
      }),
    );
    final result = await service.requestDeletion('request-0001');
    expect(refreshed, isTrue);
    expect(result.isPending, isTrue);
    expect(
      result.deleteAfter,
      DateTime.fromMillisecondsSinceEpoch(87400000, isUtc: true),
    );
  });

  test('unavailable backend never reports a deletion as accepted', () async {
    for (final status in [401, 403, 404, 409, 500]) {
      final service = AccountService(
        enabled: true,
        idToken: (_) async => 'id',
        appCheck: () async => 'app',
        client: MockClient((_) async => http.Response('{}', status)),
      );
      await expectLater(
        service.requestDeletion('request-0001'),
        throwsA(isA<AccountException>()),
      );
    }
  });

  test('missing credentials or disabled deployment makes no request', () async {
    var calls = 0;
    for (final enabled in [false, true]) {
      final service = AccountService(
        enabled: enabled,
        idToken: (_) async => null,
        appCheck: () async => null,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      await expectLater(
        service.requestDeletion('request-0001'),
        throwsA(isA<AccountException>()),
      );
    }
    expect(calls, 0);
  });

  test(
    'malformed pending deadline cannot become a confirmed request',
    () async {
      final service = AccountService(
        enabled: true,
        idToken: (_) async => 'id',
        appCheck: () async => 'app',
        client: MockClient(
          (_) async => http.Response('{"state":"pending"}', 200),
        ),
      );
      await expectLater(
        service.requestDeletion('request-0001'),
        throwsA(isA<AccountException>()),
      );
    },
  );

  test('login acknowledgement is observational for pending accounts', () async {
    final service = AccountService(
      enabled: true,
      idToken: (_) async => 'id',
      appCheck: () async => 'app',
      client: MockClient((request) async {
        expect(request.url.path, '/account/login');
        return http.Response(
          '{"state":"pending","delete_after":87400,"request_id":"request-0001"}',
          200,
        );
      }),
    );
    expect((await service.acknowledgeLogin()).state, 'pending');
  });

  test(
    'explicit cancellation requires consent and confirms cancelled state',
    () async {
      final service = AccountService(
        enabled: true,
        idToken: (_) async => 'id',
        appCheck: () async => 'app',
        client: MockClient((request) async {
          expect(request.url.path, '/account/deletion/cancel');
          expect(jsonDecode(request.body), {'consent': true});
          return http.Response(
            '{"state":"cancelled","delete_after":87400,"request_id":"request-0001"}',
            200,
          );
        }),
      );
      expect((await service.cancelDeletion()).state, 'cancelled');
    },
  );

  test('cancellation never admits an unconfirmed server state', () async {
    final service = AccountService(
      enabled: true,
      idToken: (_) async => 'id',
      appCheck: () async => 'app',
      client: MockClient((request) async {
        expect(jsonDecode(request.body), {'consent': true});
        return http.Response(
          '{"state":"pending","delete_after":87400,"request_id":"request-0001"}',
          200,
        );
      }),
    );

    await expectLater(
      service.cancelDeletion(),
      throwsA(
        isA<AccountException>().having(
          (error) => error.message,
          'message',
          contains('did not confirm'),
        ),
      ),
    );
  });
}
