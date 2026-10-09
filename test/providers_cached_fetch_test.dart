import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDown(() {
    fetchProviderModelsForTest = null;
    AppState.resetTestInstance();
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  testWidgets('explicit fetch updates only its expanded provider cache', (
    tester,
  ) async {
    final app = AppState.createForTest();
    final first = ProviderConfig(
      id: 'first-gateway',
      name: 'First gateway',
      description: 'First cached provider',
      baseUrl: 'https://first.example.test/v1',
      custom: true,
      models: ['first-existing'],
    );
    final second = ProviderConfig(
      id: 'second-gateway',
      name: 'Second gateway',
      description: 'Second cached provider',
      baseUrl: 'https://second.example.test/v1',
      custom: true,
      models: ['second-existing'],
    );
    app.providers
      ..clear()
      ..addAll([first, second]);
    final requestedIds = <String>[];
    fetchProviderModelsForTest = (provider) async {
      requestedIds.add(provider.id);
      provider.models.addAll(List.generate(12, (i) => 'fetched-$i'));
      return null;
    };
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Finder card(String name) => find.ancestor(
      of: find.text(name),
      matching: find.byType(AetherCard),
    );

    await tap(find.text('First gateway'));
    expect(find.text('first-existing'), findsOneWidget);
    expect(find.text('second-existing'), findsNothing);
    expect(requestedIds, isEmpty);

    await tap(
      find.descendant(
        of: card('First gateway'),
        matching: find.widgetWithText(TextButton, 'Fetch models'),
      ),
    );
    expect(requestedIds, ['first-gateway']);
    expect(find.text('first-existing'), findsOneWidget);
    expect(find.text('fetched-8'), findsOneWidget);
    expect(find.text('fetched-9'), findsNothing);
    expect(second.models, ['second-existing']);

    await tap(find.widgetWithText(TextButton, 'More'));
    expect(find.text('fetched-11'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'More'), findsNothing);
    await tap(find.text('First gateway'));
    await tap(find.text('Second gateway'));
    expect(find.text('second-existing'), findsOneWidget);
    expect(find.text('fetched-0'), findsNothing);
    expect(requestedIds, ['first-gateway']);

    // A state refresh must keep expansion attached to the provider's identity.
    await app.removeCustomProvider(first.id);
    await tester.pumpAndSettle();
    expect(find.text('First gateway'), findsNothing);
    expect(find.text('second-existing'), findsOneWidget);
    expect(requestedIds, ['first-gateway']);
    expect(tester.takeException(), isNull);
  });
}
