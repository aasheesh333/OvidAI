import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/collab/collab_members_page.dart';

import '_harness.dart';

const _members = [
  V2CollabMember(
    id: 'm1',
    name: 'Aarav Sharma',
    role: V2CollabRole.owner,
    isYou: true,
    isCreator: true,
    online: true,
  ),
  V2CollabMember(
    id: 'm2',
    name: 'Priya Patel',
    role: V2CollabRole.canChat,
    canRemove: true,
  ),
  V2CollabMember(
    id: 'm3',
    name: 'Elena Chen',
    role: V2CollabRole.viewOnly,
  ),
];

V2CollabMembersPageData _data({
  V2CollabMembersStatus status = V2CollabMembersStatus.ready,
  List<V2CollabMember> members = _members,
  int memberCount = 3,
}) {
  return V2CollabMembersPageData(
    members: members,
    memberCount: memberCount,
    creatorName: 'Aarav Sharma',
    storageUsedLabel: '12.4 GB',
    storageTotalLabel: '15 GB',
    storageFreeLabel: '2.6 GB',
    storagePercent: 0.83,
    status: status,
  );
}

void main() {
  testWidgets('renders one roster with role and remove', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        CollabMembersPage(
          data: _data(),
          onInvite: () {},
          onMemberMenu: (_) {},
          onLeave: () {},
        ),
        dark: dark,
      );

      expect(find.text('Members'), findsOneWidget);
      expect(find.text('3 of 50 members'), findsOneWidget);
      expect(find.text('Aarav Sharma'), findsOneWidget);
      expect(find.text('Priya Patel'), findsOneWidget);
      expect(find.text('Elena Chen'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Can chat'), findsOneWidget);
      expect(find.text('View only'), findsOneWidget);
      expect(find.text('Creator'), findsOneWidget);
      expect(find.text('(you)'), findsOneWidget);
      expect(find.bySemanticsLabel('Remove Priya Patel'), findsOneWidget);

      // Search, storage and presence paragraphs are gone.
      expect(find.text('Search members'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('pays for storage'), findsNothing);
      expect(find.textContaining('used'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('can join'), findsNothing);
      expect(find.textContaining('one person can send'), findsNothing);
    }
  });

  testWidgets('only removable members get a remove control', (tester) async {
    V2CollabMember? removed;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onMemberMenu: (member) => removed = member,
      ),
    );

    expect(find.bySemanticsLabel('Remove Aarav Sharma'), findsNothing);
    expect(find.bySemanticsLabel('Remove Elena Chen'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Remove Priya Patel'));
    await tester.pump();
    expect(removed?.id, 'm2');
  });

  testWidgets('invite and leave reach the host', (tester) async {
    var invites = 0;
    var leaves = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onInvite: () => invites++,
        onLeave: () => leaves++,
      ),
    );

    await tester.tap(find.bySemanticsLabel('Invite someone'));
    await tester.pump();
    expect(invites, 1);

    await tester.ensureVisible(find.text('Leave chat'));
    await tester.pump();
    await tester.tap(find.text('Leave chat'));
    await tester.pump();
    expect(leaves, 1);
  });

  testWidgets('empty, error and loading states are wired', (tester) async {
    var invites = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: const [], memberCount: 0),
        onInvite: () => invites++,
      ),
    );
    expect(find.text('No members yet'), findsOneWidget);
    await tester.tap(find.text('Invite someone'));
    await tester.pump();
    expect(invites, 1);

    var retries = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(status: V2CollabMembersStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load the member list.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      CollabMembersPage(data: _data(status: V2CollabMembersStatus.loading)),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabMembersPage(
          data: _data(),
          onInvite: () {},
          onMemberMenu: (_) {},
          onLeave: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Members'), findsOneWidget);
    }
  });

  testWidgets('caps and centres the roster at 640 dp', (tester) async {
    await pumpTablet(
      tester,
      CollabMembersPage(data: _data(), onLeave: () {}),
    );

    final roster = find.byType(ListView);
    expect(widthOf(tester, roster), 640);
    expect(tester.getTopLeft(roster).dx, closeTo((900 - 640) / 2, 0.5));
  });
}
