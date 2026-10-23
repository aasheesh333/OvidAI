import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/collab/collab_live_page.dart';
import 'package:ovid_ai/ui/v2/collab/collab_members_page.dart';
import 'package:ovid_ai/ui/v2/runs/run_trajectory_page.dart';
import 'package:ovid_ai/ui/v2/runs/subagent_page.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

/// Exactly 600 dp: the width where a phone layout becomes a tablet one.
///
/// Nothing may stretch past its band cap, nothing may overflow, and a sheet
/// stays centred at its own width.

const _messages = [
  V2CollabMessage(
    id: 'm1',
    speakerName: 'Priya Patel',
    timeLabel: '11:02 AM',
    text: 'I updated the auth endpoints.',
  ),
  V2CollabMessage(
    id: 'm2',
    speakerName: 'Rahul Verma',
    timeLabel: '11:03 AM',
    text: 'Running the curl check now.',
  ),
];

const _members = [
  V2CollabMember(
    id: 'm1',
    name: 'Aarav Sharma',
    role: V2CollabRole.owner,
    isYou: true,
    isCreator: true,
  ),
  V2CollabMember(
    id: 'm2',
    name: 'Priya Patel',
    role: V2CollabRole.canChat,
    canRemove: true,
  ),
];

const _workers = [
  V2SubagentLaunch(
    id: 'w1',
    agentName: 'Explorer',
    taskSummary: 'Find every caller.',
    timeLabel: '10:43',
    durationLabel: '2m 10s',
  ),
  V2SubagentLaunch(
    id: 'w2',
    agentName: 'QA runner',
    taskSummary: 'Run the regression suite.',
    timeLabel: '10:45',
    durationLabel: '54.2s',
  ),
];

void main() {
  testWidgets('the share sheet keeps its 560 dp width at 600 dp', (
    tester,
  ) async {
    await pumpAt600(
      tester,
      ShareSheet(
        data: const V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
        ),
        onCopyLink: () {},
        onStopSharing: () {},
        onClose: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    final sheet = find.byType(SingleChildScrollView);
    expect(widthOf(tester, sheet), 560);
    expect(tester.getTopLeft(sheet).dx, closeTo((600 - 560) / 2, 0.5));
  });

  testWidgets('the collab transcript fills 600 dp without exceeding 720', (
    tester,
  ) async {
    await pumpAt600(
      tester,
      CollabLivePage(
        data: const V2CollabLivePageData(
          totalMembers: 3,
          turnHolderName: 'Rahul Verma',
          turnTimeLeftLabel: '24s left',
          messages: _messages,
          creatorPaysStorage: true,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final transcript = find.byType(ListView);
    expect(widthOf(tester, transcript), 600);
    expect(tester.getTopLeft(transcript).dx, 0);
  });

  testWidgets('the members roster fills 600 dp without exceeding 640', (
    tester,
  ) async {
    await pumpAt600(
      tester,
      CollabMembersPage(
        data: const V2CollabMembersPageData(members: _members, memberCount: 2),
        onInvite: () {},
        onMemberMenu: (_) {},
        onLeave: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    final roster = find.byType(ListView);
    expect(widthOf(tester, roster), 600);
    expect(tester.getTopLeft(roster).dx, 0);
  });

  testWidgets('the run trajectory fills 600 dp without exceeding 720', (
    tester,
  ) async {
    await pumpAt600(
      tester,
      RunTrajectoryPage(
        data: const V2RunTrajectoryPageData(
          title: 'Landing page',
          runLabel: 'Run 18',
          subagents: _workers,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final steps = find.byType(ListView);
    expect(widthOf(tester, steps), 600);
    expect(tester.getTopLeft(steps).dx, 0);
  });

  testWidgets('the subagent run fills 600 dp without exceeding 720', (
    tester,
  ) async {
    await pumpAt600(
      tester,
      SubagentPage(
        data: const V2SubagentPageData(
          name: 'Frontend builder',
          instanceLabel: 'subagent_a402',
          stepLabel: 'Step 4 of 7',
          goal: 'Rebuild the landing page.',
          startedLabel: '10:41',
          elapsedLabel: '6m',
          timeLimitLabel: '8h max',
          remainingLabel: '7h 54m left',
          totalLogLines: 42,
          logPath: '/workspace/.ovid/logs/subagent_a402.log',
        ),
        onViewLog: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    final body = find.byType(ListView);
    expect(widthOf(tester, body), 600);
    expect(tester.getTopLeft(body).dx, 0);
  });
}
