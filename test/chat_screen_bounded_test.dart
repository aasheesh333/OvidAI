import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
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

class _FolderPicker extends FilePicker {
  final Completer<String?> result = Completer<String?>();
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) => result.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final composer = find.byKey(const ValueKey('chat-composer'));
  late ChatSession a;
  late ChatSession b;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
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
      AgentService.I.clearAttachment();
      AgentService.I.clearQueueForTest();
      AgentService.I.pendingApproval = null;
    }
    app.activeSessionId = a.id;
  });

  tearDown(() {
    AgentNotificationService.I.resetForTest();
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

  testWidgets('questions never inherit another session request selection', (
    tester,
  ) async {
    AgentService.I.runBucketForTest(a.id).pendingApproval = question();
    AgentService.I.runBucketForTest(b.id).pendingApproval = question();
    await pumpChat(tester);
    await tester.tap(find.text('Option A'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Answer'))
          .onPressed,
      isNotNull,
    );
    await switchTo(tester, b);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Answer'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('choosing an option replaces previously typed custom answer', (
    tester,
  ) async {
    final req = question();
    AgentService.I.pendingApproval = req;
    await pumpChat(tester);
    final ownAnswer = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.hintText == 'Or type your own answer…',
    );
    await tester.enterText(ownAnswer, 'Custom');
    await tester.tap(find.text('Option B'));
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
    AgentService.I.pendingAttachments.add((
      name: 'example.txt',
      path: file.path,
      size: 9,
    ));
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
    expect(AgentService.I.pendingAttachments, isEmpty);
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

  testWidgets('queue edit retains original until saved through composer', (
    tester,
  ) async {
    AgentService.I.pendingAttachments.add((
      name: 'queued.txt',
      path: '/workspace/queued.txt',
      size: 12,
    ));
    AgentService.I.enqueueMessage('Queued original', sessionId: a.id);
    AgentService.I.clearAttachment();
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit in composer'));
    await tester.pump();
    expect(draft(tester), 'Queued original');
    expect(AgentService.I.queuedMessagesFor(a.id), ['Queued original']);
    await tester.enterText(composer, 'Queued revision');
    await tester.tap(find.byTooltip('Save queued message'));
    await tester.pump();
    expect(AgentService.I.queuedMessagesFor(a.id), ['Queued revision']);
    expect(draft(tester), isEmpty);
    AgentService.I.queuedRunStarterForTest = (_, _) async {};
    addTearDown(() => AgentService.I.queuedRunStarterForTest = null);
    AgentService.I.runBucketForTest(a.id).activeRunId = 'queued-test';
    AgentService.I.stopRequested(sessionId: a.id);
    await tester.pump();
    final sent = a.messages.singleWhere((m) => m.content == 'Queued revision');
    expect(sent.attachments.single.path, '/workspace/queued.txt');
    await tester.pump(const Duration(milliseconds: 350));
  });

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
    AgentService.I.enqueueMessage('A queued', sessionId: a.id);
    AgentService.I.enqueueMessage('B queued', sessionId: b.id);
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
    expect(AgentService.I.queuedMessagesFor(a.id), ['A revision']);
    expect(AgentService.I.queuedMessagesFor(b.id), ['B queued']);
  });

  testWidgets('consumed queue edit keeps draft without sending it again', (
    tester,
  ) async {
    AgentService.I.enqueueMessage('Queued original', sessionId: a.id);
    await pumpChat(tester);
    await tester.tap(find.byTooltip('Edit in composer'));
    await tester.pump();
    AgentService.I.removeQueuedMessageById(
      AgentService.I.queuedMessageIdsFor(a.id).single,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Save queued message'));
    await tester.pump();
    expect(draft(tester), 'Queued original');
    expect(AgentService.I.queuedMessagesFor(a.id), isEmpty);
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
      expect(draft(tester), 'prefix @session:bounded-b ');
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
    expect(AgentService.I.pendingAttachments, isEmpty);
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
    await tester.tap(find.widgetWithText(TextButton, 'Edit in composer'));
    await tester.pumpAndSettle();
    expect(draft(tester), 'Revised');
    expect(
      AgentService.I.pendingAttachments.single.path,
      '/workspace/source.txt',
    );
    expect(a.messages, isEmpty);
  });

  testWidgets(
    'composer queue submission transfers files out of pending draft',
    (tester) async {
      AgentService.I.runBucketForTest(a.id).activeRunId = 'busy-test';
      AgentService.I.pendingAttachments.add((
        name: 'pending.txt',
        path: '/workspace/pending.txt',
        size: 10,
      ));
      await pumpChat(tester);
      await tester.enterText(composer, 'Queued with file');
      await tester.pump();
      await tester.tap(find.byTooltip('Add to queue'));
      await tester.pump();
      expect(AgentService.I.pendingAttachments, isEmpty);
      expect(AgentService.I.queuedMessagesFor(a.id), ['Queued with file']);
      await tester.tap(find.byTooltip('Edit in composer'));
      await tester.pump();
      expect(draft(tester), 'Queued with file');
      AgentService.I.runBucketForTest(a.id).activeRunId = null;
      AgentNotificationService.I.resetForTest();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
      AgentService.I.pendingAttachments.single.path,
      '/workspace/example.txt',
    );
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

  testWidgets(
    'workspace picker preserves existing probe and binds originating session',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('chat-workspace-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final existing = File('${dir.path}/.ovid_probe')
        ..writeAsStringSync('user file');
      final picker = _FolderPicker();
      FilePicker.platform = picker;
      a.mode = 'studio';
      a.workspaceFolder = '${dir.path}/old-workspace';
      await pumpChat(tester);
      await tester.longPress(find.text('old-workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select working folder'));
      await tester.pumpAndSettle();
      await switchTo(tester, b);
      picker.result.complete(dir.path);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(existing.existsSync(), isTrue);
      expect(existing.readAsStringSync(), 'user file');
      expect(a.workspaceFolder, dir.path);
      expect(b.workspaceFolder, isNull);
      expect(dir.listSync().map((e) => e.path), [existing.path]);
    },
  );
}
