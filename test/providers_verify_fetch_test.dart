import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  void freshApp() {
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
    freshApp();
  });

  tearDown(() {
    providerModelsHttpClientForTest = null;
    fetchProviderModelsForTest = null;
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  ProviderConfig addProvider({List<String>? models}) {
    final provider = ProviderConfig(
      id: 'custom-acme',
      name: 'Acme Models',
      description: 'Test provider',
      baseUrl: 'https://models.acme.test/v1',
      custom: true,
      models: models,
    );
    app.providers.add(provider);
    return provider;
  }

  http.Response models(List<String> ids) => http.Response(
    '{"data":[${ids.map((id) => '{"id":"$id"}').join(',')}]}',
    200,
  );

  test('replaceProviderModels drops stale fetched ids, keeps manual', () async {
    final provider = addProvider(models: ['shipped']);
    await app.replaceProviderModels(provider, ['a', 'b']);
    expect(provider.models, ['shipped', 'a', 'b']);
    await app.addProviderModel(provider, 'my-manual');
    final removed = await app.replaceProviderModels(provider, ['b', 'c']);
    expect(removed, ['a']);
    expect(provider.models, ['shipped', 'b', 'my-manual', 'c']);
    expect(provider.fetchedModels, {'b', 'c'});
  });

  testWidgets('Fetch models replaces retired ids and reports counts', (
    tester,
  ) async {
    // Create the credential/persist queues inside this test's zone so pumps
    // can drain them (same pattern as ui_finish_08).
    freshApp();
    final provider = addProvider();
    await tester.runAsync(() async {
      await app.replaceProviderModels(provider, ['old-1', 'keep']);
      await app.addProviderModel(provider, 'manual');
    });
    final seen = <Uri>[];
    providerModelsHttpClientForTest = MockClient((req) async {
      seen.add(req.url);
      return models(['keep', 'new-1', 'new-2']);
    });
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
    final fetch = find.widgetWithText(TextButton, 'Fetch models');
    await tester.ensureVisible(fetch);
    await tester.tap(fetch);
    // The probe and the provider write run on real IO-backed futures.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(seen.single.toString(), 'https://models.acme.test/v1/models');
    expect(provider.models, ['keep', 'manual', 'new-1', 'new-2']);
    expect(
      find.text('3 models fetched · 2 new · 1 no longer offered removed ✓'),
      findsOneWidget,
    );
  });

  testWidgets('saving a key runs a probe and marks it verified', (
    tester,
  ) async {
    freshApp();
    final provider = addProvider();
    String? auth;
    providerModelsHttpClientForTest = MockClient((req) async {
      auth = req.headers['Authorization'];
      return models(['m1', 'm2']);
    });
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
    expect(find.text('Not connected · key required'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sk-good');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(auth, 'Bearer sk-good');
    expect(provider.verifiedAt, isNotNull);
    expect(provider.models, ['m1', 'm2']);
    expect(find.text('Acme Models API key'), findsNothing);
    expect(find.text('Key verified ✓ · 2 models'), findsOneWidget);
    expect(find.text('Key verified'), findsOneWidget);
  });

  testWidgets('a rejected key keeps the sheet open with a mapped error', (
    tester,
  ) async {
    freshApp();
    final provider = addProvider();
    providerModelsHttpClientForTest = MockClient(
      (_) async => http.Response('{"error":"bad key"}', 401),
    );
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'sk-bad');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(provider.apiKey, 'sk-bad');
    expect(provider.verifiedAt, isNull);
    expect(find.text('Acme Models API key'), findsOneWidget);
    expect(find.textContaining('Key rejected by the provider'), findsOneWidget);
  });

  test('probe maps 404 and network failures', () async {
    final provider = addProvider();
    final notFound = await probeProviderModels(
      provider,
      client: MockClient((_) async => http.Response('nope', 404)),
    );
    expect(notFound.error, contains('base URL'));
    final offline = await probeProviderModels(
      provider,
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    expect(offline.error, contains("Can't reach the provider"));
  });
}
