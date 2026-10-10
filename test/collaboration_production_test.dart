import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/production.dart';

void main() {
  test('created session is durable and a fenced account cannot send', () async {
    final root = await Directory.systemTemp.createTemp(
      'collaboration-production-',
    );
    addTearDown(() => root.delete(recursive: true));
    final requests = <http.Request>[];
    CollaborationProduction make() => CollaborationProduction(
      endpoint: 'https://collab.example',
      rootDirectory: () async => root,
      accountReady: () => true,
      currentUid: () => 'alice',
      accessToken: () async => 'id-token',
      appCheckToken: () async => 'app-check',
      httpClientFactory: () => MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/members') && request.method == 'POST') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'inviteId': 'invite-one',
              'inviteCode': 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ',
              'expiresAt': '2026-10-11T00:00:00Z',
              'maxUses': 1,
            }),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }
        if (request.method == 'DELETE') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'member': {
                'participantId': 'bob',
                'role': 'participant',
                'status': 'revoked',
              },
            }),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }
        if (request.url.path.endsWith('/events')) {
          final event =
              ((jsonDecode(request.body) as Map)['events'] as List).single
                  as Map;
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'events': [
                {
                  ...event,
                  'sessionId': 'session-id',
                  'senderParticipantId': 'alice-participant',
                  'eventSequence': 1,
                  'createdAt': '2026-10-10T00:00:00Z',
                },
              ],
              'nextCursor': 'next',
              'hasMore': false,
            }),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }
        return http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'sessionToken': 'session-token',
            'session': {
              'schemaVersion': 1,
              'sessionId': 'session-id',
              'ownerParticipantId': 'alice-participant',
              'lifecycle': 'active',
            },
            'member': {
              'participantId': 'alice-participant',
              'role': 'owner',
              'status': 'active',
            },
            'cursor': 'initial',
          }),
          200,
          headers: {'cache-control': 'no-store'},
        );
      }),
    );
    var owner = make();
    await owner.bind('alice', 1);
    expect(requests, isEmpty);
    await owner.create();
    expect(owner.sessionToken, 'session-token');
    expect(requests.single.url.path, '/chat');
    // The production send must reach the real client's closed event encoder.
    await owner.sendMessage('my local message');
    expect(requests, hasLength(2));
    final sent = jsonDecode(requests.last.body) as Map;
    expect((sent['events'] as List).single, containsPair('kind', 'message'));
    expect(
      (sent['events'] as List).single,
      containsPair('payload', {'text': 'my local message'}),
    );
    await owner.invite();
    expect(owner.invitationCode, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ');
    await owner.revokeMember('bob');
    expect(requests.last.method, 'DELETE');
    expect(requests.last.url.path, '/chat/session-token/members/bob');
    await owner.release();
    owner = make();
    await owner.bind('alice', 2);
    expect(owner.sessionToken, 'session-token');
    expect(requests, hasLength(4));
    owner.fence();
    expect(owner.sessionToken, isNull);
    await expectLater(
      owner.sendMessage('execute this remote text'),
      throwsStateError,
    );
    expect(requests, hasLength(4));
    await owner.clear();
    expect(await owner.verifyEmpty(), isTrue);
    await owner.release();
  });
}
