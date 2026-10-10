import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/private_sync/client.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/protocol.dart';

class FakeClient extends http.BaseClient {
  FakeClient(this.handler);

  final Future<http.Response> Function(http.BaseRequest request) handler;
  http.BaseRequest? lastRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    final response = await handler(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

SyncUploadRecord record() => SyncUploadRecord(
  recordId: 'rec-1',
  sourceDeviceId: 'dev-1',
  conversationId: null,
  createdAt: '2026-10-08T12:00:00Z',
  revision: 1,
  payload: TranscriptPayload(
    messageId: 'msg-1',
    parentMessageId: null,
    kind: TranscriptKind.user,
    text: 'private transcript sentinel',
    providerMetadataRecordId: null,
    requestPurpose: null,
    displayTitle: null,
  ),
);

http.Response jsonResponse(
  int status,
  Object value, {
  String cache = 'no-store',
}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json', 'cache-control': cache},
);

void main() {
  test(
    'upload sends authenticated gzip wire request and decodes batch result',
    () async {
      final fake = FakeClient((request) async {
        expect(request.url.path, '/sync/v1/records');
        expect(request.headers['authorization'], 'Bearer firebase-token');
        expect(request.headers['x-firebase-appcheck'], 'app-check-token');
        expect(request.headers['content-encoding'], 'gzip');
        expect(request.headers['x-sync-device-id'], 'dev-1');
        expect(request.headers['cache-control'], 'no-store');
        expect(request.headers['x-sync-idempotency-key'], isNull);

        final body =
            jsonDecode(utf8.decode(gzip.decode(requestBody(request))))
                as Map<String, dynamic>;
        expect(body.keys, {'schemaVersion', 'idempotencyKey', 'records'});
        expect(body['schemaVersion'], 1);
        expect(body['idempotencyKey'], 'batch-1');
        expect((body['records'] as List).single['recordId'], 'rec-1');
        return jsonResponse(200, {
          'schemaVersion': 1,
          'results': [
            {
              'recordId': 'rec-1',
              'status': 'accepted',
              'revision': 1,
              'changeSequence': 7,
              'error': null,
            },
          ],
        });
      });
      final client = PrivateSyncClient(
        baseUri: Uri.parse('https://sync.example.test'),
        httpClient: fake,
        idToken: (_) async => 'firebase-token',
        appCheckToken: () async => 'app-check-token',
        deviceId: 'dev-1',
      );

      final result = await client.upload('batch-1', [record()]);
      expect(result.results.single.status, SyncRecordOutcomeStatus.accepted);
      expect(result.results.single.changeSequence, 7);
    },
  );

  test(
    'changes decodes server replay page and uses cursor query only',
    () async {
      final fake = FakeClient((request) async {
        expect(request.url.path, '/sync/v1/changes');
        expect(request.url.queryParameters, {
          'cursor': 'cursor-1',
          'limit': '2',
        });
        return jsonResponse(200, {
          'schemaVersion': 1,
          'nextCursor': 'cursor-2',
          'hasMore': false,
          'records': [
            {
              'schemaVersion': 1,
              'accountId': 'acct-1',
              'changeSequence': 2,
              'recordId': 'rec-1',
              'sourceDeviceId': 'dev-1',
              'recordType': 'transcript',
              'conversationId': null,
              'createdAt': '2026-10-08T12:00:00Z',
              'revision': 1,
              'payload': {
                'messageId': 'msg-1',
                'parentMessageId': null,
                'kind': 'user',
                'text': 'private transcript sentinel',
                'providerMetadataRecordId': null,
                'requestPurpose': null,
                'displayTitle': null,
              },
            },
          ],
        });
      });
      final client = PrivateSyncClient(
        baseUri: Uri.parse('https://sync.example.test'),
        httpClient: fake,
        idToken: (_) async => 'token',
        appCheckToken: () async => null,
        deviceId: 'dev-1',
      );

      final page = await client.changes(cursor: 'cursor-1', limit: 2);
      expect(page.nextCursor, 'cursor-2');
      expect(page.records.single.accountId, 'acct-1');
      expect(page.records.single.record.payload, record().payload);
      expect(
        fake.lastRequest!.url.query,
        isNot(contains('private transcript')),
      );
    },
  );

  test('maps the fixed server error and never exposes response body', () async {
    final fake = FakeClient(
      (_) async => jsonResponse(413, {
        'schemaVersion': 1,
        'code': 'payload_too_large',
        'message': 'The request or record exceeds the allowed size.',
        'retryAfterSeconds': 12,
      }),
    );
    final client = PrivateSyncClient(
      baseUri: Uri.parse('https://sync.example.test'),
      httpClient: fake,
      idToken: (_) async => 'token',
      appCheckToken: () async => null,
      deviceId: 'dev-1',
    );

    await expectLater(
      client.state(),
      throwsA(
        isA<SyncClientException>()
            .having((e) => e.code, 'code', 'payload_too_large')
            .having((e) => e.retryAfterSeconds, 'retry', 12)
            .having((e) => e.toString(), 'safe', isNot(contains('private'))),
      ),
    );
  });

  test('maps reset_required to SyncResetRequired', () async {
    final client = PrivateSyncClient(
      baseUri: Uri.parse('https://sync.example.test'),
      httpClient: FakeClient((_) async => jsonResponse(409, {
        'schemaVersion': 1,
        'code': 'reset_required',
        'message': 'The sync state must be reset.',
        'retryAfterSeconds': null,
      })),
      idToken: (_) async => 'token',
      appCheckToken: () async => null,
      deviceId: 'dev-1',
    );
    await expectLater(client.state(), throwsA(isA<SyncResetRequired>()));
  });

  test('requires no-store on successful responses', () async {
    final fake = FakeClient(
      (_) async => jsonResponse(200, {
        'schemaVersion': 1,
        'currentCursor': '',
        'accountId': 'account-1',
        'records': [],
        'enrollmentStatus': 'active',
        'retentionMarkers': [],
      }, cache: 'public, max-age=60'),
    );
    final client = PrivateSyncClient(
      baseUri: Uri.parse('https://sync.example.test'),
      httpClient: fake,
      idToken: (_) async => 'token',
      appCheckToken: () async => null,
      deviceId: 'dev-1',
    );

    await expectLater(
      client.state(),
      throwsA(
        isA<SyncClientException>().having(
          (e) => e.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });

  test('enroll and revoke use the server device shapes', () async {
    var calls = 0;
    final fake = FakeClient((request) async {
      calls++;
      if (request.method == 'POST') {
        expect(request.url.path, '/sync/v1/devices');
        expect(jsonDecode(utf8.decode(requestBody(request))), {
          'consent': true,
          'deviceName': 'Phone',
          'idempotencyKey': 'enroll-1',
        });
        return jsonResponse(200, {
          'schemaVersion': 1,
          'deviceId': 'dev-1',
          'deviceName': 'Phone',
          'createdAt': '2026-10-08T12:00:00Z',
          'status': 'active',
        });
      }
      expect(request.method, 'DELETE');
      expect(request.url.path, '/sync/v1/devices/dev-2');
      expect(request.headers['x-sync-idempotency-key'], 'revoke-1');
      return jsonResponse(204, <String, Object?>{});
    });
    final client = PrivateSyncClient(
      baseUri: Uri.parse('https://sync.example.test'),
      httpClient: fake,
      idToken: (_) async => 'token',
      appCheckToken: () async => null,
      deviceId: 'dev-1',
    );

    final enrollment = await client.enroll(
      deviceName: 'Phone',
      idempotencyKey: 'enroll-1',
    );
    await client.revoke('dev-2', idempotencyKey: 'revoke-1');
    expect(enrollment.deviceId, 'dev-1');
    expect(calls, 2);
  });

  test(
    'does not publish a response after the account generation fence changes',
    () async {
      var generation = 1;
      final fake = FakeClient((_) async {
        generation = 2;
        return jsonResponse(200, {
          'schemaVersion': 1,
          'currentCursor': '',
          'accountId': 'account-1',
          'records': [],
          'enrollmentStatus': 'active',
          'retentionMarkers': [],
        });
      });
      final client = PrivateSyncClient(
        baseUri: Uri.parse('https://sync.example.test'),
        httpClient: fake,
        idToken: (_) async => 'token',
        appCheckToken: () async => null,
        deviceId: 'dev-1',
        generation: () => generation,
      );

      await expectLater(
        client.state(),
        throwsA(
          isA<SyncClientException>().having(
            (e) => e.code,
            'code',
            'stale_generation',
          ),
        ),
      );
    },
  );
}

List<int> requestBody(http.BaseRequest request) {
  if (request is http.Request) return request.bodyBytes;
  throw StateError('expected buffered request');
}
