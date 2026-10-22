import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/v2/collab/turn_banner.dart';

import '_harness.dart';

V2CollabTurnBannerData _data({
  V2CollabTurnBannerStatus status = V2CollabTurnBannerStatus.ready,
  String holderName = 'Rahul Verma',
  String timeLeftLabel = '24s left in turn',
  bool isMyTurn = false,
  bool turnRequested = false,
  List<V2CollabTurnWaiter> queue = const [],
  String? queueLabel,
}) {
  return V2CollabTurnBannerData(
    status: status,
    holderName: holderName,
    timeLeftLabel: timeLeftLabel,
    isMyTurn: isMyTurn,
    turnRequested: turnRequested,
    queue: queue,
    queueLabel: queueLabel,
  );
}

void main() {
  testWidgets('states who holds the turn in one line', (tester) async {
    for (final dark in [false, true]) {
      await pumpAt(
        tester,
        CollabTurnBanner(data: _data(), onRequestTurn: () {}),
        dark: dark,
      );
      expect(
        find.text('Rahul Verma · 24s left in turn'),
        findsOneWidget,
      );
      expect(find.text('Request turn'), findsOneWidget);
      // The queue and the rule paragraph live on the members page.
      expect(find.text('Waiting'), findsNothing);
      expect(find.textContaining('One message at a time'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    }
  });

  testWidgets('the holder can ask for the turn', (tester) async {
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(),
        onRequestTurn: () => requests++,
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('your turn is a statement, not a request', (tester) async {
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(isMyTurn: true),
        onRequestTurn: () {},
      ),
    );

    expect(find.text('Your turn · 24s left in turn'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });

  testWidgets('a requested turn reads In queue with no action', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(turnRequested: true),
        onRequestTurn: () {},
      ),
    );

    expect(find.text('In queue'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
    expect(
      find.bySemanticsLabel('Rahul Verma · 24s left in turn'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a free turn offers the request action', (tester) async {
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(holderName: '', timeLeftLabel: ''),
        onRequestTurn: () => requests++,
      ),
    );

    expect(find.text('Turn is free'), findsOneWidget);
    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('an unwired turn shows no dead action', (tester) async {
    await pumpAt(tester, CollabTurnBanner(data: _data()));
    expect(find.text('Request turn'), findsNothing);
    expect(find.text('Rahul Verma · 24s left in turn'), findsOneWidget);
  });

  testWidgets('error state retries and loading shows a skeleton', (
    tester,
  ) async {
    var retries = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(status: V2CollabTurnBannerStatus.error),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('We could not load the turn.'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);

    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(status: V2CollabTurnBannerStatus.loading),
      ),
    );
    expect(find.byType(OSkeleton), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text', (tester) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabTurnBanner(
          data: _data(queue: const [
            V2CollabTurnWaiter(name: 'Priya Patel', isYou: true),
          ]),
          onRequestTurn: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Request turn'), findsOneWidget);
    }
  });
}
