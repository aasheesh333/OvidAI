import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/share/share_link_card.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

const _url = 'https://ovidsi.com/c/8f92a10c';

V2ShareLinkCardData _data({
  V2ShareMode mode = V2ShareMode.readOnly,
  bool copied = false,
  bool viewer = false,
  bool revoked = false,
  bool busy = false,
  DateTime? expiresAt,
}) {
  return V2ShareLinkCardData(
    url: _url,
    mode: mode,
    copied: copied,
    viewer: viewer,
    revoked: revoked,
    busy: busy,
    expiresAt: expiresAt,
  );
}

void main() {
  testWidgets('renders one link row with a copy control', (tester) async {
    await pumpAt(tester, V2ShareLinkCard(data: _data(), onCopy: () {}));

    expect(find.text(_url), findsOneWidget);
    expect(find.bySemanticsLabel('Share link, $_url'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
    // Mode, member count and dates belong to the sheet, not the row.
    expect(find.text('Collab'), findsNothing);
    expect(find.text('Read only'), findsNothing);
    expect(find.textContaining('members'), findsNothing);
    expect(find.textContaining('Created'), findsNothing);
  });

  testWidgets('copy announces the full link and the copied state', (
    tester,
  ) async {
    var copies = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(data: _data(copied: true), onCopy: () => copies++),
    );

    expect(find.bySemanticsLabel('Link copied, $_url'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Link copied, $_url'));
    await tester.pump();
    expect(copies, 1);
  });

  testWidgets('an empty link is not copyable', (tester) async {
    await pumpAt(
      tester,
      const V2ShareLinkCard(data: V2ShareLinkCardData(url: '')),
    );
    expect(find.text('No link yet'), findsOneWidget);
    expect(find.bySemanticsLabel('No link yet'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a revoked link says so and disables copy and revoke', (
    tester,
  ) async {
    var copies = 0;
    var revokes = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(
        data: _data(revoked: true),
        onCopy: () => copies++,
        onRevoke: () => revokes++,
      ),
    );

    expect(find.text('Link revoked.'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(copies, 0);
    expect(revokes, 0);
  });

  testWidgets('an expired link says so and disables copy', (tester) async {
    var copies = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(
        data: _data(expiresAt: DateTime(2026, 10, 1)),
        onCopy: () => copies++,
        now: DateTime(2026, 10, 21),
      ),
    );

    expect(find.text('Link expired.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(copies, 0);
  });

  testWidgets('a busy link disables copy, fork and revoke', (tester) async {
    var copies = 0;
    var revokes = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(
        data: _data(busy: true, viewer: true),
        onCopy: () => copies++,
        onFork: () {},
        onRevoke: () => revokes++,
      ),
    );

    expect(find.text('Revoking link…'), findsOneWidget);
    expect(find.text('Fork'), findsNothing);
    expect(find.text('Revoke'), findsNothing);
    await tester.tap(find.bySemanticsLabel('Copy link'), warnIfMissed: false);
    await tester.pump();
    expect(copies, 0);
    expect(revokes, 0);
  });

  testWidgets('a read-only viewer forks and never sees revoke', (tester) async {
    var forks = 0;
    var revokes = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(
        data: _data(viewer: true),
        onCopy: () {},
        onFork: () => forks++,
        onRevoke: () => revokes++,
      ),
    );

    expect(find.text('Fork'), findsOneWidget);
    expect(find.text('Revoke'), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pump();
    expect(forks, 1);
    expect(revokes, 0);
  });

  testWidgets('a creator gets one revoke action', (tester) async {
    var revokes = 0;
    await pumpAt(
      tester,
      V2ShareLinkCard(data: _data(), onCopy: () {}, onRevoke: () => revokes++),
    );

    await tester.tap(find.text('Revoke'));
    await tester.pump();
    expect(revokes, 1);
  });

  testWidgets('fits 320 dp at 200 % text', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        V2ShareLinkCard(
          data: _data(viewer: true),
          onCopy: () {},
          onFork: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Fork'), findsOneWidget);
    }
  });

  testWidgets('caps the row at 560 dp', (tester) async {
    await pumpTablet(tester, V2ShareLinkCard(data: _data(), onCopy: () {}));
    final row = find
        .ancestor(of: find.text(_url), matching: find.byType(Container))
        .first;
    expect(tester.getSize(row).width, 560);
    expect(tester.getCenter(row).dx, closeTo(450, 1));
  });
}
