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

  tearDown(() {
    removeCustomProviderForTest = null;
    AppState.resetTestInstance();
  });

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

  Future<void> pumpSidebar(
    WidgetTester tester, {
    required List<ChatSession> sessions,
    required String activeSessionId,
  }) {
    app.sessions
      ..clear()
      ..addAll(sessions);
    app.activeSessionId = activeSessionId;
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

  Finder deleteChatFor(String title) => find.descendant(
    of: find.ancestor(of: find.text(title), matching: find.byType(Dismissible)),
    matching: find.byTooltip('Delete chat'),
  );

  group('provider row delete action', () {
    testWidgets('has an accessible label only for custom providers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      addCustomProvider();

      await pumpProviders(tester);

      expect(find.byTooltip('Delete provider'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'(^|\n)Delete provider($|\n)')),
        findsOneWidget,
      );
      final builtIn = app.providers.firstWhere((provider) => !provider.custom);
      expect(
        find.descendant(
          of: find.byKey(ValueKey(builtIn.id)),
          matching: find.bySemanticsLabel(
            RegExp(r'(^|\n)Delete provider($|\n)'),
          ),
        ),
        findsNothing,
      );
      semantics.dispose();
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

    testWidgets('failed removal keeps provider and shows returned error', (
      tester,
    ) async {
      final provider = addCustomProvider();
      String? requestedProviderId;
      removeCustomProviderForTest = (providerId) async {
        requestedProviderId = providerId;
        return 'Provider removal failed.';
      };
      await pumpProviders(tester);

      await tester.tap(find.byTooltip('Delete provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(app.providerById(provider.id), same(provider));
      expect(find.text(provider.name), findsOneWidget);
      expect(find.text('Provider removal failed.'), findsOneWidget);
      expect(requestedProviderId, provider.id);
    });
  });

  group('session row delete action', () {
    late ChatSession activeChat;
    late ChatSession targetChat;

    setUp(() {
      activeChat = ChatSession(
        id: 'active-chat',
        title: 'Active planning',
        model: 'test-model',
      );
      targetChat = ChatSession(
        id: 'target-chat',
        title: 'Release planning',
        model: 'test-model',
      );
    });

    Future<void> pumpChats(WidgetTester tester) => pumpSidebar(
      tester,
      sessions: [activeChat, targetChat],
      activeSessionId: activeChat.id,
    );

    testWidgets('is visible on every session row', (tester) async {
      await pumpChats(tester);

      expect(find.byTooltip('Delete chat'), findsNWidgets(2));
      expect(deleteChatFor(activeChat.title), findsOneWidget);
      expect(deleteChatFor(targetChat.title), findsOneWidget);
    });

    testWidgets('cancel targets a row without selecting it', (tester) async {
      await pumpChats(tester);

      await tester.tap(deleteChatFor(targetChat.title));
      await tester.pumpAndSettle();

      expect(find.text('Delete ${targetChat.title}?'), findsOneWidget);
      expect(app.activeSessionId, activeChat.id);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(app.sessionById(targetChat.id), same(targetChat));
      expect(app.sessionById(activeChat.id), same(activeChat));
      expect(app.activeSessionId, activeChat.id);
    });

    testWidgets('confirm deletes only the targeted inactive row', (
      tester,
    ) async {
      await pumpChats(tester);

      await tester.tap(deleteChatFor(targetChat.title));
      await tester.pumpAndSettle();
      expect(find.text('Delete ${targetChat.title}?'), findsOneWidget);
      expect(app.activeSessionId, activeChat.id);

      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(app.sessionById(targetChat.id), isNull);
      expect(app.sessionById(activeChat.id), same(activeChat));
      expect(app.activeSessionId, activeChat.id);
      expect(find.text(targetChat.title), findsNothing);
      expect(find.text(activeChat.title), findsOneWidget);
    });

    testWidgets('swipe deletes only the targeted row', (tester) async {
      await pumpChats(tester);

      await tester.drag(
        find.byKey(ValueKey(targetChat.id)),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();

      expect(app.sessionById(targetChat.id), isNull);
      expect(app.sessionById(activeChat.id), same(activeChat));
      expect(app.activeSessionId, activeChat.id);
    });
  });
}
