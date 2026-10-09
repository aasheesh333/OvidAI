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
  late AppState app;

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

  Future<void> host(WidgetTester tester, {int modelCount = 23}) async {
    // The credential queue must be created inside the widget test's async zone.
    app = AppState.createForTest();
    app.providers
      ..clear()
      ..add(
        ProviderConfig(
          id: 'compact-gateway',
          name: 'Compact gateway',
          description: 'Cached provider',
          baseUrl: 'https://gateway.example.test/v1',
          custom: true,
          models: List.generate(modelCount, (i) => 'cached-model-$i'),
        ),
      );
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('compact rows hide cached models until expanded', (tester) async {
    await host(tester);
    final card = find.ancestor(
      of: find.text('Compact gateway'),
      matching: find.byType(AetherCard),
    );
    expect(tester.getSize(card).height, lessThanOrEqualTo(144));
    expect(find.text('cached-model-0'), findsNothing);
    await tapVisible(tester, find.text('Compact gateway'));
    expect(find.text('cached-model-0'), findsOneWidget);
    await tapVisible(tester, find.text('Compact gateway'));
    expect(find.text('cached-model-0'), findsNothing);
  });

  testWidgets('More reveals cached pages locally and ends at the final page', (
    tester,
  ) async {
    var requests = 0;
    fetchProviderModelsForTest = (_) async {
      requests++;
      return null;
    };
    await host(tester);
    await tapVisible(tester, find.text('Compact gateway'));
    expect(find.text('cached-model-9'), findsOneWidget);
    expect(find.text('cached-model-10'), findsNothing);
    await tapVisible(tester, find.widgetWithText(TextButton, 'More'));
    expect(find.text('cached-model-19'), findsOneWidget);
    expect(find.text('cached-model-20'), findsNothing);
    await tapVisible(tester, find.widgetWithText(TextButton, 'More'));
    expect(find.text('cached-model-22'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'More'), findsNothing);
    expect(requests, 0);
    await tapVisible(tester, find.text('Compact gateway'));
    await tapVisible(tester, find.text('Compact gateway'));
    expect(find.text('cached-model-10'), findsNothing);
    expect(requests, 0);
  });

  testWidgets(
    'empty expansion explains how to populate models without fetching',
    (tester) async {
      var requests = 0;
      fetchProviderModelsForTest = (_) async {
        requests++;
        return null;
      };
      await host(tester, modelCount: 0);
      await tapVisible(tester, find.text('Compact gateway'));
      expect(find.textContaining('No cached models'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'More'), findsNothing);
      expect(requests, 0);
      await tapVisible(tester, find.widgetWithText(TextButton, 'Fetch models'));
      expect(requests, 1);
    },
  );

  for (final option in [
    (label: 'Anthropic', format: ApiFormat.anthropic),
    (label: '[OI]-compatible', format: ApiFormat.openai),
  ]) {
    testWidgets('create provider passes selected ${option.label} protocol', (
      tester,
    ) async {
      await host(tester, modelCount: 0);
      await tapVisible(
        tester,
        find.widgetWithText(OutlinedButton, 'Add custom provider'),
      );
      await tester.enterText(find.byType(TextField).at(0), 'New gateway');
      await tester.enterText(
        find.byType(TextField).at(1),
        'https://proxy.example.test/v1',
      );
      // Exercise switching both ways rather than relying on the default.
      expect(find.widgetWithText(ChoiceChip, 'Anthropic'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Anthropic'));
      await tapVisible(tester, find.widgetWithText(ChoiceChip, option.label));
      await tapVisible(tester, find.widgetWithText(TextButton, 'Add'));
      final provider = app.providers.singleWhere(
        (p) => p.name == 'New gateway',
      );
      expect(provider.apiFormat, option.format);
      expect(provider.effectiveApiFormat, option.format);
    });
  }

  testWidgets(
    'edit supports both protocols and bounds cached model rendering',
    (tester) async {
      await host(tester);
      await tapVisible(tester, find.byTooltip('More actions'));
      await tapVisible(tester, find.text('Edit'));
      await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Anthropic'));
      expect(app.providers.single.apiFormat, ApiFormat.anthropic);
      await tapVisible(
        tester,
        find.widgetWithText(ChoiceChip, '[OI]-compatible'),
      );
      expect(app.providers.single.apiFormat, ApiFormat.openai);
      expect(find.byTooltip('Remove model cached-model-9'), findsOneWidget);
      expect(find.byTooltip('Remove model cached-model-10'), findsNothing);
      await tapVisible(tester, find.widgetWithText(TextButton, 'More'));
      expect(find.byTooltip('Remove model cached-model-10'), findsOneWidget);
    },
  );
}
