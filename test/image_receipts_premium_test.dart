import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'premium-request-1234';
const _fingerprint =
    '9495588e5c1a00c192e7f3d969984477c8f0018a06cea41e73d244a20e70b454';

Map<String, Object?> _receipt() => {
  'account_id': 'alice',
  'request_id': _id,
  'fingerprint': _fingerprint,
  'state': 'confirmed',
  'charged': '0.037',
};

Future<ImageStudio> _studio() async {
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
  final studio = ImageStudio(
    receiptStore: store,
    client: MockClient((request) async {
      expect(request.method, 'GET');
      return http.Response(jsonEncode({'receipt': _receipt()}), 200);
    }),
  )..bindAccount('alice');
  await studio.loadReceipts();
  return studio;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('premium receipt hierarchy and copy feedback are visible', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.getData') {
          return {'text': clipboardText};
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final studio = await _studio();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageReceiptPanel(studio: studio, headers: () async => const {
            'Authorization': 'Bearer alice',
          }),
        ),
      ),
    );

    expect(find.text('Summary'), findsOneWidget);
    expect(find.text('Reference'), findsOneWidget);
    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Check status'), findsOneWidget);
    expect(find.text('Recover image'), findsOneWidget);
    expect(find.text('Image result unavailable'), findsOneWidget);

    await tester.tap(find.text('Copy request ID'));
    await tester.pumpAndSettle();
    expect(find.text('Request ID copied'), findsOneWidget);
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      _id,
    );

    await tester.tap(find.text('Check status'));
    await tester.pumpAndSettle();
    expect(find.text('Status checked'), findsOneWidget);
    expect(find.text('Image result unavailable'), findsOneWidget);
  });
}
