import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/client.dart'
    show CollaborationClient, CollaborationClientException, maxCollaborationInviteUses;
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/production.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/ui/collab_session_screen.dart';

const _token = 'TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT';
const _code = 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
const _inviteId = 'i0123456789abcdef0123456789abcdef';

Map<String, Object?> _envelope(
  Map<String, Object?> event,
  int sequence, {
  String sender = 'p-alice',
  String? name = 'Alice Example',
}) => {
  ...event,
  'sessionId': 'session-id',
  'senderParticipantId': sender,
  'eventSequence': sequence,
  'createdAt': '2026-10-10T00:00:00.000Z',
  'senderDisplayName': ?name,
};

/// Minimal in-memory stand-in for the account service's /chat routes.
class _FakeServer {
  final requests = <http.Request>[];
  final appended = <Map<String, Object?>>[];
  var sequence = 0;
  String? joinError;

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'cache-control': 'no-store', 'content-type': 'application/json'},
  );

  Map<String, Object?> get _session => {
    'schemaVersion': 1,
    'sessionId': 'session-id',
    'ownerParticipantId': 'p-alice',
    'lifecycle': 'active',
  };

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/chat' && request.method == 'POST') {
      return _json({
        'schemaVersion': 1,
        'sessionToken': _token,
        'session': _session,
        'member': {'participantId': 'p-alice', 'role': 'owner', 'status': 'active'},
        'cursor': 'c0',
      });
    }
    if (path.endsWith('/events') && request.method == 'POST') {
      final events = (jsonDecode(request.body) as Map)['events'] as List;
      final out = [
        for (final event in events)
          _envelope(Map<String, Object?>.from(event as Map), ++sequence),
      ];
      appended.addAll(out);
      return _json({
        'schemaVersion': 1,
        'events': out,
        'nextCursor': 'c$sequence',
        'hasMore': false,
      });
    }
    if (path.endsWith('/members') && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map;
      if (body.containsKey('invitationCode')) {
        if (joinError != null) {
          return _json({
            'schemaVersion': 1,
            'code': joinError,
            'message': 'Session is full',
          }, 409);
        }
        return _json({
          'schemaVersion': 1,
          'member': {'participantId': 'p-bob', 'role': 'participant', 'status': 'active'},
          'cursor': 'c0',
        });
      }
      return _json({
        'schemaVersion': 1,
        'inviteId': _inviteId,
        'inviteCode': _code,
        'expiresAt': '2026-10-18T00:00:00.000Z',
        'maxUses': body['maxUses'],
      });
    }
    if (path.contains('/invites/') && request.method == 'DELETE') {
      return _json({'schemaVersion': 1, 'inviteId': _inviteId, 'revoked': true});
    }
    return _json({'schemaVersion': 1, 'code': 'invalid_request', 'message': 'x'}, 400);
  }
}

