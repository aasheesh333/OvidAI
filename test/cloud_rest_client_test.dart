// P8 Task 5 — CloudRestClient against MockClient. Every wire shape asserted
// here was reconciled against the BUILT gateway code (the contract, not the
// plan sketches):
//   - error envelope {error:{code,message}}  — cloud/apps/gateway/src/routes/http.ts
//   - SessionDto.mode / MessageDto / pages   — cloud/packages/shared/src/rest.ts
//   - health {status, checks:{db,redisQ}}    — cloud/apps/gateway/src/routes/health.ts
//   - sendMessage body                       — routes/messages.ts (strict schema)
//   - presigned PUT (no auth)                 — routes/attachments.ts
//   - devices body {token, platform}         — P4 plan Task 11 (route not yet
//     landed in the parallel wave; deviceRegisterRequestSchema is the pinned
//     contract there — reconcile when P4 lands).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/cloud_config.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/models.dart';

const _restBase = 'https://cloud.test';

Map<String, dynamic> _sessionJson(
  String id, {
  String mode = 'safe',
  String? title,
}) => {
      'id': id,
      'title': title,
      'mode': mode,
      'createdAt': '2026-10-16T10:00:00.000Z',
      'updatedAt': '2026-10-16T10:05:00.000Z',
    };

Map<String, dynamic> _messageJson(String id) => {
      'id': id,
      'sessionId': 's1',
      'role': 'user',
      'content': 'hi',
      'createdAt': '2026-10-16T10:00:00.000Z',
    };

String _errorBody(String code, String message) => jsonEncode({
      'error': {'code': code, 'message': message},
    });

/// Case-insensitive header lookup — http may normalize header names.
String? _header(http.Request request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

CloudRestClient _client(http.Client mock, {CloudHeaders? headers}) =>
    CloudRestClient(
      httpClient: mock,
      headers: headers ?? CloudHeaders.forTest(),
      restBase: _restBase,
    );

Matcher _throwsCloudApi({required int status, required String code}) =>
    throwsA(isA<CloudApiException>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.code, 'code', code));

/// Records the forceRefresh flag authorize was called with, so the 401-retry
/// contract ("exactly one force-refreshed retry") is observable in tests.
class _RecordingHeaders extends CloudHeaders {
  _RecordingHeaders()
      : super(idToken: () async => 'tok', appCheck: () async => 'ac');

  final flags = <bool>[];

  @override
  Future<Map<String, String>> authorize({bool forceRefresh = false}) {
    flags.add(forceRefresh);
    return super.authorize(forceRefresh: forceRefresh);
  }
}

