import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/share/share_chat_sheet.dart';
import 'package:ovid_ai/ui/v2/share/share_sheet.dart';

import '_harness.dart';

V2ShareChatSheetData _data({
  bool viewerCanFork = false,
  bool active = true,
  V2ShareStatus status = V2ShareStatus.ready,
}) {
  return V2ShareChatSheetData(
    link: 'https://ovid.si/c/8f92a10c',
    creatorName: 'Meera Nair',
    viewerCanFork: viewerCanFork,
    active: active,
    status: status,
  );
}

void main() {
  testWidgets('the chat sheet is the minimal share surface', (tester) async {
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(),
        onCopyLink: () {},
        onModeChanged: (_) {},
        onStopSharing: () {},
      ),
    );

    expect(find.text('Share this chat'), findsOneWidget);
    expect(find.text('https://ovid.si/c/8f92a10c'), findsOneWidget);
    expect(find.bySemanticsLabel('Copy link'), findsOneWidget);
    expect(find.text('Revoke link'), findsOneWidget);
    // No fork paragraph and no app grid.
    expect(find.textContaining('Forking makes a copy'), findsNothing);
    expect(find.textContaining('Anyone with the link can view'), findsNothing);
    expect(find.text('WhatsApp'), findsNothing);
  });

  testWidgets('a viewer forks into their own account', (tester) async {
    var forks = 0;
    await pumpAt(
      tester,
      ShareChatSheet(data: _data(viewerCanFork: true), onFork: () => forks++),
    );

    expect(find.text('Fork'), findsOneWidget);
    expect(find.text('Revoke link'), findsNothing);
    await tester.tap(find.text('Fork'));
    await tester.pump();
    expect(forks, 1);
  });

  testWidgets('empty and error states stay wired', (tester) async {
    var created = 0;
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(active: false),
        onCreateLink: () => created++,
        onModeChanged: (_) {},
      ),
    );
    expect(find.text('Not shared yet'), findsOneWidget);
    await tester.tap(find.text('Create link'));
    await tester.pump();
    expect(created, 1);

    var retries = 0;
    await pumpAt(
      tester,
      ShareChatSheet(
        data: _data(status: V2ShareStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load the share link.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('fits 320 dp at 200 % text', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        ShareChatSheet(
          data: _data(),
          onCopyLink: () {},
          onModeChanged: (_) {},
          onStopSharing: () {},
          onClose: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(OSkeletonList), findsNothing);
      expect(find.text('Revoke link'), findsOneWidget);
    }
  });
}
