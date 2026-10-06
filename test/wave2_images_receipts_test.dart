import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'image_studio_test.dart' show picture;

const headers = {'Authorization': 'Bearer fixture'};
const requestId = 'wave2-request-1234';
// hashlib.sha256(json.dumps(['generate', {'model':'ovid-image',
// 'prompt':'cat', 'size':'1024x1024'}], sort_keys=True,
// separators=(',', ':')).encode()).hexdigest(), from the server contract.
Map<String, Object?> receipt(
  String fingerprint, {
  String state = 'confirmed',
  Object? charged = '0.0370370367037037036703703703670',
  String uid = 'alice',
}) => {
  'account_id': uid,
  'request_id': requestId,
  'fingerprint': fingerprint,
  'state': state,
  'charged': charged,
};

http.Response capabilities() => http.Response(
  jsonEncode({
    'model': 'ovid-image',
    'operations': {
      'generate': ['1024x1024'],
      'edit': ['1024x1024'],
    },
  }),
  200,
);

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences() : super.empty();
  int writes = 0;
  int? failAt;
  bool loseAcknowledgment = false;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes++;
    if (writes == failAt) {
      if (loseAcknowledgment) await super.setValue(valueType, key, value);
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'wave2-image-journal-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => directory.path,
        );
    addTearDown(() => directory.delete(recursive: true));
  });

  test(
    'submission persists identity first, exact receipt survives restart, retry GET only',
    () async {
      final bytes = await picture();
      var posts = 0;
      late String fingerprint;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/capabilities')) return capabilities();
        if (r.method == 'POST') {
          posts++;
          final pending = (await ImageReceiptStore().list('alice')).single;
          expect(pending.requestId, requestId);
          expect(pending.state, 'pending');
          fingerprint = pending.fingerprint;
          expect(
            fingerprint,
            '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
          );
          expect(r.headers['idempotency-key'], requestId);
          expect(jsonDecode(r.body), {
            'model': 'ovid-image',
            'prompt': 'cat',
            'size': '1024x1024',
          });
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'receipt': receipt(fingerprint),
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }
        expect(r.method, 'GET');
        expect(r.url.path, '/v1/images/requests/$requestId');
        return http.Response(
          jsonEncode({'receipt': receipt(fingerprint)}),
          200,
        );
      });
      final studio = ImageStudio(client: client)..bindAccount('alice');
      await studio.refresh(headers);
      final result = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(result.bytes, bytes);
      expect(result.receipt!.charged, '0.0370370367037037036703703703670');
      expect(result.receiptPersisted, isTrue);
      final restarted = ImageStudio(client: client)..bindAccount('alice');
      final recovered = await restarted.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(recovered.record.state, 'confirmed');
      expect(recovered.imageAvailable, isFalse);
      expect(posts, 1);
      expect(
        (await ImageReceiptStore().list('alice')).single.receipt!.charged,
        '0.0370370367037037036703703703670',
      );
    },
  );

  test(
    'lost response and 404 after restart never submit same or replacement ID',
    () async {
      var posts = 0;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/capabilities')) return capabilities();
        if (r.method == 'POST') {
          posts++;
          throw const SocketException('lost secret');
        }
        return http.Response(
          '{"error":{"code":"image_request_not_found"}}',
          404,
        );
      });
      final studio = ImageStudio(client: client)..bindAccount('alice');
      await studio.refresh(headers);
      final first = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(first.record.state, 'unknown');
      final restarted = ImageStudio(client: client)..bindAccount('alice');
      await restarted.refresh(headers);
      final retry = await restarted.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(retry.record.state, 'unknown');
      await expectLater(
        restarted.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: 'replacement-1234',
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 1);
    },
  );

  test(
    'old capability response cannot repopulate after clear or account ABA',
    () async {
      final response = Completer<http.Response>();
      final studio = ImageStudio(client: MockClient((_) => response.future))
        ..bindAccount('alice');
      final pending = studio.refresh(headers);
      studio.bindAccount('bob');
      studio.bindAccount('alice');
      response.complete(capabilities());
      await pending;
      expect(studio.supportedSizes('generate'), isEmpty);
    },
  );

  test(
    'late paid completion is withheld after account switch, original identity remains recoverable',
    () async {
      final posted = Completer<void>();
      final response = Completer<http.Response>();
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          posted.complete();
          return response.future;
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final operation = studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      final assertion = expectLater(
        operation,
        throwsA(isA<ImageStudioError>()),
      );
      await posted.future;
      studio.bindAccount('bob');
      response.complete(http.Response('{}', 200));
      await assertion;
      expect(studio.receipts, isEmpty);
      expect(
        (await ImageReceiptStore().list('alice')).single.requestId,
        requestId,
      );
      expect(await ImageReceiptStore().list('bob'), isEmpty);
    },
  );

  test(
    'failed admission write makes zero POSTs, even if write committed without ack',
    () async {
      final platform = FailingPreferences()
        ..failAt = 1
        ..loseAcknowledgment = true;
      SharedPreferencesStorePlatform.instance = platform;
      var posts = 0;
      final studio = ImageStudio(
        receiptStore: ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        ),
        client: MockClient((r) async {
          if (r.url.path.endsWith('/capabilities')) return capabilities();
          if (r.method == 'POST') posts++;
          return http.Response('{}', 404);
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      await expectLater(
        studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      final retry = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(retry.record.state, 'unknown');
      expect(posts, 0);
    },
  );

  test(
    'receipt write failure preserves actual output and exact receipt, durable admission blocks replacement',
    () async {
      final platform = FailingPreferences()..failAt = 2;
      SharedPreferencesStorePlatform.instance = platform;
      final bytes = await picture();
      var posts = 0;
      final studio = ImageStudio(
        receiptStore: ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        ),
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          posts++;
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'receipt': receipt(
                '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
              ),
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final result = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(result.bytes, bytes);
      expect(result.receiptPersisted, isFalse);
      expect(result.receipt!.charged, '0.0370370367037037036703703703670');
      expect(
        (await ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        ).list('alice')).single.state,
        'pending',
      );
      await expectLater(
        studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: 'replacement-1234',
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 1);
    },
  );

  test(
    'corrupt preferences fail closed rather than forgetting paid identity',
    () async {
      SharedPreferences.setMockInitialValues({
        ImageReceiptStore.storageKey: 'broken',
      });
      var posts = 0;
      final studio = ImageStudio(
        receiptStore: ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        ),
        client: MockClient((r) async {
          if (r.method == 'POST') posts++;
          return capabilities();
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      await expectLater(
        studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 0);
    },
  );

  test(
    'concurrent callers across instances admit one POST and reject altered identity',
    () async {
      final posted = Completer<void>();
      final response = Completer<http.Response>();
      var posts = 0;
      final client = MockClient((r) async {
        if (r.url.path.endsWith('/capabilities')) return capabilities();
        if (r.method == 'POST') {
          posts++;
          posted.complete();
          return response.future;
        }
        return http.Response('{}', 404);
      });
      final first = ImageStudio(client: client)..bindAccount('alice');
      final second = ImageStudio(client: client)..bindAccount('alice');
      await first.refresh(headers);
      await second.refresh(headers);
      final pending = first.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      await posted.future;
      final duplicate = await second.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(duplicate.record.state, 'unknown');
      await expectLater(
        second.inferResult(
          prompt: 'dog',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      response.complete(http.Response('{}', 503));
      await pending;
      expect(posts, 1);
    },
  );

  test(
    'non-ASCII fingerprint matches Python server escaping exactly',
    () async {
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          expect(
            (await ImageReceiptStore().list('alice')).single.fingerprint,
            '4a6106e62b1356c3c1c9a3e0a29aa2cc48bb6c735ca04bfd8ca9cab2ffb822c8',
          );
          return http.Response('{}', 503);
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      await studio.inferResult(
        prompt: 'café 🐈\u007f',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
    },
  );

  for (final invalid in ['foreign', 'money', 'fingerprint', 'missing']) {
    test(
      'invalid $invalid receipt cannot confirm or expose response bytes',
      () async {
        final bytes = await picture();
        final studio = ImageStudio(
          client: MockClient((r) async {
            if (r.method == 'GET') return capabilities();
            final value = receipt(
              '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
            );
            if (invalid == 'foreign') value['account_id'] = 'bob';
            if (invalid == 'money') value['charged'] = 0.03;
            if (invalid == 'fingerprint') value['fingerprint'] = 'a' * 64;
            return http.Response(
              jsonEncode({
                'model': 'ovid-image',
                if (invalid != 'missing') 'receipt': value,
                'data': [
                  {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
                ],
              }),
              200,
            );
          }),
        )..bindAccount('alice');
        await studio.refresh(headers);
        final result = await studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        );
        expect(result.record.state, 'unknown');
        expect(result.imageAvailable, isFalse);
        expect(result.receipt, isNull);
      },
    );
  }

  test(
    'confirmed receipt survives output file failure, expiry and reordered pending reads',
    () async {
      final bytes = await picture();
      var status = 410;
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/capabilities')) return capabilities();
          final value = receipt(
            '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
          );
          if (r.method == 'GET') {
            return status == 410
                ? http.Response(
                    '{"error":{"code":"image_receipt_expired"}}',
                    410,
                  )
                : http.Response(
                    jsonEncode({
                      'receipt': {
                        ...value,
                        'state': 'pending',
                        'charged': null,
                      },
                    }),
                    200,
                  );
          }
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'receipt': value,
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final result = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      final dir = await Directory.systemTemp.createTemp('wave2-images-');
      addTearDown(() => dir.delete(recursive: true));
      final blocker = await File(
        '${dir.path}/not-a-directory',
      ).writeAsString('block');
      await expectLater(
        ImageStudio.save(result.bytes!, Directory(blocker.path)),
        throwsA(isA<FileSystemException>()),
      );
      final expired = await studio.recover(
        requestId: requestId,
        headers: headers,
      );
      expect(expired.record.state, 'confirmed');
      expect(expired.imageAvailable, isFalse);
      expect(expired.notice, contains('expired'));
      status = 200;
      final reordered = await studio.recover(
        requestId: requestId,
        headers: headers,
      );
      expect(reordered.record.state, 'confirmed');
      expect(reordered.receipt!.charged, result.receipt!.charged);
    },
  );

  test(
    'reset redacts receipt but keeps dedup and deletion blocks UID admission',
    () async {
      var posts = 0;
      final store = ImageReceiptStore();
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          if (r.url.path.endsWith('/capabilities')) return capabilities();
          if (r.method == 'POST') posts++;
          return http.Response('{}', 503);
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      await studio.clearAccountData('alice');
      studio.bindAccount('alice');
      await studio.refresh(headers);
      await expectLater(
        studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: 'replacement-1234',
        ),
        throwsA(isA<ImageStudioError>()),
      );
      await studio.clearAccountData('alice', deleted: true);
      studio.bindAccount('alice');
      await studio.refresh(headers);
      await expectLater(
        studio.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 1);
    },
  );

  test('account switch triggered by admission listener fences POST', () async {
    var posts = 0;
    final studio = ImageStudio(
      client: MockClient((r) async {
        if (r.method == 'POST') posts++;
        return capabilities();
      }),
    )..bindAccount('alice');
    await studio.refresh(headers);
    studio.addListener(() {
      if (studio.receipts.isNotEmpty) studio.bindAccount('bob');
    });
    await expectLater(
      studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      ),
      throwsA(isA<ImageStudioError>()),
    );
    expect(posts, 0);
  });

  test(
    'file admission failure sends no paid request; corrupt file never becomes an empty journal',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wave2-image-files-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final blocker = await File(
        '${directory.path}/block',
      ).writeAsString('block');
      var posts = 0;
      final client = MockClient((r) async {
        if (r.method == 'POST') posts++;
        return capabilities();
      });
      final broken = ImageStudio(
        client: client,
        receiptStore: ImageReceiptStore(
          directory: () async => Directory(blocker.path),
        ),
      )..bindAccount('alice');
      await broken.refresh(headers);
      await expectLater(
        broken.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      await File(
        '${directory.path}/${ImageReceiptStore.fileName}',
      ).writeAsString('{broken', flush: true);
      final corrupt = ImageStudio(
        client: client,
        receiptStore: ImageReceiptStore(directory: () async => directory),
      )..bindAccount('alice');
      await corrupt.refresh(headers);
      await expectLater(
        corrupt.inferResult(
          prompt: 'cat',
          size: '1024x1024',
          headers: headers,
          requestId: requestId,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 0);
    },
  );

  test(
    'file receipt update failure retains original admission across reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wave2-image-rename-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final bytes = await picture();
      final journal = File('${directory.path}/${ImageReceiptStore.fileName}');
      final studio = ImageStudio(
        receiptStore: ImageReceiptStore(directory: () async => directory),
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          // Simulate filesystem unavailable after server acceptance. Admission
          // remains in a moved directory, which we restore to emulate reopening.
          await directory.rename('${directory.path}-offline');
          await File(directory.path).writeAsString('mount unavailable');
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'receipt': receipt(
                '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
              ),
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final result = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(result.receiptPersisted, isFalse);
      expect(result.bytes, bytes);
      await File(directory.path).delete();
      await Directory('${directory.path}-offline').rename(directory.path);
      expect(await journal.exists(), isTrue);
      expect(
        (await ImageReceiptStore(
          directory: () async => directory,
        ).list('alice')).single.state,
        'pending',
      );
    },
  );

  test(
    'confirmed rejection read-only reconciliation unblocks a new identity',
    () async {
      var posts = 0;
      var lookups = 0;
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/capabilities')) return capabilities();
          if (r.method == 'POST') {
            posts++;
            return http.Response('{}', 503);
          }
          lookups++;
          return http.Response(
            jsonEncode({
              'receipt': {
                'account_id': 'alice',
                'request_id': requestId,
                'fingerprint':
                    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
                'state': 'failed',
                'charged': '0',
              },
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final first = await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      expect(first.record.state, 'unknown');
      final failed = await studio.recover(
        requestId: requestId,
        headers: headers,
      );
      expect(failed.record.state, 'failed');
      await studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: 'next-request-1234',
      );
      expect(posts, 2);
      expect(lookups, 1);
    },
  );

  test(
    'fingerprint encodes control characters and special characters like Python',
    () async {
      const prompt = 'tab\t slash / quote " backslash \\ newline\n';
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          expect(
            (await ImageReceiptStore().list('alice')).single.fingerprint,
            '9825dccab4d3090aade286a8437493b6c2b7ce1b5ea1332ca41f4dfb3428dafa',
          );
          return http.Response('{}', 503);
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      await studio.inferResult(
        prompt: prompt,
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
    },
  );

  test(
    'malformed 200 receipt after another terminal result cannot overwrite exact money',
    () async {
      final store = ImageReceiptStore();
      final existing = const ImageRequestRecord(
        accountId: 'alice',
        requestId: requestId,
        fingerprint:
            '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
      );
      await store.reserve(
        existing,
        isCurrent: () => true,
        canSubmit: () => true,
      );
      final original = existing.withReceipt(
        ImageReceipt.parse(receipt(existing.fingerprint)),
      );
      await store.update(original, isCurrent: () => true);
      final conflicting = existing.withReceipt(
        ImageReceipt.parse({
          ...receipt(existing.fingerprint),
          'charged': '0.99',
        }),
      );
      await expectLater(
        store.update(conflicting, isCurrent: () => true),
        throwsStateError,
      );
      expect(
        (await store.list('alice')).single.receipt!.charged,
        '0.0370370367037037036703703703670',
      );
    },
  );

  for (final concurrent in [false, true]) {
    test(
      'conflicting terminal recovery retains saved exact charge (concurrent: $concurrent)',
      () async {
        final store = ImageReceiptStore();
        const identity = ImageRequestRecord(
          accountId: 'alice',
          requestId: requestId,
          fingerprint:
              '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
        );
        await store.reserve(
          identity,
          isCurrent: () => true,
          canSubmit: () => true,
        );
        final saved = identity.withReceipt(
          ImageReceipt.parse(receipt(identity.fingerprint)),
        );
        if (!concurrent) {
          await store.update(saved, isCurrent: () => true);
        }
        final methods = <String>[];
        final studio = ImageStudio(
          receiptStore: store,
          client: MockClient((r) async {
            methods.add(r.method);
            if (concurrent) {
              await store.update(saved, isCurrent: () => true);
            }
            return http.Response(
              jsonEncode({
                'receipt': receipt(identity.fingerprint, charged: '0.99'),
              }),
              200,
            );
          }),
        )..bindAccount('alice');
        final result = await studio.recover(
          requestId: requestId,
          headers: headers,
        );
        expect(result.receipt!.charged, '0.0370370367037037036703703703670');
        expect(studio.receipts.single.receipt!.charged, result.receipt!.charged);
        expect(result.receiptPersisted, isTrue);
        expect(result.notice, contains('conflict'));
        expect(result.imageAvailable, isFalse);
        expect(methods, ['GET']);
        final reopened = ImageStudio(receiptStore: ImageReceiptStore())
          ..bindAccount('alice');
        await reopened.loadReceipts();
        expect(reopened.receipts.single.receipt!.charged, result.receipt!.charged);
      },
    );
  }

  test('recovery freezes authentication headers before journal read', () async {
    final store = ImageReceiptStore();
    await store.reserve(
      ImageRequestRecord(
        accountId: 'alice',
        requestId: requestId,
        fingerprint: 'a' * 64,
      ),
      isCurrent: () => true,
      canSubmit: () => true,
    );
    String? authorization;
    final studio = ImageStudio(
      receiptStore: store,
      client: MockClient((r) async {
        authorization = r.headers['authorization'];
        return http.Response('{}', 404);
      }),
    )..bindAccount('alice');
    final mutableHeaders = {'Authorization': 'Bearer alice-fixture'};
    final recovery = studio.recover(
      requestId: requestId,
      headers: mutableHeaders,
    );
    mutableHeaders['Authorization'] = 'Bearer bob-fixture';
    await recovery;
    expect(authorization, 'Bearer alice-fixture');
  });

  test('journal failure during recovery cannot regress known exact accounting',
      () async {
    var unavailable = false;
    final store = ImageReceiptStore(preferences: () async {
      if (unavailable) throw StateError('journal unavailable');
      return SharedPreferences.getInstance();
    });
    final identity = ImageRequestRecord(
      accountId: 'alice',
      requestId: requestId,
      fingerprint: 'a' * 64,
    );
    await store.reserve(identity, isCurrent: () => true, canSubmit: () => true);
    await store.update(
      identity.withReceipt(ImageReceipt.parse(receipt(identity.fingerprint))),
      isCurrent: () => true,
    );
    final studio = ImageStudio(
      receiptStore: store,
      client: MockClient((r) async {
        expect(r.method, 'GET');
        unavailable = true;
        return http.Response(jsonEncode({
          'receipt': receipt(identity.fingerprint, state: 'pending', charged: null),
        }), 200);
      }),
    )..bindAccount('alice');
    final result = await studio.recover(requestId: requestId, headers: headers);
    expect(result.record.state, 'confirmed');
    expect(result.receipt!.charged, '0.0370370367037037036703703703670');
    expect(result.receiptPersisted, isFalse);
    expect(studio.receipts.single.receipt!.charged, result.receipt!.charged);
    unavailable = false;
    expect((await store.list('alice')).single.receipt!.charged,
        result.receipt!.charged);
  });

  for (final charged in ['0', '-0.000', '1E-99', '12345678901234567890.00001']) {
    test('exact charge $charged survives durable recovery', () async {
      final store = ImageReceiptStore();
      final identity = ImageRequestRecord(
        accountId: 'alice',
        requestId: requestId,
        fingerprint: 'a' * 64,
      );
      await store.reserve(
        identity,
        isCurrent: () => true,
        canSubmit: () => true,
      );
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          expect(r.method, 'GET');
          return http.Response(
            jsonEncode({
              'receipt': receipt(identity.fingerprint, charged: charged),
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      final result = await studio.recover(requestId: requestId, headers: headers);
      expect(result.receipt!.charged, charged);
      expect(
        (await ImageReceiptStore().list('alice')).single.receipt!.charged,
        charged,
      );
    });
  }

  test('crash-pending admission survives preferences reset and remains GET-only',
      () async {
    final store = ImageReceiptStore();
    await store.reserve(
      const ImageRequestRecord(
        accountId: 'alice',
        requestId: requestId,
        fingerprint:
            '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
      ),
      isCurrent: () => true,
      canSubmit: () => true,
    );
    await (await SharedPreferences.getInstance()).clear();
    final methods = <String>[];
    final restarted = ImageStudio(
      client: MockClient((r) async {
        methods.add(r.method);
        if (r.url.path.endsWith('/capabilities')) return capabilities();
        return http.Response('{}', 410);
      }),
    )..bindAccount('alice');
    await restarted.refresh(headers);
    final result = await restarted.inferResult(
      prompt: 'cat',
      size: '1024x1024',
      headers: headers,
      requestId: requestId,
    );
    expect(result.record.state, 'unknown');
    await expectLater(
      restarted.inferResult(
        prompt: 'another image',
        size: '1024x1024',
        headers: headers,
      ),
      throwsA(isA<ImageStudioError>()),
    );
    expect(methods, ['GET', 'GET']);
  });

  test(
    'a saved account tombstone without a receipt is never overwritten by replayed receipt detail',
    () async {
      final store = ImageReceiptStore();
      final identity = const ImageRequestRecord(
        accountId: 'alice',
        requestId: requestId,
        fingerprint:
            '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
      );
      await store.reserve(
        identity,
        isCurrent: () => true,
        canSubmit: () => true,
      );
      await store.update(
        identity.withReceipt(ImageReceipt.parse(receipt(identity.fingerprint))),
        isCurrent: () => true,
      );
      await store.redactAccount('alice');
      await store.update(
        identity.withReceipt(ImageReceipt.parse(receipt(identity.fingerprint))),
        isCurrent: () => true,
      );
      expect((await store.list('alice')).single.receipt, isNull);
    },
  );

  test(
    'concurrent local cleanup during paid response does not reintroduce redacted receipt',
    () async {
      final posted = Completer<void>();
      final response = Completer<http.Response>();
      final store = ImageReceiptStore();
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          if (r.method == 'GET') return capabilities();
          posted.complete();
          return response.future;
        }),
      )..bindAccount('alice');
      await studio.refresh(headers);
      final operation = studio.inferResult(
        prompt: 'cat',
        size: '1024x1024',
        headers: headers,
        requestId: requestId,
      );
      final error = expectLater(operation, throwsA(isA<ImageStudioError>()));
      await posted.future;
      await studio.clearAccountData('alice');
      response.complete(
        http.Response(
          jsonEncode({
            'receipt': receipt(
              '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454',
            ),
          }),
          200,
        ),
      );
      await error;
      expect((await store.list('alice')).single.receipt, isNull);
    },
  );
}
