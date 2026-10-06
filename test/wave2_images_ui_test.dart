import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'receipt panel checks status read-only, shows exact money without claiming an image, clears on switch',
    (tester) async {
      final store = ImageReceiptStore(
        preferences: SharedPreferences.getInstance,
      );
      await store.reserve(
        const ImageRequestRecord(
          accountId: 'alice',
          requestId: 'request-1234',
          fingerprint:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      await store.reserve(
        ImageRequestRecord(
          accountId: 'bob',
          requestId: 'request-1234',
          fingerprint: 'a' * 64,
        ),
        isCurrent: () => true,
        canSubmit: () => true,
      );
      var reads = 0;
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((r) async {
          expect(r.method, 'GET');
          expect(r.url.path, '/v1/images/requests/request-1234');
          reads++;
          return http.Response(
            jsonEncode({
              'receipt': {
                'account_id': 'alice',
                'request_id': 'request-1234',
                'fingerprint':
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'state': 'confirmed',
                'charged': '0.0370370367037037036703703703670',
              },
            }),
            200,
          );
        }),
      )..bindAccount('alice');
      await studio.loadReceipts();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImageReceiptPanel(
              studio: studio,
              headers: () async => {'Authorization': 'Bearer fixture'},
            ),
          ),
        ),
      );
      expect(find.text('PENDING'), findsOneWidget);
      // A pending receipt's single context action is the read-only check.
      expect(find.text('Recover image'), findsNothing);
      await tester.tap(find.text('Check status'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(
        find.textContaining('0.0370370367037037036703703703670'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Image bytes are unavailable'),
        findsOneWidget,
      );
      studio.bindAccount('bob');
      await tester.pump();
      expect(
        find.textContaining('0.0370370367037037036703703703670'),
        findsNothing,
      );
      expect(find.textContaining('request-1234'), findsNothing);
      final bob = ImageStudio(
        receiptStore: store,
        client: MockClient((_) async => http.Response('{}', 404)),
      )..bindAccount('bob');
      await bob.loadReceipts();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImageReceiptPanel(
              studio: bob,
              headers: () async => {'Authorization': 'Bearer fixture'},
            ),
          ),
        ),
      );
      expect(find.textContaining('request-1234'), findsOneWidget);
      expect(find.textContaining('server did not find'), findsNothing);
      final headers = Completer<Map<String, String>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImageReceiptPanel(studio: bob, headers: () => headers.future),
          ),
        ),
      );
      await tester.tap(find.text('Check status'));
      bob.bindAccount('alice');
      headers.complete({'Authorization': 'Bearer previous'});
      await tester.pumpAndSettle();
      expect(find.textContaining('request-1234'), findsNothing);
      // Keep journal scenarios in the same fake-async zone: the production
      // store serializes operations process-wide, across studio instances.
      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.setMockInitialValues({});
      await _checkConflictingStatus(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      SharedPreferences.setMockInitialValues({});
      await _checkSameUidRebinding(tester);
    },
  );
}

Future<void> _checkConflictingStatus(WidgetTester tester) async {
  final store = ImageReceiptStore(preferences: SharedPreferences.getInstance);
  final identity = ImageRequestRecord(
    accountId: 'alice',
    requestId: 'request-1234',
    fingerprint: 'a' * 64,
  );
  await store.reserve(identity, isCurrent: () => true, canSubmit: () => true);
  final saved = ImageReceipt.parse({
    'account_id': 'alice',
    'request_id': 'request-1234',
    'fingerprint': 'a' * 64,
    'state': 'confirmed',
    'charged': '0.0370370367037037036703703703670',
  });
  await store.update(identity.withReceipt(saved), isCurrent: () => true);
  final methods = <String>[];
  final studio = ImageStudio(
    receiptStore: store,
    client: MockClient((r) async {
      methods.add(r.method);
      return http.Response(
        jsonEncode({
          'receipt': {...saved.toJson(), 'charged': '0.99'},
        }),
        200,
      );
    }),
  )..bindAccount('alice');
  await studio.loadReceipts();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ImageReceiptPanel(
          studio: studio,
          headers: () async => {'Authorization': 'Bearer fixture'},
        ),
      ),
    ),
  );
  // The receipt is already confirmed, so the panel's single context action
  // is recovery; its status re-verification stays a read-only GET.
  expect(find.text('Check status'), findsNothing);
  await tester.tap(find.text('Recover image'));
  await tester.pumpAndSettle();
  expect(
    find.text('Exact charge: 0.0370370367037037036703703703670'),
    findsOneWidget,
  );
  expect(find.textContaining('0.99'), findsNothing);
  expect(find.textContaining('conflicts'), findsOneWidget);
  expect(methods, ['GET']);
}

Future<void> _checkSameUidRebinding(WidgetTester tester) async {
  final store = ImageReceiptStore(preferences: SharedPreferences.getInstance);
  await store.reserve(
    ImageRequestRecord(
      accountId: 'alice',
      requestId: 'request-1234',
      fingerprint: 'a' * 64,
    ),
    isCurrent: () => true,
    canSubmit: () => true,
  );
  final methods = <String>[];
  final studio = ImageStudio(
    receiptStore: store,
    client: MockClient((r) async {
      methods.add(r.method);
      return http.Response('{}', 404);
    }),
  )..bindAccount('alice');
  await studio.loadReceipts();
  final pendingHeaders = Completer<Map<String, String>>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ImageReceiptPanel(
          studio: studio,
          headers: () => pendingHeaders.future,
        ),
      ),
    ),
  );
  await tester.tap(find.text('Check status'));
  studio.bindAccount('alice');
  await studio.loadReceipts();
  pendingHeaders.complete({'Authorization': 'Bearer old-fixture'});
  await tester.pumpAndSettle();
  expect(methods, isEmpty);
  expect(find.text('Check status'), findsOneWidget);
  expect(find.textContaining('server did not find'), findsNothing);
}
