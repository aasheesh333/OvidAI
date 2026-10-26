import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/client.dart' hide CollaborationState;
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Flutter tests.

const _session = <String, Object?>{
  'schemaVersion': 1,
  'sessionId': '00000000-0000-4000-8000-000000000001',
  'ownerParticipantId': 'p-owner',
  'lifecycle': 'active',
};
const _owner = <String, Object?>{
  'participantId': 'p-owner',
  'role': 'owner',
  'status': 'active',
  'displayName': 'Owner',
};
const _lease = <String, Object?>{
  'holderParticipantId': 'p-owner',
  'runId': '00000000-0000-4000-8000-000000000101',
  'startedAt': '2026-01-01T00:00:01.000Z',
  'heartbeatAt': '2026-01-01T00:00:08.000Z',
};

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'cache-control': 'private, no-store', 'content-type': 'application/json'},
);

Map<String, Object?> _turnResult() => const {
  'schemaVersion': 1,
  'turnId': '00000000-0000-4000-8000-000000000201',
  'runId': '00000000-0000-4000-8000-000000000101',
  'userMessageId': '00000000-0000-4000-8000-000000000002',
  'userEventId': 'message:00000000-0000-4000-8000-000000000002',
  'status': 'queued',
  'model': 'canonical-model',
};

