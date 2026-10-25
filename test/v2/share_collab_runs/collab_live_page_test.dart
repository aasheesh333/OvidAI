import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/a11y/live_region.dart';
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
  V2CollabLiveConnection connection = V2CollabLiveConnection.connected,
  String turnHolderName = 'Rahul Verma',
  String turnTimeLeftLabel = '24s left',
  DateTime? turnStartedAt,
  bool sending = false,
  int totalMembers = 50,
  int capacity = 50,
  List<V2CollabParticipant> participants = const [],
}) {
  return V2CollabLivePageData(
    title: 'Team chat',
    selfName: 'Aarav',
    participants: participants,
    totalMembers: totalMembers,
    capacity: capacity,
    typingName: 'Aarav',
    turnHolderName: turnHolderName,
    turnTimeLeftLabel: turnTimeLeftLabel,
    messages: messages,
    creatorPaysStorage: true,
    isMyTurn: isMyTurn,
    turnRequested: turnRequested,
    status: status,
    connection: connection,
    turnStartedAt: turnStartedAt,
    sending: sending,
  );
}

void main() {
  testWidgets('renders one banner line, the transcript and the composer', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        CollabLivePage(data: _data(), onSend: (_) {}),
        dark: dark,
      );

      expect(find.text('Team chat'), findsOneWidget);
      expect(find.text('50 members'), findsOneWidget);
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
      expect(
        find.byKey(const ValueKey<String>('collab-message-m1')),
        findsOneWidget,
      );
    }
  });

  testWidgets('the header states the live member count honestly', (
    tester,
  ) async {
    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 4, capacity: 50)),
    );
    expect(find.text('4 of 50 members'), findsOneWidget);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 1, capacity: 50)),
    );
    expect(find.text('1 of 50 members'), findsOneWidget);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 1, capacity: 1)),
    );
    expect(find.text('1 member'), findsOneWidget);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 0, capacity: 50)),
    );
    expect(find.textContaining('member'), findsNothing);
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
    await pumpAt(tester, CollabLivePage(data: _data(), onSend: (_) {}));

    expect(
      tester.getSemantics(find.bySemanticsLabel('Send, wait for the turn')),
      isSemantics(isButton: true, isEnabled: false),
    );
    expect(find.text('Wait for the turn'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Composer locked. Wait for the turn.'),
      findsOneWidget,
    );

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
    expect(find.bySemanticsLabel('Composer ready. Your turn.'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Hello team');
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send message')),
      isSemantics(isButton: true, isEnabled: true),
    );

    // A projection that takes the turn away must not drop the draft.
    await pumpAt(tester, CollabLivePage(data: _data(), onSend: (_) {}));
    expect(find.text('Hello team'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send, wait for the turn')),
      isSemantics(isButton: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('an old lease start never expires locally or unlocks sending', (
    tester,
  ) async {
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(
          turnStartedAt: DateTime(2020),
          turnTimeLeftLabel: '',
        ),
        onSend: (_) {},
      ),
    );

    await tester.pump(const Duration(seconds: 120));
    expect(find.text('Your turn'), findsNothing);
    expect(find.text('Wait for the turn'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });

  testWidgets('only fresh server facts without a lease unlock sending', (
    tester,
  ) async {
    await pumpAt(
      tester,
      CollabLivePage(data: _data(), onSend: (_) {}),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);

    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(
          isMyTurn: true,
          turnHolderName: '',
          turnTimeLeftLabel: '',
        ),
        onSend: (_) {},
      ),
    );
    expect(find.text('Your turn'), findsOneWidget);
    expect(find.text('Message'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('the live member count is announced and kept current', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 4, capacity: 50)),
    );
    expect(find.bySemanticsLabel('4 of 50 members'), findsOneWidget);

    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 5, capacity: 50)),
    );
    expect(find.bySemanticsLabel('5 of 50 members'), findsOneWidget);
    expect(
      tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
      'Member joined. 5 members.',
    );

    await pumpAt(
      tester,
      CollabLivePage(data: _data(totalMembers: 4, capacity: 50)),
    );
    expect(
      tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
      'Member left. 4 members.',
    );
    handle.dispose();
  });

  testWidgets('a connecting or dropped socket always locks the composer', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(
          isMyTurn: true,
          connection: V2CollabLiveConnection.connecting,
        ),
        onSend: (_) {},
      ),
    );
    expect(find.text('Connecting'), findsWidgets);
    expect(
      find.bySemanticsLabel('Connecting. Your messages are locked.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(
      find.bySemanticsLabel('Composer locked. Connecting.'),
      findsOneWidget,
    );

    var retries = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(
          isMyTurn: true,
          connection: V2CollabLiveConnection.disconnected,
        ),
        onSend: (_) {},
        onRetry: () => retries++,
      ),
    );
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('No connection'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Disconnected. Your messages are locked.'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Send, no connection')),
      isSemantics(isButton: true, isEnabled: false),
    );
    expect(
      tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
      'Disconnected. Messages locked.',
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
    handle.dispose();
  });

  testWidgets('an ended room is readable but accepts no messages', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(status: V2CollabLiveStatus.ended),
        onSend: (_) {},
      ),
    );

    expect(find.text('Chat ended'), findsOneWidget);
    expect(find.text('This live chat has ended.'), findsOneWidget);
    // A closed room has no live presence left to claim.
    expect(find.textContaining('members'), findsNothing);
    // What was said stays readable after the creator closes the room.
    expect(find.text('Running the curl check now.'), findsOneWidget);
    expect(find.text('Priya Patel'), findsOneWidget);
    // Nothing may be sent.
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(
      find.bySemanticsLabel('Chat ended. This live chat has ended.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('ending the room is announced once', (tester) async {
    await pumpAt(tester, CollabLivePage(data: _data(), onSend: (_) {}));
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(status: V2CollabLiveStatus.ended),
        onSend: (_) {},
      ),
    );

    expect(find.text('Chat ended'), findsOneWidget);
    expect(
      tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
      'Chat ended',
    );
  });

  testWidgets('empty, error and loading states are wired', (tester) async {
    var requested = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(messages: const []),
        onRequestTurn: () => requested++,
        onSend: (_) {},
      ),
    );
    expect(find.text('No messages yet'), findsOneWidget);
    expect(find.text('Start the conversation.'), findsOneWidget);
    expect(find.text('Request turn'), findsOneWidget);
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

  testWidgets('the request action is wired through the page', (tester) async {
    var requested = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(),
        onRequestTurn: () => requested++,
        onSend: (_) {},
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requested, 1);
  });

  testWidgets('an async refusal is shown inline', (tester) async {
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(),
        onRequestTurnAsync: () async => 'Rahul is still sending.',
        onSend: (_) {},
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(find.text('Rahul is still sending.'), findsOneWidget);
    expect(find.text('Request turn'), findsOneWidget);
  });

  testWidgets('the composer sends the typed draft', (tester) async {
    String? sent;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(isMyTurn: true),
        onSend: (text) => sent = text,
      ),
    );

    await tester.enterText(find.byType(TextField), 'Ship it');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sent, 'Ship it');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
  });

  testWidgets('an async send locks the field, then clears on success', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<void>();
    String? sent;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(isMyTurn: true),
        onSendAsync: (text) {
          sent = text;
          return pending.future;
        },
      ),
    );

    await tester.enterText(find.byType(TextField), 'Ship it');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    expect(sent, 'Ship it');
    expect(find.bySemanticsLabel('Sending'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.bySemanticsLabel('Sending your message.'), findsOneWidget);

    pending.complete();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      isEmpty,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    handle.dispose();
  });

  testWidgets('a failed async send keeps the draft and says why', (
    tester,
  ) async {
    final pending = Completer<void>();
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(isMyTurn: true),
        onSendAsync: (_) => pending.future,
      ),
    );

    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();

    pending.completeError('Turn expired. Try again.');
    await tester.pump();

    expect(find.text('Turn expired. Try again.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Keep this draft',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a host-reported send in flight locks the field', (tester) async {
    var sends = 0;
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(isMyTurn: true, sending: true),
        onSend: (_) => sends++,
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(find.text('Sending'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(find.text('Message'), findsNothing);

    await tester.tap(find.byType(TextField), warnIfMissed: false);
    await tester.pump();
    expect(sends, 0);
  });

  testWidgets('message attribution is stable when the roster changes', (
    tester,
  ) async {
    const messages = [
      V2CollabMessage(
        id: 'a',
        speakerName: 'Priya Patel',
        timeLabel: '11:02 AM',
        text: 'I updated the auth endpoints.',
      ),
      V2CollabMessage(
        id: 'b',
        speakerName: '',
        timeLabel: '11:03 AM',
        text: 'Person without a name.',
      ),
      V2CollabMessage(
        id: 'c',
        speakerName: '',
        timeLabel: '11:03 AM',
        text: 'Agent without a name.',
        kind: V2CollabMessageKind.agent,
      ),
      V2CollabMessage(
        id: 'd',
        speakerName: 'Former Member',
        timeLabel: '11:04 AM',
        text: 'I left the room yesterday.',
      ),
    ];

    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(
          messages: messages,
          participants: const [
            V2CollabParticipant(id: 'p1', name: 'Somebody Else'),
          ],
        ),
        onSend: (_) {},
      ),
    );

    expect(find.text('Priya Patel'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    expect(find.text('Ovid'), findsOneWidget);
    expect(find.text('Former Member'), findsOneWidget);
    expect(find.text('I left the room yesterday.'), findsOneWidget);
    expect(find.text('Somebody Else'), findsNothing);
  });

  testWidgets('a sender name is read once per message', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabLivePage(
        data: _data(messages: [_messages.first]),
        onSend: (_) {},
      ),
    );
    // The avatar is decorative; only the name row carries the label.
    expect(find.bySemanticsLabel(RegExp('Priya Patel')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('I updated the auth endpoints.')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('long member names ellipsize at 320 dp and 200 %', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabLivePage(
          data: _data(
            turnHolderName: 'Rahul Verma (Product Engineering)',
            messages: const [
              V2CollabMessage(
                id: 'long',
                speakerName: 'Rahul Verma (Product Engineering)',
                timeLabel: '11:03 AM',
                text: 'Running the curl check now.',
              ),
            ],
          ),
          onOpenMembers: () {},
          onSend: (_) {},
          onRequestTurn: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      // The banner names the holder and the transcript names the sender; both
      // ellipsize instead of pushing the row past 320 dp.
      expect(
        find.text('Rahul Verma (Product Engineering) · 24s left'),
        findsOneWidget,
      );
      expect(find.text('Rahul Verma (Product Engineering)'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    }
  });

  testWidgets('fits every supported width, scale and theme', (tester) async {
    const widths = [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0];

    for (final width in widths) {
      for (final scale in [1.0, 2.0]) {
        for (final dark in [false, true]) {
          await pumpAt(
            tester,
            CollabLivePage(
              data: _data(
                messages: const [
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
                  ),
                ],
              ),
              onOpenMembers: () {},
              onSend: (_) {},
              onRequestTurn: () {},
            ),
            size: Size(width, width <= 360 ? 640 : 900),
            textScale: scale,
            dark: dark,
          );

          expect(
            tester.takeException(),
            isNull,
            reason: 'width $width, scale $scale, dark $dark',
          );
          final transcript = find.byType(ListView);
          final expected = width >= 900
              ? 720.0
              : (width >= 600 ? math.min(width, 640.0) : width);
          expect(widthOf(tester, transcript), expected);
          expect(
            tester.getTopLeft(transcript).dx,
            closeTo((width - expected) / 2, 0.5),
          );
        }
      }
    }
  });

  testWidgets('caps and centres the transcript at 720 dp', (tester) async {
    await pumpTablet(tester, CollabLivePage(data: _data(), onSend: (_) {}));

    final transcript = find.byType(ListView);
    expect(widthOf(tester, transcript), 720);
    expect(tester.getTopLeft(transcript).dx, closeTo((900 - 720) / 2, 0.5));
  });
}
