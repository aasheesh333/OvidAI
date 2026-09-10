import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
  });

  tearDown(AppState.resetTestInstance);

  setUpAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(true);
  });

  tearDownAll(() {
    AgentService.I.debugPauseScheduleTimerForTest(false);
  });

  ProviderConfig addCustomProvider() {
    final provider = ProviderConfig(
      id: 'custom-acme',
      name: 'Acme Models',
      description: 'Test provider',
      baseUrl: 'https://models.acme.test/v1',
      custom: true,
    );
    app.providers.insert(0, provider);
    return provider;
  }

  Future<void> pumpProviders(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ProvidersScreen()),
    );
  }

  Future<void> pumpSidebar(WidgetTester tester, ChatSession session) {
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    return tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: const Scaffold(body: SessionsSidebar()),
      ),
    );
  }

  group('provider row delete action', () {
    testWidgets('is visible for custom providers', (tester) async {
      addCustomProvider();

      await pumpProviders(tester);

      expect(find.byTooltip('Delete provider'), findsOneWidget);
    });

    testWidgets('is absent for built-in providers', (tester) async {
      await pumpProviders(tester);

      expect(find.byTooltip('Delete provider'), findsNothing);
    });

    testWidgets('cancel keeps the named custom provider', (tester) async {
      final provider = addCustomProvider();
      await pumpProviders(tester);

      await tester.tap(find.byTooltip('Delete provider'));
      await tester.pumpAndSettle();

      expect(find.text('Delete ${provider.name}?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(app.providerById(provider.id), same(provider));
      expect(find.text(provider.name), findsOneWidget);
    });

    testWidgets('confirm removes the named custom provider', (tester) async {
      final provider = addCustomProvider();
      await pumpProviders(tester);

      await tester.tap(find.byTooltip('Delete provider'));
      await tester.pumpAndSettle();
      expect(find.text('Delete ${provider.name}?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(app.providerById(provider.id), isNull);
      expect(find.text(provider.name), findsNothing);
    });
  });

  group('session row delete action', () {
    ChatSession session() => ChatSession(
      id: 'chat-to-delete',
      title: 'Release planning',
      model: 'test-model',
    );

    testWidgets('is visible on every session row', (tester) async {
      await pumpSidebar(tester, session());

      expect(find.byTooltip('Delete chat'), findsOneWidget);
    });

    testWidgets('cancel keeps the named chat', (tester) async {
      final chat = session();
      await pumpSidebar(tester, chat);

      await tester.tap(find.byTooltip('Delete chat'));
      await tester.pumpAndSettle();

      expect(find.text('Delete ${chat.title}?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(app.sessionById(chat.id), same(chat));
      expect(find.text(chat.title), findsOneWidget);
    });

    testWidgets('confirm deletes the named chat', (tester) async {
      final chat = session();
      await pumpSidebar(tester, chat);

      await tester.tap(find.byTooltip('Delete chat'));
      await tester.pumpAndSettle();
      expect(find.text('Delete ${chat.title}?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(app.sessionById(chat.id), isNull);
      expect(find.text(chat.title), findsNothing);
    });
  });
}
