import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

V2ShareSheetData _data({
  bool active = true,
  bool copied = false,
  bool viewerCanFork = false,
  bool canChangeMode = true,
  V2ShareMode mode = V2ShareMode.readOnly,
  int memberCount = 1,
  V2ShareStatus status = V2ShareStatus.ready,
}) {
  return V2ShareSheetData(
    link: 'ovidsi.com/c/79f9b4c0e',
    creatorName: 'Aarav Sharma',
    active: active,
    copied: copied,
    viewerCanFork: viewerCanFork,
    canChangeMode: canChangeMode,
    mode: mode,
    memberCount: memberCount,
    status: status,
  );
}

void main() {
  testWidgets('shows the mode choice, the link row and revoke in both themes', (
    tester,
  ) async {
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
      expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
      expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
      expect(find.text('Revoke link'), findsOneWidget);

      // The operating system owns the app list.
      expect(find.text('WhatsApp'), findsNothing);
      expect(find.text('Gmail'), findsNothing);
      expect(find.text('Slack'), findsNothing);
      expect(find.text('More'), findsNothing);
      expect(find.textContaining('never include your files'), findsNothing);
    }
  });

  testWidgets('mode cards report the choice and the selected state', (
    tester,
  ) async {
    V2ShareMode? picked;
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      ShareSheet(data: _data(), onModeChanged: (mode) => picked = mode),
    );

    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Read only. Anyone with the link can read and fork.'),
      ),
      isSemantics(isButton: true, isSelected: true, isEnabled: true),
    );

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(picked, V2ShareMode.collab);
    handle.dispose();
  });

  testWidgets('copy reports Copied and revoke asks before calling the host', (
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

  testWidgets('copied state and the close control are wired', (tester) async {
    var closes = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(copied: true),
        onCopyLink: () {},
        onClose: () => closes++,
      ),
    );

    expect(find.bySemanticsLabel('Copied'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Close share sheet'));
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('an unshared chat offers one create action', (tester) async {
    var created = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(active: false),
        onCreateLink: () => created++,
        onModeChanged: (_) {},
      ),
    );

    expect(find.text('Not shared yet'), findsOneWidget);
    expect(find.text('Collab'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);
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

  testWidgets('a viewer forks and never sees revoke', (tester) async {
    var forks = 0;
    await pumpAt(
      tester,
      ShareSheet(
        data: _data(viewerCanFork: true),
        onFork: () => forks++,
        onStopSharing: () {},
      ),
    );

    expect(find.text('Revoke link'), findsNothing);
    expect(find.text('Collab'), findsNothing);
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
  });

  testWidgets('an unwired mode offers no dead choice', (tester) async {
    await pumpAt(tester, ShareSheet(data: _data()));
    expect(find.text('Collab'), findsNothing);
    expect(find.text('Read only'), findsNothing);
    expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);

    await pumpAt(
      tester,
      ShareSheet(data: _data(canChangeMode: false), onModeChanged: (_) {}),
    );
    expect(find.text('Collab'), findsNothing);
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
      expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
    }

    await pumpNarrow(
      tester,
      ShareSheet(data: _data(active: false), onCreateLink: () {}),
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

  testWidgets('centres and caps the sheet at 600 dp and wider', (tester) async {
    await pumpTablet(
      tester,
      ShareSheet(data: _data(), onCopyLink: () {}, onStopSharing: () {}),
    );

    final content = find.byType(SingleChildScrollView);
    expect(widthOf(tester, content), 560);
    expect(tester.getTopLeft(content).dx, closeTo((900 - 560) / 2, 0.5));
  });
}
