// The two destructive account routes:
//   POST /cloud/v1/data/delete-all
//   POST /cloud/v1/memory/reset
//
// The contract is the BUILT gateway, not a sketch:
//   cloud/apps/gateway/src/routes/dataControl.ts (read-only for this client)
//
// The body is STRICT: exactly `{ "confirmation": "<typed email>" }`. The
// caller's uid comes from the bearer token; a body `uid` is rejected by the
// server's `.strict()` schema, so this client must never add one. Phone
// confirmation does not exist server-side, so the client never sends a phone.
//
// Every refusal is reduced to a status + code. The server's `message` is
// deliberately dropped: the screen says its own one plain sentence, and raw
// provider text must never reach it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/data_control_client.dart';

const String _base = 'https://cloud.test/cloud/v1';

http.Response _json(Object body, [int status = 200]) => http.Response(
  body is String ? body : jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response _error(String code, String message, [int status = 400]) => _json({
  'error': {'code': code, 'message': message},
}, status);

class _Gateway {
  _Gateway(this.handler);

  final Future<http.Response> Function(http.Request request) handler;
  final List<http.Request> requests = [];

  DataControlClient client() => DataControlClient(
    rest: CloudRestClient(
      httpClient: MockClient((request) {
        requests.add(request);
        return handler(request);
      }),
      headers: CloudHeaders.forTest(),
      restBase: _base,
    ),
  );
}

void main() {
  group('deleteAll', () {
    test('posts exactly the typed confirmation to its route', () async {
      final gateway = _Gateway(
        (_) async => _json({
          'deleted': {
            'sessions': 2,
            'attachments': 1,
            'artifacts': 3,
            'workspaceFiles': 4,
            'storageObjects': 5,
          },
        }),
      );

      final counts = await gateway.client().deleteAll(
        confirmation: '  Person@Example.com ',
      );

      expect(gateway.requests, hasLength(1));
      final request = gateway.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$_base/data/delete-all');
      // The body is the whole contract: one key, the typed value verbatim
      // (the server trims and compares case-insensitively). No uid, no flag.
      expect(jsonDecode(request.body), {
        'confirmation': '  Person@Example.com ',
      });
      expect((jsonDecode(request.body) as Map).keys, hasLength(1));
      expect(request.headers['x-ovid-client-capabilities'],
          'data-control-partial-v1');

      expect(counts.sessions, 2);
      expect(counts.attachments, 1);
      expect(counts.artifacts, 3);
      expect(counts.workspaceFiles, 4);
      expect(counts.storageObjects, 5);
    });

    test('a zero-count second call is a success, not a failure', () async {
      final gateway = _Gateway(
        (_) async => _json({
          'deleted': {
            'sessions': 0,
            'attachments': 0,
            'artifacts': 0,
            'workspaceFiles': 0,
            'storageObjects': 0,
          },
        }),
      );
      final counts = await gateway.client().deleteAll(
        confirmation: 'me@example.com',
      );
      expect(counts.isEmpty, isTrue);
    });
  });

  group('resetMemory', () {
    test('posts exactly the typed confirmation to its route', () async {
      final gateway = _Gateway(
        (_) async => _json({
          'reset': {'files': 7},
        }),
      );

      final files = await gateway.client().resetMemory(
        confirmation: 'me@example.com',
      );

      final request = gateway.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), '$_base/memory/reset');
      expect(jsonDecode(request.body), {'confirmation': 'me@example.com'});
      expect((jsonDecode(request.body) as Map).keys, hasLength(1));
      expect(files, 7);
    });
  });

  group('refusals', () {
    test(
      '400 confirmation_mismatch keeps the code and one plain sentence',
      () async {
        final gateway = _Gateway(
          (_) async => _error(
            'confirmation_mismatch',
            'Type the email address registered on this account to confirm.',
          ),
        );

        await expectLater(
          gateway.client().deleteAll(confirmation: 'wrong@example.com'),
          throwsA(
            isA<DataControlFailure>()
                .having((f) => f.status, 'status', 400)
                .having((f) => f.code, 'code', 'confirmation_mismatch')
                .having(
                  (f) => f.message,
                  'message',
                  'Type the email address registered on this account to confirm.',
                ),
          ),
        );
      },
    );

    test(
      '409 confirmation_unavailable says the action needs an email',
      () async {
        final gateway = _Gateway(
          (_) async => _error(
            'confirmation_unavailable',
            'This account has no email address to confirm against, so this '
                'action is unavailable. Add an email address first.',
            409,
          ),
        );

        await expectLater(
          gateway.client().resetMemory(confirmation: 'me@example.com'),
          throwsA(
            isA<DataControlFailure>()
                .having((f) => f.code, 'code', 'confirmation_unavailable')
                .having(
                  (f) => f.message,
                  'message',
                  'This action needs an email address on your account.',
                ),
          ),
        );
      },
    );

    test(
      '503 storage_not_configured says the deployment cannot remove files',
      () async {
        final gateway = _Gateway(
          (_) async => _error(
            'storage_not_configured',
            'Object storage is not configured on this deployment, so your '
                'files cannot be removed. Nothing was deleted.',
            503,
          ),
        );
        await expectLater(
          gateway.client().deleteAll(confirmation: 'me@example.com'),
          throwsA(
            isA<DataControlFailure>()
                .having((f) => f.code, 'code', 'storage_not_configured')
                .having(
                  (f) => f.message,
                  'message',
                  'Files cannot be removed right now, so nothing was deleted.',
                ),
          ),
        );
      },
    );

    test(
      '503 storage_delete_failed says chats remain but storage outcome is incomplete',
      () async {
        final gateway = _Gateway(
          (_) async => _error(
            'storage_delete_failed',
            'Some of your files could not be removed from storage. Nothing was '
                'deleted; try again shortly.',
            503,
          ),
        );
        await expectLater(
          gateway.client().deleteAll(confirmation: 'me@example.com'),
          throwsA(
            isA<DataControlFailure>()
                .having((f) => f.code, 'code', 'storage_delete_failed')
                .having(
                  (f) => f.message,
                  'message',
                  'Your chats were not deleted. Stored-file removal may be '
                      'incomplete; try again to finish.',
                ),
          ),
        );
      },
    );

    test('503 storage_delete_partial never says nothing was deleted', () async {
      final gateway = _Gateway(
        (_) async => _error(
          'storage_delete_partial',
          '1 stored file was removed before another file could not be removed.',
          503,
        ),
      );
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>()
              .having((f) => f.code, 'code', 'storage_delete_partial')
              .having(
                (f) => f.message,
                'message',
                'Some stored files were removed before this failed. '
                    'Your chats remain; try again to finish.',
              ),
        ),
      );
    });

    test('an older app is asked to update before destructive deletion', () async {
      final gateway = _Gateway(
        (_) async => _error(
          'client_upgrade_required',
          'This app version cannot safely report storage deletion results.',
          409,
        ),
      );
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>().having(
            (f) => f.message,
            'message',
            'Update Ovid Si before deleting your data. Nothing was deleted.',
          ),
        ),
      );
    });

    test('a signed-out call says to sign in', () async {
      final gateway = _Gateway(
        (_) async =>
            _error('unauthenticated', 'Sign in to use Ovid Cloud.', 401),
      );
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>()
              .having((f) => f.status, 'status', 401)
              .having(
                (f) => f.message,
                'message',
                'Sign in to Ovid Cloud first.',
              ),
        ),
      );
    });

    test('an unreachable gateway never leaks transport text', () async {
      final gateway = _Gateway(
        (_) async => throw const SocketExceptionStub('connection refused'),
      );
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>()
              .having((f) => f.status, 'status', 0)
              .having((f) => f.code, 'code', 'unreachable')
              .having(
                (f) => f.message,
                'message',
                'Ovid Cloud did not answer, so the result is unknown. '
                    'Check your data before retrying.',
              ),
        ),
      );
    });

    test('an unparseable 500 body never becomes the screen text', () async {
      final gateway = _Gateway(
        (_) async => http.Response(
          '<html>upstream connect error</html>',
          500,
          headers: {'content-type': 'text/html'},
        ),
      );
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>().having(
            (f) => f.message,
            'message',
            'Ovid could not confirm the result. Check your data before trying again.',
          ),
        ),
      );
    });
  });

  group('success shapes', () {
    test('a 200 without the deleted envelope is a typed refusal', () async {
      final gateway = _Gateway((_) async => _json({'ok': true}));
      await expectLater(
        gateway.client().deleteAll(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>()
              .having((f) => f.code, 'code', 'invalid_response')
              .having(
                (f) => f.message,
                'message',
                'Ovid Cloud answered unexpectedly, so the result is unknown. '
                    'Check your data before retrying.',
              ),
        ),
      );
    });

    test('a 200 without the reset envelope is a typed refusal', () async {
      final gateway = _Gateway((_) async => _json({'files': 7}));
      await expectLater(
        gateway.client().resetMemory(confirmation: 'me@example.com'),
        throwsA(
          isA<DataControlFailure>().having(
            (f) => f.code,
            'code',
            'invalid_response',
          ),
        ),
      );
    });
  });

  group('copy', () {
    test(
      'every known code maps to one sentence and never echoes the server',
      () {
        const serverText = 'upstream: litellm 500 at /v1/chat';
        for (final code in const [
          'confirmation_mismatch',
          'confirmation_unavailable',
          'storage_not_configured',
          'storage_delete_failed',
          'timeout',
          'unreachable',
          'invalid_response',
          'unauthenticated',
        ]) {
          final sentence = dataControlFailureMessage(status: 503, code: code);
          expect(sentence, isNot(contains(serverText)));
          expect(sentence.trim().endsWith('.'), isTrue, reason: code);
          expect(sentence.contains('\n'), isFalse, reason: code);
          expect(sentence.length, lessThanOrEqualTo(120), reason: code);
        }
      },
    );

    test('an unknown code falls back to one generic sentence', () {
      expect(
        dataControlFailureMessage(status: 500, code: 'some_new_code'),
        'Ovid could not confirm the result. Check your data before trying again.',
      );
      expect(
        dataControlFailureMessage(status: 500, code: 'some_new_code'),
        isNot(contains('some_new_code')),
      );
    });
  });
}

/// A stand-in for a transport failure: [CloudRestClient] turns any throw from
/// the http client into its own `unreachable` answer.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub(this.message);
  final String message;
}