void main() {
  test('CloudConfig pins the production endpoints', () {
    expect(CloudConfig.prodRestBase, 'https://api.ovidsi.com/cloud/v1');
    expect(CloudConfig.prodWsUrl, 'wss://api.ovidsi.com/cloud/ws');
    // No dart-define in the test runner → the prod constants apply.
    expect(CloudConfig.restBase, CloudConfig.prodRestBase);
    expect(CloudConfig.wsUrl, CloudConfig.prodWsUrl);
  });

  test('CloudHeaders.forTest binds the documented default tokens', () async {
    final headers = await CloudHeaders.forTest().authorize();
    expect(headers, const {
      'Authorization': 'Bearer test-id-token',
      'X-Firebase-AppCheck': 'test-app-check',
    });
  });

  test('CloudHeaders.authorize throws 401 unauthenticated when signed out',
      () async {
    final headers = CloudHeaders(idToken: () async => null);
    await expectLater(
        headers.authorize(), _throwsCloudApi(status: 401, code: 'unauthenticated'));
  });

  test(
      'sendMessage posts content + attachmentIds + clientMsgId with both auth '
      'headers and parses the 202', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode(
            {'runId': 'r1', 'userMessageId': 'm1', 'status': 'queued'}),
        202,
      );
    });
    final rest = _client(mock);
    final res = await rest.sendMessage('s1', 'hi',
        attachmentIds: const ['a1'], clientMsgId: 'cm1');
    expect(captured.url.toString(), '$_restBase/sessions/s1/messages');
    expect(captured.method, 'POST');
    expect(_header(captured, 'Authorization'), 'Bearer test-id-token');
    expect(_header(captured, 'X-Firebase-AppCheck'), 'test-app-check');
    expect(jsonDecode(captured.body),
        {'content': 'hi', 'attachmentIds': ['a1'], 'clientMsgId': 'cm1'});
    expect(res.runId, 'r1');
    expect(res.userMessageId, 'm1');
    expect(res.status, 'queued');
  });

  test('409 error envelope maps to CloudApiException(409, key_not_minted)',
      () async {
    final mock = MockClient((request) async => http.Response(
          _errorBody(
              'key_not_minted', 'No model API key is provisioned for this account.'),
          409,
        ));
    final rest = _client(mock);
    await expectLater(
      rest.sendMessage('s1', 'hi'),
      _throwsCloudApi(status: 409, code: 'key_not_minted'),
    );
  });

  test('402 parses the x-ovid-resets-at epoch-ms header into resetsAt',
      () async {
    final resets = DateTime.utc(2026, 10, 18, 9);
    final mock = MockClient((request) async => http.Response(
          _errorBody('daily_limit_reached', 'Daily limit reached.'),
          402,
          headers: {'x-ovid-resets-at': '${resets.millisecondsSinceEpoch}'},
        ));
    final rest = _client(mock);
    Object? caught;
    try {
      await rest.sendMessage('s1', 'hi');
    } catch (e) {
      caught = e;
    }
    expect(
        caught,
        isA<CloudApiException>()
            .having((e) => e.status, 'status', 402)
            .having((e) => e.code, 'code', 'daily_limit_reached'));
    final resetsAt = (caught as CloudApiException).resetsAt;
    expect(resetsAt, isNotNull);
    expect(resetsAt!.millisecondsSinceEpoch, resets.millisecondsSinceEpoch);
  });

  test('402 parses the x-ovid-resets-at ISO header into resetsAt', () async {
    final mock = MockClient((request) async => http.Response(
          _errorBody('daily_limit_reached', 'Daily limit reached.'),
          402,
          headers: {'x-ovid-resets-at': '2026-10-18T09:00:00.000Z'},
        ));
    final rest = _client(mock);
    Object? caught;
    try {
      await rest.sendMessage('s1', 'hi');
    } catch (e) {
      caught = e;
    }
    expect((caught as CloudApiException).resetsAt,
        DateTime.utc(2026, 10, 18, 9));
  });

  test('unparseable error body maps to code internal', () async {
    final mock = MockClient(
        (request) async => http.Response('<html>bad gateway</html>', 502));
    final rest = _client(mock);
    await expectLater(
      rest.listSessions(),
      _throwsCloudApi(status: 502, code: 'internal'),
    );
  });

  test('listSessions parses a CloudPage of SessionDto including mode',
      () async {
    final captured = <http.Request>[];
    final mock = MockClient((request) async {
      captured.add(request);
      return http.Response(
        jsonEncode({
          'items': [_sessionJson('s1', mode: 'studio'), _sessionJson('s2')],
          'nextCursor': null,
        }),
        200,
      );
    });
    final rest = _client(mock);
    final page = await rest.listSessions();
    expect(captured.single.url.toString(), '$_restBase/sessions?limit=50');
    expect(captured.single.method, 'GET');
    expect(page.items, hasLength(2));
    expect(page.items.first.id, 's1');
    expect(page.items.first.mode, 'studio');
    expect(page.items.first.createdAt, DateTime.utc(2026, 10, 16, 10));
    expect(page.items.first.title, isNull);
    expect(page.nextCursor, isNull);
  });

  test('pageMessages passes limit/before and parses messages', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'items': [_messageJson('m9')],
          'nextCursor': 'm9',
        }),
        200,
      );
    });
    final rest = _client(mock);
    final page = await rest.pageMessages('s1', limit: 10, before: 'm10');
    expect(captured.url.toString(),
        '$_restBase/sessions/s1/messages?limit=10&before=m10');
    expect(page.items.single.content, 'hi');
    expect(page.items.single.role, 'user');
    expect(page.items.single.sessionId, 's1');
    expect(page.items.single.createdAt, DateTime.utc(2026, 10, 16, 10));
    expect(page.nextCursor, 'm9');
  });

  test('patchSession PATCHes {"mode":"studio"}', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode(_sessionJson('s9', mode: 'studio')), 200);
    });
    final rest = _client(mock);
    final session = await rest.patchSession('s9', mode: 'studio');
    expect(captured.method, 'PATCH');
    expect(captured.url.toString(), '$_restBase/sessions/s9');
    expect(jsonDecode(captured.body), {'mode': 'studio'});
    expect(session.mode, 'studio');
  });

  test('createSession posts and parses the 201 SessionDto', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode(_sessionJson('s1', title: 't')), 201);
    });
    final rest = _client(mock);
    final session = await rest.createSession(title: 't');
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/sessions');
    expect(jsonDecode(captured.body), {'title': 't'});
    expect(session.id, 's1');
    expect(session.title, 't');
  });

  test('getSession parses the SessionDto', () async {
    final mock = MockClient(
        (request) async => http.Response(jsonEncode(_sessionJson('s1')), 200));
    final rest = _client(mock);
    expect((await rest.getSession('s1')).id, 's1');
  });

  test('cancelRun parses the 202 RunCancelResponse', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'runId': 'r1', 'status': 'cancelling'}), 202);
    });
    final rest = _client(mock);
    final res = await rest.cancelRun('r1');
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/runs/r1/cancel');
    expect(res.runId, 'r1');
    expect(res.status, 'cancelling');
  });

  test('createAttachment posts name/size and parses the presign answer',
      () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'attachmentId': 'a1',
          'uploadUrl': 'https://r2.test/obj?sig=1',
          'path': 'uploads/f.png',
          'expiresAt': '2026-10-17T11:00:00.000Z',
        }),
        201,
      );
    });
    final rest = _client(mock);
    final upload = await rest.createAttachment('s1', name: 'f.png', size: 12);
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/sessions/s1/attachments');
    expect(jsonDecode(captured.body), {'name': 'f.png', 'size': 12});
    expect(upload.attachmentId, 'a1');
    expect(upload.uploadUrl, 'https://r2.test/obj?sig=1');
    expect(upload.path, 'uploads/f.png');
    expect(upload.expiresAt, DateTime.utc(2026, 10, 17, 11));
  });

  test('uploadAttachmentBytes PUTs the raw bytes with NO auth headers',
      () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response('', 200);
    });
    final rest = _client(mock);
    final upload = AttachmentUpload(
      attachmentId: 'a1',
      uploadUrl: 'https://r2.test/users/u1/sessions/s1/uploads/a1?sig=x',
      path: 'uploads/f.png',
      expiresAt: DateTime.utc(2026, 10, 17, 11),
    );
    await rest.uploadAttachmentBytes(upload, [1, 2, 3]);
    expect(captured.method, 'PUT');
    expect(captured.url.toString(), upload.uploadUrl);
    expect(_header(captured, 'Authorization'), isNull,
        reason: 'the presigned URL is the credential — no auth headers');
    expect(_header(captured, 'X-Firebase-AppCheck'), isNull);
    expect(captured.bodyBytes, [1, 2, 3]);
  });

  test('importMessages posts ISO UTC timestamps and parses the report',
      () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'sessionId': 's1', 'imported': 2, 'skipped': 1}), 201);
    });
    final rest = _client(mock);
    final report = await rest.importMessages(
      title: 'old phone',
      createdAt: DateTime.utc(2026, 10, 15, 8),
      messages: [
        ImportMessage(
          clientMsgId: 'c1',
          role: 'user',
          content: 'a',
          createdAt: DateTime.utc(2026, 10, 15, 8),
        ),
        ImportMessage(
          clientMsgId: 'c2',
          role: 'assistant',
          content: 'b',
          createdAt: DateTime.utc(2026, 10, 15, 8, 0, 1),
        ),
        ImportMessage(
          clientMsgId: 'c3',
          role: 'user',
          content: 'c',
          createdAt: DateTime.utc(2026, 10, 15, 8, 0, 2),
        ),
      ],
    );
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/import/sessions');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['title'], 'old phone');
    expect(body['createdAt'], '2026-10-15T08:00:00.000Z');
    expect(
      (body['messages'] as List).first,
      {
        'clientMsgId': 'c1',
        'role': 'user',
        'content': 'a',
        'createdAt': '2026-10-15T08:00:00.000Z',
      },
    );
    expect(report.sessionId, 's1');
    expect(report.imported, 2);
    expect(report.skipped, 1);
  });

  test('mintTicket posts to /auth/ticket and unwraps the ticket', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(jsonEncode({'ticket': 'tk-123'}), 200);
    });
    final rest = _client(mock);
    expect(await rest.mintTicket(), 'tk-123');
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/auth/ticket');
  });

  test('registerDevice posts the FCM token to /devices', () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
          jsonEncode({'token': 'fcm-1', 'platform': 'android'}), 200);
    });
    final rest = _client(mock);
    await rest.registerDevice(fcmToken: 'fcm-1');
    expect(captured.method, 'POST');
    expect(captured.url.toString(), '$_restBase/devices');
    expect(
        jsonDecode(captured.body), {'token': 'fcm-1', 'platform': 'android'});
  });

  test('health sends NO auth headers and parses the built wire shape',
      () async {
    late http.Request captured;
    final mock = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'status': 'ok',
          'checks': {'db': true, 'redisQ': true},
        }),
        200,
      );
    });
    final rest = _client(mock);
    final health = await rest.health();
    expect(captured.method, 'GET');
    expect(captured.url.toString(), '$_restBase/health');
    expect(_header(captured, 'Authorization'), isNull,
        reason: '/health is the public liveness route');
    expect(_header(captured, 'X-Firebase-AppCheck'), isNull);
    expect(health.status, 'ok');
    expect(health.checks.db, isTrue);
    expect(health.checks.redisQ, isTrue);
  });

  test('health returns the degraded body on the 503 variant too', () async {
    final mock = MockClient((request) async => http.Response(
          jsonEncode({
            'status': 'degraded',
            'checks': {'db': true, 'redisQ': false},
          }),
          503,
        ));
    final rest = _client(mock);
    final health = await rest.health();
    expect(health.status, 'degraded');
    expect(health.checks.db, isTrue);
    expect(health.checks.redisQ, isFalse);
  });

  test('a 401 answers with exactly one force-refreshed retry, then succeeds',
      () async {
    final recording = _RecordingHeaders();
    var calls = 0;
    final mock = MockClient((request) async {
      calls++;
      if (calls == 1) {
        return http.Response(
          _errorBody('unauthenticated', 'Missing or invalid credentials.'),
          401,
        );
      }
      return http.Response(jsonEncode(_sessionJson('s1')), 200);
    });
    final rest = _client(mock, headers: recording);
    final session = await rest.getSession('s1');
    expect(session.id, 's1');
    expect(calls, 2, reason: 'exactly one retry, never more');
    expect(recording.flags, [false, true],
        reason: 'the retry must force-refresh the ID token');
  });
}
