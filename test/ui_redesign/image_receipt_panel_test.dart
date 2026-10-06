import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/usage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Smoke coverage for the wave2-images `ImageReceiptPanel` (wave 2 UI).
///
/// Pins the two host-facing guarantees: the panel renders its Aether header
/// and honest empty state without any account binding or network, and the
/// Usage screen exposes an 'Image receipts' menu route that pushes the panel
/// bound to the singleton studio. Full recovery semantics (exact charge,
/// account switching, read-only GET) live in `test/wave2_images_ui_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('panel renders header and empty state without an account', (
    tester,
  ) async {
    final studio = ImageStudio(); // unbound: no receipts, no network
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImageReceiptPanel(
            studio: studio,
            headers: () async => const {},
          ),
        ),
      ),
    );

    expect(find.text('Image receipts'), findsOneWidget);
    expect(
      find.text('No loaded image receipts for this account.'),
      findsOneWidget,
    );
    expect(find.text('Check status'), findsNothing);
  });

  testWidgets('usage screen menu pushes the image receipts route', (
    tester,
  ) async {
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'test-id-token';
    // Server usage fetch fails so the hero header falls back to local state.
    OvidCloudService.httpClientFactoryForTest = () =>
        MockClient((_) async => http.Response('down', 503));
    addTearDown(() {
      OvidCloudService.idTokenOverrideForTest = null;
      OvidCloudService.httpClientFactoryForTest = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: UsageScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Image receipts'));
    await tester.pumpAndSettle();

    // The pushed route embeds the panel bound to the singleton studio.
    expect(find.byType(ImageReceiptPanel), findsOneWidget);
    expect(
      find.text('No loaded image receipts for this account.'),
      findsOneWidget,
    );

    // Back returns to Usage.
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(ImageReceiptPanel), findsNothing);
    expect(find.text('Usage'), findsOneWidget);
  });
}
