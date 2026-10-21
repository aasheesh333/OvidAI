import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/collab/collab_live_page.dart';

const _participants = [
  V2CollabParticipant(id: 'p1', name: 'Priya Patel'),
  V2CollabParticipant(id: 'p2', name: 'Rahul Verma'),
  V2CollabParticipant(id: 'p3', name: 'Elena Chen'),
  V2CollabParticipant(id: 'p4', name: 'Marcus Vance'),
];

const _messages = [
  V2CollabMessage(
    id: 'm1',
    speakerName: 'Priya Patel',
    timeLabel: '11:02 AM',
    text: 'I updated the auth endpoints. Ovid, can you test the login flow?',
  ),
  V2CollabMessage(
    id: 'm2',
    speakerName: 'Rahul Verma',
    timeLabel: '11:03 AM',
    text: 'Running the curl check right now, hold on.',
    isTurnHolder: true,
  ),
  V2CollabMessage(
    id: 'm3',
    speakerName: 'Ovid',
    timeLabel: '11:03 AM',
    text: 'All 6 test suites passed with no regressions.',
    kind: V2CollabMessageKind.agent,
    agentStatus: 'Testing endpoints',
    toolName: 'POST /api/v1/auth/token',
    toolResult: '200 OK',
    artifactName: 'payload_report_v2.json',
  ),
];

V2CollabLivePageData _data({
  V2CollabLiveStatus status = V2CollabLiveStatus.ready,
  List<V2CollabMessage> messages = _messages,
}) {
  return V2CollabLivePageData(
    subtitle: '3 agents here',
    selfName: 'Aarav',
    participants: _participants,
    totalMembers: 50,
    typingName: 'Aarav',
    turnHolderName: 'Rahul Verma',
    turnTimeLeftLabel: '24s left in turn',
    queueLabel: 'Queue position #3 · about 1m 12s',
    messages: messages,
    creatorPaysStorage: true,
    status: status,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(MaterialApp(theme: theme, home: child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  testWidgets('renders the live room and transcript in light and dark', (
    tester,
  ) async {
    for (final theme in [OTheme.light(), OTheme.dark()]) {
      await _pump(tester, CollabLivePage(data: _data()), theme);

      expect(find.text('Team chat'), findsOneWidget);
      expect(find.text('+46'), findsOneWidget);
      expect(find.text('Aarav is typing…'), findsOneWidget);
      expect(find.text('Only one person can send at a time'), findsOneWidget);
      expect(find.text('Priya Patel'), findsOneWidget);
      expect(find.text('Rahul Verma'), findsOneWidget);
      expect(find.text('Ovid'), findsOneWidget);
      expect(find.text('Wait for the turn'), findsOneWidget);
      expect(find.text('50 members · Creator pays storage'), findsOneWidget);
    }
  });

  testWidgets('narrow phone at 200% text lays out without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final status in V2CollabLiveStatus.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CollabLivePage(
            data: _data(
              status: status,
              messages: status == V2CollabLiveStatus.ready
                  ? _messages
                  : const [],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));

      expect(tester.takeException(), isNull, reason: 'status $status');
      expect(find.text('Team chat'), findsOneWidget, reason: 'status $status');
    }
  });

  testWidgets('empty state requests a turn', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      CollabLivePage(
        data: _data(status: V2CollabLiveStatus.empty, messages: const []),
        onRequestTurn: () => requests++,
      ),
      OTheme.light(),
    );

    expect(find.text('No messages yet'), findsOneWidget);
    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('error state offers a retry that fires', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      CollabLivePage(
        data: _data(status: V2CollabLiveStatus.error, messages: const []),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load this live chat.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('request turn callback fires from the composer', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      CollabLivePage(data: _data(), onRequestTurn: () => requests++),
      OTheme.light(),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('the send control is announced as disabled', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester, CollabLivePage(data: _data()), OTheme.light());

      expect(
        tester.getSemantics(find.bySemanticsLabel('Send, wait for the turn')),
        isSemantics(
          label: 'Send, wait for the turn',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the member cluster opens the member list', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      CollabLivePage(data: _data(), onOpenMembers: () => opened++),
      OTheme.light(),
    );

    await tester.tap(find.byIcon(Icons.group_rounded));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the agent artifact opens by name', (tester) async {
    String? opened;
    await _pump(
      tester,
      CollabLivePage(data: _data(), onOpenArtifact: (name) => opened = name),
      OTheme.light(),
    );

    await tester.ensureVisible(find.text('payload_report_v2.json'));
    await tester.pump();
    await tester.tap(find.text('payload_report_v2.json'));
    await tester.pump();
    expect(opened, 'payload_report_v2.json');
  });
}
