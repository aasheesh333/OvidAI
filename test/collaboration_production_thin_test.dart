import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/collaboration/client.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/production.dart';

// UNEXECUTED: authored while HEAVY-COMMANDS-PAUSED.md forbids Flutter tests.

const _sessionId = '00000000-0000-4000-8000-000000000001';
const _attachmentId = '00000000-0000-4000-8000-000000000301';

class _ThinServer {
  final requests = <http.Request>[];
  final turnKeys = <String>[];
  final attachmentKeys = <String>[];
  final acceptedTurns = <String, Map<String, Object?>>{};
  final readyAttachments = <String, Map<String, Object?>>{};
  final attachmentCreateKeys = <String, String>{};
  var failNextTurn = false;
  var loseNextTurnResponse = false;
  Future<void> Function()? afterAcceptedTurn;
  var runs = 0;
  var messages = 0;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    http.Response json(Object? body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'cache-control': 'private, no-store'},
    );
    if (request.url.path == '/chat') {
      return json({
        'schemaVersion': 1,
        'sessionToken': 'tok',
        'session': {
          'schemaVersion': 1,
          'sessionId': _sessionId,
          'ownerParticipantId': 'p-owner',
          'lifecycle': 'active',
        },
        'member': {'participantId': 'p-owner', 'role': 'owner', 'status': 'active'},
        'cursor': 'v1:0',
      }, 201);
    }
    if (request.url.path == '/chat/tok/members') {
      return json({
        'schemaVersion': 1,
        'inviteId': 'i0123456789abcdef0123456789abcdef',
        'inviteCode': 'C' * 43,
        'expiresAt': '2026-01-02T00:00:00.000Z',
        'maxUses': 50,
      }, 201);
    }
    if (request.url.path == '/chat/tok/turns') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      turnKeys.add(body['idempotencyKey'] as String);
      final key = body['idempotencyKey'] as String;
      final original = acceptedTurns[key];
      if (original != null) {
        if (jsonEncode(original['request']) != jsonEncode(body)) {
          return json({
            'schemaVersion': 1,
            'code': 'request_already_used',
            'message': 'Request was already used',
          }, 409);
        }
        return json(original['result']);
      }
      if (failNextTurn) {
        failNextTurn = false;
        return json({'error': {'code': 'internal', 'message': 'private upstream detail'}}, 503);
      }
      final attachmentIds = (body['attachmentIds'] as List? ?? const []).cast<String>();
      if (attachmentIds.any((id) => !readyAttachments.values.any((row) => row['attachmentId'] == id))) {
        return json({'schemaVersion': 1, 'code': 'invalid_request', 'message': 'Invalid request'}, 400);
      }
      runs++;
      messages++;
      final result = <String, Object?>{
        'schemaVersion': 1,
        'turnId': '00000000-0000-4000-8000-000000000201',
        'runId': '00000000-0000-4000-8000-000000000101',
        'userMessageId': '00000000-0000-4000-8000-000000000002',
        'userEventId': 'message:00000000-0000-4000-8000-000000000002',
        'status': 'queued',
        'model': body['model'] ?? 'auto',
      };
      acceptedTurns[key] = {'request': body, 'result': result};
      await afterAcceptedTurn?.call();
      if (loseNextTurnResponse) {
        loseNextTurnResponse = false;
        return json({'error': {'code': 'internal', 'message': 'response lost after acceptance'}}, 503);
      }
      return json(result, 201);
    }
    if (request.method == 'PUT') return http.Response('', 200);
    if (request.url.path.endsWith('/url')) {
      return json({
        'schemaVersion': 1,
        'url': 'https://objects.example.test/download?signature=secret',
        'expiresAt': '2026-01-01T01:00:00.000Z',
      });
    }
    if (request.url.path.endsWith('/finalize')) {
      final createKey = attachmentCreateKeys[_attachmentId]!;
      readyAttachments[createKey] = {
        'schemaVersion': 1,
        'attachmentId': _attachmentId,
        'status': 'ready',
        'size': 3,
        'contentType': 'text/plain',
      };
      return json(readyAttachments[createKey]);
    }
    if (request.url.path == '/chat/tok/attachments') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final key = body['idempotencyKey'] as String;
      attachmentKeys.add(key);
      if (readyAttachments.containsKey(key)) {
        return json({
          'schemaVersion': 1,
          'code': 'attachment_changed',
          'message': 'The attachment upload is no longer active.',
        }, 409);
      }
      attachmentCreateKeys[_attachmentId] = key;
      return json({
        'schemaVersion': 1,
        'attachmentId': _attachmentId,
        'uploadUrl': 'https://objects.example.test/upload?signature=secret',
        'path': 'uploads/note.txt',
        'expiresAt': '2026-01-01T00:15:00.000Z',
        'contentType': 'text/plain',
        'requiredHeaders': {'Content-Type': 'text/plain'},
        'uploadHeaders': {'Content-Type': 'text/plain'},
      }, 201);
    }
    return json({'error': {'code': 'not_found', 'message': 'Route not found.'}}, 404);
  }
}

