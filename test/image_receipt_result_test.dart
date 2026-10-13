import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_result_locator.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/recovered_images.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

const _fingerprint =
    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';

ImageRequestRecord _row(
  String id, {
  String state = 'confirmed',
  String? session,
}) => ImageRequestRecord(
  accountId: 'alice',
  requestId: id,
  fingerprint: _fingerprint,
  state: state,
  sessionId: session,
);

Map<String, Object?> _receipt(String id, String state) => {
  'account_id': 'alice',
  'request_id': id,
  'fingerprint': _fingerprint,
  'state': state,
  'charged': state == 'pending' || state == 'unknown' ? null : '0.04',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Message keeps the image request id across persistence', () {
    final m = Message(
      role: 'assistant',
      kind: MsgKind.imageGen,
      imagePath: '/x.png',
      imageRequestId: 'request-msg1',
    );
    final back = Message.fromJson(jsonDecode(jsonEncode(m.toJson())));
    expect(back.imageRequestId, 'request-msg1');
    expect(Message.fromJson({'role': 'user'}).imageRequestId, isNull);
  });

  group('ImageResultLocator', () {
    late Directory dir;
    late AppState app;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      app = AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
      dir = await Directory.systemTemp.createTemp('image-result-');
      RecoveredImages.directoryForTest = () async =>
          Directory('${dir.path}/recovered-images');
    });

    tearDown(() async {
      RecoveredImages.directoryForTest = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
      await dir.delete(recursive: true);
    });

    Future<File> image(String name) async =>
        File('${dir.path}/$name')..writeAsBytesSync(await picture());

    test('finds the chat image tagged with the request id', () async {
      final file = await image('tagged.png');
      app.sessions.add(
        ChatSession(id: 'c1', title: 'Foxes', model: 'auto')
          ..messages.add(
            Message(
              role: 'assistant',
              kind: MsgKind.imageGen,
              imagePath: file.path,
              imageRequestId: 'request-tag1',
            ),
          ),
      );
      final found = await ImageResultLocator.find(
        _row('request-tag1', session: 'c1'),
        app: app,
      );
      expect(found?.path, file.path);
    });

    test('finds a legacy chat image through its tool result text', () async {
      final file = await image('legacy.png');
      app.sessions.add(
        ChatSession(id: 'c2', title: 'Old chat', model: 'auto')
          ..messages.addAll([
            Message(
              role: 'assistant',
              kind: MsgKind.tool,
              toolName: 'generate_image',
              toolDetail:
                  'Request `request-old1`: confirmed; exact charge 0.04; '
                  'receipt saved. Image saved: `${file.path}` (workspace '
                  'path: `x.png`). Displayed in chat. 10 bytes.',
            ),
            Message(
              role: 'assistant',
              kind: MsgKind.imageGen,
              imagePath: file.path,
            ),
          ]),
      );
      // The receipt predates session tracking: every chat is searched.
      final found = await ImageResultLocator.find(
        _row('request-old1'),
        app: app,
      );
      expect(found?.path, file.path);
    });

    test('finds the kept recovered copy', () async {
      final kept = Directory('${dir.path}/recovered-images')..createSync();
      final file = File('${kept.path}/request-kept1.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final found = await ImageResultLocator.find(
        _row('request-kept1'),
        app: app,
      );
      expect(found?.path, file.path);
    });

    test('a deleted file or a failed request is not on the device', () async {
      app.sessions.add(
        ChatSession(id: 'c3', title: 'Gone', model: 'auto')
          ..messages.add(
            Message(
              role: 'assistant',
              kind: MsgKind.imageGen,
              imagePath: '${dir.path}/deleted.png',
              imageRequestId: 'request-gone1',
            ),
          ),
      );
      expect(
        await ImageResultLocator.find(_row('request-gone1'), app: app),
        isNull,
      );
      expect(
        await ImageResultLocator.find(
          _row('request-gone1', state: 'failed'),
          app: app,
        ),
        isNull,
      );
    });
  });

  group('receipts panel result', () {
    Future<ImageStudio> studioWith(Map<String, String> states) async {
      SharedPreferences.setMockInitialValues({});
      final store = ImageReceiptStore(
        preferences: SharedPreferences.getInstance,
      );
      for (final id in states.keys) {
        await store.reserve(
          _row(id, state: 'pending'),
          isCurrent: () => true,
          canSubmit: () => true,
        );
        if (states[id] != 'pending') {
          await store.update(
            _row(id).withReceipt(ImageReceipt.parse(_receipt(id, states[id]!))),
            isCurrent: () => true,
          );
        }
      }
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((_) async => http.Response('{}', 404)),
      )..bindAccount('alice');
      await studio.loadReceipts();
      return studio;
    }

    testWidgets('shows the saved image with Save/Share when it exists', (
      tester,
    ) async {
      const id = 'request-show1';
      late File file;
      final saved = <String>[];
      await tester.runAsync(() async {
        final studio = await studioWith({id: 'confirmed'});
        file = File(
          '${(await Directory.systemTemp.createTemp('receipt-show-')).path}/a.png',
        )..writeAsBytesSync(await picture());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: studio,
                headers: () async => const {},
                locateResult: (record) async =>
                    record.requestId == id ? file : null,
                saveFile: (path, name) async {
                  saved.add(path);
                  return true;
                },
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(find.byKey(const ValueKey('receipt-image-$id')), findsOneWidget);
      expect(find.text('Image not saved on this device'), findsNothing);
      expect(find.textContaining('unavailable'), findsNothing);
      expect(find.byKey(const ValueKey('receipt-save-$id')), findsOneWidget);
      expect(find.byKey(const ValueKey('receipt-share-$id')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('receipt-save-$id')));
        await tester.pump();
      });
      expect(saved, [file.path]);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('states without an image explain what to do', (tester) async {
      await tester.runAsync(() async {
        final studio = await studioWith({
          'request-done1': 'confirmed',
          'request-fail1': 'failed',
          'request-wait1': 'pending',
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: studio,
                headers: () async => const {},
                locateResult: (_) async => null,
              ),
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      expect(find.text('Image not saved on this device'), findsOneWidget);
      expect(find.text('No image: the request failed'), findsOneWidget);
      expect(find.text('Result not ready yet'), findsOneWidget);
      expect(find.text('Image result unavailable'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