void main() {
  group('wire models', () {
    test('member display names and message roles are optional and round-trip', () {
      final member = Member.fromWire({
        'participantId': 'p1',
        'role': 'participant',
        'status': 'active',
        'displayName': 'Gary',
      });
      expect(member.displayName, 'Gary');
      expect(Member.fromWire(member.toWire()), member);
      expect(
        Member.fromWire({'participantId': 'p1', 'role': 'owner', 'status': 'active'})
            .displayName,
        isNull,
      );
      final event = CollaborationEvent.fromWire(
        _envelope({
          'schemaVersion': 1,
          'eventId': 'e1',
          'kind': 'message',
          'payload': {'text': 'hi', 'role': 'assistant', 'model': 'gpt-x', 'replyTo': 'e0'},
        }, 1),
      );
      final payload = event.payload as MessagePayload;
      expect(payload.role, MessageRole.assistant);
      expect(payload.model, 'gpt-x');
      expect(payload.replyTo, 'e0');
      expect(event.senderDisplayName, 'Alice Example');
      expect(CollaborationEvent.fromWire(event.toWire()).toWire(), event.toWire());
    });

    test('legacy payloads still parse and bad names are rejected', () {
      final legacy = CollaborationEvent.fromWire(
        _envelope({
          'schemaVersion': 1,
          'eventId': 'e1',
          'kind': 'message',
          'payload': {'text': 'hi'},
        }, 1, name: null),
      );
      expect((legacy.payload as MessagePayload).role, isNull);
      expect(legacy.toWire().containsKey('senderDisplayName'), isFalse);
      for (final name in ['/root/x', 'n' * 65, '']) {
        expect(
          () => CollaborationEvent.fromWire(
            _envelope({
              'schemaVersion': 1,
              'eventId': 'e1',
              'kind': 'presence',
              'payload': {'state': 'online'},
            }, 1, name: name),
          ),
          throwsA(isA<CollaborationWireException>()),
        );
      }
      expect(
        () => CollaborationEvent.fromWire(
          _envelope({
            'schemaVersion': 1,
            'eventId': 'e1',
            'kind': 'message',
            'payload': {'text': 'hi', 'role': 'system'},
          }, 1),
        ),
        throwsA(isA<CollaborationWireException>()),
      );
    });
  });

  test('reducer tracks author names with neutral fallbacks', () {
    var state = CollaborationState.bootstrap(
      session: CollaborationSession.fromWire({
        'schemaVersion': 1,
        'sessionId': 'session-id',
        'ownerParticipantId': 'p-alice',
        'lifecycle': 'active',
      }),
      members: const [
        Member(participantId: 'p-alice', role: MemberRole.owner, status: MemberStatus.active),
      ],
      localParticipantId: 'p-alice',
      lastSequence: 0,
    );
    expect(state.nameOf('p-alice'), 'Owner');
    const reducer = CollaborationReducer();
    state = reducer.apply(
      state,
      CollaborationEvent.fromWire(_envelope({
        'schemaVersion': 1,
        'eventId': 'j',
        'kind': 'membership',
        'payload': {'action': 'joined', 'participantId': 'p-bob', 'role': 'participant'},
      }, 1, sender: 'p-bob', name: 'bob')),
    );
    state = reducer.apply(
      state,
      CollaborationEvent.fromWire(_envelope({
        'schemaVersion': 1,
        'eventId': 'm',
        'kind': 'message',
        'payload': {'text': 'hello', 'role': 'user'},
      }, 2)),
    );
    expect(state.nameOf('p-bob'), 'bob');
    expect(state.nameOf('p-alice'), 'Alice Example');
    expect(state.nameOf('p-unknown'), 'Member');
    expect(state.messages.single.role, MessageRole.user);
    expect(state.messages.single.authorName, 'Alice Example');
  });

  group('production', () {
    late Directory root;
    late _FakeServer server;
    final runnerCalls = <({String providerId, String model, List<Map<String, dynamic>> messages})>[];

    CollaborationProduction make({CollaborationTurnRunner? runner}) => CollaborationProduction(
      endpoint: 'https://api.example.test',
      publicOrigin: 'https://share.example.test',
      rootDirectory: () async => root,
      accountReady: () => true,
      currentUid: () => 'alice',
      accessToken: () async => 'id-token',
      appCheckToken: () async => 'app-check',
      httpClientFactory: () => MockClient(server.handle),
      turnRunner: runner ??
          ({required providerId, required model, required messages}) async {
            runnerCalls.add((providerId: providerId, model: model, messages: messages));
            return 'Here is my answer.';
          },
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('collab-link-');
      server = _FakeServer();
      runnerCalls.clear();
    });
    tearDown(() => root.delete(recursive: true));

    test('owner starts Collab from a chat: seed, presence and a 50-use link', () async {
      final owner = make();
      await owner.bind('alice', 1);
      await owner.startFromConversation(
        sourceSessionId: 'local-chat',
        seed: const [
          CollaborationSeedMessage(MessageRole.user, 'What is 2+2?'),
          CollaborationSeedMessage(MessageRole.assistant, '4'),
        ],
      );
      expect(owner.shareLink, 'https://share.example.test/s/$_token/$_code');
      expect(owner.sourceSessionId, 'local-chat');
      final invite = server.requests.firstWhere(
        (r) => r.url.path.endsWith('/members'),
      );
      expect(jsonDecode(invite.body), containsPair('maxUses', maxCollaborationInviteUses));
      expect(server.appended.map((e) => e['kind']), ['presence', 'message', 'message']);
      expect(owner.state!.messages.map((m) => m.role), [MessageRole.user, MessageRole.assistant]);

      await owner.revokeLink();
      expect(owner.shareLink, isNull);
      expect(server.requests.last.method, 'DELETE');
      expect(server.requests.last.url.path, '/chat/$_token/invites/$_inviteId');
      await owner.newLink();
      expect(owner.shareLink, isNotNull);
      await owner.release();
    });

    test('a turn publishes the prompt, runs the LOCAL model, then publishes the reply', () async {
      final owner = make();
      await owner.bind('alice', 1);
      await owner.startFromConversation(sourceSessionId: 'c', seed: const []);
      await owner.sendTurn(
        'Plan a trip',
        providerId: 'ovid-cloud',
        model: 'auto',
        modelLabel: 'auto',
      );
      final kinds = server.appended.map((e) => e['kind']).toList();
      expect(kinds, ['presence', 'message', 'modelStatus', 'message', 'modelStatus']);
      final prompt = server.appended[1]['payload'] as Map;
      final reply = server.appended[3]['payload'] as Map;
      expect(prompt, {'text': 'Plan a trip', 'role': 'user'});
      expect(reply['role'], 'assistant');
      expect(reply['model'], 'auto');
      expect(reply['replyTo'], server.appended[1]['eventId']);
      expect((server.appended[2]['payload'] as Map)['status'], 'running');
      expect((server.appended[4]['payload'] as Map)['status'], 'completed');
      // Own provider/model only; context attributes the prompt by name.
      expect(runnerCalls.single.providerId, 'ovid-cloud');
      expect(runnerCalls.single.messages.last, {
        'role': 'user',
        'content': 'Alice Example: Plan a trip',
      });
      expect(runnerCalls.single.messages.first['role'], 'system');
      // No request ever carries a provider key.
      for (final request in server.requests) {
        expect(request.body, isNot(contains('apiKey')));
        expect(request.headers['Authorization'], 'Bearer id-token');
      }
      expect(owner.state!.messages.last.isAssistant, isTrue);
      expect(owner.turnRunning, isFalse);
      await owner.release();
    });

    test('a failed model call publishes a failed status and surfaces the reason', () async {
      final owner = make(
        runner: ({required providerId, required model, required messages}) async =>
            throw StateError('Choose a model with a connected provider to reply.'),
      );
      await owner.bind('alice', 1);
      await owner.startFromConversation(sourceSessionId: 'c', seed: const []);
      await expectLater(
        owner.sendTurn('hi', providerId: 'p', model: 'm', modelLabel: 'm'),
        throwsStateError,
      );
      expect((server.appended.last['payload'] as Map)['status'], 'failed');
      expect(owner.turnRunning, isFalse);
      await owner.release();
    });

    test('the 11th joiner sees a clear full-session message', () async {
      server.joinError = 'session_full';
      final guest = make();
      await guest.bind('alice', 1);
      Object? caught;
      try {
        await guest.joinLink(_token, _code);
      } catch (error) {
        caught = error;
      }
      expect(collaborationErrorMessage(caught!), 'This session is full (10/10).');
      expect(guest.sessionToken, isNull);
      await guest.release();
    });

    test('long-poll replay sends wait and extends the request timeout', () async {
      final client = CollaborationClient(
        baseUri: Uri.parse('https://api.example.test'),
        accessToken: () async => 't',
        appCheckToken: () async => 'a',
        requestTimeout: const Duration(seconds: 1),
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['wait'], '2');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          return http.Response(
            jsonEncode({'schemaVersion': 1, 'events': [], 'nextCursor': 'c', 'hasMore': false}),
            200,
            headers: {'cache-control': 'no-store'},
          );
        }),
      );
      final page = await client.replay(_token, waitSeconds: 2);
      expect(page.events, isEmpty);
      expect(() => client.replay(_token, waitSeconds: 26), throwsA(isA<CollaborationClientException>()));
    });
  });

  testWidgets('message bubbles show the author and whose model answered', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: const [
              CollabMessageBubble(
                message: CollaborationMessage(
                  sequence: 1,
                  clientEventId: 'a',
                  author: 'p-bob',
                  createdAt: '2026-10-10T00:00:00.000Z',
                  text: 'Hi **all**',
                  role: MessageRole.user,
                ),
                authorName: 'Bob',
                mine: false,
              ),
              CollabMessageBubble(
                message: CollaborationMessage(
                  sequence: 2,
                  clientEventId: 'b',
                  author: 'p-bob',
                  createdAt: '2026-10-10T00:00:00.000Z',
                  text: 'Hello Bob',
                  role: MessageRole.assistant,
                  model: 'gpt-x',
                ),
                authorName: 'Bob',
                mine: false,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text("Bob's AI · gpt-x"), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });
}
