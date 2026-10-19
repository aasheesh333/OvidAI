import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/share_actions.dart';

class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();
  @override
  double scale(double fontSize) =>
      fontSize <= 12 ? fontSize * 2 : fontSize * 1.5;
  @override
  double get textScaleFactor => 2;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = find.byKey(const ValueKey('chat-composer'));
  late ChatSession a;
  late ChatSession b;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    a = ChatSession(
      id: 'bounded-a',
      title: 'A',
      model: 'm',
      messages: [Message(role: 'assistant', content: 'Ready')],
    );
    b = ChatSession(
      id: 'bounded-b',
      title: 'B',
      model: 'm',
      messages: [Message(role: 'assistant', content: 'Other chat')],
    );
    app.sessions
      ..clear()
      ..addAll([a, b]);
    for (final s in [a, b]) {
      app.activeSessionId = s.id;
      CloudAgentFacade.I.clearAttachment();
      CloudAgentFacade.I.clearQueueForTest();
      CloudAgentFacade.I.pendingApprovalForTest = null;
    }
    app.activeSessionId = a.id;
  });

  tearDown(() {
    CloudAgentFacade.I.setActiveRunForTest(a.id, null);
    CloudAgentFacade.I.setActiveRunForTest(b.id, null);
    CloudAgentFacade.I.clearQueueForTest();
    CloudAgentFacade.I.clearAttachment();
    CloudAgentFacade.I.pendingApprovalForTest = null;
    AppState.resetTestInstance();
  });

  Future<void> pumpChat(WidgetTester tester, {TextScaler? scaler}) async {
    tester.view.physicalSize = const Size(700, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scaler),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  String draft(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!.text;

  Future<void> switchTo(WidgetTester tester, ChatSession s) async {
    AppState.I.selectSession(s.id);
    await tester.pump();
    await tester.pump();
  }

  ApprovalRequest question() => ApprovalRequest(
    tool: 'ask_user_question',
    summary: 'Choose',
    detail: '',
    questions: [
      UserQuestion(
        id: 'same-id',
        question: 'Which option?',
        options: [
          const QuestionOption(label: 'Option A'),
          const QuestionOption(label: 'Option B'),
        ],
      ),
    ],
  );

  testWidgets('header has no chat share action', (tester) async {
    await pumpChat(tester);
    expect(find.byType(ChatShareButton), findsNothing);
  });

  testWidgets('fenced diff is finite and long lines scroll horizontally', (
    tester,
  ) async {
    a.messages.single.content = '```diff\n-${'old ' * 100}\n+new\n```';
    await pumpChat(tester);
    expect(tester.takeException(), isNull);
    final scrollables = tester.stateList<ScrollableState>(
      find.byType(Scrollable),
    );
    final horizontal = scrollables.where(
      (s) =>
          s.position.axis == Axis.horizontal && s.position.maxScrollExtent > 0,
    );
    expect(horizontal, isNotEmpty);
    final position = horizontal.first.position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('main transcript composes nonlinear OS scaling with chat size', (
    tester,
  ) async {
    AppState.I.chatFontScale = 1.2;
    await pumpChat(tester, scaler: const _NonlinearScaler());
    final context = tester.element(
      find.byKey(const ValueKey('chat-transcript-list')),
    );
    final scaler = MediaQuery.textScalerOf(context);
    expect(scaler.scale(10), closeTo(24, .001));
    expect(scaler.scale(20), closeTo(36, .001));
    expect(MediaQuery.textScalerOf(tester.element(composer)).scale(20), 30);
  });

  testWidgets('child transcript retains nonlinear OS scaling', (tester) async {
    AppState.I.chatFontScale = 1.2;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            textScaler: _NonlinearScaler(),
          ),
          child: Scaffold(body: ChatTranscript(session: a)),
        ),
      ),
    );
    final scaler = MediaQuery.textScalerOf(
      tester.element(find.byType(ListView)),
    );
    expect(scaler.scale(20), closeTo(36, .001));
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('choosing an option replaces previously typed custom answer', (
    tester,
  ) async {
    final req = question();
    CloudAgentFacade.I.pendingApprovalForTest = req;
    await pumpChat(tester);
    final ownAnswer = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Or type your own answer…',
    );
    await tester.enterText(ownAnswer, 'Custom');
    await tester.tap(find.text('Option B'));
    await tester.pump();
    // The approval dock is a bounded scroll view; reveal the action before
    // tapping so the selection is committed.
    await tester.ensureVisible(find.text('Answer'));
    await tester.pump();
    await tester.tap(find.text('Answer'));
    expect(req.answers['same-id'], 'Option B');
    await tester.pump();
  });

  for (final switchSession in [false, true]) {
    testWidgets(
      'async command preserves ${switchSession ? 'other session' : 'newly typed'} draft',
      (tester) async {
        final result = Completer<CommandResult>();
        CommandService.I.register(
          AgentCommand(
            name: 'boundedwait',
            description: 'Wait',
            handler: (_) => result.future,
          ),
        );
        await pumpChat(tester);
        await tester.enterText(composer, '/boundedwait');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        if (switchSession) await switchTo(tester, b);
        await tester.enterText(composer, 'Keep this draft');
        result.complete(const CommandResult());
        await tester.pump();
        expect(draft(tester), 'Keep this draft');
        if (switchSession) {
          await switchTo(tester, a);
          expect(draft(tester), isEmpty);
        }
      },
    );
  }

  testWidgets('command clearInput false retains submitted draft', (
    tester,
  ) async {
    CommandService.I.register(
      AgentCommand(
        name: 'boundedkeep',
        description: 'Keep',
        handler: (_) async => const CommandResult(clearInput: false),
      ),
    );
    await pumpChat(tester);
    await tester.enterText(composer, '/boundedkeep');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(draft(tester), '/boundedkeep');
  });

  testWidgets('autocomplete tracks programmatic clear and session changes', (
    tester,
  ) async {
    await pumpChat(tester);
    await tester.enterText(composer, '/hel');
    await tester.pump();
    expect(find.text('/help'), findsOneWidget);
    tester.widget<TextField>(composer).controller!.clear();
    await tester.pump();
    expect(find.text('/help'), findsNothing);
    await tester.enterText(composer, '/hel');
    await tester.pump();
    await switchTo(tester, b);
    expect(find.text('/help'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment removal is named, 48dp, and keeps the file', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('chat-attachment-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/example.txt')
      ..writeAsStringSync('retain me');
    CloudAgentFacade.I.stageAttachmentForTest(
      a.id,
      name: 'example.txt',
      path: file.path,
      size: 9,
    );
    final semantics = tester.ensureSemantics();
    await pumpChat(tester);
    final remove = find.byTooltip('Remove attachment example.txt');
    expect(remove, findsOneWidget);
    expect(tester.getSize(remove).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(remove).height, greaterThanOrEqualTo(48));
    expect(
      tester
          .getSemantics(remove)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    await tester.tap(remove);
    await tester.pump();
    expect(CloudAgentFacade.I.pendingAttachments, isEmpty);
    expect(file.readAsStringSync(), 'retain me');
    semantics.dispose();
  });

  testWidgets(
    'child transcript offers no destructive edit or regenerate actions',
    (tester) async {
      final child = ChatSession(
        id: 'bounded-child',
        parentId: a.id,
        title: 'Child',
        model: 'm',
        messages: [
          Message(role: 'user', content: 'Child task'),
          Message(role: 'assistant', content: 'Child result'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatTranscript(session: child)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byTooltip('Edit & resend'), findsNothing);
      expect(find.byTooltip('Regenerate'), findsNothing);
      expect(find.byTooltip('Copy'), findsNWidgets(2));
    },
  );

  testWidgets('async command clears unchanged draft after cursor movement', (
    tester,
  ) async {
    final result = Completer<CommandResult>();
    CommandService.I.register(
      AgentCommand(
        name: 'boundedcursor',
        description: 'Wait',
        handler: (_) => result.future,
      ),
    );
    await pumpChat(tester);
    await tester.enterText(composer, '/boundedcursor');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    tester.widget<TextField>(composer).controller!.selection =
        const TextSelection.collapsed(offset: 2);
    result.complete(const CommandResult());
    await tester.pump();
    expect(draft(tester), isEmpty);
    expect(find.text('/boundedcursor'), findsNothing);
  });

  testWidgets('async command cannot clear a retyped identical draft', (
    tester,
  ) async {
    final result = Completer<CommandResult>();
    CommandService.I.register(
      AgentCommand(
        name: 'boundedretype',
        description: 'Wait',
        handler: (_) => result.future,
      ),
    );
    await pumpChat(tester);
    await tester.enterText(composer, '/boundedretype');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.enterText(composer, 'Something new');
    await tester.enterText(composer, '/boundedretype');
    result.complete(const CommandResult());
    await tester.pump();
    expect(draft(tester), '/boundedretype');
  });

  testWidgets('queue edit cannot overwrite another session queue', (
    tester,
  ) async {
    CloudAgentFacade.I.setActiveRunForTest(a.id, 'busy-a');
    CloudAgentFacade.I.setActiveRunForTest(b.id, 'busy-b');
    CloudAgentFacade.I.enqueueMessage('A queued', sessionId: a.id);
    CloudAgentFacade.I.enqueueMessage('B queued', sessionId: b.id);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit in composer'));
    await tester.pump();
    await tester.enterText(composer, 'A revision');
    await switchTo(tester, b);
    expect(find.byTooltip('Save queued message'), findsNothing);
    expect(draft(tester), isEmpty);
    await switchTo(tester, a);
    await tester.tap(find.byTooltip('Save queued message'));
    await tester.pump();
    expect(CloudAgentFacade.I.queuedMessagesFor(a.id), ['A revision']);
    expect(CloudAgentFacade.I.queuedMessagesFor(b.id), ['B queued']);
  });

  testWidgets('consumed queue edit keeps draft without sending it again', (
    tester,
  ) async {
    CloudAgentFacade.I.setActiveRunForTest(a.id, 'busy');
    CloudAgentFacade.I.enqueueMessage('Queued original', sessionId: a.id);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit in composer'));
    await tester.pump();
    CloudAgentFacade.I.removeQueuedMessageById(
      CloudAgentFacade.I.queuedMessageIdsFor(a.id).single,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Save queued message'));
    await tester.pump();
    expect(draft(tester), 'Queued original');
    expect(CloudAgentFacade.I.queuedMessagesFor(a.id), isEmpty);
    expect(a.messages.where((m) => m.role == 'user'), isEmpty);
  });

  testWidgets(
    'mention insertion uses current caret and survives cleared controller',
    (tester) async {
      await pumpChat(tester);
      await tester.enterText(composer, 'prefix @B');
      await tester.pump();
      final suggestion = find.text('B');
      expect(suggestion, findsOneWidget);
      await tester.tap(suggestion);
      await tester.pump();
      expect(draft(tester), 'prefix @[B] ');
      await tester.enterText(composer, 'prefix @B');
      await tester.pump();
      tester.widget<TextField>(composer).controller!.clear();
      // The old suggestion can still receive a tap before the next frame.
      await tester.tap(suggestion);
      await tester.pump();
      expect(draft(tester), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing legacy attachment paths leave original message intact', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..add(
        Message(
          role: 'user',
          content: 'Original',
          attachments: [MessageAttachment(name: 'legacy.txt', size: 3)],
        ),
      );
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit & resend'));
    await tester.pump();
    expect(a.messages.single.content, 'Original');
    expect(draft(tester), isEmpty);
    expect(CloudAgentFacade.I.pendingAttachments, isEmpty);
  });

  testWidgets('earlier-message edit transfers files before truncation', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..addAll([
        Message(
          role: 'user',
          content: 'Original',
          attachments: [
            MessageAttachment(
              name: 'source.txt',
              path: '/workspace/source.txt',
              size: 4,
            ),
          ],
        ),
        Message(role: 'assistant', content: 'Previous answer'),
      ]);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit & resend'));
    await tester.pumpAndSettle();
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'Revised');
    expect(find.textContaining('This removes the 1 message'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Edit & remove 1'));
    await tester.pumpAndSettle();
    expect(draft(tester), 'Revised');
    expect(
      CloudAgentFacade.I.pendingAttachments.single.path,
      '/workspace/source.txt',
    );
    expect(a.messages, isEmpty);
    // Let the Undo window expire.
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
  });

  testWidgets('double-tapping Send runs a slash command once (F-131)', (
    tester,
  ) async {
    final result = Completer<CommandResult>();
    var calls = 0;
    CommandService.I.register(
      AgentCommand(
        name: 'boundedcount',
        description: 'Count',
        handler: (_) {
          calls++;
          return result.future;
        },
      ),
    );
    await pumpChat(tester);
    await tester.enterText(composer, '/boundedcount');
    await tester.pump();
    // Two taps before the frame that disables Send: the re-entrancy guard
    // must drop the second one.
    await tester.tap(find.byTooltip('Send'));
    await tester.tap(find.byTooltip('Send'), warnIfMissed: false);
    await tester.pump();
    expect(calls, 1);
    result.complete(const CommandResult());
    await tester.pump();
    expect(calls, 1);
  });

  testWidgets('async command completion after disposal is harmless', (
    tester,
  ) async {
    final result = Completer<CommandResult>();
    CommandService.I.register(
      AgentCommand(
        name: 'boundeddispose',
        description: 'Wait',
        handler: (_) => result.future,
      ),
    );
    await pumpChat(tester);
    await tester.enterText(composer, '/boundeddispose');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpWidget(const SizedBox.shrink());
    result.complete(const CommandResult());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('generated image retains its local share action', (tester) async {
    final dir = Directory.systemTemp.createTempSync('chat-image-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final image = File('${dir.path}/image.png')..writeAsBytesSync([0]);
    a.messages
      ..clear()
      ..add(
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'Generated image',
          imagePath: image.path,
        ),
      );
    await pumpChat(tester);
    expect(find.text('Share'), findsOneWidget);
    expect(find.byType(ChatShareButton), findsNothing);
  });

  testWidgets('a late-arriving generated image renders without a rebuild', (
    tester,
  ) async {
    // The image lands in the workspace AFTER the row first renders — a
    // notFound stat must never be cached as a verdict (audit P2 B).
    final dir = Directory.systemTemp.createTempSync('chat-image-late-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final late = File('${dir.path}/late.png');
    a.messages
      ..clear()
      ..add(
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'Generated image',
          imagePath: late.path,
        ),
      );
    await pumpChat(tester);
    expect(find.text('image file not in workspace'), findsOneWidget);
    expect(find.text('Fullscreen'), findsNothing);

    late.writeAsBytesSync([0]);
    // The negative result is not cached: the row's delayed re-stat (5s while
    // the row is mounted) picks the file up with no rebuild to help it.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    await tester.pump();

    expect(find.text('image file not in workspace'), findsNothing);
    expect(find.text('Fullscreen'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
  });

  for (final appAvailable in [true, false]) {
    testWidgets(
      'generated image Open uses the FileProvider channel '
      '(app available: $appAvailable)',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('chat-image-open-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final image = File('${dir.path}/image.png')..writeAsBytesSync([0]);
        final calls = <MethodCall>[];
        const channel = MethodChannel('ovid/native');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'openFile' ? appAvailable : null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        a.messages
          ..clear()
          ..add(
            Message(
              role: 'assistant',
              kind: MsgKind.imageGen,
              content: 'Generated image',
              imagePath: image.path,
            ),
          );
        await pumpChat(tester);
        await tester.tap(find.text('Open'));
        await tester.pump();
        await tester.pump();
        final open = calls.singleWhere((c) => c.method == 'openFile');
        expect((open.arguments as Map)['filePath'], image.path);
        expect((open.arguments as Map)['mime'], 'image/png');
        expect(
          find.textContaining('No app can open'),
          appAvailable ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  testWidgets('last-message edit retains attachments in composer', (
    tester,
  ) async {
    a.messages
      ..clear()
      ..add(
        Message(
          role: 'user',
          content: 'Original',
          attachments: [
            MessageAttachment(
              name: 'example.txt',
              size: 3,
              path: '/workspace/example.txt',
            ),
          ],
        ),
      );
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit & resend'));
    await tester.pump();
    expect(draft(tester), 'Original');
    expect(
      CloudAgentFacade.I.pendingAttachments.single.path,
      '/workspace/example.txt',
    );
    // Let the Undo window expire.
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'edit does not destroy history when existing draft cannot transfer',
    (tester) async {
      a.messages
        ..clear()
        ..add(Message(role: 'user', content: 'Original'));
      await pumpChat(tester);
      await tester.enterText(composer, 'Unsubmitted draft');
      await tester.tap(find.byTooltip('Edit & resend'));
      await tester.pump();
      expect(a.messages.single.content, 'Original');
      expect(draft(tester), 'Unsubmitted draft');
    },
  );

  // CH-027 / ST-012: the Studio-mode composer chip used to open a "Sandbox
  // folder (Studio)" sheet that pinned a PHONE folder the cloud never saw. It
  // is now a single chip that opens Studio — no device folder picker.
  testWidgets('Studio mode shows one Studio chip and no folder picker', (
    tester,
  ) async {
    a.mode = 'studio';
    a.workspaceFolder = '/nonexistent/tap-workspace';
    await pumpChat(tester);
    expect(find.byKey(const ValueKey('composer-studio-chip')), findsOneWidget);
    expect(find.text('tap-workspace'), findsNothing);
    expect(find.byTooltip('Working folder'), findsNothing);
    expect(find.text('Select working folder'), findsNothing);
  });
}