void main() {
  test('turn admits only strict server fields and returns every accepted ID', () async {
    final requests = <http.Request>[];
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        requests.add(request);
        return _json(_turnResult(), 201);
      }),
    );

    final result = await client.turn(
      'tok',
      idempotencyKey: 'turn-request-1',
      text: 'Canonical question',
      model: 'canonical-model',
      attachmentIds: const ['00000000-0000-4000-8000-000000000301'],
    );

    expect(requests.single.method, 'POST');
    expect(requests.single.url.path, '/chat/tok/turns');
    expect(jsonDecode(requests.single.body), {
      'schemaVersion': 1,
      'idempotencyKey': 'turn-request-1',
      'text': 'Canonical question',
      'model': 'canonical-model',
      'attachmentIds': ['00000000-0000-4000-8000-000000000301'],
    });
    expect(result.turnId, '00000000-0000-4000-8000-000000000201');
    expect(result.runId, '00000000-0000-4000-8000-000000000101');
    expect(result.userMessageId, '00000000-0000-4000-8000-000000000002');
    expect(result.userEventId, 'message:00000000-0000-4000-8000-000000000002');
    expect(result.status, CollaborationTurnResultStatus.queued);
    expect(result.model, 'canonical-model');
  });

  test('turn omits absent model and attachments and rejects forged or duplicate input', () async {
    var sent = 0;
    late http.Request captured;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        sent++;
        captured = request;
        return _json(_turnResult());
      }),
    );
    await client.turn('tok', idempotencyKey: 'turn-request-2', text: 'hello', model: null);
    expect(jsonDecode(captured.body), {
      'schemaVersion': 1,
      'idempotencyKey': 'turn-request-2',
      'text': 'hello',
    });
    for (final call in <Future<Object?> Function()>[
      () => client.turn('tok', idempotencyKey: 'turn-request-3', text: ' ', model: 'auto'),
      () => client.turn('tok', idempotencyKey: 'turn-request-4', text: 'x', model: 'sk-live-secret'),
      () => client.turn('tok', idempotencyKey: 'turn-request-5', text: 'x', model: 'auto',
          attachmentIds: const ['not-an-attachment-id']),
      () => client.turn('tok', idempotencyKey: 'turn-request-6', text: 'x', model: 'auto',
          attachmentIds: const [
            '00000000-0000-4000-8000-000000000301',
            '00000000-0000-4000-8000-000000000301',
          ]),
    ]) {
      await expectLater(call(), throwsA(isA<CollaborationClientException>()));
    }
    expect(sent, 1);
  });

  test('create adopts the canonical session ID instead of uploading history', () async {
    late http.Request captured;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        captured = request;
        return _json({
          'schemaVersion': 1,
          'sessionToken': 'tok',
          'session': _session,
          'member': _owner,
          'cursor': 'v1:0',
        }, 201);
      }),
    );
    await client.create(
      requestId: 'create-request-1',
      sessionId: '00000000-0000-4000-8000-000000000001',
    );
    expect(jsonDecode(captured.body), {
      'schemaVersion': 1,
      'requestId': 'create-request-1',
      'idempotencyKey': 'create-request-1',
      'sessionId': '00000000-0000-4000-8000-000000000001',
    });
  });

  test('state requires and parses the top-level heartbeat lease with private no-store', () async {
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async => _json({
        'schemaVersion': 1,
        'session': _session,
        'member': _owner,
        'members': [_owner],
        'initialMembers': [_owner],
        'replayThroughSequence': 8,
        'cursor': 'v1:0',
        'turn': _lease,
      })),
    );
    final state = await client.state('tok');
    expect(state.turn!.holderParticipantId, 'p-owner');
    expect(state.turn!.runId, '00000000-0000-4000-8000-000000000101');
    expect(state.turn!.heartbeatAt, DateTime.utc(2026, 1, 1, 0, 0, 8));
    expect(state.replayThroughSequence, 8);
  });

  test('attachment ticket, exact signed PUT, finalize and artifact mint use server IDs', () async {
    final requests = <http.Request>[];
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.method == 'PUT') return http.Response('', 200);
        if (request.url.path.endsWith('/finalize')) {
          return _json({
            'schemaVersion': 1,
            'attachmentId': '00000000-0000-4000-8000-000000000301',
            'status': 'ready',
            'size': 3,
            'contentType': 'text/plain',
          });
        }
        if (request.url.path.endsWith('/url')) {
          return _json({
            'schemaVersion': 1,
            'url': 'https://objects.example.test/signed-download?signature=secret',
            'expiresAt': '2026-01-01T01:00:00.000Z',
          });
        }
        return _json({
          'schemaVersion': 1,
          'attachmentId': '00000000-0000-4000-8000-000000000301',
          'uploadUrl': 'https://objects.example.test/signed-upload?signature=secret',
          'path': 'uploads/note.txt',
          'expiresAt': '2026-01-01T00:15:00.000Z',
          'contentType': 'text/plain',
          'requiredHeaders': {'Content-Type': 'text/plain'},
          'uploadHeaders': {'Content-Type': 'text/plain'},
        }, 201);
      }),
    );
    final ticket = await client.createAttachment(
      'tok',
      idempotencyKey: 'attachment-create-1',
      name: 'note.txt',
      size: 3,
      contentType: 'text/plain',
    );
    await client.uploadAttachment(ticket, const [97, 98, 99]);
    final ready = await client.finalizeAttachment(
      'tok',
      attachmentId: ticket.attachmentId,
    );
    final minted = await client.objectUrl(
      'tok',
      artifactId: '00000000-0000-4000-8000-000000000401',
    );
    final mintedAttachment = await client.objectUrl(
      'tok',
      attachmentId: ticket.attachmentId,
    );

    expect(ready.attachmentId, ticket.attachmentId);
    expect(ready.size, 3);
    expect(minted.url.host, 'objects.example.test');
    expect(mintedAttachment.url.host, 'objects.example.test');
    expect(requests.map((request) => '${request.method} ${request.url.path}'), [
      'POST /chat/tok/attachments',
      'PUT /signed-upload',
      'POST /chat/tok/attachments/00000000-0000-4000-8000-000000000301/finalize',
      'GET /chat/tok/artifacts/00000000-0000-4000-8000-000000000401/url',
      'GET /chat/tok/attachments/00000000-0000-4000-8000-000000000301/url',
    ]);
    expect(jsonDecode(requests[0].body), {
      'schemaVersion': 1,
      'idempotencyKey': 'attachment-create-1',
      'name': 'note.txt',
      'size': 3,
      'contentType': 'text/plain',
    });
    expect(requests[1].headers['content-type'], 'text/plain');
    expect(requests[1].headers.containsKey('authorization'), isFalse);
    expect(requests[1].headers.containsKey('x-firebase-appcheck'), isFalse);
    expect(requests[1].bodyBytes, [97, 98, 99]);
    expect(jsonDecode(requests[2].body), {'schemaVersion': 1});
  });

  test('report, block, unblock and owner removal use strict member routes', () async {
    final requests = <http.Request>[];
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/reports')) {
          return _json({'schemaVersion': 1, 'reportId': 'report-1'}, 201);
        }
        if (request.url.path.contains('/blocks/')) {
          return _json({
            'schemaVersion': 1,
            'participantId': 'p-target',
            'blocked': request.method == 'PUT',
          });
        }
        return _json({'schemaVersion': 1, 'messageId': 'message-1', 'removed': true});
      }),
    );
    final reportId = await client.report(
      'tok',
      requestId: 'report-request-1',
      kind: 'collab_message',
      targetId: 'message-1',
      reason: 'hate',
      details: 'details',
    );
    await client.block('tok', participantId: 'p-target');
    await client.unblock('tok', participantId: 'p-target');
    await client.removeMessage('tok', messageId: 'message-1');

    expect(reportId, 'report-1');
    expect(jsonDecode(requests[0].body), {
      'schemaVersion': 1,
      'requestId': 'report-request-1',
      'kind': 'collab_message',
      'targetId': 'message-1',
      'reason': 'hate',
      'details': 'details',
    });
    expect(requests.map((request) => '${request.method} ${request.url.path}'), [
      'POST /chat/tok/reports',
      'PUT /chat/tok/blocks/p-target',
      'DELETE /chat/tok/blocks/p-target',
      'DELETE /chat/tok/messages/message-1',
    ]);
    expect(jsonDecode(requests[1].body), {'schemaVersion': 1});
    expect(requests[2].body, isEmpty);
    expect(requests[3].body, isEmpty);
  });

  for (final status in [404, 405, 501]) {
    test('missing object capability at $status fails honestly instead of minting locally', () async {
      final client = CollaborationClient(
        baseUri: Uri.parse('https://collab.example.test'),
        accessToken: () async => 'token',
        httpClient: MockClient((request) async => _json({
          'error': {'code': 'not_found', 'message': 'Route not found.'},
        }, status)),
      );
      await expectLater(
        client.objectUrl('tok', artifactId: '00000000-0000-4000-8000-000000000401'),
        throwsA(isA<CollaborationClientException>()
            .having((error) => error.code, 'code', 'collab_unavailable')),
      );
    });
  }

  test('canonical replay decodes run, tool and artifact facts without private payloads', () async {
    final page = await CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async => _json({
        'schemaVersion': 1,
        'events': [
          {
            'schemaVersion': 1,
            'eventId': 'message:00000000-0000-4000-8000-000000000002',
            'sessionId': _session['sessionId'],
            'eventSequence': 1,
            'senderParticipantId': 'p-owner',
            'kind': 'message',
            'createdAt': '2026-01-01T00:00:01.000Z',
            'payload': {'text': 'Canonical question', 'role': 'user'},
          },
          {
            'schemaVersion': 1,
            'eventId': 'mirror:1000-0',
            'sessionId': _session['sessionId'],
            'eventSequence': 2,
            'senderParticipantId': 'p-owner',
            'kind': 'modelStatus',
            'createdAt': '2026-01-01T00:00:02.000Z',
            'payload': {
              'runId': _lease['runId'],
              'status': 'running',
              'streaming': true,
              'model': 'canonical-model',
            },
          },
          {
            'schemaVersion': 1,
            'eventId': 'mirror:1001-0',
            'sessionId': _session['sessionId'],
            'eventSequence': 3,
            'senderParticipantId': 'p-owner',
            'kind': 'tool_started',
            'createdAt': '2026-01-01T00:00:03.000Z',
            'payload': {
              'runId': _lease['runId'],
              'callId': 'call-1',
              'name': 'safe_tool',
              'status': 'running',
            },
          },
          {
            'schemaVersion': 1,
            'eventId': 'mirror:1004-0',
            'sessionId': _session['sessionId'],
            'eventSequence': 4,
            'senderParticipantId': '',
            'kind': 'artifact_created',
            'createdAt': '2026-01-01T00:00:06.000Z',
            'payload': {
              'runId': null,
              'artifactId': '00000000-0000-4000-8000-000000000401',
              'name': 'safe.txt',
              'sizeBytes': 12,
              'contentType': 'text/plain',
            },
          },
        ],
        'nextCursor': 'v1:opaque',
        'hasMore': false,
      })),
    ).replay('tok');

    var state = CollaborationState.bootstrap(
      session: CollaborationSession.fromWire(_session),
      members: const [Member(participantId: 'p-owner', role: MemberRole.owner, status: MemberStatus.active)],
      localParticipantId: 'p-owner',
      lastSequence: 0,
    );
    state = const CollaborationReducer().applyPage(state, page.events);
    expect(state.lastSequence, 4);
    expect(state.messages.single.text, 'Canonical question');
    expect(state.modelStates['p-owner']!.runId, _lease['runId']);
    expect(state.modelStates['p-owner']!.model, 'canonical-model');
    expect(state.tools['call-1']!.status, ModelExecutionStatus.running);
    expect(state.artifacts['00000000-0000-4000-8000-000000000401']!.sizeBytes, 12);
    expect(state.artifacts.values.single.author, isEmpty);
  });

  test('opaque cursors retain the canonical 4096-byte transport bound', () async {
    final cursor = 'v1:${'x' * 4093}';
    late Uri uri;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      httpClient: MockClient((request) async {
        uri = request.url;
        return _json({'schemaVersion': 1, 'events': [], 'nextCursor': cursor, 'hasMore': false});
      }),
    );
    final page = await client.replay('tok', cursor: CollaborationCursor(cursor));
    expect(uri.queryParameters['cursor'], cursor);
    expect(page.nextCursor.value, cursor);
    await expectLater(
      client.replay('tok', cursor: CollaborationCursor('v1:${'x' * 4094}')),
      throwsA(isA<CollaborationClientException>()),
    );
  });

  test('release integration contains no local runner, seed, or assistant fallback', () {
    final files = [
      'lib/core/collaboration/production.dart',
      'lib/core/collaboration/client.dart',
      'lib/core/state.dart',
      'lib/ui/conversation_share_sheet.dart',
      'lib/ui/v2/app/v2_collab_routes.dart',
      'lib/ui/v2/collab/collab_live_page.dart',
    ];
    for (final path in files) {
      final source = File(path).readAsStringSync();
      for (final forbidden in [
        'CollaborationTurnRunner',
        'turnRunner',
        'appendEvents',
        'contextFor',
        'maxSeedMessages',
        '_collaborationTurnRunner',
        'kCollaborationReadOnlyNotice',
        '_appendCollabReadOnlyNotice',
        'turnDuration',
        'serverDuration',
        'onTurnExpired',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: '$path: $forbidden');
      }
    }
  });
}
