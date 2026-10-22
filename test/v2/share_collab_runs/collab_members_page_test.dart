import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
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
  int? memberCount,
  int capacity = 50,
}) {
  return V2CollabMembersPageData(
    members: members,
    memberCount: memberCount ?? members.length,
    capacity: capacity,
    creatorName: 'Aarav Sharma',
    storageUsedLabel: '12.4 GB',
    storageTotalLabel: '15 GB',
    storageFreeLabel: '2.6 GB',
    storagePercent: 0.83,
    status: status,
  );
}

String _rowLabel(V2CollabMember member) => [
  member.name,
  member.role.label,
  if (member.isYou) 'you',
  if (member.isCreator) 'creator',
].join(', ');

void _mockClipboard(List<Map<String, Object?>> writes) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      writes.add((call.arguments as Map).cast<String, Object?>());
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

Finder _dialogAction(String label) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.text(label),
);

void main() {
  testWidgets('renders one roster with names, roles and identity', (
    tester,
  ) async {
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
      expect(find.text('3 of 50'), findsOneWidget);
      expect(find.text('Aarav Sharma'), findsOneWidget);
      expect(find.text('Priya Patel'), findsOneWidget);
      expect(find.text('Elena Chen'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('Editor'), findsOneWidget);
      expect(find.text('Viewer'), findsOneWidget);
      expect(find.text('Can chat'), findsNothing);
      expect(find.text('Creator'), findsOneWidget);
      expect(find.text('(you)'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Remove Priya Patel, destructive'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Leave chat, destructive'),
        findsOneWidget,
      );

      // Each row announces its name, role and whether it is you.
      expect(
        find.bySemanticsLabel(_rowLabel(_members[0])),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(_rowLabel(_members[1])),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(_rowLabel(_members[2])),
        findsOneWidget,
      );

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

  testWidgets('only removable members get a destructive remove control', (
    tester,
  ) async {
    V2CollabMember? removed;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onMemberMenu: (member) => removed = member,
      ),
    );

    expect(
      find.bySemanticsLabel('Remove Aarav Sharma, destructive'),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel('Remove Elena Chen, destructive'),
      findsNothing,
    );

    await tester.tap(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
    );
    await tester.pump();
    expect(removed?.id, 'm2');
  });

  testWidgets('the invite action is disabled at the 50 member cap', (
    tester,
  ) async {
    final members = [
      for (var i = 0; i < 50; i++)
        V2CollabMember(
          id: 'm$i',
          name: 'Member $i',
          role: i == 0 ? V2CollabRole.owner : V2CollabRole.canChat,
          isYou: i == 0,
          isCreator: i == 0,
          canRemove: i > 0,
        ),
    ];
    var invites = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: members, memberCount: 50),
        onInvite: () => invites++,
      ),
    );

    expect(find.text('Room is full (50 of 50).'), findsOneWidget);
    final invite = find.bySemanticsLabel(
      'Invite someone, Room is full (50 of 50).',
    );
    expect(invite, findsOneWidget);
    expect(
      tester.getSemantics(invite).flagsCollection.isEnabled,
      Tristate.isFalse,
    );

    await tester.tap(invite);
    await tester.pumpAndSettle();
    expect(invites, 0);

    // One seat left is not full: the same control is enabled.
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: members.take(49).toList(), memberCount: 49),
        onInvite: () => invites++,
      ),
    );
    expect(find.text('49 of 50'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Invite someone'));
    await tester.pumpAndSettle();
    expect(invites, 1);
  });

  testWidgets('a page-owned invite copies the real link and never races it', (
    tester,
  ) async {
    final clipboardWrites = <Map<String, Object?>>[];
    _mockClipboard(clipboardWrites);
    final invite = Completer<String?>();
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onCreateInviteLink: () => invite.future,
      ),
    );

    await tester.tap(find.bySemanticsLabel('Invite someone'));
    await tester.pump();

    // In flight: no link exists yet, so no success is claimed.
    expect(find.bySemanticsLabel('Creating invite link'), findsOneWidget);
    expect(find.text('Invite link copied.'), findsNothing);
    expect(clipboardWrites, isEmpty);

    const link = 'https://ovidsi.com/s/tok/invite-code';
    invite.complete(link);
    await tester.pumpAndSettle();

    expect(clipboardWrites.single['text'], link);
    expect(find.text('Invite link copied.'), findsOneWidget);
  });

  testWidgets('a failed invite reports failure and copies nothing', (
    tester,
  ) async {
    final clipboardWrites = <Map<String, Object?>>[];
    _mockClipboard(clipboardWrites);
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onCreateInviteLink: () async => throw StateError('offline'),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Invite someone'));
    await tester.pumpAndSettle();

    expect(find.text('We could not create an invite link.'), findsOneWidget);
    expect(find.text('Invite link copied.'), findsNothing);
    expect(clipboardWrites, isEmpty);
  });

  testWidgets('host-owned invite and leave actions still reach the host', (
    tester,
  ) async {
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
    await tester.pumpAndSettle();
    expect(invites, 1);

    await tester.ensureVisible(find.text('Leave chat'));
    await tester.pump();
    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();
    expect(leaves, 1);
  });

  testWidgets('roles are visible and only the owner may change them', (
    tester,
  ) async {
    final changes = <(String, V2CollabRole)>[];
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(
          members: [
            _members[0],
            _members[1],
            const V2CollabMember(
              id: 'm4',
              name: 'Owner Two',
              role: V2CollabRole.owner,
              canRemove: true,
            ),
          ],
        ),
        onRoleChanged: (member, role) => changes.add((member.id, role)),
        onMemberMenu: (_) {},
      ),
    );

    expect(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Editor',
      ),
      findsOneWidget,
    );
    // The owner's own row is never demotable, and a second owner row is not
    // removable even when a host marks it so.
    expect(
      find.bySemanticsLabel(RegExp('Change role for Aarav Sharma')),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel(RegExp('Change role for Owner Two')),
      findsNothing,
    );
    expect(
      find.bySemanticsLabel('Remove Owner Two, destructive'),
      findsNothing,
    );

    await tester.tap(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Editor',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Change role'), findsOneWidget);
    expect(find.text('Can send messages'), findsOneWidget);
    expect(find.text('Can read only'), findsOneWidget);

    await tester.tap(find.widgetWithText(OListRow, 'Viewer'));
    await tester.pumpAndSettle();
    expect(changes, [('m2', V2CollabRole.viewOnly)]);
    expect(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Viewer',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a role change is optimistic and rolls back on failure', (
    tester,
  ) async {
    final change = Completer<void>();
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onRoleChanged: (_, _) => change.future,
      ),
    );

    await tester.tap(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Editor',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OListRow, 'Viewer'));
    // Wait out the sheet dismissal without settling: the in-flight spinner is
    // deliberately animating until the handler resolves.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // The row updates immediately, and the control says it is updating.
    expect(
      find.bySemanticsLabel(RegExp('^Priya Patel, Viewer')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Updating role for Priya Patel, currently Viewer',
      ),
      findsOneWidget,
    );

    change.completeError(StateError('not allowed'));
    await tester.pumpAndSettle();

    // Failure rolls the row back rather than leaving a role the service
    // rejected on screen.
    expect(
      find.bySemanticsLabel('Priya Patel, Editor'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Editor',
      ),
      findsOneWidget,
    );
    expect(find.text('We could not change this role.'), findsOneWidget);
  });

  testWidgets('removing names the person, confirms and reports the outcome', (
    tester,
  ) async {
    final removed = Completer<void>();
    V2CollabMember? target;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onRemove: (member) {
          target = member;
          return removed.future;
        },
      ),
    );

    await tester.tap(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove Priya Patel?'), findsOneWidget);
    expect(find.text('They lose access to this chat.'), findsOneWidget);

    await tester.tap(_dialogAction('Cancel'));
    await tester.pumpAndSettle();
    expect(target, isNull);

    await tester.tap(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
    );
    await tester.pumpAndSettle();
    await tester.tap(_dialogAction('Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(target?.id, 'm2');
    expect(find.bySemanticsLabel('Removing Priya Patel'), findsOneWidget);
    expect(find.text('Priya Patel was removed.'), findsNothing);

    removed.complete();
    await tester.pumpAndSettle();
    expect(find.text('Priya Patel was removed.'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Removing Priya')), findsNothing);
  });

  testWidgets('a failed removal says so and leaves the row in place', (
    tester,
  ) async {
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onRemove: (_) async => throw StateError('server said no'),
      ),
    );

    await tester.tap(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
    );
    await tester.pumpAndSettle();
    await tester.tap(_dialogAction('Remove'));
    await tester.pumpAndSettle();

    expect(find.text('We could not remove Priya Patel.'), findsOneWidget);
    expect(find.text('Priya Patel'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
      findsOneWidget,
    );
  });

  testWidgets('leaving confirms and tells the owner the chat is archived', (
    tester,
  ) async {
    var leaves = 0;
    final leave = Completer<void>();
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onLeaveChat: () {
          leaves++;
          return leave.future;
        },
      ),
    );

    await tester.ensureVisible(find.text('Leave chat'));
    await tester.pump();
    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();

    expect(find.text('End this chat?'), findsOneWidget);
    expect(
      find.text('The chat is archived. The link stops working.'),
      findsOneWidget,
    );

    await tester.tap(_dialogAction('Cancel'));
    await tester.pumpAndSettle();
    expect(leaves, 0);

    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogAction('End chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(leaves, 1);
    expect(find.text('Chat ended.'), findsNothing);
    leave.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a member who leaves is told how to rejoin', (tester) async {
    final members = [
      const V2CollabMember(
        id: 'm1',
        name: 'Aarav Sharma',
        role: V2CollabRole.owner,
        isCreator: true,
      ),
      const V2CollabMember(
        id: 'm2',
        name: 'Priya Patel',
        role: V2CollabRole.canChat,
        isYou: true,
      ),
    ];
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: members),
        onLeaveChat: () {},
      ),
    );

    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();
    expect(find.text('Leave this chat?'), findsOneWidget);
    expect(
      find.text('You can rejoin with a valid link.'),
      findsOneWidget,
    );
  });

  testWidgets('leave failure reports the real outcome', (tester) async {
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onLeaveChat: () async => throw StateError('offline'),
      ),
    );

    await tester.ensureVisible(find.text('Leave chat'));
    await tester.pump();
    await tester.tap(find.text('Leave chat'));
    await tester.pumpAndSettle();
    await tester.tap(_dialogAction('End chat'));
    await tester.pumpAndSettle();

    expect(find.text('We could not leave this chat.'), findsOneWidget);
  });

  testWidgets('empty is only you, error retries and loading is a skeleton', (
    tester,
  ) async {
    var invites = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: [_members[0]], memberCount: 1),
        onInvite: () => invites++,
      ),
    );
    expect(find.text('Only you'), findsOneWidget);
    expect(find.text('1 of 50'), findsOneWidget);
    expect(find.text('Invite someone'), findsOneWidget);
    expect(find.text('Aarav Sharma'), findsNothing);

    await tester.tap(find.text('Invite someone'));
    await tester.pumpAndSettle();
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
      expect(find.text('3 of 50'), findsOneWidget);
    }
  });

  testWidgets('survives 320 to 1280 dp at both text scales and themes', (
    tester,
  ) async {
    const longName =
        'Aarav Sharma With An Extraordinarily Long Name That Must Ellipsize '
        'Instead Of Pushing The Role And Remove Controls Off Screen';
    final members = [
      V2CollabMember(
        id: 'm1',
        name: longName,
        role: V2CollabRole.owner,
        isYou: true,
        isCreator: true,
        canRemove: true,
      ),
      _members[1],
      _members[2],
    ];

    for (final width in [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0]) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          await pumpAt(
            tester,
            CollabMembersPage(
              data: _data(members: members),
              onInvite: () {},
              onMemberMenu: (_) {},
              onLeave: () {},
            ),
            size: Size(width, 900),
            textScale: scale,
            dark: dark,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: 'width $width, scale $scale, dark $dark',
          );

          final list = find.byType(ListView);
          expect(widthOf(tester, list), lessThanOrEqualTo(640));
          if (width >= 640) {
            expect(widthOf(tester, list), 640);
            expect(
              tester.getTopLeft(list).dx,
              closeTo((width - 640) / 2, 0.5),
            );
          }

          final row = find.bySemanticsLabel(
            RegExp('^${RegExp.escape(longName)}, Owner'),
          );
          expect(row, findsOneWidget);
          expect(
            tester.getSize(row).height,
            greaterThanOrEqualTo(OSpace.listRow),
          );

          final name = tester.widget<Text>(find.text(longName));
          expect(name.maxLines, 1);
          expect(name.overflow, TextOverflow.ellipsis);
        }
      }
    }
  });

  testWidgets('a link that cannot be copied is never reported as copied', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        throw PlatformException(code: 'clipboard_unavailable');
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onCreateInviteLink: () async => 'https://ovidsi.com/s/tok/invite-code',
      ),
    );

    await tester.tap(find.bySemanticsLabel('Invite someone'));
    await tester.pumpAndSettle();

    expect(find.text('We could not copy the link.'), findsOneWidget);
    expect(find.text('Invite link copied.'), findsNothing);
    expect(find.text('We could not create an invite link.'), findsNothing);
  });

  testWidgets('the page-owned invite is disabled at the cap too', (
    tester,
  ) async {
    final members = [
      for (var i = 0; i < 50; i++)
        V2CollabMember(
          id: 'm$i',
          name: 'Member $i',
          role: i == 0 ? V2CollabRole.owner : V2CollabRole.canChat,
          isYou: i == 0,
          isCreator: i == 0,
        ),
    ];
    var invites = 0;
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: members, memberCount: 50),
        onCreateInviteLink: () async {
          invites++;
          return 'https://ovidsi.com/s/tok/invite-code';
        },
      ),
    );

    final invite = find.bySemanticsLabel(
      'Invite someone, Room is full (50 of 50).',
    );
    expect(
      tester.getSemantics(invite).flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    await tester.tap(invite);
    await tester.pumpAndSettle();
    expect(invites, 0);
  });

  testWidgets('an empty roster shows 0 of 50', (tester) async {
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(members: const [], memberCount: 0),
        onInvite: () {},
      ),
    );

    expect(find.text('0 of 50'), findsOneWidget);
    expect(find.text('No members yet'), findsOneWidget);
  });

  testWidgets('a row with role and remove controls fits 320 dp at 200 %', (
    tester,
  ) async {
    const longName =
        'Priya Patel With A Very Long Name That Must Ellipsize Cleanly';
    final members = [
      const V2CollabMember(
        id: 'm1',
        name: 'Aarav Sharma',
        role: V2CollabRole.owner,
        isYou: true,
        isCreator: true,
      ),
      const V2CollabMember(
        id: 'm2',
        name: longName,
        role: V2CollabRole.canChat,
        canRemove: true,
      ),
    ];

    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabMembersPage(
          data: _data(members: members),
          onRoleChanged: (_, _) {},
          onRemove: (_) {},
        ),
        dark: dark,
      );

      expect(tester.takeException(), isNull, reason: 'dark $dark');

      final row = find.bySemanticsLabel(RegExp('^${RegExp.escape(longName)}'));
      expect(row, findsOneWidget);
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(OSpace.listRow),
      );
      expect(
        find.bySemanticsLabel(
          'Change role for $longName, currently Editor',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Remove $longName, destructive'),
        findsOneWidget,
      );

      final name = tester.widget<Text>(find.text(longName));
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);

      // The role picker must also survive the tightest layout.
      await tester.tap(
        find.bySemanticsLabel(
          'Change role for $longName, currently Editor',
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'role sheet, dark $dark');
      expect(find.text('Can send messages'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a mutation in flight blocks the conflicting action', (
    tester,
  ) async {
    final change = Completer<void>();
    await pumpAt(
      tester,
      CollabMembersPage(
        data: _data(),
        onRoleChanged: (_, _) => change.future,
        onRemove: (_) {},
      ),
    );

    expect(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
      findsOneWidget,
    );

    await tester.tap(
      find.bySemanticsLabel(
        'Change role for Priya Patel, currently Editor',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OListRow, 'Viewer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // While the role write is in flight, removal is not offered.
    expect(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
      findsNothing,
    );

    change.complete();
    await tester.pumpAndSettle();
    expect(
      find.bySemanticsLabel('Remove Priya Patel, destructive'),
      findsOneWidget,
    );
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
