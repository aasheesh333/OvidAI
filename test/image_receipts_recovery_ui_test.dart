import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/recovered_images.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'image_studio_test.dart' show picture;

const _fingerprint =
    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';
const _headers = {'Authorization': 'Bearer alice-fixture'};
late String _png;

ImageRequestRecord _row(String id, {DateTime? at, String? session}) =>
    ImageRequestRecord(
      accountId: 'alice',
      requestId: id,
      fingerprint: _fingerprint,
      createdAt: at,
      sessionId: session,
    );

Map<String, Object?> _receipt(String id, {String charged = '0.04'}) => {
  'account_id': 'alice',
  'request_id': id,
  'fingerprint': _fingerprint,
  'state': 'confirmed',
  'charged': charged,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => _png = base64Encode(await picture()));

  group('receipt metadata (F-205)', () {
    test('createdAt and sessionId persist and survive receipt updates', () {
      final at = DateTime.utc(2026, 10, 11, 14, 2);
      final row = _row('request-0001', at: at, session: 'chat-1');
      final decoded = ImageRequestRecord.fromJson(
        jsonDecode(jsonEncode(row.toJson())),
      );
      expect(decoded.createdAt, at);
      expect(decoded.sessionId, 'chat-1');
      final done = decoded.withReceipt(
        ImageReceipt.parse(_receipt('request-0001')),
      );
      expect((done.createdAt, done.sessionId), (at, 'chat-1'));
      expect(decoded.unknown.sessionId, 'chat-1');
    });

    test('invalid metadata is dropped, never fails the journal', () {
      final json = _row('request-0002').toJson()
        ..['created_at'] = 'yesterday'
        ..['session_id'] = '../../etc';
      final decoded = ImageRequestRecord.fromJson(json);
      expect(decoded.createdAt, isNull);
      expect(decoded.sessionId, isNull);
    });

    test('local reset redacts metadata with the receipt', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ImageReceiptStore(
        preferences: SharedPreferences.getInstance,
      );
      await store.reserve(
        _row('request-0003', at: DateTime.utc(2026), session: 'chat-1'),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      await store.redactAccount('alice');
      final row = (await store.list('alice')).single;
      expect(row.createdAt, isNull);
      expect(row.sessionId, isNull);
    });
  });

  test('charge summary never renders the internal number (F-207)', () {
    for (final charged in ['0.04', '4E-2', '12345.6', '1E-99']) {
      final text = imageChargeSummary('confirmed', charged);
      expect(text, 'Charged to your Ovid Cloud allowance');
      expect(text, isNot(matches(RegExp(r'\d'))));
    }
    expect(imageChargeSummary('confirmed', '0'), 'Not charged');
    expect(imageChargeSummary('failed', '-0.000'), 'Not charged');
    expect(imageChargeSummary('pending', null), 'Charge pending confirmation');
  });

  testWidgets(
    'cards are titled, newest first, ID under Details; loads on open',
    (tester) async {
      late ImageStudio studio;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final store = ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        );
        studio = ImageStudio(receiptStore: store)..bindAccount('alice');
        await studio
            .loadReceipts(); // empty: rows arrive after the sign-in load
        for (final row in [
          _row(
            'request-old1',
            at: DateTime(2026, 10, 9, 9, 5),
            session: 'gone',
          ),
          _row(
            'request-new1',
            at: DateTime(2026, 10, 11, 14, 2),
            session: 'c1',
          ),
        ]) {
          await store.update(
            (await store.reserve(
              row,
              isCurrent: () => true,
              canSubmit: () => true,
            )).record.withReceipt(ImageReceipt.parse(_receipt(row.requestId))),
            isCurrent: () => true,
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: studio,
                headers: () async => _headers,
                sessionTitle: (id) => id == 'c1' ? 'Fox drawings' : null,
              ),
            ),
          ),
        );
        // The open-time reload runs in this real-async zone.
        for (var i = 0; i < 100 && studio.receipts.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await tester.pump();
      });
      expect(studio.receipts, hasLength(2), reason: 'panel reloads on open');
      final newer = find.text('Oct 11, 14:02');
      final older = find.text('Oct 9, 09:05');
      expect(newer, findsOneWidget);
      expect(older, findsOneWidget);
      expect(
        tester.getTopLeft(newer).dy,
        lessThan(tester.getTopLeft(older).dy),
      );
      expect(find.text('In “Fox drawings”'), findsOneWidget);
      expect(find.textContaining('0.04'), findsNothing);
      expect(
        find.text('Charged to your Ovid Cloud allowance'),
        findsNWidgets(2),
      );
      expect(find.text('Request request-new1'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('receipt-details-request-new1')),
          matching: find.text('Details'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Request request-new1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recovered image offers Save, Share, Open in chat and full view (F-206)',
    (tester) async {
      late ImageStudio studio;
      late File kept;
      final saved = <String>[];
      final shared = <String>[];
      final opened = <String>[];
      const id = 'request-rec1';
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final store = ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        );
        await store.reserve(
          _row(id, at: DateTime(2026, 10, 11, 8), session: 'c1'),
          isCurrent: () => true,
          canSubmit: () => true,
        );
        kept = File(
          '${(await Directory.systemTemp.createTemp('recovered-')).path}/$id.png',
        );
        studio = ImageStudio(
          receiptStore: store,
          client: MockClient(
            (r) async => http.Response(
              jsonEncode({
                'receipt': _receipt(id),
                if (r.url.path.endsWith('/result')) ...{
                  'model': 'ovid-image',
                  'data': [
                    {'b64_json': _png, 'mime_type': 'image/png'},
                  ],
                },
              }),
              200,
            ),
          ),
        )..bindAccount('alice');
        await studio.loadReceipts();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ImageReceiptPanel(
                studio: studio,
                headers: () async => _headers,
                persistRecovered: (record, bytes) async {
                  expect(record.sessionId, 'c1');
                  return RecoveredImage(kept, sessionId: 'c1');
                },
                saveFile: (path, name) async {
                  saved.add(path);
                  return true;
                },
                shareFile: (path) async => shared.add(path),
                onOpenSession: opened.add,
              ),
            ),
          ),
        );
        Future<void> settle(bool Function() done) async {
          for (var i = 0; i < 100 && !done(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
          }
        }

        await settle(() => !studio.receiptsLoading);
        await tester.tap(find.text('Recover image'));
        await settle(() => find.text('Save').evaluate().isNotEmpty);
        expect(find.byKey(const ValueKey('receipt-save-$id')), findsOneWidget);
        expect(find.byKey(const ValueKey('receipt-share-$id')), findsOneWidget);
        expect(find.textContaining('added back to its chat'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('receipt-save-$id')));
        await tester.pump();
        expect(saved, [kept.path]);
        expect(find.text('Image saved'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('receipt-share-$id')));
        await tester.pump();
        expect(shared, [kept.path]);
        await tester.tap(find.byKey(const ValueKey('receipt-open-chat-$id')));
        expect(opened, ['c1']);
        await tester.ensureVisible(
          find.byKey(const ValueKey('receipt-image-$id')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('receipt-image-$id')));
        await settle(
          () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
        );
        expect(find.byType(InteractiveViewer), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    },
  );

  test(
    'RecoveredImages.persist keeps a file and attaches it to its chat once',
    () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
      final dir = await Directory.systemTemp.createTemp('recovered-root-');
      RecoveredImages.directoryForTest = () async => dir;
      addTearDown(() async {
        RecoveredImages.directoryForTest = null;
        AgentService.I.debugPauseScheduleTimerForTest(false);
        AppState.resetTestInstance();
        await dir.delete(recursive: true);
      });
      final session = ChatSession(
        id: 'c1',
        title: 'Fox drawings',
        model: 'auto',
      );
      app.sessions.add(session);
      final bytes = base64Decode(_png);
      final row = _row('request-keep1', session: 'c1');
      final first = await RecoveredImages.persist(row, bytes, app: app);
      final second = await RecoveredImages.persist(row, bytes, app: app);
      expect(first.file.path, second.file.path);
      expect(await first.file.readAsBytes(), bytes);
      expect(first.sessionId, 'c1');
      expect(
        session.messages.where((m) => m.imagePath == first.file.path),
        hasLength(1),
      );
      final orphan = await RecoveredImages.persist(
        _row('request-keep2', session: 'deleted'),
        bytes,
        app: app,
      );
      expect(orphan.sessionId, isNull);
      expect(await orphan.file.exists(), isTrue);
    },
  );
}
