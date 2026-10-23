// Spec Screen 2: "the user cannot send a Studio message until selected."
//
// Switching the chatbox mode to STUDIO must gate the composer on a chosen
// repo/folder. Before this, `_canSend` only looked at text, lock and running
// state, so a Studio message went out with no repo bound and the agent landed
// in an empty workspace.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';

Widget _app(Widget child) => MaterialApp(
      theme: OTheme.light(),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('Studio mode without a folder cannot send', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: V2ChatPageData(
            permissionLabel: 'Studio',
            studioFolder: null,
            draft: 'refactor the auth module',
          ),
          onSubmit: (_) => sent++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final send = find.bySemanticsLabel('Send');
    expect(send, findsOneWidget);
    await tester.tap(send, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(sent, 0, reason: 'no repo selected, so nothing may be sent');
  });

  testWidgets('the composer offers the folder selection it requires', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: V2ChatPageData(
            permissionLabel: 'Studio',
            studioFolder: null,
            draft: 'refactor the auth module',
            onSelectStudioFolder: () => opened++,
          ),
          onSubmit: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('composer-studio-folder'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a bound repo unlocks sending in Studio mode', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(
            permissionLabel: 'Studio',
            studioFolder: 'ovid/ovid-si',
            draft: 'refactor the auth module',
          ),
          onSubmit: (_) => sent++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composer-studio-folder')), findsNothing);
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();
    expect(sent, 1);
  });

  testWidgets('General mode is never gated by a folder', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      _app(
        V2ChatPage(
          data: const V2ChatPageData(draft: 'hello'),
          onSubmit: (_) => sent++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('composer-studio-folder')), findsNothing);
    await tester.tap(find.bySemanticsLabel('Send'));
    await tester.pumpAndSettle();
    expect(sent, 1);
  });
}
