import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const headers = {'Authorization': 'Bearer fixture'};
  late ImageReceiptStore store;
  late ImageStudio studio;
  late List<http.Request> posts;
  var status = 503;
  var code = 'image_capacity_unavailable';
  var withReceipt = true;
  Object? retryAfter = 90;
  late DateTime now;
  var capabilityStatus = 200;
  String? rawBody;
  String? retryHeader;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = ImageReceiptStore(preferences: SharedPreferences.getInstance);
    posts = [];
    status = 503;
    code = 'image_capacity_unavailable';
    withReceipt = true;
    retryAfter = 90;
    now = DateTime.utc(2026, 10, 12);
    capabilityStatus = 200;
    rawBody = null;
    retryHeader = null;
    studio = ImageStudio(
      clock: () => now,
      receiptStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/capabilities')) {
          if (capabilityStatus != 200) {
            return http.Response(jsonEncode({'error': {
              'code': code, 'retryAfterSeconds': retryAfter,
            }}), capabilityStatus);
          }
          return http.Response(
            '{"model":"ovid-image","operations":{"generate":["1024x1024"]}}',
            200,
          );
        }
        if (request.method == 'POST') posts.add(request);
        if (rawBody != null) return http.Response(rawBody!, status);
        final record = (await store.list('alice')).last;
        return http.Response(jsonEncode({
          'error': {
            'code': code,
            'retryAfterSeconds': retryAfter,
            'message': 'private provider key secret',
          },
          if (withReceipt) 'receipt': {
            'account_id': 'alice',
            'request_id': record.requestId,
            'fingerprint': record.fingerprint,
            'state': 'failed',
            'charged': '0',
          },
        }), status, headers: {if (retryHeader != null) 'Retry-After': retryHeader!});
      }),
    )..bindAccount('alice');
  });

  Future<ImageStudioResult> submit(String id) async {
    await studio.refresh(headers);
    return studio.inferResult(
      prompt: 'cat', size: '1024x1024', headers: headers, requestId: id,
    );
  }

  test('capacity retains public diagnostics and exact zero without provider text', () async {
    final result = await submit('capacity-1234');
    expect(result.notice, contains('capacity'));
    expect(result.notice, isNot(contains('private')));
    expect(result.receipt!.charged, '0');
    expect(result.error!.statusCode, 503);
    expect(result.error!.code, 'image_capacity_unavailable');
    expect(result.error!.retryAfter, const Duration(seconds: 90));
  });

  test('capacity prevents fresh IDs even after capability refresh', () async {
    await submit('capacity-1234');
    await expectLater(submit('replacement-1234'), throwsA(isA<ImageStudioError>()));
    expect(posts, hasLength(1));
    expect(await store.list('alice'), hasLength(1));
  });

  test('capacity without a receipt never invents zero or resolves unknown work', () async {
    withReceipt = false;
    final result = await submit('capacity-unknown');
    expect(result.error!.code, 'image_capacity_unavailable');
    expect(result.record.state, 'unknown');
    expect(result.receipt, isNull);
    expect(result.notice!.toLowerCase(), isNot(contains('not charged')));
    now = now.add(const Duration(seconds: 121));
    await expectLater(submit('unsafe-replacement'), throwsA(isA<ImageStudioError>()));
    expect(posts, hasLength(1));
  });

  test('capability rejection propagates typed error without reserving a job', () async {
    capabilityStatus = 503;
    await expectLater(submit('not-submitted-1234'), throwsA(
      isA<ImageStudioError>()
        .having((e) => e.code, 'public code', 'image_capacity_unavailable')
        .having((e) => e.statusCode, 'HTTP status', 503)
        .having((e) => e.retryAfter, 'retry hint', const Duration(seconds: 90)),
    ));
    expect(posts, isEmpty);
    expect(await store.list('alice'), isEmpty);
  });

  for (final (httpStatus, publicCode) in [
    (401, 'sign_in_required'), (403, 'image_access_denied'),
    (400, 'invalid_image_request'),
    (422, 'unsupported_image_operation'),
  ]) {
    test('known pre-dispatch $httpStatus/$publicCode resolves only new POST admission', () async {
      status = httpStatus;
      code = publicCode;
      withReceipt = false;
      final result = await submit('refused-1234');
      expect(result.record.unresolved, isFalse);
      expect(result.receipt, isNull);
      expect(result.error!.code, publicCode);
      await submit('refused-new-1234');
      expect(posts, hasLength(2));
    });
  }

  test('contract-known pre-admission quota rejection releases admission without inventing zero', () async {
    status = 402;
    code = 'image_limit_reached';
    withReceipt = false;
    final result = await submit('quota-1234');
    expect(result.notice, contains('allowance'));
    expect(result.record.state, 'failed');
    expect(result.receipt, isNull);
    expect(result.notice!.toLowerCase(), isNot(contains('not charged')));
    await submit('quota-new-1234');
    expect(posts, hasLength(2));
    status = 404;
    code = 'image_request_not_found';
    final recovered = await studio.recover(requestId: 'quota-1234', headers: headers);
    expect(recovered.record.unresolved, isFalse);
    expect(recovered.receipt, isNull);
    expect(posts, hasLength(2));
  });

  test('unknown public codes are not exposed as provider diagnostics', () async {
    code = 'private-provider-secret';
    withReceipt = false;
    final result = await submit('unknown-1234');
    expect(result.record.state, 'unknown');
    expect(result.notice, isNot(contains('private')));
    expect(result.error!.statusCode, 503);
    expect(result.error!.code, isNull);
  });

  test('non-JSON proxy failure preserves HTTP status and unknown billing', () async {
    rawBody = '<html>private provider secret</html>';
    status = 502;
    final result = await submit('proxy-1234');
    expect(result.error!.statusCode, 502);
    expect(result.error!.code, isNull);
    expect(result.record.state, 'unknown');
    expect(result.receipt, isNull);
    expect(result.notice, isNot(contains('private')));
  });

  test('HTTP retry hint and compatibility infer preserve typed capacity failure', () async {
    retryAfter = null;
    retryHeader = '17';
    await studio.refresh(headers);
    await expectLater(studio.infer(
      prompt: 'cat', size: '1024x1024', headers: headers, requestId: 'infer-1234',
    ), throwsA(isA<ImageStudioError>()
      .having((e) => e.statusCode, 'HTTP status', 503)
      .having((e) => e.code, 'public code', 'image_capacity_unavailable')
      .having((e) => e.retryAfter, 'retry hint', const Duration(seconds: 17))));
    expect(posts, hasLength(1));
  });

  test('allowlisted auth code on status GET cannot resolve unknown admission', () async {
    withReceipt = false;
    code = 'image_unavailable';
    await submit('unknown-1234');
    code = 'sign_in_required';
    status = 401;
    final result = await studio.recover(requestId: 'unknown-1234', headers: headers);
    expect(result.record.state, 'unknown');
    expect(result.receipt, isNull);
    expect(result.error!.code, 'sign_in_required');
    await expectLater(submit('unsafe-new-1234'), throwsA(isA<ImageStudioError>()));
    expect(posts, hasLength(1));
  });

  test('bare auth failure then 404 never fabricates rejection evidence', () async {
    status = 401;
    code = 'unknown';
    withReceipt = false;
    final result = await submit('uncertain-1234');
    expect(result.record.state, 'unknown');
    status = 404;
    code = 'image_request_not_found';
    final recovered = await studio.recover(requestId: 'uncertain-1234', headers: headers);
    expect(recovered.record.state, 'unknown');
    await expectLater(submit('unsafe-new-1234'), throwsA(isA<ImageStudioError>()));
    expect(posts, hasLength(1));
  });

  test('same ID is read-only during cooldown; later manual fresh ID is admitted', () async {
    await submit('capacity-1234');
    await submit('capacity-1234');
    expect(posts, hasLength(1));
    now = now.add(const Duration(seconds: 91));
    await submit('manual-later-1234');
    expect(posts, hasLength(2));
  });

  for (final (hint, seconds) in [(999999, 120), (-1, 30), (0, 1), ('secret', 30)]) {
    test('capacity cooldown bounds hint $hint and expires', () async {
      retryAfter = hint;
      final first = await submit('capacity-1234');
      expect(first.error!.retryAfter, Duration(seconds: seconds));
      now = now.add(Duration(seconds: seconds - 1));
      await expectLater(submit('too-soon-1234'), throwsA(isA<ImageStudioError>()));
      now = now.add(const Duration(seconds: 2));
      await submit('manual-later-1234');
      expect(posts, hasLength(2));
    });
  }
}
