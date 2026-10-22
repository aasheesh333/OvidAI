import 'dart:async';

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
      expect(find.text('Rahul Verma · 24s left in turn'), findsOneWidget);
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
      CollabTurnBanner(data: _data(), onRequestTurn: () => requests++),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('a request never grows the line into two rows', (tester) async {
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(
          queue: const [V2CollabTurnWaiter(name: 'Priya Patel', isYou: true)],
        ),
        onRequestTurn: () {},
      ),
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Request turn'), findsOneWidget);
    expect(
      tester.getSize(find.byType(CollabTurnBanner)).height,
      lessThanOrEqualTo(72),
    );
  });

  testWidgets('your turn is a statement, not a request', (tester) async {
    await pumpAt(
      tester,
      CollabTurnBanner(data: _data(isMyTurn: true), onRequestTurn: () {}),
    );

    expect(find.text('Your turn · 24s left in turn'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });

  testWidgets('a requested turn reads In queue with no action', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabTurnBanner(data: _data(turnRequested: true), onRequestTurn: () {}),
    );

    expect(find.text('In queue'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
    expect(find.bySemanticsLabel('Rahul Verma has the turn'), findsOneWidget);
    // The countdown is omitted from speech so the live region does not talk
    // over the room every second.
    expect(find.bySemanticsLabel(RegExp('24s left')), findsNothing);
    final banner = tester.getSemantics(
      find.bySemanticsLabel('Rahul Verma has the turn'),
    );
    expect(banner.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  testWidgets('a queue position is spoken with the holder', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(
          queue: const [
            V2CollabTurnWaiter(name: 'Priya Patel'),
            V2CollabTurnWaiter(name: 'Aarav', isYou: true),
          ],
        ),
        onRequestTurn: () {},
      ),
    );

    expect(
      find.bySemanticsLabel('Rahul Verma has the turn. You are #2 in line.'),
      findsOneWidget,
    );
    expect(find.text('Request turn'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a free turn offers the take action', (tester) async {
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(holderName: '', timeLeftLabel: ''),
        onRequestTurn: () => requests++,
      ),
    );

    expect(find.text('Turn is free'), findsOneWidget);
    await tester.tap(find.text('Take turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('taking a free turn shows progress, then In queue', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<String?>();
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(holderName: '', timeLeftLabel: ''),
        onRequestTurnAsync: () {
          requests++;
          return pending.future;
        },
      ),
    );

    await tester.tap(find.text('Take turn'));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('Take turn'), findsNothing);
    expect(find.bySemanticsLabel('Requesting turn'), findsOneWidget);

    pending.complete(null);
    await tester.pump();
    expect(find.text('In queue'), findsOneWidget);
    expect(find.text('Take turn'), findsNothing);

    // A projection that already queued this device offers no second request.
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(holderName: '', timeLeftLabel: '', turnRequested: true),
        onRequestTurnAsync: () async => null,
      ),
    );
    expect(find.text('In queue'), findsOneWidget);
    expect(find.text('Take turn'), findsNothing);
    handle.dispose();
  });

  testWidgets('an unwired turn shows no dead action', (tester) async {
    await pumpAt(tester, CollabTurnBanner(data: _data()));
    expect(find.text('Request turn'), findsNothing);
    expect(find.text('Take turn'), findsNothing);
    expect(find.text('Rahul Verma · 24s left in turn'), findsOneWidget);
  });

  testWidgets('connecting and disconnected explain the lock', (tester) async {
    final handle = tester.ensureSemantics();
    var retries = 0;

    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(status: V2CollabTurnBannerStatus.connecting),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('Connecting'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.bySemanticsLabel('Connecting. Your messages are locked.'),
      findsOneWidget,
    );

    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(status: V2CollabTurnBannerStatus.disconnected),
        onRetry: () => retries++,
      ),
    );
    expect(find.text('Disconnected'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Disconnected. Your messages are locked.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(retries, 1);
    handle.dispose();
  });

  testWidgets('async request shows progress, then In queue', (tester) async {
    final handle = tester.ensureSemantics();
    final pending = Completer<String?>();
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(),
        onRequestTurnAsync: () {
          requests++;
          return pending.future;
        },
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
    expect(find.text('Request turn'), findsNothing);
    expect(find.bySemanticsLabel('Requesting turn'), findsOneWidget);

    pending.complete(null);
    await tester.pump();
    expect(find.text('In queue'), findsOneWidget);
    expect(find.bySemanticsLabel('Requesting turn'), findsNothing);
    handle.dispose();
  });

  testWidgets('a refusal stays on the banner and can be retried', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var requests = 0;
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(),
        onRequestTurnAsync: () async {
          requests++;
          return 'Rahul is still sending.';
        },
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(find.text('Rahul is still sending.'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Rahul Verma has the turn. Rahul is still sending.',
      ),
      findsOneWidget,
    );
    // The action comes back so the member can retry.
    expect(find.text('Request turn'), findsOneWidget);

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 2);
    handle.dispose();
  });

  testWidgets('a thrown request is shown as a reason, not a crash', (
    tester,
  ) async {
    await pumpAt(
      tester,
      CollabTurnBanner(
        data: _data(),
        onRequestTurnAsync: () async => throw 'Turn request refused.',
      ),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(find.text('Turn request refused.'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
      CollabTurnBanner(data: _data(status: V2CollabTurnBannerStatus.loading)),
    );
    expect(find.byType(OSkeleton), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text with a long holder name', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await pumpNarrow(
        tester,
        CollabTurnBanner(
          data: _data(
            holderName: 'Rahul Verma (Product Engineering)',
            queue: const [V2CollabTurnWaiter(name: 'Priya Patel', isYou: true)],
          ),
          onRequestTurn: () {},
        ),
        dark: dark,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.text('Rahul Verma (Product Engineering) · 24s left in turn'),
        findsOneWidget,
      );
      expect(find.text('Request turn'), findsOneWidget);
    }
  });
}
