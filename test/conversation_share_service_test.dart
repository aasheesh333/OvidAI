import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/state.dart';

const shareId = 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG';
const shareUrl = 'https://share.example.test/s/$shareId';
Map<String, dynamic> shareReceipt() => {
  'id': shareId,
  'url': shareUrl,
  'session_id': 's',
  'created_at': 100,
  'expires_at': 200,
};

ChatSession
shareSession() => ChatSession(id: 's', title: 'Private title', model: 'model')
  ..messages.addAll([
    Message(
      role: 'user',
      content: 'Hello',
      attachments: [
        MessageAttachment(name: 'secret', size: 4, path: '/private'),
      ],
    ),
    Message(role: 'assistant', content: 'Answer'),
    Message(
      role: 'assistant',
      kind: MsgKind.reasoning,
      content: 'thinking secret',
    ),
    Message(role: 'assistant', kind: MsgKind.tool, content: 'tool secret'),
    Message(role: 'assistant', kind: MsgKind.streaming, content: 'unfinished'),
    Message(role: 'system', content: 'system secret'),
    Message(role: 'user', content: '[report from subagent sub-1]\ninternal'),
    Message(role: 'user', content: 'Authorization: Bearer secret'),
    Message(
      role: 'user',
      content:
          'Background subagent sub-1 (task) finished\nIts closing message: private',
    ),
  ]);

void main() {
  test('snapshot freezes only completed visible text and no metadata', () {
    final session = shareSession();
    final snapshot = ConversationSnapshot.fromSession(session);
    session.messages.first.content = 'Changed';
    expect(snapshot.messages.map((m) => m.content), ['Hello', 'Answer']);
    expect(jsonEncode(snapshot.toJson()), isNot(contains('secret')));
    expect(jsonEncode(snapshot.toJson()), isNot(contains('Private title')));
  });

  test('authenticated create/list/revoke use configured endpoints', () async {
    final methods = <String>[];
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'firebase-token',
      appCheck: () async => 'app-token',
      currentUid: () => 'alice',
      client: MockClient((request) async {
        methods.add(request.method);
        expect(request.headers['authorization'], 'Bearer firebase-token');
        expect(request.headers['x-firebase-appcheck'], 'app-token');
        if (request.method == 'POST') {
          expect(request.url.path, '/shares');
          final body = jsonDecode(request.body) as Map;
          expect(body.containsKey('uid'), false);
          expect(body['messages'], [
            {'role': 'user', 'content': 'Hello'},
            {'role': 'assistant', 'content': 'Answer'},
          ]);
          return http.Response(jsonEncode(shareReceipt()), 201);
        }
        if (request.method == 'GET') {
          expect(request.url.queryParameters['session_id'], 's');
          return http.Response(
            jsonEncode({
              'shares': [shareReceipt()],
            }),
            200,
          );
        }
        expect(request.url.path, '/shares/$shareId');
        return http.Response('', 204);
      }),
    );
    expect(
      (await service.create(
        ConversationSnapshot.fromSession(shareSession()),
        requestId: 'r',
      )).url.toString(),
      shareUrl,
    );
    expect((await service.list('s')).single.id, shareId);
    await service.revoke(shareId);
    expect(methods, ['POST', 'GET', 'DELETE']);
  });

  test('authenticated fork sends share token and idempotency request ID', () async {
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'firebase-token',
      currentUid: () => 'alice',
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/shares/$shareId/fork');
        expect(jsonDecode(request.body), {'request_id': 'fork-request'});
        return http.Response(
          jsonEncode({'session_id': 'forked-session-1234567'}),
          201,
        );
      }),
    );

    expect(
      await service.fork(shareId, requestId: 'fork-request'),
      'forked-session-1234567',
    );
  });

  test('fork rejects invalid request IDs before making a request', () async {
    var sent = false;
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'firebase-token',
      client: MockClient((_) async {
        sent = true;
        return http.Response('{}', 500);
      }),
    );

    for (final requestId in ['', 'contains spaces', 'x' * 129]) {
      await expectLater(
        service.fork(shareId, requestId: requestId),
        throwsA(isA<ConversationShareException>()),
      );
    }
    expect(sent, false);
  });

  test('fork rejects malformed server responses', () async {
    for (final body in [
      '{}',
      '{"session_id": "too-short"}',
      '{"session_id": 42}',
    ]) {
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'firebase-token',
        client: MockClient((_) async => http.Response(body, 201)),
      );
      await expectLater(
        service.fork(shareId, requestId: 'fork-request'),
        throwsA(isA<ConversationShareException>()),
      );
    }
  });

  test(
    'missing config, auth, failed network and forged URL never produce a link',
    () async {
      for (final base in [
        '',
        'http://share.example.test',
        'https://user:pass@share.example.test',
      ]) {
        final service = ConversationShareService(
          baseUrl: base,
          idToken: () async => 'token',
        );
        expect(service.available, false);
        await expectLater(
          service.list('s'),
          throwsA(isA<ConversationShareException>()),
        );
      }
      for (final response in [
        http.Response('unavailable', 503),
        http.Response(
          jsonEncode(shareReceipt()..['url'] = 'https://evil.test/s/$shareId'),
          201,
        ),
        http.Response('{}', 201),
      ]) {
        final service = ConversationShareService(
          baseUrl: 'https://share.example.test',
          idToken: () async => 'token',
          client: MockClient((_) async => response),
        );
        await expectLater(
          service.create(
            ConversationSnapshot.fromSession(shareSession()),
            requestId: 'r',
          ),
          throwsA(isA<ConversationShareException>()),
        );
      }
      final offline = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'token',
        client: MockClient((_) async => throw http.ClientException('offline')),
      );
      await expectLater(
        offline.list('s'),
        throwsA(isA<ConversationShareException>()),
      );
      final anonymous = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => null,
      );
      await expectLater(
        anonymous.list('s'),
        throwsA(isA<ConversationShareException>()),
      );
    },
  );

  test('account change rejects delayed response', () async {
    var uid = 'alice';
    final pending = Completer<http.Response>();
    final started = Completer<void>();
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'token',
      currentUid: () => uid,
      client: MockClient((_) {
        started.complete();
        return pending.future;
      }),
    );
    final result = service.list('s');
    await started.future;
    uid = 'bob';
    pending.complete(
      http.Response(
        jsonEncode({
          'shares': [shareReceipt()],
        }),
        200,
      ),
    );
    await expectLater(result, throwsA(isA<ConversationShareException>()));
  });

  test(
    'configured App Check fails closed when no attestation is returned',
    () async {
      var sent = false;
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'token',
        appCheck: () async => null,
        client: MockClient((_) async {
          sent = true;
          return http.Response('{"shares":[]}', 200);
        }),
      );
      await expectLater(
        service.list('s'),
        throwsA(isA<ConversationShareException>()),
      );
      expect(sent, false);
    },
  );
}
