import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  test('real HTTP stalled body is aborted and the next request remains usable', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final transport = http.Client();
    addTearDown(() async { transport.close(); await server.close(force: true); });
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.headers.set('cache-control', 'no-store');
      if (requests == 1) {
        request.response.write('{');
        await request.response.flush();
      } else {
        request.response.write(jsonEncode({'schemaVersion': 1, 'session': _session,
          'member': _member, 'members': [_member], 'cursor': 'cursor'}));
        await request.response.close();
      }
    });
    final client = CollaborationClient(baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      httpClient: transport, requestTimeout: const Duration(milliseconds: 200));
    await expectLater(client.state('tok'), throwsA(isA<CollaborationClientException>()
      .having((e) => e.code, 'code', 'request_timeout')));
    expect((await client.state('tok')).member.participantId, 'p-owner');
    expect(requests, 2);
  });
  for (final headersHang in [true, false]) {
    test('deadline aborts ${headersHang ? 'headers' : 'body'} without retrying POST', () async {
      final transport = HangingClient(headersHang);
      final client = CollaborationClient(baseUri: Uri.parse('https://test.invalid'),
        accessToken: () async => 'token', appCheckToken: () async => 'check',
        httpClient: transport, requestTimeout: const Duration(milliseconds: 30));
      await expectLater(client.create(requestId: 'create'), throwsA(
        isA<CollaborationClientException>().having((e) => e.code, 'code', 'request_timeout')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transport.sent, 1);
      expect(transport.aborted, isTrue);
      if (!headersHang) expect(transport.cancelled, isTrue);
    });
  }
  test('typed invite, revoke and leave match the server member routes', () async {
    final requests = <http.Request>[];
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test/chat'),
      accessToken: () async => 'token',
      appCheckToken: () async => 'check',
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(request.method == 'POST' ? {
          'schemaVersion': 1, 'inviteId': 'invite-1', 'inviteCode': 'c' * 43,
          'expiresAt': '2026-10-10T12:00:00.000Z', 'maxUses': 2,
        } : {
          'schemaVersion': 1, 'member': {'participantId': 'p-guest',
            'role': 'participant', 'status': request.url.path.endsWith('/me') ? 'left' : 'revoked'},
        }), 200, headers: {'cache-control': 'no-store'});
      }),
    );
    final invite = await client.createInvite('tok', idempotencyKey: 'invite-1', maxUses: 2, ttlSeconds: 60);
    final revoked = await client.revokeMember('tok', participantId: 'p-guest');
    final left = await client.leave('tok');
    expect(invite.inviteId, 'invite-1');
    expect(invite.inviteCode, 'c' * 43);
    expect(invite.expiresAt, DateTime.utc(2026, 10, 10, 12));
    expect(invite.maxUses, 2);
    expect(revoked.status, MemberStatus.revoked);
    expect(left.status, MemberStatus.left);
    expect(requests.map((r) => '${r.method} ${r.url.path}'), [
      'POST /chat/tok/members', 'DELETE /chat/tok/members/p-guest', 'DELETE /chat/tok/members/me',
    ]);
    expect(jsonDecode(requests.first.body), {'schemaVersion': 1, 'idempotencyKey': 'invite-1',
      'maxUses': 2, 'ttlSeconds': 60});
    expect(requests.skip(1).every((r) => r.body.isEmpty), isTrue);
  });

  test('stream response is cancelled at the byte bound before buffering the rest', () async {
    var read = 0;
    var cancelled = false;
    final transport = StreamingClient(() async* {
      try {
        for (var i = 0; i < 200; i++) {
          read++;
          yield List.filled(256 * 1024, 32);
        }
      } finally {
        cancelled = true;
      }
    });
    final client = CollaborationClient(baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token', appCheckToken: () async => 'check', httpClient: transport);
    await expectLater(client.state('tok'), throwsA(isA<CollaborationClientException>()));
    expect(read, lessThan(40));
    expect(cancelled, isTrue);
  });

  test('request event count, bytes, ids and server fields rejected before transport', () async {
    var sent = 0;
    final client = CollaborationClient(baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      httpClient: MockClient((_) async { sent++; return http.Response('{}', 200); }));
    final event = <String, Object?>{'schemaVersion': 1, 'eventId': 'e', 'kind': 'message', 'payload': {'text': 'hi'}};
    for (final events in <List<Map<String, Object?>>>[
      [], List.generate(101, (i) => {...event, 'eventId': 'e$i'}),
      [event, event], [{...event, 'senderParticipantId': 'spoof'}],
      [{...event, 'payload': {'text': 'x' * (256 * 1024)}}],
      List.generate(8, (i) => {...event, 'eventId': 'e$i', 'payload': {'text': 'x' * (200 * 1024)}}),
    ]) {
      await expectLater(client.appendEvents('tok', events: events, idempotencyKey: 'batch'),
        throwsA(isA<CollaborationClientException>()));
    }
    await expectLater(client.create(requestId: 'bad key!'), throwsA(isA<CollaborationClientException>()));
    expect(sent, 0);
  });

  test('invalid typed success model is converted to a fixed client error', () async {
    final client = CollaborationClient(baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token', appCheckToken: () async => 'check',
      httpClient: MockClient((_) async => http.Response(jsonEncode({
        'schemaVersion': 1, 'session': {..._session, 'lifecycle': 'private-sentinel'},
        'member': _member, 'members': [_member], 'cursor': 'cursor',
      }), 200, headers: {'cache-control': 'no-store'})));
    await expectLater(client.state('tok'), throwsA(isA<CollaborationClientException>()
      .having((e) => e.toString(), 'fixed', 'Invalid collaboration response.')));
  });

  for (final entry in {'rate_limited': 'Collaboration rate limit exceeded',
    'quota_exhausted': 'Collaboration quota exceeded'}.entries) {
    test('decodes fixed ${entry.key} error', () async {
      final client = CollaborationClient(baseUri: Uri.parse('https://collab.example.test'),
        accessToken: () async => 'token', appCheckToken: () async => 'check',
        httpClient: MockClient((_) async => http.Response(jsonEncode({
          'schemaVersion': 1, 'code': entry.key, 'message': entry.value,
        }), 429, headers: {'cache-control': 'no-store'})));
      await expectLater(client.state('tok'), throwsA(isA<CollaborationClientException>()
        .having((e) => e.code, 'code', entry.key)));
    });
  }
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
        appCheckToken: () async => null,
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

class StreamingClient extends http.BaseClient {
  StreamingClient(this.stream);
  final Stream<List<int>> Function() stream;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(stream(), 200, headers: {'cache-control': 'no-store'});
}

class HangingClient extends http.BaseClient {
  HangingClient(this.headersHang);
  final bool headersHang;
  int sent = 0;
  bool aborted = false;
  bool cancelled = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    (request as http.Abortable).abortTrigger!.then((_) => aborted = true);
    if (headersHang) return Completer<http.StreamedResponse>().future;
    final stream = StreamController<List<int>>(onCancel: () { cancelled = true; });
    return Future.value(http.StreamedResponse(stream.stream, 200, headers: {'cache-control': 'no-store'}));
  }
}
