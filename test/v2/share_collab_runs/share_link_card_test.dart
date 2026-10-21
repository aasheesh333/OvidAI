import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/share/share_link_card.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

const _url = 'https://ovid.si/c/79f9b4c0e';

V2ShareLinkCardData _data({
  V2ShareMode mode = V2ShareMode.collab,
  bool viewer = false,
  bool copied = false,
  bool revoked = false,
  int memberCount = 3,
  DateTime? expiresAt,
}) {
  return V2ShareLinkCardData(
    url: _url,
    mode: mode,
    createdAt: DateTime(2026, 10, 12, 9, 30),
    expiresAt: expiresAt ?? DateTime(2026, 11, 11, 18),
    memberCount: memberCount,
    copied: copied,
    viewer: viewer,
    revoked: revoked,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child,
  ThemeData theme, {
  bool narrow = false,
}) async {
  if (narrow) {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, appChild) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: narrow
              ? media.copyWith(
                  size: const Size(320, 640),
                  textScaler: const TextScaler.linear(2),
                )
              : media,
          child: appChild!,
        );
      },
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('Collab card shows URL, mode, members and dates in both themes', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        V2ShareLinkCard(data: _data(), onCopy: () {}, onRevoke: () {}),
        theme,
      );

      expect(find.text('Share link'), findsOneWidget);
      expect(find.text('Collab'), findsOneWidget);
      expect(find.text(_url), findsOneWidget);
      expect(find.text('3 of 50 members'), findsOneWidget);
      expect(find.text('Created 12 Oct 2026'), findsOneWidget);
      expect(find.text('Expires 11 Nov 2026'), findsOneWidget);
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Revoke link'), findsOneWidget);
      expect(find.text('Fork into my account'), findsNothing);
      expect(find.text('Read only'), findsNothing);
    }
  });

  testWidgets('read-only owner sees the snapshot badge and revoke only', (
    tester,
  ) async {
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(mode: V2ShareMode.readOnly, memberCount: 9),
        onRevoke: () {},
      ),
      OTheme.light(),
    );

    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Collab'), findsNothing);
    expect(find.text('9 of 50 members'), findsNothing);
    expect(find.text('One person sends at a time.'), findsNothing);
    expect(find.text('Revoke link'), findsOneWidget);
    expect(find.text('Fork into my account'), findsNothing);
  });

  testWidgets('a read-only viewer gets a working fork CTA', (tester) async {
    var copies = 0;
    var forks = 0;
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(mode: V2ShareMode.readOnly, viewer: true),
        onCopy: () => copies++,
        onRevoke: () {},
        onFork: () => forks++,
      ),
      OTheme.light(),
    );

    expect(find.text('Shared with you'), findsOneWidget);
    expect(find.text('Fork into my account'), findsOneWidget);
    expect(find.text('Revoke link'), findsNothing);
    expect(find.textContaining('Forking makes a copy'), findsOneWidget);

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 1);

    await tester.ensureVisible(find.text('Fork into my account'));
    await tester.pump();
    await tester.tap(find.text('Fork into my account'));
    await tester.pump();
    expect(forks, 1);
  });

  testWidgets('a Collab viewer sees members but cannot fork or revoke', (
    tester,
  ) async {
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(viewer: true, memberCount: 12),
        onRevoke: () {},
        onFork: () {},
      ),
      OTheme.light(),
    );

    expect(find.text('Shared with you'), findsOneWidget);
    expect(find.text('12 of 50 members'), findsOneWidget);
    expect(find.text('Fork into my account'), findsNothing);
    expect(find.text('Revoke link'), findsNothing);
  });

  testWidgets('copy reports the copied state and the callback', (tester) async {
    var copies = 0;
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(copied: true),
        onCopy: () => copies++,
        onRevoke: () {},
      ),
      OTheme.light(),
    );

    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Copy link'), findsNothing);

    await tester.tap(find.text('Copied'));
    await tester.pump();
    expect(copies, 1);
  });

  testWidgets('an expired link says Expired and disables copy and fork', (
    tester,
  ) async {
    var copies = 0;
    var forks = 0;
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(
          mode: V2ShareMode.readOnly,
          viewer: true,
          expiresAt: DateTime(2026, 10, 1),
        ),
        now: DateTime(2026, 10, 21),
        onCopy: () => copies++,
        onFork: () => forks++,
      ),
      OTheme.light(),
    );

    expect(find.text('Expired 1 Oct 2026'), findsOneWidget);
    expect(find.text('Expires 1 Oct 2026'), findsNothing);

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 0);

    await tester.ensureVisible(find.text('Fork into my account'));
    await tester.pump();
    await tester.tap(find.text('Fork into my account'));
    await tester.pump();
    expect(forks, 0);
  });

  testWidgets('a revoked link is announced and has no actions', (tester) async {
    var copies = 0;
    var revokes = 0;
    await _pump(
      tester,
      V2ShareLinkCard(
        data: _data(revoked: true),
        onCopy: () => copies++,
        onRevoke: () => revokes++,
      ),
      OTheme.light(),
    );

    expect(
      find.text('This link was revoked. Nobody can open it now.'),
      findsOneWidget,
    );
    expect(find.text('Revoke link'), findsNothing);
    expect(find.text('Fork into my account'), findsNothing);

    await tester.tap(find.text('Copy link'));
    await tester.pump();
    expect(copies, 0);
    expect(revokes, 0);
  });

  testWidgets('a full Collab room shows the cap and the wait rule', (
    tester,
  ) async {
    await _pump(
      tester,
      V2ShareLinkCard(data: _data(memberCount: 50), onRevoke: () {}),
      OTheme.dark(),
    );

    expect(find.text('50 of 50 members'), findsOneWidget);
    expect(find.text('Room full'), findsOneWidget);
    expect(
      find.text('The room is full. New people need a free seat.'),
      findsOneWidget,
    );
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(
        tester,
        V2ShareLinkCard(
          data: _data(memberCount: 50, expiresAt: DateTime(2026, 12, 31)),
          onCopy: () {},
          onRevoke: () {},
        ),
        theme,
        narrow: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('50 of 50 members'), findsOneWidget);
      expect(find.text('Revoke link'), findsOneWidget);

      await _pump(
        tester,
        V2ShareLinkCard(
          data: _data(mode: V2ShareMode.readOnly, viewer: true, copied: true),
          onCopy: () {},
          onFork: () {},
        ),
        theme,
        narrow: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Fork into my account'), findsOneWidget);
      expect(find.text('Copied'), findsOneWidget);
    }
  });

  test('formats share-link dates without the intl package', () {
    expect(formatShareLinkDate(DateTime(2026, 1, 5)), '5 Jan 2026');
    expect(formatShareLinkDate(DateTime(2026, 10, 12)), '12 Oct 2026');
  });

  testWidgets('an empty URL cannot be copied and says so', (tester) async {
    var copies = 0;
    await _pump(
      tester,
      V2ShareLinkCard(
        data: const V2ShareLinkCardData(
          url: '',
          mode: V2ShareMode.readOnly,
          copied: true,
        ),
        onCopy: () => copies++,
        onRevoke: () {},
      ),
      OTheme.light(),
    );

    expect(find.text('No link yet'), findsOneWidget);
    expect(find.text('Copied'), findsNothing);
    await tester.tap(find.text('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(copies, 0);
  });

  testWidgets('revoke is hidden when the host has no revoke action', (
    tester,
  ) async {
    await _pump(
      tester,
      V2ShareLinkCard(data: _data(), onCopy: () {}),
      OTheme.light(),
    );

    expect(find.text('Revoke link'), findsNothing);
  });
}
