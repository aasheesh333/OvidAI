import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/collab/collab_live_page.dart';

import '_harness.dart';

const _messages = [
  V2CollabMessage(
    id: 'm1',
    speakerName: 'Priya Patel',
    timeLabel: '11:02 AM',
    text: 'I updated the auth endpoints.',
  ),
  V2CollabMessage(
    id: 'm2',
    speakerName: 'Rahul Verma',
    timeLabel: '11:03 AM',
    text: 'Running the curl check now.',
    isTurnHolder: true,
  ),
  V2CollabMessage(
    id: 'm3',
    speakerName: 'Ovid',
    timeLabel: '11:03 AM',
    text: 'All six suites passed.',
    kind: V2CollabMessageKind.agent,
    toolName: 'POST /api/v1/auth/token',
    toolResult: '200 OK',
    artifactName: 'payload_report_v2.json',
  ),
];

V2CollabLivePageData _data({
  V2CollabLiveStatus status = V2CollabLiveStatus.ready,
  List<V2CollabMessage> messages = _messages,
  bool isMyTurn = false,
  bool turnRequested = false,
}) {
  return V2CollabLivePageData(
    title: 'Team chat',
    selfName: 'Aarav',
    totalMembers: 50,
    typingName: 'Aarav',
    turnHolderName: 'Rahul Verma',
    turnTimeLeftLabel: '24s left',
    messages: messages,
    creatorPaysStorage: true,
    isMyTurn: isMyTurn,
    turnRequested: turnRequested,
    status: status,
  );
}

void main() {
  testWidgets('renders one banner line, the transcript and the composer', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(tester, CollabLivePage(data: _data()), dark: dark);

      expect(find.text('Team chat'), findsOneWidget);
      expect(find.text('Rahul Verma · 24s left'), findsOneWidget);
      expect(find.text('I updated the auth endpoints.'), findsOneWidget);
      expect(find.text('Running the curl check now.'), findsOneWidget);
      expect(find.text('All six suites passed.'), findsOneWidget);
      expect(find.text('payload_report_v2.json'), findsOneWidget);
      expect(find.text('Wait for the turn'), findsOneWidget);

      // Presence, the member summary and the storage pill are gone.
      expect(find.textContaining('is typing'), findsNothing);
      expect(find.text('Live now'), findsNothing);
      expect(find.textContaining('members in this room'), findsNothing);
      expect(find.textContaining('Creator pays storage'), findsNothing);
      expect(find.text('Waiting'), findsNothing);
    }
  });

  testWidgets('the header carries the one member action', (tester) async {
    var opened = 0;
    await pumpAt(
      tester,
      CollabLivePage(data: _data(), onOpenMembers: () => opened++),
    );

    await tester.tap(find.bySemanticsLabel('Members'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('sending stays closed until it is this member turn', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabLivePage(data: _data(), onSend: (_) {}),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send, wait for the turn')),
      isSemantics(isButton: true, isEnabled: false),
    );
    expect(find.text('Wait for the turn'), findsOneWidget);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(isMyTurn: true), onSend: (_) {}),
    );

    expect(find.text('Your turn · 24s left'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send message')),
      isSemantics(isButton: true, isEnabled: false),
    );

    await tester.enterText(find.byType(TextField), 'Hello team');
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send message')),
      isSemantics(isButton: true, isEnabled: true),
    );
    handle.dispose();
  });

  testWidgets('the composer sends the typed draft', (tester) async {
    String? sent;
    await pumpAt(
      tester,
      CollabLivePage(data: _data(isMyTurn: true), onSend: (text) => sent = text),
    );

    await tester.enterText(find.byType(TextField), 'Ship it');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sent, 'Ship it');
  });

  testWidgets('empty, error and loading states are wired', (tester) async {
    var requested = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(messages: const []),
        onRequestTurn: () => requested++,
      ),
    );
    expect(find.text('No messages yet'), findsOneWidget);
    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requested, 1);

    var retries = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(status: V2CollabLiveStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load this live chat.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(status: V2CollabLiveStatus.loading)),
    );
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200 % text in both themes', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabLivePage(
          data: _data(isMyTurn: true),
          onOpenMembers: () {},
          onSend: (_) {},
          onRequestTurn: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Team chat'), findsOneWidget);
    }
  });

  testWidgets('caps and centres the transcript at 720 dp', (tester) async {
    await pumpTablet(tester, CollabLivePage(data: _data(), onSend: (_) {}));

    final transcript = find.byType(ListView);
    expect(widthOf(tester, transcript), 720);
    expect(
      tester.getTopLeft(transcript).dx,
      closeTo((900 - 720) / 2, 0.5),
    );
  });
}
