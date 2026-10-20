// W9 (chat UX) regression suite.
//
// Covers the owner-spec controls added on top of the chat surface:
//   * @ autocomplete over all root chats, projects and active subagents;
//   * explicit-only refs (R1) for `@[Title]` and `@session:<id>`;
//   * the model lock during a live turn;
//   * STUDIO's repo/branch gate and chip;
//   * the ⋮ menu's Add to Project / Pin entries when W1's port is installed;
//   * the live subagent activity strip + trajectory drill-down;
//   * voice-first mode's language sheet and TTS service seam.

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_session_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/voice_reply_service.dart';
import 'package:ovid_ai/ui/chat_overflow_menu.dart';
import 'package:ovid_ai/ui/chat_screen.dart';

class _FakeProjects extends ProjectsPort {
  _FakeProjects({this.projects = const []});

  @override
  bool ready = true;

  @override
  bool supportsTurnProjectRefs = true;

  @override
  List<ProjectOption> projects;

  final Set<String> pinned = <String>{};

  @override
  bool isPinned(String sessionId) => pinned.contains(sessionId);

  @override
  Future<void> addSessionToProject(String sessionId, String? projectId) async {}

  @override
  Future<void> setPinned(String sessionId, bool pinned) async {
    if (pinned) {
      this.pinned.add(sessionId);
    } else {
      this.pinned.remove(sessionId);
    }
    notifyListeners();
  }

  @override
  List<String> projectRefsIn(String text) => [
    for (final m in RegExp(r'@project:([A-Za-z0-9_\-]+)').allMatches(text))
      m.group(1)!,
  ];
}

class _FakeStudio extends StudioBindingPort {
  _FakeStudio({this.binding});

  StudioBinding? binding;

  @override
  bool ready = true;

  @override
  StudioBinding? bindingFor(String sessionId) => binding;

  @override
  Future<List<String>> listRepos() async => const ['acme/app'];

  @override
  Future<List<String>> listBranches(String repo) async => const ['main', 'dev'];

  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {
    binding = StudioBinding(repo: repo, branch: branch);
    notifyListeners();
  }

