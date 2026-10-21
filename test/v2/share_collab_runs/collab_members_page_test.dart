import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/collab/collab_members_page.dart';

const _members = [
  V2CollabMember(
    id: 'you',
    name: 'Aarav Sharma',
    subtitle: 'Platform Lead · Current turn',
    role: V2CollabRole.owner,
    isYou: true,
    isCreator: true,
    online: true,
  ),
  V2CollabMember(
    id: 'priya',
    name: 'Priya Patel',
    subtitle: 'Design Systems · In queue (#1)',
    role: V2CollabRole.canChat,
    online: true,
  ),
  V2CollabMember(
    id: 'rahul',
    name: 'Rahul Verma',
    subtitle: 'Backend Engineer · Idle',
    role: V2CollabRole.canChat,
    online: true,
  ),
  V2CollabMember(
    id: 'kenji',
    name: 'Kenji Sato',
    subtitle: 'Observing from Tokyo',
    role: V2CollabRole.viewOnly,
  ),
];

V2CollabMembersPageData _data({
  V2CollabMembersStatus status = V2CollabMembersStatus.ready,
  List<V2CollabMember> members = _members,
  int memberCount = 50,
  int capacity = 50,
}) {
  return V2CollabMembersPageData(
    chatName: 'Team chat',
    members: members,
    memberCount: memberCount,
    capacity: capacity,
    creatorName: 'Aarav Sharma',
    storageUsedLabel: '12.4 GB',
    storageTotalLabel: '15 GB',
    storageFreeLabel: '2.6 GB',
    storagePercent: 0.82,
    status: status,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(MaterialApp(theme: theme, home: child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  testWidgets('renders the roster and roles in light and dark', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, CollabMembersPage(data: _data()), theme);

      expect(find.text('50 of 50 members'), findsOneWidget);
      expect(find.text('Members'), findsWidgets);
      expect(find.text('Team chat'), findsOneWidget);
      expect(find.text('Search members'), findsOneWidget);
      expect(find.text('Aarav Sharma'), findsOneWidget);
      expect(find.text('(you)'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Creator'), findsOneWidget);
      expect(find.text('Can chat'), findsNWidgets(2));
      expect(find.text('View only'), findsOneWidget);
      expect(find.text('The creator pays for storage'), findsOneWidget);
      expect(find.text('Leave chat'), findsOneWidget);
    }
  });

  testWidgets('empty state invites someone', (tester) async {
    var invites = 0;
    await _pump(
      tester,
      CollabMembersPage(
        data: _data(
          status: V2CollabMembersStatus.empty,
          members: const [],
          memberCount: 0,
        ),
        onInvite: () => invites++,
      ),
      OTheme.light(),
    );

    expect(find.text('No members yet'), findsOneWidget);
    await tester.tap(find.text('Invite someone'));
    await tester.pump();
    expect(invites, 1);
  });

  testWidgets('error state retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      CollabMembersPage(
        data: _data(status: V2CollabMembersStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load the member list.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('an empty ready roster invites and shows no storage numbers', (
    tester,
  ) async {
    await _pump(
      tester,
      const CollabMembersPage(
        data: V2CollabMembersPageData(memberCount: 0, capacity: 50),
      ),
      OTheme.light(),
    );

    expect(find.text('No members yet'), findsOneWidget);
    expect(find.text('No members found'), findsNothing);
    expect(find.text('The creator pays for storage'), findsOneWidget);
    expect(find.textContaining('used'), findsNothing);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('leave chat callback fires', (tester) async {
    var left = 0;
    await _pump(
      tester,
      CollabMembersPage(data: _data(), onLeave: () => left++),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Leave chat'));
    await tester.pump();
    await tester.tap(find.text('Leave chat'));
    await tester.pump();
    expect(left, 1);
  });

  testWidgets('fits a 320 dp phone at 200 % text', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pumpNarrow(tester, CollabMembersPage(data: _data()));

    expect(tester.takeException(), isNull);
    expect(find.text('Leave chat'), findsOneWidget);

    // The no-results state has to fit the same narrow, large-text viewport.
    await tester.enterText(find.byType(TextField), 'Nobody');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('No members found'), findsOneWidget);
  });

  testWidgets('reduced motion still shows the roster', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: CollabMembersPage(data: _data()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Aarav Sharma'), findsOneWidget);
    expect(find.text('Leave chat'), findsOneWidget);
  });

  testWidgets('search filters the roster and the member menu fires', (
    tester,
  ) async {
    V2CollabMember? menuMember;
    await _pump(
      tester,
      CollabMembersPage(
        data: _data(),
        onMemberMenu: (member) => menuMember = member,
      ),
      OTheme.light(),
    );

    await tester.enterText(find.byType(TextField), 'Priya');
    await tester.pump();

    expect(find.text('Priya Patel'), findsOneWidget);
    expect(find.text('Rahul Verma'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pump();
    expect(menuMember?.id, 'priya');
  });

  testWidgets('capacity defaults to the 50 person cap and shows seats left', (
    tester,
  ) async {
    expect(const V2CollabMembersPageData(memberCount: 0).capacity, 50);

    await _pump(
      tester,
      CollabMembersPage(data: _data(memberCount: 12)),
      OTheme.light(),
    );

    expect(find.text('12 of 50 members'), findsOneWidget);
    expect(find.text('38 seats left'), findsOneWidget);
    expect(
      find.text('Up to 50 people can join, including the creator.'),
      findsOneWidget,
    );
    expect(find.text('Room full'), findsNothing);
  });

  testWidgets('the creator badge and storage are attributed to the creator', (
    tester,
  ) async {
    await _pump(tester, CollabMembersPage(data: _data()), OTheme.dark());

    expect(find.text('Creator'), findsOneWidget);
    expect(
      find.text(
        'Aarav Sharma pays for this chat. Storage is billed to the '
        "creator's plan.",
      ),
      findsOneWidget,
    );
    expect(find.text('12.4 GB of 15 GB used'), findsOneWidget);
  });
}

Future<void> _pumpNarrow(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 720),
          textScaler: TextScaler.linear(2),
        ),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}
