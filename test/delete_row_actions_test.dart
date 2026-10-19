import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
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
    AppState.resetTestInstance();
  });

  setUpAll(() {
  });

  tearDownAll(() {
  });

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

      // The row disappears at once; the durable delete waits for the Undo
      // window to pass.
      expect(find.text(targetChat.title), findsNothing);
      expect(find.text('Chat deleted'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
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

      // The row disappears at once; the durable delete waits for the Undo
      // window to pass.
      expect(find.text(targetChat.title), findsNothing);
      expect(find.text('Chat deleted'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(app.sessionById(targetChat.id), isNull);
      expect(app.sessionById(activeChat.id), same(activeChat));
      expect(app.activeSessionId, activeChat.id);
      expect(find.text(targetChat.title), findsNothing);
      expect(find.text(activeChat.title), findsOneWidget);
    });

    testWidgets('Undo restores the deleted chat', (tester) async {
      await pumpChats(tester);
      await tester.tap(deleteChatFor(activeChat.title));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text(activeChat.title), findsNothing);
      // The deleted chat was active: another chat takes over meanwhile.
      expect(app.activeSessionId, targetChat.id);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(find.text(activeChat.title), findsOneWidget);
      expect(app.activeSessionId, activeChat.id);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(app.sessionById(activeChat.id), same(activeChat));
    });

    testWidgets('swipe-delete while settings are busy restores the row', (
      tester,
    ) async {
      await pumpChats(tester);
      app.settingsBusyForTest = true;
      addTearDown(() => app.settingsBusyForTest = false);
      await tester.drag(
        find.byKey(ValueKey(targetChat.id)),
        const Offset(-400, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text(targetChat.title), findsNothing);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      // The durable delete failed: the row is back and the user is told.
      expect(tester.takeException(), isNull);
      expect(app.sessionById(targetChat.id), same(targetChat));
      expect(find.text(targetChat.title), findsOneWidget);
      expect(find.textContaining('could not be deleted'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });
}
