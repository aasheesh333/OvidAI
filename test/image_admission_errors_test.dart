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
  const fingerprint =
      '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';
  late ImageReceiptStore store;
  late ImageStudio studio;
  late List<String> posts;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = ImageReceiptStore(preferences: SharedPreferences.getInstance);
    posts = [];
    studio = ImageStudio(
      receiptStore: store,
      client: MockClient((request) async {
        if (request.method == 'POST') posts.add(request.url.path);
        return http.Response(
          jsonEncode({
            'model': 'ovid-image',
            'operations': {
              'generate': ['1024x1024'],
            },
          }),
          200,
        );
      }),
    )..bindAccount('alice');
  });

  Future<void> reserve() async {
    await store.reserve(
      const ImageRequestRecord(
        accountId: 'alice',
        requestId: 'existing-1234',
        fingerprint: fingerprint,
      ),
      isCurrent: () => true,
      canSubmit: () => true,
    );
  }

  Future<void> rejected(String id, String message) async {
    await expectLater(
      studio.inferResult(
        prompt: 'different image',
        size: '1024x1024',
        headers: headers,
        requestId: id,
      ),
      throwsA(
        isA<ImageStudioError>().having(
          (error) => error.message,
          'actionable reason',
          contains(message),
        ),
      ),
    );
    expect(posts, isEmpty);
  }

  test('capability loss is not reported as a pending request', () async {
    await rejected('new-request-1234', 'currently unavailable');
    expect(await store.list('alice'), isEmpty);
  });

  test(
    'unresolved admission identifies the existing receipt to recover',
    () async {
      await reserve();
      await studio.refresh(headers);
      await rejected('new-request-1234', 'existing-1234');
      expect((await store.list('alice')).single.state, 'pending');
    },
  );

  test('reused ID with changed content explains identity conflict', () async {
    await reserve();
    await studio.refresh(headers);
    await rejected('existing-1234', 'different image content');
    expect((await store.list('alice')).single.fingerprint, fingerprint);
  });

  test(
    'corrupt journal is a storage failure, never an invented pending job',
    () async {
      SharedPreferences.setMockInitialValues({
        ImageReceiptStore.storageKey: '{broken',
      });
      await studio.refresh(headers);
      await rejected('new-request-1234', 'storage');
      expect(
        (await SharedPreferences.getInstance()).getString(
          ImageReceiptStore.storageKey,
        ),
        '{broken',
      );
    },
  );

  test(
    '503 with terminal receipt permits new work and never reposts old ID',
    () async {
      final methods = <String>[];
      final rejecting = ImageStudio(
        receiptStore: store,
        client: MockClient((request) async {
          methods.add(request.method);
          if (request.url.path.endsWith('/capabilities')) {
            return http.Response(
              jsonEncode({
                'model': 'ovid-image',
                'operations': {
                  'generate': ['1024x1024'],
                },
              }),
              200,
            );
          }
          final saved = (await store.list('alice')).first;
          return http.Response(
            jsonEncode({
              'receipt': {
                'account_id': saved.accountId,
                'request_id': saved.requestId,
                'fingerprint': saved.fingerprint,
                'state': 'failed',
                'charged': '0',
              },
            }),
            request.method == 'POST' ? 503 : 200,
          );
        }),
      )..bindAccount('alice');
      await rejecting.refresh(headers);
      final result = await rejecting.inferResult(
        prompt: 'red square',
        size: '1024x1024',
        headers: headers,
        requestId: 'failed-job-1234',
      );
      expect(result.record.unresolved, isFalse);
      expect(result.receiptPersisted, isTrue);
      expect(result.receipt!.charged, '0');
      await rejecting.inferResult(
        prompt: 'red square',
        size: '1024x1024',
        headers: headers,
        requestId: 'failed-job-1234',
      );
      expect(methods, ['GET', 'POST', 'GET']);
      final next = await store.reserve(
        const ImageRequestRecord(
          accountId: 'alice',
          requestId: 'fresh-job-1234',
          fingerprint: fingerprint,
        ),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      expect(next.created, isTrue);
    },
  );

  test(
    'server reconciliation resolves local blocker via status GET only',
    () async {
      await reserve();
      final recovering = ImageStudio(
        receiptStore: store,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.path, '/v1/images/requests/existing-1234');
          return http.Response(
            jsonEncode({
              'receipt': {
                'account_id': 'alice',
                'request_id': 'existing-1234',
                'fingerprint': fingerprint,
                'state': 'failed',
                'charged': '0',
              },
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      final result = await recovering.recover(
        requestId: 'existing-1234',
        headers: headers,
      );
      expect(result.receiptPersisted, isTrue);
      expect(result.record.unresolved, isFalse);
      expect(result.receipt!.charged, '0');
      expect(result.notice, contains('resolved'));
      // A new identity is admitted only after terminal accounting is persisted.
      final next = await store.reserve(
        const ImageRequestRecord(
          accountId: 'alice',
          requestId: 'next-job-1234',
          fingerprint: fingerprint,
        ),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      expect(next.created, isTrue);
    },
  );
}
