import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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

  // Aether redesign: provider removal lives behind the tile's overflow menu
  // ('More actions' → 'Remove'), not a dedicated row IconButton.
  Finder providerOverflowFor(String providerId) => find.descendant(
    of: find.byKey(ValueKey(providerId)),
    matching: find.byTooltip('More actions'),
  );

  Future<void> tapRemoveFor(WidgetTester tester, String providerId) async {
    await tester.tap(providerOverflowFor(providerId));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
  }

  group('provider row delete action', () {
    testWidgets('has an accessible label only for custom providers', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final provider = addCustomProvider();

      await pumpProviders(tester);

      // The affordance sits behind the row's (tooltip-labelled) overflow menu.
      expect(providerOverflowFor(provider.id), findsOneWidget);
      await tester.tap(providerOverflowFor(provider.id));
      await tester.pumpAndSettle();

      final removeItem = find.bySemanticsLabel(RegExp(r'(^|\n)Remove($|\n)'));
      expect(removeItem, findsOneWidget);
      final removeSemantics = tester.getSemantics(removeItem);
      expect(
        removeSemantics.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(
        removeSemantics.getSemanticsData().flagsCollection.isButton,
        isTrue,
      );
      // Dismiss the popup via its barrier (middle-left is outside the menu).
      await tester.tapAt(const Offset(10, 400));
      await tester.pumpAndSettle();

      // A built-in BYOK row: the managed Ovid Cloud tile has no overflow
      // menu at all, so the negative check needs a keyed BYOK tile.
      final builtIn = app.providers.firstWhere(
        (provider) =>
            !provider.custom && provider.id != AppState.ovidCloudProviderId,
      );
      await tester.ensureVisible(providerOverflowFor(builtIn.id));
      await tester.pumpAndSettle();
      await tester.tap(providerOverflowFor(builtIn.id));
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'(^|\n)Remove($|\n)')),
        findsNothing,
      );
      expect(find.text('Edit'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('cancel keeps the named custom provider', (tester) async {
      final provider = addCustomProvider();
      await pumpProviders(tester);

      await tapRemoveFor(tester, provider.id);

      expect(find.text('Remove ${provider.name}?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(app.providerById(provider.id), same(provider));
      expect(find.text(provider.name), findsOneWidget);
    });

    testWidgets('confirm removes the named custom provider', (tester) async {
      final provider = addCustomProvider();
      await pumpProviders(tester);

      await tapRemoveFor(tester, provider.id);
      expect(find.text('Remove ${provider.name}?'), findsOneWidget);

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

      await tapRemoveFor(tester, provider.id);
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

    testWidgets('swipe asks for confirmation before deleting', (tester) async {
      await pumpChats(tester);

      await tester.drag(
        find.byKey(ValueKey(targetChat.id)),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();

      // Swipe-to-delete now asks for confirmation (an accidental swipe used
      // to delete the chat with no way back) — nothing is deleted yet.
      expect(app.sessionById(targetChat.id), same(targetChat));
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
  });
}
