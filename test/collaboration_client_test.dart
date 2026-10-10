import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/client.dart';
import 'package:ovid_ai/core/collaboration/models.dart';

const _session = {
  'schemaVersion': 1,
  'sessionId': 's-1',
  'ownerParticipantId': 'p-owner',
  'lifecycle': 'active',
};
const _member = {
  'participantId': 'p-owner',
  'role': 'owner',
  'status': 'active',
};

void main() {
  for (final status in [200, 403]) {
    test('rejects cacheable collaboration response at status $status', () async {
      final client = CollaborationClient(
        baseUri: Uri.parse('https://collab.example.test'),
        accessToken: () async => 'token',
        appCheckToken: () async => 'app-check',
        httpClient: MockClient((_) async => http.Response('{}', status)),
      );
      await expectLater(client.state('tok'), throwsA(
        isA<CollaborationClientException>().having((e) => e.message, 'message',
          'Invalid collaboration response.'),
      ));
    });
  }

  for (final extra in [<String, Object?>{}, {'code': 'unknown'},
    {'message': 'private sentinel'}, {'extra': 'private sentinel'}]) {
    test('strict fixed collaboration error parsing $extra', () async {
      final client = CollaborationClient(
        baseUri: Uri.parse('https://collab.example.test'),
        accessToken: () async => 'token',
        appCheckToken: () async => 'app-check',
        httpClient: MockClient((request) async {
          expect(request.headers['cache-control'], 'no-store');
          return http.Response(jsonEncode({
            'schemaVersion': 1, 'code': 'not_member',
            'message': 'Not a session member', ...extra,
          }), 403, headers: {'cache-control': 'no-store'});
        }),
      );
      await expectLater(client.state('tok'), throwsA(
        isA<CollaborationClientException>()
          .having((e) => e.code, 'code', extra.isEmpty ? 'not_member' : null)
          .having((e) => e.toString(), 'safe', isNot(contains('private sentinel'))),
      ));
    });
  }
  test(
    'create sends authenticated camelCase idempotent request and decodes models',
    () async {
      http.Request? request;
      final client = CollaborationClient(
        baseUri: Uri.parse('https://collab.example.test/api'),
        accessToken: () async => 'access-token',
        appCheckToken: () async => 'app-check-token',
        httpClient: MockClient((incoming) async {
          request = incoming;
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'sessionToken': 'opaque-token',
              'session': _session,
              'member': _member,
              'cursor': 'cursor-0',
            }),
            201,
            headers: {'cache-control': 'no-store'},
          );
        }),
      );

      final result = await client.create(requestId: 'request-1');

      expect(request!.method, 'POST');
      expect(request!.url.toString(), 'https://collab.example.test/api/chat');
      expect(request!.headers['authorization'], 'Bearer access-token');
      expect(request!.headers['x-firebase-appcheck'], 'app-check-token');
      expect(jsonDecode(request!.body), {
        'schemaVersion': 1,
        'requestId': 'request-1',
        'idempotencyKey': 'request-1',
      });
      expect(result.sessionToken, 'opaque-token');
      expect(result.session.sessionId, 's-1');
      expect(result.member.role, MemberRole.owner);
      expect(result.cursor.value, 'cursor-0');
    },
  );

  test('state, join, replay and close use the specified chat routes', () async {
    final requests = <http.Request>[];
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      appCheckToken: () async => 'app-check-token',
      httpClient: MockClient((request) async {
        requests.add(request);
        switch (request.method) {
          case 'GET' when request.url.path == '/chat/tok':
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'session': _session,
                'member': _member,
                'members': [_member],
                'cursor': 'cursor-1',
              }),
              200,
              headers: {'cache-control': 'no-store'},
            );
          case 'POST' when request.url.path == '/chat/tok/members':
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'member': {
                  ..._member,
                  'participantId': 'p-joined',
                  'role': 'participant',
                },
                'cursor': 'cursor-2',
              }),
              200,
              headers: {'cache-control': 'no-store'},
            );
          case 'GET' when request.url.path == '/chat/tok/events':
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'events': <Object?>[],
                'nextCursor': 'cursor-3',
                'hasMore': false,
              }),
              200,
              headers: {'cache-control': 'no-store'},
            );
          case 'POST' when request.url.path == '/chat/tok/close':
            return http.Response(
              jsonEncode({
                'schemaVersion': 1,
                'session': {..._session, 'lifecycle': 'closed'},
              }),
              200,
              headers: {'cache-control': 'no-store'},
            );
          default:
            return http.Response('{}', 404);
        }
      }),
    );

    final state = await client.state('tok');
    final joined = await client.join(
      'tok',
      invitationCode: 'invite-1',
      idempotencyKey: 'join-1',
    );
    final page = await client.events('tok', cursor: state.cursor);
    final closed = await client.close('tok', idempotencyKey: 'close-1');

    expect(state.members.single.participantId, 'p-owner');
    expect(joined.member.role, MemberRole.participant);
    expect(page.nextCursor.value, 'cursor-3');
    expect(closed.lifecycle, SessionLifecycle.closed);
    expect(requests.map((r) => r.url.path), [
      '/chat/tok',
      '/chat/tok/members',
      '/chat/tok/events',
      '/chat/tok/close',
    ]);
    expect(jsonDecode(requests[1].body), {
      'schemaVersion': 1,
      'invitationCode': 'invite-1',
      'idempotencyKey': 'join-1',
    });
    expect(requests[2].url.queryParameters, {'cursor': 'cursor-1'});
  });

  test(
    'rejects non-2xx and malformed envelopes without exposing response text',
    () async {
      final client = CollaborationClient(
        baseUri: Uri.parse('https://collab.example.test'),
        accessToken: () async => 'token',
        appCheckToken: () async => 'app-check-token',
        httpClient: MockClient(
          (_) async => http.Response('Bearer secret-token leaked', 503,
              headers: {'cache-control': 'no-store'}),
        ),
      );

      await expectLater(
        client.state('tok'),
        throwsA(
          isA<CollaborationClientException>()
              .having((e) => e.message, 'fixed error', 'Invalid collaboration response.')
              .having(
                (e) => e.toString(),
                'message',
                isNot(contains('secret-token')),
              ),
        ),
      );
    },
  );

  test('requires an access token before making a request', () async {
    var called = false;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => null,
      httpClient: MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.state('tok'),
      throwsA(isA<CollaborationClientException>()),
    );
    expect(called, isFalse);
  });

  test('requires App Check and sends no-store for account-backed requests', () async {
    var called = false;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      appCheckToken: () async => null,
      httpClient: MockClient((request) async {
        called = true;
        return http.Response('{}', 200,
            headers: {'cache-control': 'no-store'});
      }),
    );
    await expectLater(client.state('tok'), throwsA(isA<CollaborationClientException>()));
    expect(called, isFalse);
  });
}
