// OVID_APPCHECK (default false): with App Check off, no cloud caller may
// activate Firebase App Check, request a token, send `X-Firebase-AppCheck`,
// or fail a request because no attestation exists. Firebase ID tokens stay
// mandatory everywhere.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud_app_check.dart';
import 'package:ovid_ai/core/collaboration/client.dart';
import 'package:ovid_ai/core/content_report_service.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';

bool _hasAppCheck(http.BaseRequest r) =>
    r.headers.keys.any((k) => k.toLowerCase() == 'x-firebase-appcheck');

void main() {
  test('the build default is App Check off', () {
    expect(kOvidAppCheck, isFalse);
  });

  group('production factories wire no App Check provider when off', () {
    test('content reports', () {
      expect(ContentReportService.production().appCheck, isNull);
    });
    test('conversation shares', () {
      expect(ConversationShareService.production().appCheck, isNull);
    });
  });

  group('CloudHeaders', () {
    test('no provider: Authorization only, no App Check header', () async {
      final headers = await CloudHeaders(idToken: () async => 'id').authorize();
      expect(headers, {'Authorization': 'Bearer id'});
    });

    test('provider returning null/blank omits the header', () async {
      final headers = await CloudHeaders(
        idToken: () async => 'id',
        appCheck: () async => '  ',
      ).authorize();
      expect(headers.containsKey('X-Firebase-AppCheck'), isFalse);
    });

    test('a provider that throws becomes a typed CloudApiException', () async {
      final headers = CloudHeaders(
        idToken: () async => 'id',
        appCheck: () async => throw const AppCheckUnavailable(),
      );
      await expectLater(
        headers.authorize(),
        throwsA(
          isA<CloudApiException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'app_check_unavailable'),
        ),
      );
    });

    test('an ID token failure becomes a typed 401', () async {
      final headers = CloudHeaders(
        idToken: () async => throw StateError('firebase down'),
      );
      await expectLater(
        headers.authorize(),
        throwsA(
          isA<CloudApiException>()
              .having((e) => e.status, 'status', 401)
              .having((e) => e.code, 'code', 'unauthenticated'),
        ),
      );
    });
  });

  test('AccountService without a provider sends no App Check header', () async {
    http.BaseRequest? sent;
    final service = AccountService(
      enabled: true,
      idToken: (_) async => 'identity',
      appCheck: null,
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"state":"none"}', 200);
      }),
    );
    try {
      await service.status();
    } on AccountException catch (_) {
      // Body parsing is not under test; the request going out is.
    }
    expect(sent, isNotNull);
    expect(_hasAppCheck(sent!), isFalse);
    expect(sent!.headers['Authorization'], 'Bearer identity');
  });

  test('ContentReportService without a provider still submits', () async {
    http.BaseRequest? sent;
    final service = ContentReportService(
      baseUrl: 'https://api.example.test/ovid',
      idToken: () async => 'id-token',
      client: MockClient((request) async {
        sent = request;
        return http.Response('{"id":"r1"}', 201);
      }),
    );
    await service.submit(
      ContentReport(
        kind: ContentReportKind.aiOutput,
        reason: ContentReportReason.hate,
      ),
    );
    expect(_hasAppCheck(sent!), isFalse);
  });

  test('ConversationShareService without a provider still lists', () async {
    http.BaseRequest? sent;
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'token',
      client: MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode({'shares': []}), 200);
      }),
    );
    expect(await service.list('s'), isEmpty);
    expect(_hasAppCheck(sent!), isFalse);
  });

  test('CollaborationClient without a provider sends no App Check header',
      () async {
    http.BaseRequest? sent;
    final client = CollaborationClient(
      baseUri: Uri.parse('https://collab.example.test'),
      accessToken: () async => 'token',
      appCheckToken: null,
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response('{}', 500,
            headers: {'cache-control': 'no-store'});
      }),
    );
    // The response is an error; we only care that the request went out
    // without the attestation header rather than failing locally.
    try {
      await client.state('tok');
    } on CollaborationClientException catch (e) {
      expect(e.code, isNot('credential_unavailable'));
    }
    expect(sent, isNotNull);
    expect(_hasAppCheck(sent!), isFalse);
  });
}
