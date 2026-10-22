import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/session_artifacts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/artifact_preview.dart';
import 'package:ovid_ai/ui/artifacts_screen.dart';
import 'package:ovid_ai/ui/chat_overflow_menu.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/widgets/chat_tool_visuals.dart';
import 'package:ovid_ai/ui/widgets/code_highlight.dart';

/// Claude-style chat redesign: three-action header + ⋮ menu, thinking block,
/// tool rows, subagent cards, artifact cards and the Artifacts screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.sessions.clear();
    app.activeSessionId = null;
    ArtifactListPrefs.I.resetForTest();
    tmp = Directory.systemTemp.createTempSync('claude-style-chat-');
  });

  tearDown(() {
    AppState.resetTestInstance();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ChatSession addSession(
    String id,
    List<Message> messages, {
    String title = 'Chat',
    String? parentId,
    bool active = true,
  }) {
    final s = ChatSession(
      id: id,
      title: title,
      model: 'm',
      mode: 'auto',
      parentId: parentId,
      messages: messages,
    );
    AppState.I.sessions.add(s);
    if (active) AppState.I.activeSessionId = id;
    return s;
  }

  Future<void> pumpChat(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ChatScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Message tool(
    String name, {
    String state = 'ok',
    String? title,
    String? summary,
    String? detail,
    String? input,
    String? childId,
  }) => Message(
    role: 'assistant',
    kind: MsgKind.tool,
    toolName: name,
    toolTitle: title ?? name,
    toolSummary: summary,
    toolDetail: detail,
    toolState: state,
    toolInput: input,
    toolSessionId: childId,
  );

  group('header', () {
    testWidgets('shows the cloud header actions: Studio, Browser, ⋮', (
      tester,
    ) async {
      addSession('h1', [
        Message(role: 'user', content: 'hello'),
        Message(role: 'assistant', content: 'hi there'),
      ]);
      await pumpChat(tester);
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      final actions = bar.actions!.where((w) => w is! SizedBox).toList();
      expect(actions, hasLength(3));
      expect(find.byKey(const ValueKey('chat-header-studio')), findsOneWidget);
      // P8 Task 20 removed the dual-path gate: the cloud screencast viewer is
      // the only browser surface and is always present.
      expect(find.byKey(const ValueKey('chat-header-browser')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-header-more')), findsOneWidget);
      // The old share / new-session / jobs icons are gone from the header.
      final inBar = find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(IconButton),
      );
      expect(inBar, findsNWidgets(3));
      expect(find.byTooltip('Share chat'), findsNothing);
      expect(find.byTooltip('New chat'), findsNothing);
      expect(find.byTooltip('Background jobs'), findsNothing);
    });

    testWidgets('⋮ menu on a non-empty chat offers Share and New chat', (
      tester,
    ) async {
      addSession('h2', [
        Message(role: 'user', content: 'hello'),
        Message(role: 'assistant', content: 'hi there'),
      ]);
      await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      for (final a in [
        'share',
        'newChat',
        'rename',
        'artifacts',
        'trajectory',
        'usage',
        'delete',
      ]) {
        expect(find.byKey(ValueKey('chat-menu-$a')), findsOneWidget, reason: a);
      }
      expect(find.text('Share chat'), findsOneWidget);
      expect(find.text('New chat'), findsOneWidget);

      // New chat starts a fresh session.
      final before = AppState.I.sessions.length;
      await tester.tap(find.text('New chat'));
      await tester.pumpAndSettle();
      expect(AppState.I.sessions.length, before + 1);
      expect(AppState.I.activeSessionId, isNot('h2'));
    });

    testWidgets('⋮ menu on an empty chat hides Share and New chat', (
      tester,
    ) async {
      addSession('h3', []);
      await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-menu-share')), findsNothing);
      expect(find.byKey(const ValueKey('chat-menu-newChat')), findsNothing);
      for (final a in [
        'rename',
        'artifacts',
        'trajectory',
        'usage',
        'delete',
      ]) {
        expect(find.byKey(ValueKey('chat-menu-$a')), findsOneWidget, reason: a);
      }
      // Artifacts opens the Artifacts screen.
      await tester.tap(find.byKey(const ValueKey('chat-menu-artifacts')));
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactsScreen), findsOneWidget);
    });

    test('menu items: jobs only with jobs, subagents are not shareable', () {
      final full = ChatSession(
        id: 'a',
        title: 't',
        model: 'm',
        messages: [Message(role: 'user', content: 'x')],
      );
      expect(chatMenuActionsFor(full, 0), isNot(contains(ChatMenuAction.jobs)));
      expect(chatMenuActionsFor(full, 2), contains(ChatMenuAction.jobs));
      final empty = ChatSession(id: 'b', title: 't', model: 'm');
      expect(
        chatMenuActionsFor(empty, 0),
        isNot(
          anyOf(
            contains(ChatMenuAction.share),
            contains(ChatMenuAction.newChat),
          ),
        ),
      );
      final child = ChatSession(
        id: 'c',
        title: 't',
        model: 'm',
        parentId: 'a',
        messages: [Message(role: 'user', content: 'x')],
      );
      final childActions = chatMenuActionsFor(child, 0);
      expect(childActions, isNot(contains(ChatMenuAction.share)));
      expect(childActions, isNot(contains(ChatMenuAction.delete)));
      expect(childActions, contains(ChatMenuAction.newChat));
      expect(chatMenuActionsFor(null, 0), [
        ChatMenuAction.artifacts,
        ChatMenuAction.usage,
      ]);
    });

    test('menu items: a cloud session gates on the projection transcript', () {
      // Cloud sessions keep ChatSession.messages empty — the facade's live
      // projection is the transcript (chat_screen's `_messagesOf` parity).
      final cloud = ChatSession(id: 'd', title: 't', model: 'm');
      expect(
        chatMenuActionsFor(cloud, 0),
        isNot(
          anyOf(
            contains(ChatMenuAction.share),
            contains(ChatMenuAction.newChat),
          ),
        ),
        reason: 'no projection and empty rows: nothing to share',
      );
      final projected = chatMenuActionsFor(cloud, 0, transcript: [
        Message(role: 'user', content: 'hello cloud'),
      ]);
      expect(projected, contains(ChatMenuAction.share));
      expect(projected, contains(ChatMenuAction.newChat));
      // A present-but-empty projection wins over stale local rows.
      final stale = ChatSession(
        id: 'e',
        title: 't',
        model: 'm',
        messages: [Message(role: 'user', content: 'x')],
      );
      expect(
        chatMenuActionsFor(stale, 0, transcript: const <Message>[]),
        isNot(contains(ChatMenuAction.share)),
      );
    });

    testWidgets('rename from the ⋮ menu renames the chat', (tester) async {
      addSession('h4', [Message(role: 'user', content: 'hello')]);
      await pumpChat(tester);
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-menu-rename')));
      await tester.pumpAndSettle();
      expect(find.text('Rename chat'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Renamed chat');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(AppState.I.sessionById('h4')!.title, 'Renamed chat');
    });
  });

  group('thinking block', () {
    testWidgets('finished reasoning shows its duration and toggles', (
      tester,
    ) async {
      addSession('t1', [
        Message(role: 'user', content: 'why?'),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          content: 'THINK_BODY',
          elapsedMs: 4200,
        ),
      ]);
      await pumpChat(tester);
      expect(find.text('Thought for 4s'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-reasoning-body')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-reasoning-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reasoning-body')), findsOneWidget);
      expect(find.textContaining('THINK_BODY'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('chat-reasoning-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-reasoning-body')), findsNothing);
    });

    testWidgets('live thinking shimmers, then leaves "Thought for" above '
        'the answer', (tester) async {
      final live = Message(
        role: 'assistant',
        kind: MsgKind.streaming,
        thinking: true,
        content: 'LIVE_REASONING',
      );
      addSession('t2', [Message(role: 'user', content: 'go'), live]);
      await pumpChat(tester);
      expect(find.textContaining('Thinking…'), findsOneWidget);
      // Expanded while live so the thought stream is visible.
      expect(find.byKey(const ValueKey('chat-reasoning-body')), findsOneWidget);

      // The bubble turns into the answer.
      live
        ..thinking = false
        ..kind = MsgKind.text
        ..content = 'FINAL_ANSWER';
      AppState.I.refresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Thought for'), findsOneWidget);
      expect(find.textContaining('FINAL_ANSWER'), findsWidgets);
      // Collapsed by default, expandable to the recorded reasoning.
      expect(find.byKey(const ValueKey('chat-reasoning-body')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-reasoning-summary')));
      await tester.pumpAndSettle();
      expect(find.textContaining('LIVE_REASONING'), findsWidgets);
    });
  });

  group('tool rows', () {
    testWidgets('one glyph per tool family and a status badge', (tester) async {
      addSession('r1', [
        Message(role: 'user', content: 'do it'),
        tool('fs_grep', summary: 'TODO'),
        tool('run_shell', state: 'error', summary: 'make'),
        tool('file_read', summary: 'a.dart'),
        tool('fs_edit', summary: 'b.dart'),
        tool('fetch_url', summary: 'https://x'),
        tool('generate_image', summary: 'cat'),
        tool('mcp__github__list', state: 'stopped', summary: 'issues'),
      ]);
      await pumpChat(tester);
      // The run may fold; open the strip when it does.
      final strip = find.textContaining('tool calls');
      if (strip.evaluate().isNotEmpty) {
        await tester.tap(strip.first);
        await tester.pumpAndSettle();
      }
      for (final family in [
        'search',
        'terminal',
        'read',
        'edit',
        'web',
        'image',
        'mcp',
      ]) {
        expect(
          find.byKey(ValueKey('chat-tool-icon-$family')),
          findsOneWidget,
          reason: family,
        );
      }
      expect(find.byKey(const ValueKey('chat-tool-status-ok')), findsWidgets);
      expect(
        find.byKey(const ValueKey('chat-tool-status-error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chat-tool-status-stopped')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('running row shows a spinner', (tester) async {
      addSession('r2', [
        Message(role: 'user', content: 'do it'),
        tool('run_shell', state: 'running', summary: 'sleep 1'),
      ]);
      await pumpChat(tester);
      expect(
        find.byKey(const ValueKey('chat-tool-status-running')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('chat-tool-status-running')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
    });

    testWidgets('expanded details show input, coloured diff and a copy '
        'action', (tester) async {
      addSession('r3', [
        Message(role: 'user', content: 'edit'),
        tool(
          'fs_edit',
          title: 'Edit',
          summary: 'lib/a.dart',
          input: '{"path":"lib/a.dart"}',
          detail: 'diff lib/a.dart\n-old line\n+new line',
        ),
      ]);
      await pumpChat(tester);
      expect(find.text('+1 −1', findRichText: true), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('chat-tool-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-tool-body')), findsOneWidget);
      expect(find.text('INPUT'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.byTooltip('Copy output'), findsOneWidget);
      SelectableText line(String text) => tester.widget<SelectableText>(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == text),
      );
      expect(line('+new line').style?.color, Aether.success);
      expect(line('-old line').style?.color, Aether.danger);
    });

    test('tool families and highlighter', () {
      expect(chatToolFamily('mcp__srv__tool'), 'mcp');
      expect(chatToolFamily('plugin__x'), 'plugin');
      expect(chatToolFamily('edit_image'), 'image');
      expect(chatToolFamily('web_search'), 'search');
      expect(chatToolFamily('dispatch_agent'), 'agent');
      expect(chatToolFamily('fs_grep'), 'search');
      expect(chatToolFamily('fs_glob'), 'search');
      expect(chatToolFamily('fs_read'), 'read');
      final span = highlightCode(
        'final x = "hi"; // note',
        lang: 'dart',
        style: const TextStyle(),
      );
      final styled = <String, Color?>{};
      span.visitChildren((s) {
        if (s is TextSpan && s.text != null) styled[s.text!] = s.style?.color;
        return true;
      });
      expect(styled['final'], isNotNull);
      expect(styled['"hi"'], isNotNull);
      expect(styled['// note'], isNotNull);
      // Plain text is left alone.
      final plain = highlightCode(
        'just text',
        lang: 'text',
        style: const TextStyle(),
      );
      expect(plain.children, isNull);
      expect(plain.text, 'just text');
    });
  });

  group('subagent card', () {
    testWidgets('nested, collapsible card with name, status and own tools', (
      tester,
    ) async {
      addSession(
        'child-1',
        [
          Message(role: 'user', content: 'review'),
          tool('file_read', summary: 'lib/main.dart', title: 'Read'),
          tool('fs_grep', summary: 'TODO', title: 'Grep'),
          Message(role: 'assistant', content: 'report'),
        ],
        parentId: 'parent-1',
        title: 'reviewer',
        active: false,
      );
      addSession('parent-1', [
        Message(role: 'user', content: 'check the code'),
        tool(
          'dispatch_agent',
          title: 'Subagent',
          summary: 'Review the code',
          input: '{"subagent_type":"reviewer","objective":"Review the code"}',
          childId: 'child-1',
        ),
      ]);
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-subagent-card')), findsOneWidget);
      expect(find.text('reviewer'), findsWidgets);
      expect(find.text('Review the code'), findsOneWidget);
      expect(find.textContaining('Done · 2 tool uses'), findsOneWidget);
      // Finished → collapsed by default.
      expect(find.byKey(const ValueKey('chat-subagent-body')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-subagent-header')));
      await tester.pumpAndSettle();
      final body = find.byKey(const ValueKey('chat-subagent-body'));
      expect(body, findsOneWidget);
      expect(
        find.descendant(
          of: body,
          matching: find.byKey(const ValueKey('chat-tool-disclosure')),
        ),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: body,
          matching: find.byKey(const ValueKey('chat-tool-icon-read')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('chat-subagent-open')), findsOneWidget);
      // Collapses again.
      await tester.tap(find.byKey(const ValueKey('chat-subagent-header')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-subagent-body')), findsNothing);
    });

    testWidgets('a running subagent starts open with live rows', (
      tester,
    ) async {
      addSession(
        'child-2',
        [
          Message(role: 'user', content: 'work'),
          tool('run_shell', summary: 'ls', title: 'bash'),
        ],
        parentId: 'parent-2',
        active: false,
      );
      addSession('parent-2', [
        Message(role: 'user', content: 'go'),
        tool(
          'dispatch_agent',
          state: 'running',
          summary: 'Explore',
          input: '{"subagent_type":"explorer"}',
          childId: 'child-2',
        ),
      ]);
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-subagent-body')), findsOneWidget);
      expect(find.text('explorer'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('chat-tool-icon-terminal')),
        findsOneWidget,
      );
    });
  });

  group('artifacts', () {
    testWidgets('a written file shows an artifact card that opens a preview', (
      tester,
    ) async {
      final file = File('${tmp.path}/notes.dart')
        ..writeAsStringSync('void main() {\n  print("ARTIFACT_BODY");\n}\n');
      addSession('a1', [
        Message(role: 'user', content: 'write it'),
        tool(
          'file_write',
          title: 'Write',
          summary: file.path,
          input: '{"path":"${file.path}"}',
        ),
      ]);
      await pumpChat(tester);
      final card = find.byWidgetPredicate((w) => w is ArtifactCard);
      expect(card, findsOneWidget);
      expect(find.text('notes.dart'), findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactPreviewScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-preview-text')),
        findsOneWidget,
      );
      expect(
        find.textContaining('ARTIFACT_BODY', findRichText: true),
        findsWidgets,
      );
      expect(find.byTooltip('Copy'), findsOneWidget);
      expect(find.byTooltip('Share'), findsOneWidget);
    });

    testWidgets('missing file preview explains instead of crashing', (
      tester,
    ) async {
      addSession('a2', [Message(role: 'user', content: 'x')]);
      await tester.pumpWidget(
        MaterialApp(
          home: ArtifactPreviewScreen(
            artifact: SessionArtifact(
              id: 'x',
              name: 'gone.pdf',
              path: '${tmp.path}/gone.pdf',
              sessionId: 'a2',
              sessionTitle: 'Chat',
              time: DateTime(2026),
              origin: ArtifactOrigin.generated,
              kind: ArtifactKind.document,
            ),
          ),
        ),
      );
      expect(find.text('File not available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('collects uploads, images, html and written files', () {
      final s = ChatSession(
        id: 's',
        title: 'Trip',
        model: 'm',
        messages: [
          Message(
            role: 'user',
            content: 'see',
            attachments: [
              MessageAttachment(
                name: 'photo.png',
                size: 10,
                path: '/x/photo.png',
              ),
            ],
            time: DateTime(2026, 1, 1),
          ),
          Message(
            role: 'assistant',
            kind: MsgKind.imageGen,
            content: 'img',
            imagePath: '/x/gen.png',
            time: DateTime(2026, 1, 2),
          ),
          tool('file_write', input: '{"path":"out/report.md"}'),
          // Rewritten → listed once.
          tool('fs_edit', input: '{"path":"out/report.md"}'),
          // Failed writes and reads are not artifacts.
          tool('file_write', state: 'error', input: '{"path":"bad.txt"}'),
          tool('file_read', input: '{"path":"in.txt"}'),
        ],
      );
      final all = collectSessionArtifacts([s]);
      expect(
        all.map((a) => a.name),
        containsAll(['photo.png', 'gen.png', 'report.md']),
      );
      expect(all, hasLength(3));
      expect(
        all.where((a) => a.origin == ArtifactOrigin.uploaded).single.kind,
        ArtifactKind.image,
      );
      expect(
        all.firstWhere((a) => a.name == 'report.md').kind,
        ArtifactKind.document,
      );
      expect(artifactKindFor('main.py'), ArtifactKind.code);
      expect(artifactKindFor('page.html'), ArtifactKind.html);
    });

    testWidgets('Artifacts screen lists uploaded and generated with filters', (
      tester,
    ) async {
      final up = File('${tmp.path}/brief.txt')..writeAsStringSync('brief');
      final gen = File('${tmp.path}/result.md')..writeAsStringSync('# result');
      addSession('as1', [
        Message(
          role: 'user',
          content: 'here',
          attachments: [
            MessageAttachment(name: 'brief.txt', size: 5, path: up.path),
          ],
        ),
        tool('file_write', input: '{"path":"${gen.path}"}'),
      ], title: 'Research');
      addSession(
        'as2',
        [
          Message(
            role: 'assistant',
            kind: MsgKind.imageGen,
            content: 'img',
            imagePath: '${tmp.path}/other.png',
          ),
        ],
        title: 'Other chat',
        active: false,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const ArtifactsScreen(sessionId: 'as1'),
        ),
      );
      await tester.pump();
      // This chat: one upload + one generated file.
      expect(find.text('brief.txt'), findsOneWidget);
      expect(find.text('result.md'), findsOneWidget);
      expect(find.text('other.png'), findsNothing);

      await tester.tap(find.text('Uploaded'));
      await tester.pump();
      expect(find.text('brief.txt'), findsOneWidget);
      expect(find.text('result.md'), findsNothing);

      await tester.tap(find.text('Generated'));
      await tester.pump();
      expect(find.text('brief.txt'), findsNothing);
      expect(find.text('result.md'), findsOneWidget);

      // All chats widens the scope.
      await tester.tap(find.byKey(const ValueKey('artifacts-scope-all')));
      await tester.pump();
      expect(find.text('other.png'), findsOneWidget);

      await tester.tap(find.text('All'));
      await tester.pump();
      expect(find.byKey(const ValueKey('artifact-origin-up')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('artifact-origin-gen')),
        findsNWidgets(2),
      );

      // Long-press → remove from list (with undo).
      await tester.longPress(find.text('result.md'));
      await tester.pumpAndSettle();
      expect(find.text('Share'), findsOneWidget);
      await tester.tap(find.text('Remove from list'));
      await tester.pumpAndSettle();
      expect(find.text('result.md'), findsNothing);
      expect(find.text('Removed from Artifacts'), findsOneWidget);

      // Tap previews.
      await tester.tap(find.text('brief.txt'));
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactPreviewScreen), findsOneWidget);
      expect(find.text('brief', findRichText: true), findsWidgets);
      // Let the undo snack bar's commit timer run out.
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('Artifacts screen empty state', (tester) async {
      addSession('e1', [Message(role: 'user', content: 'hi')]);
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: const ArtifactsScreen(sessionId: 'e1'),
        ),
      );
      await tester.pump();
      expect(find.text('No artifacts yet'), findsOneWidget);
    });
  });

  group('320dp at 2.0x text', () {
    testWidgets('chat with tool rows, subagent and artifact card fits', (
      tester,
    ) async {
      final file = File('${tmp.path}/a_rather_long_generated_file_name.md')
        ..writeAsStringSync('x');
      addSession(
        'n-child',
        [tool('fs_grep', summary: 'pattern across the whole repository')],
        parentId: 'n1',
        active: false,
      );
      addSession('n1', [
        Message(role: 'user', content: 'a long request that wraps'),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          content: 'thinking',
          elapsedMs: 65000,
        ),
        Message(role: 'assistant', content: 'answer'),
        Message(role: 'user', content: 'more'),
        tool(
          'file_write',
          summary: file.path,
          input: '{"path":"${file.path}"}',
        ),
        tool(
          'fs_edit',
          summary: 'lib/some/deeply/nested/path/file.dart',
          detail: 'diff lib/x.dart\n+a\n-b',
        ),
        tool(
          'dispatch_agent',
          summary: 'A long subagent objective that must ellipsize',
          input: '{"subagent_type":"general-purpose-with-a-long-name"}',
          childId: 'n-child',
        ),
      ]);
      await pumpChat(tester, size: const Size(320, 640), textScale: 2.0);
      expect(tester.takeException(), isNull);
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      expect(bar.actions!.where((w) => w is! SizedBox), hasLength(3));
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Artifacts screen fits', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addSession('n2', [
        Message(
          role: 'user',
          content: 'x',
          attachments: [
            MessageAttachment(
              name: 'an_extremely_long_uploaded_document_name_v2_final.pdf',
              size: 123456,
              path: '${tmp.path}/doc.pdf',
            ),
          ],
        ),
      ], title: 'A chat with a long title');
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          home: const ArtifactsScreen(sessionId: 'n2'),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.text('an_extremely_long_uploaded_document_name_v2_final.pdf'),
        findsOneWidget,
      );
    });
  });
}
