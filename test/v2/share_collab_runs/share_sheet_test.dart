import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/share/share_link_card.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

V2ShareSheetData _data({
  bool active = true,
  bool copied = false,
  V2ShareStatus status = V2ShareStatus.ready,
}) {
  return V2ShareSheetData(
    link: 'ovidsi.com/c/79f9b4c0e',
    creatorName: 'Aarav Sharma',
    active: active,
    copied: copied,
    status: status,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps at 320 dp wide with 200 % text, the tightest supported layout.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child,
  ThemeData theme,
) async {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, appChild) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(2)),
        child: appChild!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'renders the link, permissions and privacy note in light and dark',
    (tester) async {
      for (final theme in [OTheme.light(), OTheme.dark()]) {
        await _pump(
          tester,
          ShareSheet(
            data: _data(),
            onToggleAnyoneCanView: (_) {},
            onToggleShowName: (_) {},
            onShareTarget: (_) {},
            onStopSharing: () {},
          ),
          theme,
        );

        expect(find.text('Share this chat'), findsOneWidget);
        expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
        expect(find.text('Copy link'), findsOneWidget);
        expect(find.text('Anyone with the link can read this chat'), findsOneWidget);
        expect(find.text('Show my name'), findsOneWidget);
        expect(find.text('Displays Aarav Sharma as creator'), findsOneWidget);
        expect(find.text('WhatsApp'), findsOneWidget);
        expect(find.text('Gmail'), findsOneWidget);
        expect(find.text('Slack'), findsOneWidget);
        expect(find.text('More'), findsOneWidget);
        expect(find.text('Stop sharing'), findsOneWidget);
        expect(
          find.text('Shared chats never include your files or connectors.'),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('empty state creates a link', (tester) async {
    var created = 0;
    await _pump(
      tester,
      ShareSheet(
        data: _data(active: false),
        onCreateLink: () => created++,
        onModeChanged: (_) {},
      ),
      OTheme.light(),
    );

    expect(find.text('This chat is not shared yet'), findsOneWidget);
    // The mode is chosen before anything is generated.
    expect(find.text('Collab'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    await tester.ensureVisible(find.text('Create link'));
    await tester.pump();
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);
  });

  testWidgets('copy link and stop sharing callbacks fire', (tester) async {
    var copies = 0;
    var stops = 0;
    await _pump(
      tester,
      ShareSheet(
        data: _data(),
        onCopyLink: () => copies++,
        onStopSharing: () => stops++,
      ),
      OTheme.light(),
    );

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);

    await tester.ensureVisible(find.text('Stop sharing'));
    await tester.pump();
    await tester.tap(find.text('Stop sharing'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke this link?'), findsOneWidget);
    expect(stops, 0);
    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });

  testWidgets('toggles and a share target update the injected state', (
    tester,
  ) async {
    bool? anyone;
    bool? showName;
    V2ShareTarget? target;
    await _pump(
      tester,
      ShareSheet(
        data: _data(),
        onToggleAnyoneCanView: (value) => anyone = value,
        onToggleShowName: (value) => showName = value,
        onShareTarget: (value) => target = value,
      ),
      OTheme.light(),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(anyone, isFalse);

    await tester.tap(find.byType(Switch).last);
    await tester.pump();
    expect(showName, isFalse);

    await tester.ensureVisible(find.text('Slack'));
    await tester.pump();
    await tester.tap(find.text('Slack'));
    await tester.pump();
    expect(target, V2ShareTarget.slack);
  });

  testWidgets('loading state shows skeletons and error state retries', (
    tester,
  ) async {
    await _pump(
      tester,
      ShareSheet(data: _data(status: V2ShareStatus.loading)),
      OTheme.light(),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Copy link'), findsNothing);

    var retries = 0;
    await _pump(
      tester,
      ShareSheet(
        data: _data(status: V2ShareStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );
    expect(find.text('We could not load the share link.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('copied state and the close button are wired', (tester) async {
    var closes = 0;
    await _pump(
      tester,
      ShareSheet(data: _data(copied: true), onClose: () => closes++),
      OTheme.light(),
    );

    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy link'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Close share sheet'));
    await tester.pump();
    expect(closes, 1);
  });

  testWidgets('share targets are hidden when the host cannot share', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, ShareSheet(data: _data()), OTheme.light());
    expect(find.bySemanticsLabel('Share on Slack'), findsNothing);

    await _pump(
      tester,
      ShareSheet(data: _data(), onShareTarget: (_) {}),
      OTheme.light(),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Share on Slack')),
      isSemantics(label: 'Share on Slack', isButton: true, isEnabled: true),
    );

    handle.dispose();
  });

  testWidgets('fits 320 dp at 200% text without overflow', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pumpNarrow(
        tester,
        ShareSheet(
          data: _data(),
          forkNote:
              'Forking makes a copy in their own account. Your original stays '
              'private.',
          onCopyLink: () {},
          onToggleAnyoneCanView: (_) {},
          onToggleShowName: (_) {},
          onShareTarget: (_) {},
          onStopSharing: () {},
          onClose: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Stop sharing'), findsOneWidget);
      expect(find.text('ovidsi.com/c/79f9b4c0e'), findsOneWidget);
    }

    await _pumpNarrow(
      tester,
      ShareSheet(data: _data(active: false), onCreateLink: () {}),
      OTheme.light(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Create link'), findsOneWidget);

    await _pumpNarrow(
      tester,
      ShareSheet(data: _data(status: V2ShareStatus.error), onRetry: () {}),
      OTheme.light(),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('switching to Collab changes the copy and reports the mode', (
    tester,
  ) async {
    V2ShareMode? picked;
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          memberCount: 3,
        ),
        onModeChanged: (mode) => picked = mode,
        onToggleAnyoneCanView: (_) {},
        onToggleShowName: (_) {},
      ),
      OTheme.light(),
    );

    expect(find.text('SHARE MODE'), findsOneWidget);
    expect(find.text('Collab'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Anyone with the link can read this chat'), findsOneWidget);
    expect(find.textContaining('Up to 50 people can join'), findsNothing);

    await tester.tap(find.text('Collab'));
    await tester.pump();
    expect(picked, V2ShareMode.collab);

    // The owner of the state rebuilds the sheet in the new mode.
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          mode: V2ShareMode.collab,
          memberCount: 3,
        ),
        onModeChanged: (mode) => picked = mode,
      ),
      OTheme.light(),
    );

    expect(find.text('3 of 50 members'), findsOneWidget);
    expect(find.text('One person sends at a time'), findsOneWidget);
    expect(find.text('You pay for storage'), findsOneWidget);
    expect(
      find.textContaining('Up to 50 people can join'),
      findsOneWidget,
    );
    expect(find.text('Anyone with the link can read this chat'), findsNothing);
    expect(find.text('Read only'), findsOneWidget);
  });

  testWidgets('Collab shows the 50 person cap and a full room', (tester) async {
    expect(v2ShareMemberLimit, 50);

    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          mode: V2ShareMode.collab,
          memberCount: 50,
        ),
      ),
      OTheme.dark(),
    );

    expect(find.text('50 of 50 members'), findsOneWidget);
    expect(find.text('Room full'), findsOneWidget);
    expect(
      find.textContaining('Up to 50 people can join'),
      findsOneWidget,
    );
  });

  testWidgets('a read-only viewer can fork into their own account', (
    tester,
  ) async {
    var forks = 0;
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          viewerCanFork: true,
        ),
        onFork: () => forks++,
      ),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Fork into my account'));
    await tester.pump();
    expect(find.text('Stop sharing'), findsNothing);
    expect(find.text('Anyone with the link can read this chat'), findsNothing);
    await tester.tap(find.text('Fork into my account'));
    await tester.pump();
    expect(forks, 1);

    // Collab rooms are not forkable.
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          mode: V2ShareMode.collab,
          viewerCanFork: true,
        ),
        onFork: () => forks++,
      ),
      OTheme.light(),
    );
    expect(find.text('Fork into my account'), findsNothing);
  });

  testWidgets('a member who cannot change the mode does not see the selector', (
    tester,
  ) async {
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          canChangeMode: false,
        ),
      ),
      OTheme.light(),
    );

    expect(find.text('SHARE MODE'), findsNothing);
    expect(find.text('Collab'), findsNothing);
    // The link card's badge still states the mode the member is in.
    expect(find.byType(V2ShareLinkCard), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
  });

  testWidgets('Collab and the fork action fit 320 dp at 200 % text', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pumpNarrow(
        tester,
        ShareSheet(
          data: V2ShareSheetData(
            link: 'ovidsi.com/c/79f9b4c0e',
            creatorName: 'Aarav Sharma',
            mode: V2ShareMode.collab,
            memberCount: 50,
          ),
          onModeChanged: (_) {},
          onCopyLink: () {},
          onStopSharing: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('50 of 50 members'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);

      await _pumpNarrow(
        tester,
        ShareSheet(
          data: V2ShareSheetData(
            link: 'ovidsi.com/c/79f9b4c0e',
            creatorName: 'Aarav Sharma',
            viewerCanFork: true,
          ),
          onFork: () {},
        ),
        theme,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Fork into my account'), findsOneWidget);
    }
  });

  testWidgets('the active link block is the shared V2ShareLinkCard', (
    tester,
  ) async {
    var copies = 0;
    await _pump(
      tester,
      ShareSheet(data: _data(), onCopyLink: () => copies++),
      OTheme.light(),
    );

    final card = tester.widget<V2ShareLinkCard>(find.byType(V2ShareLinkCard));
    expect(card.data.url, 'ovidsi.com/c/79f9b4c0e');
    expect(card.data.mode, V2ShareMode.readOnly);
    expect(card.data.copied, isFalse);
    expect(card.data.viewer, isFalse);
    expect(find.text('Copy link'), findsOneWidget);

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);
  });

  testWidgets('the link card carries the Collab cap and member count', (
    tester,
  ) async {
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          mode: V2ShareMode.collab,
          memberCount: 50,
        ),
      ),
      OTheme.dark(),
    );

    final card = tester.widget<V2ShareLinkCard>(find.byType(V2ShareLinkCard));
    expect(card.data.mode, V2ShareMode.collab);
    expect(card.data.memberCount, 50);
    expect(card.data.capacity, v2ShareMemberLimit);
    // The member count and the full-room pill live on the card, once.
    expect(find.text('50 of 50 members'), findsOneWidget);
    expect(find.text('Room full'), findsOneWidget);
  });

  testWidgets('a viewer reads the card as shared-with-them and can fork', (
    tester,
  ) async {
    var forks = 0;
    await _pump(
      tester,
      ShareSheet(
        data: V2ShareSheetData(
          link: 'ovidsi.com/c/79f9b4c0e',
          creatorName: 'Aarav Sharma',
          viewerCanFork: true,
        ),
        onFork: () => forks++,
      ),
      OTheme.light(),
    );

    final card = tester.widget<V2ShareLinkCard>(find.byType(V2ShareLinkCard));
    expect(card.data.viewer, isTrue);
    expect(find.text('Shared with you'), findsOneWidget);
    // The card owns the fork action, so the sheet does not repeat it.
    expect(find.text('Fork into my account'), findsOneWidget);
    expect(find.text('Revoke link'), findsNothing);

    await tester.ensureVisible(find.text('Fork into my account'));
    await tester.pump();
    await tester.tap(find.text('Fork into my account'));
    await tester.pump();
    expect(forks, 1);
  });

  testWidgets('an empty link is not copyable and shows no fake Copied', (
    tester,
  ) async {
    var copies = 0;
    await _pump(
      tester,
      ShareSheet(
        data: const V2ShareSheetData(link: '', creatorName: 'Aarav'),
        onCopyLink: () => copies++,
      ),
      OTheme.light(),
    );

    expect(find.text('No link yet'), findsOneWidget);
    await tester.tap(find.text('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(copies, 0);
  });

  testWidgets('an unwired mode offers no dead switch', (tester) async {
    await _pump(
      tester,
      ShareSheet(data: _data()),
      OTheme.light(),
    );

    expect(find.text('SHARE MODE'), findsNothing);
    expect(find.text('Switch'), findsNothing);
    // The link card still states the real mode.
    expect(find.text('Read only'), findsOneWidget);
  });

  testWidgets('revoking the card link asks before it calls the host', (
    tester,
  ) async {
    var stops = 0;
    await _pump(
      tester,
      ShareSheet(data: _data(), onStopSharing: () => stops++),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('Revoke link'));
    await tester.pump();
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

  testWidgets('production wiring fits 320 dp at 200 % text in both themes', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pumpNarrow(
        tester,
        ShareSheet(
          data: V2ShareSheetData(
            link: 'https://ovidsi.com/s/79f9b4c0e',
            creatorName: 'Aarav Sharma',
          ),
          onCopyLink: () {},
          onShareTarget: (_) {},
          onStopSharing: () {},
          onClose: () {},
        ),
        theme,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      // No mode switch is shown because the host did not wire one.
      expect(find.text('SHARE MODE'), findsNothing);
    }
  });
}