void main() {
  late Directory root;
  late _ThinServer server;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('collab-thin-production-');
    server = _ThinServer();
  });
  tearDown(() => root.delete(recursive: true));

  CollaborationProduction make() => CollaborationProduction(
    endpoint: 'https://collab.example.test',
    rootDirectory: () async => root,
    accountReady: () => true,
    currentUid: () => 'alice',
    accessToken: () async => 'token',
    httpClientFactory: () => MockClient(server.handle),
  );

  test('session adoption and turns contain no seed, local reply, or arbitrary events', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.startFromConversation(
      sourceSessionId: _sessionId,
      seed: const [CollaborationSeedMessage(MessageRole.user, 'local history must not upload')],
    );
    final createBody = jsonDecode(server.requests.first.body) as Map<String, dynamic>;
    expect(createBody['sessionId'], _sessionId);
    expect(createBody.containsKey('events'), isFalse);
    expect(server.requests.any((request) => request.url.path.endsWith('/events') && request.method == 'POST'), isFalse);

    await owner.sendTurn(
      'Canonical question',
      providerId: 'ignored-legacy-provider',
      model: 'canonical-model',
      modelLabel: 'ignored-legacy-label',
      attachments: const [CollaborationAttachmentInput(name: 'note.txt', bytes: [97, 98, 99], contentType: 'text/plain')],
    );

    final turn = server.requests.singleWhere((request) => request.url.path == '/chat/tok/turns');
    expect(jsonDecode(turn.body), {
      'schemaVersion': 1,
      'idempotencyKey': server.turnKeys.single,
      'text': 'Canonical question',
      'model': 'canonical-model',
      'attachmentIds': [_attachmentId],
    });
    expect(turn.body, isNot(contains('providerId')));
    expect(turn.body, isNot(contains('modelLabel')));
    expect(turn.body, isNot(contains('role')));
    expect(turn.body, isNot(contains('usage')));
    expect(owner.state!.messages, isEmpty, reason: 'only server replay may render the prompt/reply');
    expect(owner.turnRunning, isFalse);
    await owner.release();
  });

  test('production object mint accepts attachment or artifact IDs without a required artifact', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    final attachment = await owner.objectUrl(attachmentId: _attachmentId);
    final artifact = await owner.objectUrl(
      artifactId: '00000000-0000-4000-8000-000000000401',
    );
    expect(attachment.url.host, 'objects.example.test');
    expect(artifact.url.host, 'objects.example.test');
    expect(
      server.requests.where((request) => request.url.path.endsWith('/url')).map((request) => request.url.path),
      [
        '/chat/tok/attachments/$_attachmentId/url',
        '/chat/tok/artifacts/00000000-0000-4000-8000-000000000401/url',
      ],
    );
    await expectLater(owner.objectUrl(), throwsA(isA<CollaborationClientException>()));
    await owner.release();
  });

  test('object and every UGC wrapper fails honestly when capability is absent', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    for (final call in <Future<Object?> Function()>[
      () => owner.objectUrl(attachmentId: _attachmentId),
      () => owner.report(
        kind: 'collab_message',
        targetId: 'message-1',
        reason: 'hate',
      ),
      () => owner.block('p-target'),
      () => owner.unblock('p-target'),
      () => owner.removeMessage('message-1'),
    ]) {
      await expectLater(
        call(),
        throwsA(isA<CollaborationClientException>()
            .having((error) => error.code, 'code', 'collab_unavailable')),
      );
    }
    expect(owner.state!.messages, isEmpty);
    expect(owner.state!.members, hasLength(1));
    await owner.release();
  });

  test('a lost admission response retries with the same key and clears it after acceptance', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    server.loseNextTurnResponse = true;
    await expectLater(owner.sendTurn('retry me', model: 'canonical-model'), throwsA(isA<CollaborationClientException>()));
    await owner.sendTurn('retry me', model: 'canonical-model');
    expect(server.turnKeys, hasLength(2));
    expect(server.turnKeys[0], server.turnKeys[1]);
    expect(server.acceptedTurns, hasLength(1));
    expect(server.runs, 1);
    expect(server.messages, 1);

    await owner.sendTurn('retry me', model: 'canonical-model');
    expect(server.turnKeys[2], isNot(server.turnKeys[1]));
    expect(server.acceptedTurns, hasLength(2));
    await owner.release();
  });

  test('attachment retry preserves create key but a later turn gets a fresh identity', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    const attachments = [
      CollaborationAttachmentInput(name: 'note.txt', bytes: [97, 98, 99], contentType: 'text/plain'),
    ];
    server.loseNextTurnResponse = true;
    await expectLater(
      owner.sendTurn('same input', model: 'canonical-model', attachments: attachments),
      throwsA(isA<CollaborationClientException>()),
    );
    await owner.sendTurn('same input', model: 'canonical-model', attachments: attachments);
    expect(server.attachmentKeys, hasLength(1),
        reason: 'a ready attachment is reused, never re-created');
    expect(server.turnKeys[0], server.turnKeys[1]);
    expect(server.acceptedTurns, hasLength(1));
    expect(server.runs, 1);
    expect(server.messages, 1);

    await owner.sendTurn('same input', model: 'canonical-model', attachments: attachments);
    expect(server.attachmentKeys, hasLength(2));
    expect(server.attachmentKeys[1], isNot(server.attachmentKeys[0]));
    expect(server.turnKeys[2], isNot(server.turnKeys[1]));
    expect(server.acceptedTurns, hasLength(2));
    await owner.release();
  });

  test('accepted turn and finalized attachment survive metadata cleanup failure', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    const attachments = [
      CollaborationAttachmentInput(name: 'note.txt', bytes: [97, 98, 99], contentType: 'text/plain'),
    ];
    final metadataPath = '${root.path}/collaboration/${sha256.convert(utf8.encode('alice'))}/session.json';
    server.afterAcceptedTurn = () async {
      await File(metadataPath).delete();
      await Directory(metadataPath).create();
    };
    await expectLater(
      owner.sendTurn('accepted but cleanup failed', model: 'canonical-model', attachments: attachments),
      throwsA(isA<FileSystemException>()),
    );
    expect(server.acceptedTurns, hasLength(1));
    expect(server.runs, 1);
    expect(server.messages, 1);

    await Directory(metadataPath).delete(recursive: true);
    server.afterAcceptedTurn = null;
    await owner.sendTurn('accepted but cleanup failed', model: 'canonical-model', attachments: attachments);
    expect(server.turnKeys[0], server.turnKeys[1]);
    expect(server.attachmentKeys, hasLength(1));
    expect(server.acceptedTurns, hasLength(1));
    expect(server.runs, 1);
    expect(server.messages, 1);
    await owner.release();
  });

  test('fenced account cannot admit a fresh turn', () async {
    final owner = make();
    await owner.bind('alice', 1);
    await owner.create(sessionId: _sessionId);
    owner.fence();
    await expectLater(owner.sendTurn('stale account', model: 'canonical-model'), throwsStateError);
    expect(server.requests.any((request) => request.url.path == '/chat/tok/turns'), isFalse);
    await owner.release();
  });
}
