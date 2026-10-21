import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/collaboration/models.dart';
import 'package:ovid_ai/core/collaboration/reducer.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_collab_routes.dart';
import 'package:ovid_ai/ui/v2/app/v2_run_routes.dart';
import 'package:ovid_ai/ui/v2/app/v2_studio_routes.dart';
import 'package:ovid_ai/ui/v2/collab/collab_live_page.dart';
import 'package:ovid_ai/ui/v2/collab/collab_members_page.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';
import 'package:ovid_ai/ui/v2/studio/branch_picker_sheet.dart';
import 'package:ovid_ai/ui/v2/studio/changes_page.dart';
import 'package:ovid_ai/ui/v2/studio/live_preview_page.dart';
import 'package:ovid_ai/ui/v2/studio/studio_workspace_page.dart';

class _FakeStudio extends StudioBindingPort {
  @override
  bool ready = true;

  @override
  StudioBinding? bindingFor(String sessionId) => null;

  @override
  Future<List<String>> listRepos() async => const ['acme/app'];

  @override
  Future<List<String>> listBranches(String repo) async => const ['main', 'dev'];

  @override
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  }) async {}

  @override
  Future<void> syncLatest(String sessionId) async {}
}

ChatSession _rootSession() {
  final session = ChatSession(
    id: 'root',
    title: 'Build landing page',
    model: 'deepseek-chat',
    createdAt: DateTime(2026, 10, 20, 10),
  );
  session.messages.addAll([
    Message(
      role: 'user',
      content: 'Build a landing page',
      time: DateTime(2026, 10, 20, 10),
    ),
    Message(
      role: 'assistant',
      content: 'The page is ready.',
      elapsedMs: 1200,
      time: DateTime(2026, 10, 20, 10, 0, 2),
    ),
    Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: 'fs_edit',
      toolTitle: 'Edit lib/app.dart',
      toolSummary: '+12 −3',
      toolState: 'ok',
      toolInput: '{"path":"lib/app.dart"}',
      time: DateTime(2026, 10, 20, 10, 0, 3),
    ),
  ]);
  return session;
}

ChatSession _subagentSession() {
  final session = ChatSession(
    id: 'sub-1',
    title: 'Research pricing',
    model: 'deepseek-chat',
    parentId: 'root',
    agentLabel: 'Pricing research',
    agentState: 'running',
    createdAt: DateTime(2026, 10, 21, 10),
  );
  session.messages.add(
    Message(
      role: 'assistant',
      kind: MsgKind.tool,
      toolName: 'fs_write',
      toolTitle: 'Write notes.md',
      toolSummary: 'notes.md',
      toolState: 'ok',
      toolInput: '{"path":"notes.md"}',
      time: DateTime(2026, 10, 21, 10, 2),
    ),
  );
  return session;
}

