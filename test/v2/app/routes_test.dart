import 'dart:convert';

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
import 'package:ovid_ai/ui/v2/runs/subagent_summary.dart';
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
    test('a root session maps no workers, so the trajectory is empty', () {
      // The main agent's own messages and tool calls are the chat, not the
      // trajectory. Without a child session there is nothing to show.
      final session = _rootSession();
      session.analytics.add(
        inputTokens: 1200,
        outputTokens: 300,
        llmMs: 2400,
        toolMs: 600,
      );

      final data = V2RunRoutes.trajectoryDataFor(
        session,
        allSessions: [session],
      );

      expect(data.status, V2RunTrajectoryStatus.empty);
      expect(data.subagents, isEmpty);
      expect(data.runLabel, isEmpty);
    });

    test('a root session with a child maps only that worker', () {
      final root = _rootSession();
      final child = _subagentSession();

      final data = V2RunRoutes.trajectoryDataFor(
        root,
        allSessions: [root, child],
      );

      expect(data.status, V2RunTrajectoryStatus.ready);
      expect(data.subagents, hasLength(1));
      expect(data.subagents.single.id, 'sub-1');
      expect(data.subagents.single.agentName, 'Pricing research');
      expect(data.subagents.single.taskSummary, 'Research pricing');
      expect(data.subagents.single.status, V2SubagentLaunchStatus.running);
      // The worker's own recorded tool call is carried, not the parent's.
      expect(data.subagents.single.toolCount, 1);
      // The header must not claim a step count the screen does not show.
      expect(data.runLabel, isEmpty);
    });

    test('child sessions appear as real subagent launches in order', () {
      final root = _rootSession();
      final child = _subagentSession();
      final later = ChatSession(
        id: 'sub-2',
        title: 'Second child',
        model: 'deepseek-chat',
        parentId: root.id,
        agentLabel: 'QA runner',
        agentState: 'failed',
        createdAt: DateTime(2026, 10, 21, 11),
      );

      final data = V2RunRoutes.trajectoryDataFor(
        root,
        allSessions: [later, root, child],
      );

      expect(data.subagents, hasLength(2));
      expect(data.subagents.first.id, 'sub-1');
      expect(data.subagents.first.agentName, 'Pricing research');
      expect(data.subagents.first.status, V2SubagentLaunchStatus.running);
      expect(data.subagents.last.status, V2SubagentLaunchStatus.failed);
    });

    test('a session with no messages is empty', () {
      final session = ChatSession(id: 'blank', title: 'Blank', model: 'm');

      final data = V2RunRoutes.trajectoryDataFor(session);

      expect(data.status, V2RunTrajectoryStatus.empty);
      expect(data.subagents, isEmpty);
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
      expect(data.progressKnown, isFalse);
      expect(data.files, ['notes.md']);
      expect(data.logLines, hasLength(1));
      expect(data.logLines.single.text, 'notes.md');
      expect(data.totalLogLines, 1);
      expect(data.timeLimitLabel, V2RunRoutes.notReported);
      // The typed runtime state and the real clock, not display copy.
      expect(data.reportedStatus, V2SubagentRunStatus.running);
      expect(data.runStatus, V2SubagentRunStatus.running);
      expect(data.createdAt, DateTime(2026, 10, 21, 10));
      expect(data.finishedAt, isNull);
      expect(data.logPath, '/workspace/.ovid/logs/subagent_sub-1.log');
    });

    test('stopped and failed runs carry their typed status and end time', () {
      final stopped = _subagentSession()..agentState = 'stopped';
      final stoppedData = V2RunRoutes.subagentDataFor(stopped);

      expect(stoppedData.reportedStatus, V2SubagentRunStatus.cancelled);
      expect(stoppedData.runStatus, V2SubagentRunStatus.cancelled);
      expect(stoppedData.working, isFalse);
      expect(stoppedData.finishedAt, isNotNull);

      final failed = _subagentSession()..agentState = 'failed';
      final failedData = V2RunRoutes.subagentDataFor(failed);

      expect(failedData.reportedStatus, V2SubagentRunStatus.failed);
      expect(failedData.runStatus, V2SubagentRunStatus.failed);
    });

    test('a run past the 8 hour ceiling reports timed out', () {
      final session = _subagentSession();

      final data = V2RunRoutes.subagentDataFor(
        session,
        now: DateTime(2026, 10, 21, 18, 1),
      );

      expect(data.reportedStatus, V2SubagentRunStatus.timedOut);
      expect(data.runStatus, V2SubagentRunStatus.timedOut);
      expect(data.working, isFalse);
      expect(data.elapsedLabel, '8h 1m');
      expect(data.createdAt, DateTime(2026, 10, 21, 10));
      expect(data.finishedAt, DateTime(2026, 10, 21, 18, 1));
    });

    test('the strict JSON contract is parsed from the final answer', () {
      final session = _subagentSession()
        ..agentState = 'finished'
        ..agentResult = jsonEncode({
          'status': 'completed',
          'files_modified': ['notes.md'],
          'artifacts_created': ['report.pdf'],
          'key_findings': ['Pricing is stable.'],
          'error_if_any': null,
        });

      final data = V2RunRoutes.subagentDataFor(session);

      expect(data.summary, isNotNull);
      expect(data.summary!.status, 'completed');
      expect(data.summary!.filesModified, ['notes.md']);
      expect(data.summary!.artifactsCreated, ['report.pdf']);
      expect(data.summary!.keyFindings, ['Pricing is stable.']);
      expect(data.summary!.hasField('error_if_any'), isTrue);
      expect(data.summary!.hasError, isFalse);
      expect(data.totalLogLines, 1);
    });

    test('absent contract fields stay unreported', () {
      final session = _subagentSession()
        ..agentState = 'finished'
        ..agentResult = jsonEncode({'status': 'completed'});

      final data = V2RunRoutes.subagentDataFor(session);

      expect(data.summary, isNotNull);
      expect(data.summary!.hasField('status'), isTrue);
      expect(data.summary!.hasField('files_modified'), isFalse);
      expect(data.summary!.hasField('error_if_any'), isFalse);
      expect(data.summary!.json, isNot(contains('files_modified')));
    });

    test('a non-JSON final answer is an honest empty summary', () {
      final session = _subagentSession()
        ..agentState = 'finished'
        ..agentResult = 'All done, nothing to report.';

      final data = V2RunRoutes.subagentDataFor(session);

      expect(data.summary, isNull);
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
      // Nobody holds an empty room's turn, so this device can send.
      expect(live.turnHolderName, isEmpty);
      expect(live.isMyTurn, isTrue);
    });

    test(
      'the turn belongs to the last unanswered author, not a placeholder',
      () {
        final state = _collabState(local: 'p2');
        final message = CollaborationEvent.fromWire({
          'schemaVersion': 1,
          'eventId': 'm1',
          'sessionId': 'collab-1',
          'eventSequence': 1,
          'senderParticipantId': 'p1',
          'kind': 'message',
          'createdAt': DateTime.utc(2026, 10, 21, 10).toIso8601String(),
          'payload': MessagePayload('Hello team').toWire(),
        });
        final withMessage = const CollaborationReducer().apply(state, message);

        expect(V2CollabRoutes.turnHolderId(withMessage), 'p1');
        final live = V2CollabRoutes.liveDataFor(withMessage);
        expect(live.turnHolderName, 'Priya Patel');
        expect(live.isMyTurn, isFalse);
        expect(live.capacity, maxActiveMembers);
        expect(live.creatorPaysStorage, isTrue);

        final mine = CollaborationEvent.fromWire({
          'schemaVersion': 1,
          'eventId': 'm2',
          'sessionId': 'collab-1',
          'eventSequence': 2,
          'senderParticipantId': 'p2',
          'kind': 'message',
          'createdAt': DateTime.utc(2026, 10, 21, 10, 1).toIso8601String(),
          'payload': MessagePayload('My turn now').toWire(),
        });
        final mineState = const CollaborationReducer().apply(withMessage, mine);
        expect(V2CollabRoutes.liveDataFor(mineState).isMyTurn, isTrue);
      },
    );

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
      expect(data.members[1].canRemove, isFalse);
      expect(data.members.first.canRemove, isFalse);
      expect(data.creatorName, 'Priya Patel');
      expect(data.hasStorageInfo, isFalse);

      final owner = V2CollabRoutes.membersDataFor(_collabState(local: 'p1'));
      expect(owner.members[1].canRemove, isTrue);
      // The wire model has no viewer role, so the route never invents one.
      expect(
        data.members.map((member) => member.role),
        everyElement(isIn([V2CollabRole.owner, V2CollabRole.canChat])),
      );
    });

    test('a closed room is ended, not an error', () {
      final state = CollaborationState.bootstrap(
        session: const CollaborationSession(
          sessionId: 'collab-1',
          ownerParticipantId: 'p1',
          lifecycle: SessionLifecycle.closed,
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
        localParticipantId: 'p2',
        lastSequence: 0,
      );

      final data = V2CollabRoutes.liveDataFor(state);

      expect(data.status, V2CollabLiveStatus.ended);
      expect(data.endedMessage, 'This live chat has ended.');
      expect(data.isMyTurn, isFalse);
      expect(data.turnStartedAt, isNull);
    });

    test('a removed member sees the honest ended reason', () {
      final state = CollaborationState.bootstrap(
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
        ],
        localParticipantId: 'p2',
        lastSequence: 0,
      );

      final data = V2CollabRoutes.liveDataFor(state);

      expect(state.closeReason, CloseReason.localRemoved);
      expect(data.status, V2CollabLiveStatus.ended);
      expect(data.endedMessage, 'You were removed from this live chat.');
    });

    test('the real socket state reaches the screen', () {
      final state = _collabState();

      expect(
        V2CollabRoutes.liveDataFor(state).connection,
        V2CollabLiveConnection.connected,
      );
      expect(
        V2CollabRoutes.liveDataFor(
          state,
          connection: V2CollabLiveConnection.disconnected,
        ).connection,
        V2CollabLiveConnection.disconnected,
      );
      expect(
        V2CollabRoutes.connectionFor(null),
        V2CollabLiveConnection.connected,
      );
    });

    test('a server turn lease is passed, and no start is ever invented', () {
      final session = CollaborationSession.fromWire({
        'schemaVersion': 1,
        'sessionId': 'collab-1',
        'ownerParticipantId': 'p1',
        'lifecycle': 'active',
        'turn': {
          'participantId': 'p1',
          'startedAt': '2026-10-22T10:00:00.000Z',
          'expiresAt': '2026-10-22T10:01:30.000Z',
        },
      });
      final withTurn = CollaborationState.bootstrap(
        session: session,
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
        localParticipantId: 'p2',
        lastSequence: 0,
      );

      final data = V2CollabRoutes.liveDataFor(withTurn);
      expect(data.turnStartedAt, DateTime.utc(2026, 10, 22, 10));
      expect(data.turnDuration, const Duration(seconds: 90));
      // The server's lease names the holder, so an empty transcript cannot
      // misattribute the running turn to this device.
      expect(data.turnHolderName, 'Priya Patel');
      expect(data.isMyTurn, isFalse);

      // Without a published lease there is no countdown and no made-up start.
      final withoutTurn = V2CollabRoutes.liveDataFor(_collabState());
      expect(withoutTurn.turnStartedAt, isNull);
      expect(withoutTurn.turnTimeLeftLabel, isEmpty);
    });

    test('the route refuses another invite at the 50-member cap', () {
      final members = <Member>[
        const Member(
          participantId: 'p0',
          role: MemberRole.owner,
          status: MemberStatus.active,
        ),
        for (var i = 1; i < maxActiveMembers; i++)
          Member(
            participantId: 'p$i',
            role: MemberRole.participant,
            status: MemberStatus.active,
          ),
      ];
      final full = CollaborationState.bootstrap(
        session: const CollaborationSession(
          sessionId: 'collab-1',
          ownerParticipantId: 'p0',
          lifecycle: SessionLifecycle.active,
        ),
        members: members,
        localParticipantId: 'p0',
        lastSequence: 0,
      );

      expect(full.activeMembers, hasLength(maxActiveMembers));
      expect(V2CollabRoutes.atCapacity(full), isTrue);
      expect(V2CollabRoutes.atCapacity(_collabState()), isFalse);
      expect(V2CollabRoutes.atCapacity(null), isFalse);
      expect(V2CollabRoutes.membersDataFor(full).capacity, maxActiveMembers);
      expect(V2CollabRoutes.membersDataFor(full).roomFull, isTrue);
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
