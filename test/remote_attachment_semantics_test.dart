import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/remote_attachment_tile.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('a ready attachment exposes a real semantic open action', (
    tester,
  ) async {
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Scaffold(
          body: RemoteAttachmentTile(
            attachment: MessageAttachment(name: 'ready.txt', size: 2),
            state: RemoteAttachmentState.ready,
            onOpen: () => opens++,
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Open ready.txt'));
    expect(opens, 1);
  });
}
