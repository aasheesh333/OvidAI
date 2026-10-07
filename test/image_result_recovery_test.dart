import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

const _id = 'recover-request-1234';
const _fingerprint =
    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';
const _headers = {'Authorization': 'Bearer alice-fixture'};
const _charge = '0.0370370367037037036703703703670';
late String _png;

Map<String, Object?> _receipt() => {
  'account_id': 'alice',
  'request_id': _id,
  'fingerprint': _fingerprint,
  'state': 'confirmed',
  'charged': _charge,
};

http.Response _response({
  Map<String, Object?>? receipt,
  int status = 200,
  bool image = false,
}) => http.Response(
  jsonEncode({
    'receipt': receipt ?? _receipt(),
    if (image) ...{
      'model': 'ovid-image',
      'data': [
        {'b64_json': _png, 'mime_type': 'image/png'},
      ],
    },
    if (status == 410) 'error': {'code': 'image_replay_expired'},
  }),
  status,
);

Future<ImageReceiptStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  final store = ImageReceiptStore(preferences: SharedPreferences.getInstance);
  await store.reserve(
    const ImageRequestRecord(
      accountId: 'alice',
      requestId: _id,
      fingerprint: _fingerprint,
    ),
    isCurrent: () => true,
    canSubmit: () => true,
  );
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => _png = base64Encode(await picture()));

  test(
    'delayed same-account result returns real bytes and exact accounting',
    () async {
      final store = await _store();
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final paths = <String>[];
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) {
          expect(r.method, 'GET');
          expect(r.body, isEmpty);
          expect(r.followRedirects, isFalse);
          expect(r.headers['authorization'], 'Bearer alice-fixture');
          paths.add(r.url.path);
          if (r.url.path.endsWith('/result')) {
            requested.complete();
            return response.future;
          }
          return Future.value(_response());
        }),
      )..bindAccount('alice');
      final pending = studio.recover(
        requestId: _id,
        headers: _headers,
        retrieveImage: true,
      );
      await requested.future;
      expect(studio.receipts.single.receipt!.charged, _charge);
      response.complete(_response(image: true));
      final result = await pending;
      expect(result.bytes, base64Decode(_png));
      expect(result.receipt!.charged, _charge);
      expect(result.receiptPersisted, isTrue);
      expect(paths, [
        '/v1/images/requests/$_id',
        '/v1/images/requests/$_id/result',
      ]);
      expect((await store.list('alice')).single.receipt!.charged, _charge);
    },
  );

  for (final boundary in ['bob', 'alice', 'aba']) {
    for (final stage in ['receipt', 'result']) {
      test('delayed $stage is fenced at $boundary account boundary', () async {
        final store = await _store();
        final requested = Completer<void>();
        final response = Completer<http.Response>();
        var resultReads = 0;
        final studio = ImageStudio(
          receiptStore: store,
          client: MockClient((r) {
            expect(r.method, 'GET');
            final result = r.url.path.endsWith('/result');
            if (result) resultReads++;
            if ((stage == 'result') == result) {
              requested.complete();
              return response.future;
            }
            return Future.value(_response());
          }),
        )..bindAccount('alice');
        final pending = studio.recover(
          requestId: _id,
          headers: _headers,
          retrieveImage: true,
        );
        final assertion = expectLater(
          pending,
          throwsA(isA<ImageStudioError>()),
        );
        await requested.future;
        studio.bindAccount(boundary == 'aba' ? 'bob' : boundary);
        if (boundary == 'aba') studio.bindAccount('alice');
        response.complete(_response(image: stage == 'result'));
        await assertion;
        expect(studio.receipts, isEmpty);
        expect(await store.list('bob'), isEmpty);
        expect(resultReads, stage == 'result' ? 1 : 0);
      });
    }
  }

  for (final fault in [
    'account',
    'request',
    'fingerprint',
    'charge',
    'pending',
    'failed',
    'missing',
    'unauthorized',
    'expired',
    'malformed',
  ]) {
    test(
      'result $fault withholds bytes and preserves verified charge',
      () async {
        final store = await _store();
        final studio = ImageStudio(
          receiptStore: store,
          client: MockClient((r) async {
            expect(r.method, 'GET');
            if (!r.url.path.endsWith('/result')) return _response();
            final receipt = _receipt();
            switch (fault) {
              case 'account':
                receipt['account_id'] = 'bob';
              case 'request':
                receipt['request_id'] = 'other-request-123';
              case 'fingerprint':
                receipt['fingerprint'] = 'a' * 64;
              case 'charge':
                receipt['charged'] = '0.99';
              case 'pending':
                receipt['state'] = 'pending';
                receipt['charged'] = null;
              case 'failed':
                receipt['state'] = 'failed';
                receipt['charged'] = '0';
              case 'missing':
                return http.Response(
                  jsonEncode({
                    'model': 'ovid-image',
                    'data': [
                      {'b64_json': _png, 'mime_type': 'image/png'},
                    ],
                  }),
                  200,
                );
              case 'malformed':
                return http.Response(
                  jsonEncode({
                    'receipt': receipt,
                    'model': 'ovid-image',
                    'data': [
                      {'b64_json': 'broken', 'mime_type': 'image/png'},
                    ],
                  }),
                  200,
                );
            }
            return _response(
              receipt: receipt,
              image: true,
              status: fault == 'expired'
                  ? 410
                  : fault == 'unauthorized'
                  ? 403
                  : 200,
            );
          }),
        )..bindAccount('alice');
        final result = await studio.recover(
          requestId: _id,
          headers: _headers,
          retrieveImage: true,
        );
        expect(result.bytes, isNull);
        expect(result.receipt!.charged, _charge);
        expect((await store.list('alice')).single.receipt!.charged, _charge);
        if (fault == 'expired') expect(result.notice, contains('expired'));
      },
    );
  }

  for (final fault in [
    'foreign',
    'missing',
    'pending',
    'failed',
    'conflict',
    '401',
    '403',
    '404',
    '410',
  ]) {
    test('fresh receipt $fault cannot authorize result retrieval', () async {
      final store = await _store();
      final identity = (await store.list('alice')).single;
      await store.update(
        identity.withReceipt(ImageReceipt.parse(_receipt())),
        isCurrent: () => true,
      );
      var resultReads = 0;
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          expect(r.method, 'GET');
          if (r.url.path.endsWith('/result')) resultReads++;
          final receipt = _receipt();
          if (fault == 'foreign') receipt['account_id'] = 'bob';
          if (fault == 'pending') {
            receipt['state'] = 'pending';
            receipt['charged'] = null;
          }
          if (fault == 'failed') {
            receipt['state'] = 'failed';
            receipt['charged'] = '0';
          }
          if (fault == 'conflict') receipt['charged'] = '0.99';
          if (fault == 'missing') return http.Response('{}', 200);
          return _response(
            receipt: receipt,
            status: int.tryParse(fault) ?? 200,
          );
        }),
      )..bindAccount('alice');
      final result = await studio.recover(
        requestId: _id,
        headers: _headers,
        retrieveImage: true,
      );
      expect(resultReads, 0);
      expect(result.bytes, isNull);
      expect(result.receipt!.charged, _charge);
    });
  }

  test(
    'result expiry between status and delayed replay retains accounting',
    () async {
      final store = await _store();
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) {
          expect(r.method, 'GET');
          if (r.url.path.endsWith('/result')) {
            requested.complete();
            return response.future;
          }
          return Future.value(_response());
        }),
      )..bindAccount('alice');
      final pending = studio.recover(
        requestId: _id,
        headers: _headers,
        retrieveImage: true,
      );
      await requested.future;
      response.complete(_response(status: 410));
      final result = await pending;
      expect(result.bytes, isNull);
      expect(result.notice, contains('expired'));
      expect(result.receipt!.charged, _charge);
    },
  );

  test(
    'journal write failure blocks result fetch while retaining exact receipt',
    () async {
      await _store();
      var unavailable = false;
      var reads = 0;
      final store = ImageReceiptStore(
        preferences: () async {
          if (unavailable) throw StateError('unavailable');
          return SharedPreferences.getInstance();
        },
      );
      final identity = (await store.list('alice')).single;
      await store.update(
        identity.withReceipt(ImageReceipt.parse(_receipt())),
        isCurrent: () => true,
      );
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          expect(r.method, 'GET');
          reads++;
          unavailable = true;
          return _response();
        }),
      )..bindAccount('alice');
      final result = await studio.recover(
        requestId: _id,
        headers: _headers,
        retrieveImage: true,
      );
      expect(reads, 1);
      expect(result.bytes, isNull);
      expect(result.receipt!.charged, _charge);
      expect(result.receiptPersisted, isFalse);
    },
  );

  test(
    'missing authentication or local ownership never sends a recovery request',
    () async {
      final store = await _store();
      var reads = 0;
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          reads++;
          return _response(image: true);
        }),
      )..bindAccount('alice');
      await expectLater(
        studio.recover(requestId: _id, headers: {}, retrieveImage: true),
        throwsA(isA<ImageStudioError>()),
      );
      studio.bindAccount('bob');
      await expectLater(
        studio.recover(requestId: _id, headers: _headers, retrieveImage: true),
        throwsA(isA<ImageStudioError>()),
      );
      expect(reads, 0);
    },
  );

  test(
    'redaction during delayed result does not reintroduce receipt or bytes',
    () async {
      final store = await _store();
      final requested = Completer<void>();
      final response = Completer<http.Response>();
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) {
          expect(r.method, 'GET');
          if (r.url.path.endsWith('/result')) {
            requested.complete();
            return response.future;
          }
          return Future.value(_response());
        }),
      )..bindAccount('alice');
      final pending = studio.recover(
        requestId: _id,
        headers: _headers,
        retrieveImage: true,
      );
      await requested.future;
      await store.redactAccount('alice');
      response.complete(_response(image: true));
      final result = await pending;
      expect(result.bytes, isNull);
      expect(result.receipt, isNull);
      expect((await store.list('alice')).single.receipt, isNull);
    },
  );

  // The journal serializes across instances. Run the widget's journal/image
  // work in the same real async zone as the core cases above.
  testWidgets(
    'panel recovers actual output and retries failed journal loading',
    (tester) async {
      await tester.runAsync(() async {
        final store = await _store();
        final paths = <String>[];
        final studio = ImageStudio(
          receiptStore: store,
          client: MockClient((r) async {
            expect(r.method, 'GET');
            expect(r.headers['authorization'], 'Bearer alice-fixture');
            paths.add(r.url.path);
            return _response(image: r.url.path.endsWith('/result'));
          }),
        )..bindAccount('alice');
        await studio.loadReceipts();
        final recovered = Completer<void>();
        var publications = 0;
        studio.addListener(() {
          if (++publications == 2) recovered.complete();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: studio,
                headers: () async => _headers,
              ),
            ),
          ),
        );
        await tester.tap(find.text('Recover image'));
        await recovered.future;
        await tester.pumpAndSettle();
        expect(paths, [
          '/v1/images/requests/$_id',
          '/v1/images/requests/$_id/result',
        ]);
        expect(find.byType(Image), findsOneWidget);
        expect(find.text('Exact charge: $_charge'), findsOneWidget);
        studio.bindAccount('alice');
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());

        var broken = true;
        final brokenStudio = ImageStudio(
          receiptStore: ImageReceiptStore(
            preferences: () async {
              if (broken) throw StateError('journal unavailable');
              return SharedPreferences.getInstance();
            },
          ),
        )..bindAccount('alice');
        await expectLater(brokenStudio.loadReceipts(), throwsStateError);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: brokenStudio,
                headers: () async => _headers,
              ),
            ),
          ),
        );
        expect(find.textContaining('could not be loaded'), findsOneWidget);
        expect(
          find.text('No loaded image receipts for this account.'),
          findsNothing,
        );
        broken = false;
        await tester.tap(find.text('Retry loading receipts'));
        await tester.pumpAndSettle();
        expect(find.text('Request $_id'), findsOneWidget);
        expect(find.textContaining('could not be loaded'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );
}
