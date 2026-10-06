import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium model-picker contract (wave 2 UI).
///
/// Covers the behaviour the Aether-polished `_ModelPickerSheet` owes callers:
///
/// 1. When the managed Ovid Cloud catalogue is present (connection ready,
///    at least the `auto` alias and one named model shipped), the sheet
///    surfaces the provider name "Ovid Cloud" together with an `Auto` row
///    and `Manual` rows (one per non-auto model).
/// 2. An empty catalogue — Ovid Cloud present but not yet connected — shows a
///    retry affordance (`AetherGhostButton` labelled "Retry") so the user can
///    reconnect without leaving the sheet.
/// 3. Typing into the search field filters providers that do not match the
///    query by name or model id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.activeSessionId = null;
    OvidCloudService.I.setConnectionForTest(
      app,
      const CloudConnectionState(CloudConnectionStatus.idle),
    );
  });

  tearDown(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  ChatSession seedSession({
    String providerId = 'ovid-cloud',
    String model = 'auto',
  }) {
    final session = ChatSession(
      id: 'picker-sess',
      title: 'Picker test',
      providerId: providerId,
      model: model,
      mode: 'auto',
      messages: [],
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    return session;
  }

  void seedOvidCloud({
    List<String> models = const ['auto', 'gpt-5', 'kimi-k2'],
  }) {
    final existing = app.providerById(AppState.ovidCloudProviderId);
    if (existing != null) {
      existing.models
        ..clear()
        ..addAll(models);
      existing.apiKey = 'cloud-test-key';
      return;
    }
    app.providers.add(
      ProviderConfig(
        id: AppState.ovidCloudProviderId,
        name: 'Ovid Cloud',
        description: 'Managed cloud',
        baseUrl: 'https://cloud.ovid.ai/v1',
        apiKey: 'cloud-test-key',
        models: [...models],
        isFree: false,
      ),
    );
  }

  Future<void> openPicker(WidgetTester tester, {String openerText = 'Auto'}) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final opener = find.text(openerText).first;
    await tester.tap(opener, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'picker shows Ovid Cloud with Auto + Manual rows when models exist',
    (tester) async {
      seedSession();
      seedOvidCloud();
      OvidCloudService.I.setConnectionForTest(
        app,
        const CloudConnectionState(CloudConnectionStatus.ready),
      );

      await openPicker(tester);

      expect(find.text('Select model'), findsWidgets);
      expect(find.text('Ovid Cloud'), findsOneWidget);

      // Managed `auto` alias renders an Auto pill.
      expect(
        find.descendant(
          of: find.byType(AetherPill),
          matching: find.text('Auto'),
        ),
        findsOneWidget,
      );
      // The two non-auto models each render a Manual pill.
      expect(
        find.descendant(
          of: find.byType(AetherPill),
          matching: find.text('Manual'),
        ),
        findsNWidgets(2),
      );
    },
  );

  testWidgets('empty catalogue shows a retry affordance', (tester) async {
    seedSession(providerId: '', model: '');
    seedOvidCloud();
    OvidCloudService.I.setConnectionForTest(
      app,
      const CloudConnectionState(CloudConnectionStatus.idle),
    );

    // With an empty session model there is no "Auto" opener; the compact
    // picker affordance is labelled Select model.
    await openPicker(tester, openerText: 'Select model');

    expect(find.text('Ovid Cloud'), findsOneWidget);
    // No model rows render while idle — no Auto pill.
    expect(
      find.descendant(
        of: find.byType(AetherPill),
        matching: find.text('Auto'),
      ),
      findsNothing,
    );
    expect(find.widgetWithText(AetherGhostButton, 'Retry'), findsOneWidget);
  });

  testWidgets('search filters providers by name', (tester) async {
    seedSession();
    seedOvidCloud();
    OvidCloudService.I.setConnectionForTest(
      app,
      const CloudConnectionState(CloudConnectionStatus.ready),
    );
    app.providers.add(
      ProviderConfig(
        id: 'acme-ai',
        name: 'Acme AI',
        description: 'Byok',
        baseUrl: 'https://acme.ai/v1',
        apiKey: 'acme-key',
        models: ['acme-pro', 'acme-mini'],
      ),
    );
    app.refresh();

    await openPicker(tester);

    expect(find.text('Ovid Cloud'), findsOneWidget);

    // Provider cards live in a lazy sliver list inside a DraggableScrollableSheet.
    // The first drag expands the sheet to its max snap size; subsequent drags
    // scroll the list to reveal provider cards below the fold. Multiple short
    // bounded drags are more reliable in a 600px test viewport than a single
    // large drag, which can bail out mid-expansion.
    final listFinder = find.byKey(const ValueKey('model-picker-list'));
    for (var i = 0; i < 4; i++) {
      await tester.drag(listFinder, const Offset(0, -300));
      await tester.pumpAndSettle();
      if (find.text('Acme AI').evaluate().isNotEmpty) break;
    }
    expect(find.text('Acme AI'), findsOneWidget);

    final searchField = find.byKey(const ValueKey('model-picker-search'));
    // Search shares the lazy viewport with the catalogue. Return through the
    // real sheet controller's gesture path before editing the off-screen field.
    for (var i = 0; i < 12 && searchField.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(listFinder, const Offset(0, 200));
      await tester.pumpAndSettle();
    }
    expect(searchField, findsOneWidget);
    expect(searchField.hitTestable(), findsOneWidget);
    await tester.enterText(searchField, 'acme');
    await tester.pumpAndSettle();

    // Ovid Cloud must be filtered out; Acme AI remains.
    expect(find.text('Ovid Cloud'), findsNothing);
    expect(find.text('Acme AI'), findsOneWidget);
    expect(find.text('acme-pro'), findsOneWidget);
    expect(find.text('acme-mini'), findsOneWidget);

    await tester.enterText(searchField, 'acme-mini');
    await tester.pumpAndSettle();
    expect(find.text('Ovid Cloud'), findsNothing);
    expect(find.text('Acme AI'), findsOneWidget);
    // Match the result label, not the EditableText containing the same query.
    expect(find.byWidgetPredicate((w) => w is Text && w.data == 'acme-mini'), findsOneWidget);
    expect(find.text('acme-pro'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