  @override
  Future<void> syncLatest(String sessionId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    FlutterSecureStorage.setMockInitialValues(const <String, String>{});
    AppState.resetTestInstance();
    CloudAgentFacade.resetForTest();
    ProjectsPort.installForTest(null);
    StudioBindingPort.installForTest(null);
    ChatPinsStore.I.clearForTest();
    VoiceReplyService.I.speakOverrideForTest = null;
    VoiceReplyService.I.stopOverrideForTest = null;
    VoiceReplyService.I.availableOverrideForTest = null;
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    CloudAgentFacade.resetForTest();
    CloudSessionStore.resetForTest();
    ProjectsPort.installForTest(null);
    StudioBindingPort.installForTest(null);
    ChatPinsStore.I.clearForTest();
    VoiceReplyService.I.speakOverrideForTest = null;
    VoiceReplyService.I.stopOverrideForTest = null;
    VoiceReplyService.I.availableOverrideForTest = null;
    AppState.resetTestInstance();
  });

  ChatSession addSession(
    String id, {
    String title = 'Chat',
    String mode = 'auto',
  }) {
    final s = ChatSession(id: id, title: title, model: 'm', mode: mode);
    AppState.I.sessions.add(s);
    AppState.I.activeSessionId = id;
    return s;
  }

  Future<void> pumpChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('R1 explicit refs', () {
    test('@session:<local id> resolves to the child server id', () {
      final store = CloudSessionStore.forTest(
        idMap: const {'child-local': '0199aaaa-0000-7000-8000-00000000c001'},
      );
      CloudSessionStore.installForTest(store);
      addSession('parent');
      AppState.I.sessions.add(
        ChatSession(id: 'child-local', title: 'Child', model: 'm', mode: 'auto')
          ..parentId = 'parent',
      );

      final refs = ChatScreen.sessionRefsInForTest(
        'ask @session:child-local and @session:child-local again',
        'parent',
      );
      expect(refs, ['0199aaaa-0000-7000-8000-00000000c001']);
    });

    test('@[Title] still resolves by title and skips the current chat', () {
      final store = CloudSessionStore.forTest(
        idMap: const {
          'local-a': '0199aaaa-0000-7000-8000-00000000c00a',
          'local-self': '0199aaaa-0000-7000-8000-00000000c00b',
        },
      );
      CloudSessionStore.installForTest(store);
      addSession('local-self', title: 'Self chat');
      AppState.I.sessions.add(
        ChatSession(
          id: 'local-a',
          title: 'Trip plan',
          model: 'm',
          mode: 'auto',
        ),
      );

      final refs = ChatScreen.sessionRefsInForTest(
        'compare @[Trip plan] with @[Self chat]',
        'local-self',
      );
      expect(refs, ['0199aaaa-0000-7000-8000-00000000c00a']);
    });

    test('projectRefsIn delegates to the installed port', () {
      ProjectsPort.installForTest(
        _FakeProjects(
          projects: const [ProjectOption(id: 'p1', name: 'Launch')],
        ),
      );
      expect(ChatScreen.projectRefsInForTest('use @project:p1 please'), ['p1']);
      ProjectsPort.installForTest(null);
      expect(
        ChatScreen.projectRefsInForTest('use @project:p1 please'),
        isEmpty,
      );
    });
  });

  group('⋮ menu', () {
    test('Add to Project needs the W1 port; Pin always works locally', () {
      final s = ChatSession(
        id: 's',
        title: 'T',
        model: 'm',
        mode: 'auto',
        messages: [Message(role: 'user', content: 'hi')],
      );
      final without = chatMenuActionsFor(s, 0);
      expect(without, isNot(contains(ChatMenuAction.addToProject)));
      expect(
        without,
        contains(ChatMenuAction.pin),
        reason: 'the local pin store backs Pin even before W1 lands',
      );

      final withProjects = chatMenuActionsFor(s, 0, projectsAvailable: true);
      expect(withProjects, contains(ChatMenuAction.addToProject));
      expect(withProjects, contains(ChatMenuAction.pin));
    });

    testWidgets('Pin Session persists locally and shows in the header', (
      tester,
    ) async {
      addSession('pinnable', title: 'Pinnable');
      await pumpChat(tester);

      expect(find.byKey(const ValueKey('chat-header-pinned')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-header-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-menu-pin')));
      await tester.pumpAndSettle();

      expect(ChatPinsStore.I.isPinned('pinnable'), isTrue);
      expect(find.byKey(const ValueKey('chat-header-pinned')), findsOneWidget);
    });
  });

  group('@ autocomplete', () {
    testWidgets('offers every root chat, projects and active subagents', (
      tester,
    ) async {
      final s = addSession('root', title: 'Current');
      AppState.I.sessions.add(
        ChatSession(id: 'other', title: 'Other chat', model: 'm', mode: 'auto'),
      );
      ProjectsPort.installForTest(
        _FakeProjects(
          projects: const [ProjectOption(id: 'p1', name: 'Project One')],
        ),
      );
      CloudAgentFacade.I.seedRowForTest(
        s.id,
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'dispatch_agent',
          toolTitle: 'Research',
          toolState: 'running',
          toolSessionId: 'child-1',
          content: '',
        ),
      );
      await pumpChat(tester);

      await tester.enterText(find.byKey(const ValueKey('chat-composer')), '@');
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('CHATS'), findsOneWidget);
      expect(find.text('Other chat'), findsOneWidget);
      expect(find.text('PROJECTS'), findsOneWidget);
      expect(find.text('Project One'), findsOneWidget);
      expect(find.text('SUBAGENTS'), findsOneWidget);
      expect(find.text('Research'), findsOneWidget);
    });

    testWidgets('project rows are hidden when the gateway cannot take refs', (
      tester,
    ) async {
      addSession('root', title: 'Current');
      final port = _FakeProjects(
        projects: const [ProjectOption(id: 'p1', name: 'Project One')],
      )..supportsTurnProjectRefs = false;
      ProjectsPort.installForTest(port);
      await pumpChat(tester);

      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        '@proj',
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Project One'), findsNothing);
    });
  });

  group('model lock', () {
    testWidgets('header picker is locked while a run is live', (tester) async {
      final s = addSession('locked', title: 'Locked');
      await pumpChat(tester);
      CloudAgentFacade.I.setActiveRunForTest(s.id, 'run-1');
      await tester.pump();

      final lockedIcon = find.byIcon(Icons.lock_outline);
      expect(lockedIcon, findsOneWidget);
      await tester.tap(lockedIcon);
      await tester.pump();
      // The header tap is a no-op while locked: the picker never opens.
      expect(find.text('Search models or providers'), findsNothing);
      expect(find.text('Search models'), findsNothing);
    });
  });

  group('STUDIO gate', () {
    testWidgets('no binding shows Choose repo and keeps Send disabled', (
      tester,
    ) async {
      addSession('studio', title: 'Studio chat', mode: 'studio');
      await pumpChat(tester);

      expect(find.text('Choose repo'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('chat-composer')),
        'build it',
      );
      await tester.pump();
      // The primary button is disabled (null onPressed) while the gate is
      // closed; the tooltip explains why.
      expect(
        find.byTooltip('Choose a repository and branch in Studio first'),
        findsOneWidget,
      );
    });

    testWidgets('a bound repo + branch renders the chip and opens the gate', (
      tester,
    ) async {
      addSession('studio', title: 'Studio chat', mode: 'studio');
      StudioBindingPort.installForTest(
        _FakeStudio(
          binding: const StudioBinding(repo: 'acme/app', branch: 'main'),
        ),
      );
      await pumpChat(tester);

      expect(find.text('app · main'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('composer-studio-sync')),
        findsOneWidget,
      );
      expect(find.text('Choose repo'), findsNothing);
    });
  });

  group('live subagents', () {
    testWidgets('running child renders the activity strip + trajectory hook', (
      tester,
    ) async {
      final s = addSession('parent', title: 'Parent');
      CloudAgentFacade.I.seedRowForTest(
        s.id,
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'dispatch_agent',
          toolTitle: 'Research',
          toolState: 'running',
          toolSessionId: 'child-1',
          content: '',
        ),
      );
      await pumpChat(tester);

      expect(
        find.byKey(const ValueKey('subagent-activity-dock')),
        findsOneWidget,
      );
      expect(find.textContaining('1 subagent running'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subagent-activity-trajectory-sub-1')),
        findsOneWidget,
      );
    });
  });

  group('voice-first mode', () {
    testWidgets('language sheet offers English/Hindi/Hinglish/Tamil', (
      tester,
    ) async {
      addSession('voice', title: 'Voice');
      await pumpChat(tester);

      await tester.tap(find.byKey(const ValueKey('composer-voice-chip')));
      await tester.pumpAndSettle();
      expect(find.text('Voice-first mode'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('हिन्दी'), findsOneWidget);
      expect(find.text('Hinglish'), findsOneWidget);
      expect(find.text('தமிழ்'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('voice-first-switch')));
      await tester.pump();
      expect(find.text('Voice · English'), findsOneWidget);

      // Hinglish shares hi-IN with Hindi but keeps its own label.
      await tester.tap(find.text('Hinglish'));
      await tester.pump();
      expect(find.text('Voice · Hinglish'), findsOneWidget);
    });

    test('VoiceReplyService routes speak/stop through the seam', () async {
      final spoken = <String>[];
      VoiceReplyService.I.speakOverrideForTest = (text, locale) async {
        spoken.add('$text|$locale');
        return true;
      };
      var stopped = false;
      VoiceReplyService.I.stopOverrideForTest = () => stopped = true;

      expect(
        await VoiceReplyService.I.speak('नमस्ते', localeId: 'hi-IN'),
        isTrue,
      );
      expect(spoken, ['नमस्ते|hi-IN']);
      await VoiceReplyService.I.stop();
      expect(stopped, isTrue);
    });
  });
}
