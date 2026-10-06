// Smoke render tests for the Wave 2 "settings sub" Aether redesign.
//
// These lock the redesigned composition of the backup screen, cloud usage
// status, HTML artifact card, and the shared transcript share button. They are
// rendering smoke tests only: they assert the Aether primitives are present
// and that critical user-facing strings survive the polish, not the deep
// behavior already covered by the dedicated widget suites.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/html_artifact.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/html_artifact_view.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:ovid_ai/ui/share_actions.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
  });

  Widget host(Widget child) => MaterialApp(
    theme: Aether.theme(),
    home: Scaffold(body: SafeArea(child: child)),
  );

  testWidgets('backup screen renders Aether section, card and actions', (
    tester,
  ) async {
    await tester.pumpWidget(host(const SettingsBackupScreen()));
    await tester.pump();
    expect(find.byType(AetherSectionTitle), findsWidgets);
    expect(find.byType(AetherCard), findsWidgets);
    expect(find.text('BACKUP'), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('View backup files'), findsOneWidget);
  });

  testWidgets('cloud usage status renders pill/progress/caption when stale', (
    tester,
  ) async {
    OvidCloudService.idTokenOverrideForTest = () async => 'account-a';
    final store = CloudUsageStore.acquire(AppState.I);
    addTearDown(() {
      store.release();
    });
    // Force the stale+error render path before mounting so the very first
    // frame carries the error.
    store.stale = true;
    store.error = 'Cloud allowance unavailable (400). Retry to refresh.';
    store.loading = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: CloudUsageStatus(store: store)),
      ),
    );
    // First frame: pill + Retry are derived from the store's current state.
    expect(find.byType(AetherPill), findsWidgets);
    expect(find.textContaining('Retry'), findsWidgets);
    // Drain the schedule timer that fired during acquire.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('cloud usage status hides when fresh', (tester) async {
    OvidCloudService.idTokenOverrideForTest = () async => 'account-a';
    final store = CloudUsageStore.acquire(AppState.I);
    addTearDown(() {
      store.release();
    });
    store.stale = false;
    store.error = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(body: CloudUsageStatus(store: store)),
      ),
    );
    await tester.pump();
    expect(find.byType(AetherPill), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('html artifact view is wrapped in an AetherCard', (tester) async {
    final artifact = HtmlArtifact.create('owner', {
      'title': 'Counter',
      'html': '<button>0</button>',
    });
    await tester.pumpWidget(
      host(
        SingleChildScrollView(
          child: HtmlArtifactView(artifact: artifact, sessionId: 'owner'),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AetherCard), findsWidgets);
    expect(find.text('Counter'), findsOneWidget);
    // Existing tooltips must survive the card wrapper.
    expect(find.byTooltip('View source'), findsOneWidget);
    expect(find.byTooltip('Expand preview'), findsOneWidget);
  });

  testWidgets('share button keeps the Share popup menu', (tester) async {
    final session = ChatSession(
      id: 'one',
      title: 'Visible session',
      model: 'm',
      messages: [Message(role: 'user', content: 'hi')],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(appBar: AppBar(actions: [ChatShareButton(session: session)])),
      ),
    );
    expect(find.byTooltip('Share'), findsOneWidget);
    await tester.tap(find.byTooltip('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Share chat transcript'), findsOneWidget);
  });
}
