import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Premium `providers_screen` redesign contract (wave 2 UI).
///
/// These tests pin the *public* surface the redesign owes callers — the
/// managed Ovid Cloud tile is always surfaced, the BYOK list uses an
/// [AetherEmptyState] when empty, fetch-models round-trips through a
/// provider-level seam, the API-key sheet writes through
/// [AppState.updateProviderApiKey], and the overflow Remove action deletes
/// through [removeCustomProviderForTest].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
  });

  tearDown(() {
    removeCustomProviderForTest = null;
    fetchProviderModelsForTest = null;
    AppState.resetTestInstance();
  });

  setUpAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDownAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  Future<void> pumpProviders(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
  }

  ProviderConfig addCustomProvider() {
    final provider = ProviderConfig(
      id: 'custom-acme',
      name: 'Acme Models',
      description: 'Test provider',
      baseUrl: 'https://models.acme.test/v1',
      custom: true,
    );
    app.providers.add(provider);
    return provider;
  }

  void removeAllByok() {
    // Keep only the managed Ovid Cloud row; everything else (seeded
    // built-ins + any custom row) is a BYOK provider by this screen's
    // definition, so dropping them exercises the empty-state branch.
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
  }

  testWidgets('Ovid Cloud managed tile is always visible', (tester) async {
    await pumpProviders(tester);
    expect(find.text('Ovid Cloud'), findsOneWidget);
    expect(find.text('Manage plan'), findsOneWidget);
  });

  testWidgets(
    'Ovid Cloud tile is still visible when no BYOK providers remain',
    (tester) async {
      removeAllByok();
      await pumpProviders(tester);
      expect(find.text('Ovid Cloud'), findsOneWidget);
    },
  );

  testWidgets('AetherEmptyState renders when BYOK list is empty',
      (tester) async {
    removeAllByok();
    await pumpProviders(tester);
    expect(find.byType(AetherEmptyState), findsOneWidget);
  });

  testWidgets(
    'AetherEmptyState does not render once a BYOK provider exists',
    (tester) async {
      removeAllByok();
      addCustomProvider();
      await pumpProviders(tester);
      expect(find.byType(AetherEmptyState), findsNothing);
      expect(find.text('Acme Models'), findsOneWidget);
    },
  );

  testWidgets('Fetch models invokes provider.fetchModels', (tester) async {
    removeAllByok();
    final provider = addCustomProvider();
    final seen = <String>[];
    fetchProviderModelsForTest = (p) async {
      seen.add(p.id);
      p.models
        ..clear()
        ..addAll(['acme-chat', 'acme-reasoner']);
      return null;
    };
    await pumpProviders(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Fetch models'));
    await tester.pumpAndSettle();
    expect(seen, [provider.id]);
    expect(provider.models, ['acme-chat', 'acme-reasoner']);
  });

  testWidgets('API key sheet writes the key via AppState', (tester) async {
    removeAllByok();
    final provider = addCustomProvider();
    await pumpProviders(tester);

    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'sk-live-abc123');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(provider.apiKey, 'sk-live-abc123');
    expect(provider.hasKey, isTrue);
  });

  testWidgets('Overflow Remove deletes the custom provider', (tester) async {
    removeAllByok();
    final provider = addCustomProvider();
    String? requested;
    removeCustomProviderForTest = (id) async {
      requested = id;
      app.providers.removeWhere((p) => p.id == id);
      app.refresh();
      return null;
    };
    await pumpProviders(tester);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Remove'));
    await tester.pumpAndSettle();
    // Confirm the destructive dialog.
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(requested, provider.id);
    expect(app.providerById(provider.id), isNull);
    expect(find.text('Acme Models'), findsNothing);
  });
}
