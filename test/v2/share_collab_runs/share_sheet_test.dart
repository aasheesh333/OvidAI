import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

const _url = 'https://ovidsi.com/c/79f9b4c0e';

V2ShareSheetData _data({
  bool active = true,
  bool copied = false,
  bool viewerCanFork = false,
  bool canChangeMode = true,
  bool revoked = false,
  bool collabAvailable = true,
  bool readOnlyAvailable = true,
  String? collabUnavailableReason,
  V2ShareMode mode = V2ShareMode.readOnly,
  int memberCount = 1,
  V2ShareStatus status = V2ShareStatus.ready,
  String link = _url,
}) {
  return V2ShareSheetData(
    link: link,
    creatorName: 'Aarav Sharma',
    active: active,
    copied: copied,
    viewerCanFork: viewerCanFork,
    canChangeMode: canChangeMode,
    revoked: revoked,
    collabAvailable: collabAvailable,
    readOnlyAvailable: readOnlyAvailable,
    collabUnavailableReason: collabUnavailableReason,
    mode: mode,
    memberCount: memberCount,
    status: status,
  );
}

void main() {
  testWidgets(
    'shows the mode radio group, link row and revoke in both themes',
    (tester) async {
      for (final dark in [false, true]) {
        await pumpAt(
          tester,
          ShareSheet(
            data: _data(),
            onCopyLink: () {},
            onModeChanged: (_) {},
            onStopSharing: () {},
            onClose: () {},
          ),
          dark: dark,
        );

        expect(find.text('Share this chat'), findsOneWidget);
        expect(find.text('Collab'), findsOneWidget);
        expect(find.text('Read only'), findsOneWidget);
        expect(
          find.text('Max 50 · one sender at a time · creator pays storage.'),
          findsOneWidget,
        );
        expect(
          find.text('Recipients fork into their own account.'),
          findsOneWidget,
        );
        expect(find.text(_url), findsOneWidget);
        expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
        expect(find.text('Revoke link'), findsOneWidget);

        // The operating system owns the app list.
        expect(find.text('WhatsApp'), findsNothing);
        expect(find.text('Gmail'), findsNothing);
        expect(find.text('Slack'), findsNothing);
        expect(find.text('More'), findsNothing);
      }
    },
  );

  testWidgets('mode cards are a radio group with checked state and the facts', (
    tester,
  ) async {
    V2ShareMode? picked;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      ShareSheet(data: _data(), onModeChanged: (mode) => picked = mode),
    );

    expect(find.bySemanticsLabel('Sharing mode'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(
          'Read only. Recipients fork into their own account.',
        ),
      ),
      isSemantics(
        hasCheckedState: true,
        isChecked: true,
        isInMutuallyExclusiveGroup: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(
          'Collab. Max 50 · one sender at a time · creator pays storage.',
        ),
      ),
      isSemantics(
        hasCheckedState: true,
        isChecked: false,
        isInMutuallyExclusiveGroup: true,
        isEnabled: true,
      ),
    );

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(picked, V2ShareMode.collab);
    handle.dispose();
  });

  testWidgets('mode choice is explicit and create uses the selected mode', (
    tester,
  ) async {
    var mode = V2ShareMode.readOnly;
    V2ShareMode? created;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ShareSheet(
          data: _data(mode: mode, active: false),
          onModeChanged: (next) => setState(() => mode = next),
          onCreateLinkForMode: (next) => created = next,
        ),
      ),
    );

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(mode, V2ShareMode.collab);

    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, V2ShareMode.collab);
    expect(find.text('Creating link'), findsOneWidget);
  });

  testWidgets('an unavailable mode is disabled with the real reason', (
    tester,
  ) async {
    V2ShareMode? picked;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(
          collabAvailable: false,
          collabUnavailableReason: 'Live chats need a newer server.',
        ),
        onModeChanged: (mode) => picked = mode,
      ),
    );

    expect(find.text('Live chats need a newer server.'), findsOneWidget);
    expect(
      tester.getSemantics(
        find.bySemanticsLabel(
          'Collab. Max 50 · one sender at a time · creator pays storage. '
          'Live chats need a newer server.',
        ),
      ),
      isSemantics(isEnabled: false, hasCheckedState: true, isChecked: false),
    );

    await tester.tap(find.text('Collab'), warnIfMissed: false);
    await tester.pump();
    expect(picked, isNull);
    handle.dispose();
  });

  testWidgets('create shows in-flight, then renders the returned URL', (
    tester,
  ) async {
    var active = false;
    var link = '';
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ShareSheet(
          data: _data(active: active, link: link),
          onCreateLink: () {
            setState(() {
              active = true;
              link = _url;
            });
          },
          onCopyLink: () {},
          onStopSharing: () {},
        ),
      ),
    );

    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(find.text(_url), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
    expect(find.text('Revoke link'), findsOneWidget);
  });

  testWidgets('a data-driven creating state never shows a fake link', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(active: false, status: V2ShareStatus.creating),
        onCreateLink: () {},
      ),
    );

    expect(find.text('Creating link'), findsOneWidget);
    expect(find.text(_url), findsNothing);
    expect(find.bySemanticsLabel('Copy link'), findsNothing);
  });

  testWidgets('copy reports the copied link and revoke asks before acting', (
    tester,
  ) async {
    var copies = 0;
    var stops = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(),
        onCopyLink: () => copies++,
        onStopSharing: () => stops++,
      ),
    );

    await tester.tap(find.bySemanticsLabel('Copy link'));
    await tester.pump();
    expect(copies, 1);
    expect(find.bySemanticsLabel('Link copied, $_url'), findsOneWidget);

    await tester.tap(find.text('Revoke link'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke this link?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(stops, 0);

    await tester.tap(find.text('Revoke link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });

  testWidgets('revoking disables the link, then shows the revoked state', (
    tester,
  ) async {
    var active = true;
    await pumpAt(
      tester,
      StatefulBuilder(
        builder: (context, setState) => ShareSheet(
          data: _data(active: active),
          onCopyLink: () {},
          onCreateLink: () {},
          onStopSharing: () => setState(() => active = false),
        ),
      ),
    );

    await tester.tap(find.text('Revoke link'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();

    expect(find.text('Link revoked'), findsOneWidget);
    expect(find.text(_url), findsNothing);
    expect(find.text('No one can open it now.'), findsOneWidget);
    expect(find.text('Create link'), findsOneWidget);
  });

  testWidgets('an explicit revoking state keeps the link but disables copy', (
    tester,
  ) async {
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(status: V2ShareStatus.revoking),
        onCopyLink: () {},
        onStopSharing: () {},
      ),
    );

    expect(find.text(_url), findsOneWidget);
    expect(find.text('Revoking link…'), findsOneWidget);
    expect(find.text('Revoking'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Copy link'), warnIfMissed: false);
    await tester.pump();
  });

  testWidgets('an unshared chat offers one real create action', (tester) async {
    var created = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(active: false, link: ''),
        onCreateLink: () => created++,
        onModeChanged: (_) {},
      ),
    );

    expect(find.text('Not shared yet'), findsOneWidget);
    expect(find.text('Only people with the link can open it.'), findsOneWidget);
    expect(find.text('Collab'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);
    expect(find.text('Creating link'), findsOneWidget);
  });

  testWidgets('loading and error states stay inside the sheet', (tester) async {
    await pumpAt(
      tester,
      ShareSheet(data: _data(status: V2ShareStatus.loading)),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsNothing);

    var retries = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(status: V2ShareStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load the share link.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('a viewer gets static mode facts, fork, and no revoke', (
    tester,
  ) async {
    var forks = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(viewerCanFork: true),
        onFork: () => forks++,
        onStopSharing: () {},
      ),
    );

    expect(find.text('Read only'), findsOneWidget);
    expect(
      find.text('Recipients fork into their own account.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Sharing mode'), findsNothing);
    expect(find.text('Revoke link'), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pump();
    expect(forks, 1);
  });

  testWidgets('a Collab room is not forkable', (tester) async {
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(mode: V2ShareMode.collab, viewerCanFork: true),
        onFork: () {},
      ),
    );
    expect(find.text('Fork'), findsNothing);
    expect(
      find.text('Max 50 · one sender at a time · creator pays storage.'),
      findsOneWidget,
    );
  });

  testWidgets('an unwired mode offers no dead choice', (tester) async {
    await pumpAt(tester, ShareSheet(data: _data()));
    expect(find.text('Sharing mode'), findsNothing);
    expect(find.text('Read only'), findsOneWidget);

    await pumpAt(
      tester,
      ShareSheet(data: _data(canChangeMode: false), onModeChanged: (_) {}),
    );
    expect(find.text('Sharing mode'), findsNothing);
    expect(find.text('Read only'), findsOneWidget);
  });

  testWidgets('every touch target is at least 48 dp', (tester) async {
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(),
        onCopyLink: () {},
        onModeChanged: (_) {},
        onStopSharing: () {},
        onClose: () {},
      ),
    );

    final modeCard = find
        .ancestor(of: find.text('Collab'), matching: find.byType(OPressable))
        .first;
    expect(tester.getSize(modeCard).height, greaterThanOrEqualTo(48));
    final revoke = find
        .ancestor(of: find.text('Revoke link'), matching: find.byType(OButton))
        .first;
    expect(tester.getSize(revoke).height, greaterThanOrEqualTo(48));
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        ShareSheet(
          data: _data(mode: V2ShareMode.collab, memberCount: 50),
          onCopyLink: () {},
          onModeChanged: (_) {},
          onStopSharing: () {},
          onClose: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Revoke link'), findsOneWidget);
      expect(find.text(_url), findsOneWidget);
    }

    await pumpNarrow(
      tester,
      ShareSheet(
        data: _data(active: false, link: ''),
        onCreateLink: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Create link'), findsOneWidget);

    await pumpNarrow(
      tester,
      ShareSheet(
        data: _data(status: V2ShareStatus.error),
        onRetry: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('survives 320 to 1280 at 100 % and 200 % text', (tester) async {
    const widths = [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0];
    for (final width in widths) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          await pumpAt(
            tester,
            ShareSheet(
              data: _data(mode: V2ShareMode.collab, memberCount: 4),
              onCopyLink: () {},
              onModeChanged: (_) {},
              onStopSharing: () {},
              onClose: () {},
            ),
            size: Size(width, 900),
            textScale: scale,
            dark: dark,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '$width dp at ${scale}x, dark: $dark',
          );
          final sheet = find.byType(SingleChildScrollView).first;
          expect(widthOf(tester, sheet), width < 560 ? width : 560);
        }
      }
    }
  });

  testWidgets('centres and caps the sheet at 600 dp and wider', (tester) async {
    await pumpTablet(
      tester,
      ShareSheet(data: _data(), onCopyLink: () {}, onStopSharing: () {}),
    );

    final content = find.byType(SingleChildScrollView).first;
    expect(widthOf(tester, content), 560);
    expect(tester.getTopLeft(content).dx, closeTo((900 - 560) / 2, 0.5));
  });
}
