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

ChatSession shareSession() => ChatSession(id: 's', title: 't', model: 'm')
  ..messages.addAll([
    Message(role: 'user', content: 'Hello'),
    Message(role: 'assistant', content: 'Answer'),
  ]);

void main() {
  test(
    'local readback is truthfully empty before and after create/clearLocal '
    'and clearLocal never deletes server shares',
    () async {
      final methods = <String>[];
      final service = ConversationShareService(
        baseUrl: 'https://share.example.test',
        idToken: () async => 'firebase-token',
        currentUid: () => 'alice',
        client: MockClient((request) async {
          methods.add(request.method);
          if (request.method == 'POST') {
            return http.Response(jsonEncode(shareReceipt()), 201);
          }
          return http.Response('', 204);
        }),
      );

      expect(await service.localShareCount(), 0);

      final share = await service.create(
        ConversationSnapshot.fromSession(shareSession()),
        requestId: 'r',
      );
      expect(share.id, shareId);

      // The service caches no receipts: create returns to the caller and the
      // server stays the only owner of the share row.
      expect(await service.localShareCount(), 0);

      await service.clearLocal();
      expect(await service.localShareCount(), 0);

      // clearLocal must not attempt server deletion; only the explicit create
      // reached the transport.
      expect(methods, ['POST']);
    },
  );

  test('existing revoke behavior is preserved', () async {
    final methods = <String>[];
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'firebase-token',
      client: MockClient((request) async {
        methods.add(request.method);
        return http.Response('', 204);
      }),
    );
    await service.revoke(shareId);
    expect(methods, ['DELETE']);
    expect(await service.localShareCount(), 0);
  });
}
