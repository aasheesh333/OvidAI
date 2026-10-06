import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory work;
  late ChatSession session;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('agent-hook-integration-');
    work = await Directory('${root.path}/work').create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    SessionLedger.rootOverrideForTest = await Directory(
      '${root.path}/ledger',
    ).create();
    AppState.resetTestInstance();
    final app = AppState.createForTest(pluginBootActivator: (_, _) async {});
    session = ChatSession(
      id: 'agent-hook-images',
      title: 'Image accounting',
      model: 'fixture',
      mode: 'auto',
      workspaceFolder: work.path,
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    AgentService.setRunSessionForTest(session.id);
    AgentService.I.debugPauseScheduleTimerForTest(true);
    HookService.I.enabled = false;
    ImageStudio.I.bindAccount('fixture-account');
    OvidCloudService.idTokenOverrideForTest = () async => 'fixture-token';
    final mintClient = MockClient((request) async {
      if (request.url.path == '/mint') {
        return http.Response(
          '{"key":"fixture-key","tier":"free",'
          '"base_url":"https://fixture.invalid/v1"}',
          200,
        );
      }
      expect(request.url.path, '/v1/models');
      return http.Response('{"data":[{"id":"fixture"}]}', 200);
    });
    addTearDown(mintClient.close);
    expect(
      (await OvidCloudService.I.bindOvidCloud(client: mintClient)).ok,
      isTrue,
    );
  });

  tearDown(() async {
    await SessionLedger.I.close(session.id);
    await AppState.I.flushSessionPersistence();
    SessionLedger.rootOverrideForTest = null;
    AgentService.setRunSessionForTest('');
    AgentService.I.clearRunCtxForTest();
    AgentService.I.debugPauseScheduleTimerForTest(false);
    ImageStudio.I.bindAccount(null);
    OvidCloudService.idTokenOverrideForTest = null;
    AppState.resetTestInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await root.delete(recursive: true);
  });

  // Catches loss of a confirmed receipt when local save throws after inference.
  // The cloud boundary is fake; admission, receipt parsing/storage, tool policy,
  // image decoding, filesystem failure and the tool result are production code.
  for (final failReceiptWrite in [false, true]) {
    test('save failure retains exact charge and request; retry never POSTs again '
        '(receipt write fails: $failReceiptWrite)', () async {
      const requestId = 'agent-hook-image-save-failure';
      const charge = '0.0370370367037037036703703703670';
      final bytes = await picture();
      var posts = 0;
      var statusReads = 0;
      var journalUnavailable = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async {
              if (journalUnavailable &&
                  call.method == 'getApplicationSupportDirectory') {
                throw PlatformException(code: 'private-journal-error-marker');
              }
              return root.path;
            },
          );
      late Map<String, Object?> receipt;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer fixture-token');
        expect(request.headers['X-Ovid-Key'], 'fixture-key');
        if (request.url.path.endsWith('/capabilities')) {
          return http.Response(
            '{"model":"ovid-image","operations":{"generate":["1024x1024"]}}',
            200,
          );
        }
        if (request.method == 'POST') {
          posts++;
          expect(request.url.path, '/v1/images/generations');
          expect(request.headers['Idempotency-Key'], requestId);
          final pending = (await ImageReceiptStore().list(
            'fixture-account',
          )).single;
          expect(pending.state, 'pending');
          receipt = {
            'account_id': 'fixture-account',
            'request_id': requestId,
            'fingerprint': pending.fingerprint,
            'state': 'confirmed',
            'charged': charge,
          };
          // The workspace becomes unwritable after path permission was checked.
          // A file at the directory path deterministically fails even as root.
          await work.delete();
          await File(work.path).writeAsString('private-save-error-marker');
          journalUnavailable = failReceiptWrite;
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'receipt': receipt,
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/images/requests/$requestId');
        statusReads++;
        return http.Response(jsonEncode({'receipt': receipt}), 200);
      });
      addTearDown(client.close);
      const args = {
        'prompt': 'cat',
        'size': '1024x1024',
        'request_id': requestId,
      };
      await http.runWithClient(() async {
        final result = await AgentService.I.dispatchForTest(
          'generate_image',
          args,
        );
        expect(posts, 1);
        expect(result, contains('Error:'));
        expect(result, contains('Request `$requestId`: confirmed'));
        expect(result, contains('exact charge $charge'));
        expect(
          result,
          contains(failReceiptWrite ? 'receipt not saved' : 'receipt saved'),
        );
        if (failReceiptWrite) {
          expect(
            result,
            contains(
              'Receipt update could not be saved. '
              'The original request identity is retained; check it before any new paid job.',
            ),
          );
        }
        expect(result, isNot(contains(root.path)));
        expect(result, isNot(contains('private-save-error-marker')));
        expect(result, isNot(contains('private-journal-error-marker')));
        expect(
          session.messages.where((m) => m.kind == MsgKind.imageGen),
          isEmpty,
        );
        expect(AgentService.I.producedFiles, isEmpty);
        journalUnavailable = false;
        final saved = (await ImageReceiptStore().list(
          'fixture-account',
        )).single;
        if (failReceiptWrite) {
          expect(saved.state, 'pending');
        } else {
          expect(saved.receipt!.charged, charge);
        }

        await File(work.path).delete();
        await work.create();
        final retry = await AgentService.I.dispatchForTest(
          'generate_image',
          args,
        );
        expect(retry, contains('exact charge $charge'));
        expect(retry, contains('Image bytes unavailable'));
        expect(posts, 1);
        expect(statusReads, 1);
        expect(
          session.messages.where((m) => m.kind == MsgKind.imageGen),
          isEmpty,
        );
      }, () => client);
    });
  }
}