CollaborationState _collabState({String local = 'p2'}) {
  return CollaborationState.bootstrap(
    session: const CollaborationSession(
      sessionId: 'collab-1',
      ownerParticipantId: 'p1',
      lifecycle: SessionLifecycle.active,
    ),
    members: const [
      Member(
        participantId: 'p1',
        role: MemberRole.owner,
        status: MemberStatus.active,
        displayName: 'Priya Patel',
      ),
      Member(
        participantId: 'p2',
        role: MemberRole.participant,
        status: MemberStatus.active,
        displayName: 'Rahul Verma',
      ),
    ],
    localParticipantId: local,
    lastSequence: 0,
  );
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    AppState.resetTestInstance();
    AppState.createForTest();
    StudioBindingPort.installForTest(null);
  });

  tearDown(() {
    StudioBindingPort.installForTest(null);
    AppState.resetTestInstance();
  });

  group('run trajectory mapping', () {
    test('a root session maps its own steps, tokens and duration', () {
      final session = _rootSession();
      session.analytics.add(
        inputTokens: 1200,
        outputTokens: 300,
        llmMs: 2400,
        toolMs: 600,
      );

      final data = V2RunRoutes.trajectoryDataFor(session);

      expect(data.status, V2RunTrajectoryStatus.ready);
      expect(data.title, 'Build landing page');
      expect(data.prompt, 'Build a landing page');
      expect(data.model, 'deepseek-chat');
      expect(data.steps, hasLength(3));
      expect(data.steps.first.title, 'You');
      expect(data.steps.first.kind, V2RunStepKind.message);
      expect(data.steps[1].durationLabel, '1s');
      expect(data.steps[2].title, 'Edit lib/app.dart');
      expect(data.steps[2].kind, V2RunStepKind.write);
      expect(data.steps[2].fileName, 'lib/app.dart');
      expect(data.tokensLabel, '1.5K tokens');
      expect(data.durationLabel, '3s');
    });

    test('a session without analytics reports nothing instead of numbers', () {
      final session = _rootSession();

      final data = V2RunRoutes.trajectoryDataFor(session);

      expect(data.tokensLabel, V2RunRoutes.notReported);
      expect(data.durationLabel, V2RunRoutes.notReported);
    });

    test('a session with no messages is empty', () {
      final session = ChatSession(id: 'blank', title: 'Blank', model: 'm');

      final data = V2RunRoutes.trajectoryDataFor(session);

      expect(data.status, V2RunTrajectoryStatus.empty);
      expect(data.steps, isEmpty);
    });

    test('a missing session is an error', () {
      final data = V2RunRoutes.trajectoryDataFor(null);

      expect(data.status, V2RunTrajectoryStatus.error);
      expect(data.errorMessage, isNotEmpty);
    });

    test('a subagent maps its label, state, files and log', () {
      final data = V2RunRoutes.subagentDataFor(
        _subagentSession(),
        now: DateTime(2026, 10, 21, 10, 5),
      );

      expect(data.status, V2SubagentStatus.ready);
      expect(data.name, 'Pricing research');
      expect(data.goal, 'Research pricing');
      expect(data.working, isTrue);
      expect(data.stepLabel, 'Working');
      expect(data.elapsedLabel, '5m');
      expect(data.progress, 0);
      expect(data.files, ['notes.md']);
      expect(data.logLines, hasLength(1));
      expect(data.logLines.single.text, 'notes.md');
      expect(data.totalLogLines, 1);
      expect(data.timeLimitLabel, V2RunRoutes.notReported);
    });

    test('a root chat is not a subagent', () {
      final data = V2RunRoutes.subagentDataFor(_rootSession());

      expect(data.status, V2SubagentStatus.empty);
      expect(data.logLines, isEmpty);
    });

    test('a missing subagent is an error', () {
      final data = V2RunRoutes.subagentDataFor(null);

      expect(data.status, V2SubagentStatus.error);
    });
  });

  group('collaboration mapping', () {
    test('no live session opens the empty state with no members', () {
      final live = V2CollabRoutes.liveDataFor(null);
      final members = V2CollabRoutes.membersDataFor(null);

      expect(live.status, V2CollabLiveStatus.empty);
      expect(live.totalMembers, 0);
      expect(live.messages, isEmpty);
      expect(members.status, V2CollabMembersStatus.empty);
      expect(members.memberCount, 0);
      expect(members.capacity, maxActiveMembers);
    });

    test('a live session maps its real members and no fake count', () {
      final state = _collabState();

      final live = V2CollabRoutes.liveDataFor(state);

      expect(live.status, V2CollabLiveStatus.ready);
      expect(live.totalMembers, 2);
      expect(live.participants, hasLength(2));
      expect(live.selfName, 'Rahul Verma');
      expect(live.messages, isEmpty);
    });

    test('the roster maps roles, identity and capacity', () {
      final state = _collabState();

      final data = V2CollabRoutes.membersDataFor(state);

      expect(data.status, V2CollabMembersStatus.ready);
      expect(data.memberCount, 2);
      expect(data.capacity, maxActiveMembers);
      expect(data.members, hasLength(2));
      expect(data.members.first.role, V2CollabRole.owner);
      expect(data.members.first.name, 'Priya Patel');
      expect(data.members[1].isYou, isTrue);
      expect(data.creatorName, 'Priya Patel');
      expect(data.hasStorageInfo, isFalse);
    });
  });

  group('studio mapping', () {
    test('a workspace is empty without an installed port', () {
      final data = V2StudioRoutes.workspaceDataFor(
        repo: 'acme/app',
        branch: 'dev',
        portReady: false,
      );

      expect(data.status, V2WorkspaceStatus.empty);
      expect(data.branch, isEmpty);
    });

    test('a workspace shows the bound repo and branch with a port', () {
      final data = V2StudioRoutes.workspaceDataFor(
        repo: 'acme/app',
        branch: 'dev',
        portReady: true,
      );

      expect(data.status, V2WorkspaceStatus.content);
      expect(data.repoName, 'acme/app');
      expect(data.branch, 'dev');
    });

    test('branches come from the port, never invented', () {
      final empty = V2StudioRoutes.branchPickerDataFor(
        currentBranch: 'dev',
        branches: const [],
        portReady: false,
      );
      expect(empty.status, V2BranchPickerStatus.empty);

      final data = V2StudioRoutes.branchPickerDataFor(
        currentBranch: 'dev',
        branches: const ['main', 'dev'],
        portReady: true,
      );
      expect(data.status, V2BranchPickerStatus.content);
      expect(data.current?.name, 'dev');
      expect(data.branches.map((b) => b.name).toList(), ['main', 'dev']);
      expect(
        data.branches.firstWhere((b) => b.name == 'dev').isCurrent,
        isTrue,
      );

      final failed = V2StudioRoutes.branchPickerDataFor(
        currentBranch: 'dev',
        branches: const [],
        portReady: true,
        failed: true,
      );
      expect(failed.status, V2BranchPickerStatus.error);
    });

    test('changes stay empty and only carry the bound branch label', () {
      final ready = V2StudioRoutes.changesDataFor(
        branch: 'dev',
        portReady: true,
      );
      expect(ready.status, V2ChangesStatus.empty);
      expect(ready.branchLabel, 'dev');
      expect(ready.files, isEmpty);

      final noPort = V2StudioRoutes.changesDataFor(
        branch: 'dev',
        portReady: false,
      );
      expect(noPort.branchLabel, isNull);
    });

    test('the live preview opens in its start state', () {
      final data = V2StudioRoutes.livePreviewDataFor(
        repo: 'acme/app',
        portReady: true,
      );

      expect(data.status, V2PreviewStatus.empty);
      expect(data.url, isEmpty);
      expect(data.siteName, 'acme/app');
    });
  });

  group('route builders', () {
    testWidgets('every builder opens its screen without throwing', (
      tester,
    ) async {
      final root = _rootSession();
      final child = _subagentSession();
      AppState.I.sessions.addAll([root, child]);

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const Scaffold(body: Center(child: Text('home'))),
        ),
      );
      final context = tester.element(find.text('home'));

      Future<void> openAndClose(
        Future<void> Function() open,
        String marker,
      ) async {
        // The builder's future resolves only when the route pops, so start it
        // without awaiting and settle the transition separately.
        final opened = open();
        await _settle(tester);
        expect(find.text(marker), findsOneWidget);
        Navigator.of(context).pop();
        await _settle(tester);
        await opened;
      }

      await openAndClose(
        () => V2RunRoutes.openTrajectory(context, root.id),
        'Run trajectory',
      );
      await openAndClose(
        () => V2RunRoutes.openSubagent(context, child.id),
        'Subagent',
      );
      await openAndClose(
        () => V2CollabRoutes.openLive(context, 'missing'),
        'Team chat',
      );
      await openAndClose(
        () => V2CollabRoutes.openMembers(context, 'missing'),
        'Members',
      );
      await openAndClose(
        () => V2StudioRoutes.openWorkspace(context, 'acme/app', 'main'),
        'Studio',
      );
      await openAndClose(
        () => V2StudioRoutes.openBranchPicker(
          context,
          'acme/app',
          'main',
          (_) {},
        ),
        'Switch branch',
      );
      await openAndClose(
        () => V2StudioRoutes.openChanges(context, 'acme/app', 'main'),
        'Changes',
      );
      await openAndClose(
        () => V2StudioRoutes.openLivePreview(context, 'acme/app', 'main'),
        'Live preview',
      );
    });

    testWidgets('the branch picker lists real port branches', (tester) async {
      StudioBindingPort.installForTest(_FakeStudio());
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: const Scaffold(body: Center(child: Text('home'))),
        ),
      );
      final context = tester.element(find.text('home'));

      String? selected;
      final opened = V2StudioRoutes.openBranchPicker(
        context,
        'acme/app',
        'main',
        (branch) => selected = branch,
      );
      await _settle(tester);

      expect(find.text('dev'), findsOneWidget);
      await tester.tap(find.text('dev'));
      await _settle(tester);

      expect(selected, 'dev');
      await opened;
    });
  });
}
