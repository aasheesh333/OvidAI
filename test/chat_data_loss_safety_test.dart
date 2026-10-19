// PR-3b: the chat screen never silently loses typed text, history, queued
// messages or goals.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// A server-shaped (UUID) message id — rows the server stores.
String _id(int n) => '0199aaaa-0000-7000-8000-${n.toString().padLeft(12, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = find.byKey(const ValueKey('chat-composer'));
  late ChatSession a;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.providers
      ..clear()
      ..add(
        ProviderConfig(
          id: 'p',
          name: 'Provider',
          description: '',
          baseUrl: 'https://example.test/v1',
          apiKey: 'key',
          models: ['m'],
        ),
      );
    a = ChatSession(
      id: 'safety-a',
      title: 'A',
      model: 'm',
      providerId: 'p',
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    app.sessions
      ..clear()
      ..add(a);
    app.activeSessionId = a.id;
    CloudAgentFacade.I.clearAttachment();
    CloudAgentFacade.I.clearQueueForTest();
    CloudAgentFacade.I.pendingApprovalForTest = null;
  });

  tearDown(() {
    CloudAgentFacade.I.setActiveRunForTest(a.id, null);
    CloudAgentFacade.I.pendingApprovalForTest = null;
    CloudAgentFacade.I.clearQueueForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  String draft(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!.text;

  Future<void> expireSnackBars(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 12));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('draft survives recreating ChatScreen after process death', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.enterText(composer, 'A long prompt I typed carefully');
    // Debounced write.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox());
    // Process death: every in-memory draft is gone, preferences remain.
    ComposerDraftStore.I.resetForTest();
    expect(
      (await SharedPreferences.getInstance()).getString(
        ComposerDraftStore.prefsKey,
      ),
      contains('A long prompt I typed carefully'),
    );
    await pumpChat(tester);
    await tester.pump();
    expect(draft(tester), 'A long prompt I typed carefully');
  });

  // CT-004 / CH-024: history edits are server operations on server-stored
  // rows. A local-only row offers no Regenerate (nothing it could re-run).
  testWidgets('Regenerate is not offered on a row the server does not store', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'user', content: 'Question'),
        Message(role: 'assistant', content: 'Answer'),
      ]);
    await pumpChat(tester);
    expect(find.byTooltip('Regenerate'), findsNothing);
    expect(a.messages, hasLength(2));
  });

  testWidgets('edit dialog states how many later messages it removes, and a '
      'refused edit keeps the history', (tester) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'user', content: 'First', privateSyncId: _id(1)),
        Message(role: 'assistant', content: 'One', privateSyncId: _id(2)),
        Message(role: 'user', content: 'Second', privateSyncId: _id(3)),
        Message(role: 'assistant', content: 'Two', privateSyncId: _id(4)),
      ]);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit & resend').first);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This also removes the 3 messages after it'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('edit-resend-send')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // The test HTTP stack refuses every request: the server never truncated,
    // so nothing local changes and the user is told.
    expect(a.messages.map((m) => m.content), ['First', 'One', 'Second', 'Two']);
    expect(find.byType(SnackBar), findsOneWidget);
    await expireSnackBars(tester);
  });

  testWidgets('Delete from here asks first; a refused delete keeps the rows', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..addAll([
        Message(role: 'assistant', content: 'Hello', privateSyncId: _id(5)),
        Message(role: 'user', content: 'Oops', privateSyncId: _id(6)),
      ]);
    await pumpChat(tester);
    expect(find.byTooltip('Revert'), findsNothing);
    await tester.tap(find.byTooltip('More actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete from here'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this message?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-delete-from')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(a.messages.map((m) => m.content), ['Hello', 'Oops']);
    await expireSnackBars(tester);
  });

  testWidgets('pending approval disables Attach and the mic', (tester) async {
    CloudAgentFacade.I.pendingApprovalForTest = ApprovalRequest(
      tool: 'bash',
      summary: 'Run',
      detail: 'ls',
    );
    await pumpChat(tester);
    tester.widget<TextField>(composer).controller!.text = 'My draft';
    await tester.pump();
    final attach = tester.widget<AetherGhostButton>(
      find.byWidgetPredicate(
        (w) => w is AetherGhostButton && w.label == 'Attach',
      ),
    );
    expect(attach.onPressed, isNull);
    final mic = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.mic_none),
    );
    expect(mic.onPressed, isNull);
    expect(draft(tester), 'My draft');
  });

  testWidgets('refused Generate image keeps the draft', (tester) async {
    a.messages.clear();
    // No usable model: the send path refuses with a snack bar.
    AppState.I.providers.single.models = ['other-model'];
    await pumpChat(tester);
    await tester.enterText(composer, 'My unrelated draft');
    await tester.tap(find.byTooltip('Attach'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate image'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'a mountain',
    );
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(draft(tester), 'My unrelated draft');
    expect(a.messages, isEmpty);
    await expireSnackBars(tester);
  });

  testWidgets('queue Clear all can be undone with the same ids', (
    tester,
  ) async {
    CloudAgentFacade.I.setActiveRunForTest(a.id, 'busy');
    for (final text in ['one', 'two', 'three']) {
      CloudAgentFacade.I.enqueueMessage(text, sessionId: a.id);
    }
    final ids = CloudAgentFacade.I.queuedMessageIdsFor(a.id);
    expect(ids, hasLength(3));
    await pumpChat(tester);
    await tester.tap(find.text('Clear all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(CloudAgentFacade.I.queuedMessagesFor(a.id), isEmpty);
    expect(find.text('Cleared 3 queued messages'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(CloudAgentFacade.I.queuedMessagesFor(a.id), ['one', 'two', 'three']);
    expect(CloudAgentFacade.I.queuedMessageIdsFor(a.id), ids);
    await expireSnackBars(tester);
  });

  testWidgets('complete goal renders nothing; Clear removes the bar', (
    tester,
  ) async {
    a.goal = {'objective': 'Ship it', 'status': 'complete', 'round': 3};
    await pumpChat(tester);
    expect(find.text('Ship it'), findsNothing);

    a.goal = {'objective': 'Ship it', 'status': 'active', 'round': 1};
    AppState.I.refresh();
    await tester.pump();
    expect(find.text('Ship it'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear goal'));
    await tester.pumpAndSettle();
    expect(a.goal, isNull);
    expect(find.text('Ship it'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(a.goal?['objective'], 'Ship it');
    expect(find.text('Ship it'), findsOneWidget);
    await expireSnackBars(tester);
  });
}
