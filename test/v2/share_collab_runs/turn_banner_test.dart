import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/collab/turn_banner.dart';

const _queue = [
  V2CollabTurnWaiter(name: 'Priya Patel', waitLabel: 'about 1m 12s'),
  V2CollabTurnWaiter(name: 'Elena Chen', waitLabel: 'about 2m 40s'),
];

V2CollabTurnBannerData _data({
  V2CollabTurnBannerStatus status = V2CollabTurnBannerStatus.ready,
  String holderName = 'Rahul Verma',
  String timeLeftLabel = '24s left in turn',
  double? timeLeftFraction = 0.4,
  bool isMyTurn = false,
  bool turnRequested = false,
  List<V2CollabTurnWaiter> queue = _queue,
  String? queueLabel,
  int maxVisibleQueue = 4,
}) {
  return V2CollabTurnBannerData(
    status: status,
    holderName: holderName,
    timeLeftLabel: timeLeftLabel,
    timeLeftFraction: timeLeftFraction,
    isMyTurn: isMyTurn,
    turnRequested: turnRequested,
    queue: queue,
    queueLabel: queueLabel,
    maxVisibleQueue: maxVisibleQueue,
  );
}

Future<void> _pump(WidgetTester tester, Widget child, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
}

void main() {
  testWidgets(
    'shows the turn holder, time left, queue and rule in both themes',
    (tester) async {
      for (final theme in [OTheme.light(), OTheme.dark()]) {
        await _pump(tester, CollabTurnBanner(data: _data()), theme);

        expect(find.text('Current turn'), findsOneWidget);
        expect(find.text('Rahul Verma'), findsOneWidget);
        expect(find.text('24s left in turn'), findsOneWidget);
        expect(find.text('Waiting'), findsOneWidget);
        expect(find.text('2 people'), findsOneWidget);
        expect(find.text('Priya Patel'), findsOneWidget);
        expect(find.text('about 1m 12s'), findsOneWidget);
        expect(find.text('Elena Chen'), findsOneWidget);
        expect(find.text('Request turn'), findsOneWidget);
        expect(find.textContaining('One message at a time'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('request turn fires from the banner', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      CollabTurnBanner(data: _data(), onRequestTurn: () => requests++),
      OTheme.light(),
    );

    await tester.tap(find.text('Request turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('the turn holder sees a disabled request control', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var requests = 0;
    try {
      await _pump(
        tester,
        CollabTurnBanner(
          data: _data(holderName: 'Aarav', isMyTurn: true),
          onRequestTurn: () => requests++,
        ),
        OTheme.light(),
      );

      expect(find.text('Your turn'), findsOneWidget);
      expect(find.text('Aarav (you)'), findsOneWidget);
      expect(find.text('You have the turn'), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
      expect(find.text('You are #2 in line.'), findsNothing);
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Your turn. Send your message.'),
        ),
        isSemantics(
          label: 'Your turn. Send your message.',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );

      await tester.tap(find.text('You have the turn'), warnIfMissed: false);
      await tester.pump();
      expect(requests, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a requested turn is announced as queued and disabled', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var requests = 0;
    try {
      await _pump(
        tester,
        CollabTurnBanner(
          data: _data(
            turnRequested: true,
            queue: const [
              V2CollabTurnWaiter(name: 'Elena Chen'),
              V2CollabTurnWaiter(name: 'Aarav', isYou: true),
            ],
          ),
          onRequestTurn: () => requests++,
        ),
        OTheme.light(),
      );

      expect(find.text('In queue'), findsOneWidget);
      expect(find.text('(you)'), findsOneWidget);
      expect(find.text('You are #2 in line.'), findsOneWidget);
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('In queue. You asked to send next.'),
        ),
        isSemantics(
          label: 'In queue. You asked to send next.',
          isButton: true,
          hasEnabledState: true,
          isEnabled: false,
        ),
      );

      await tester.tap(find.text('In queue'), warnIfMissed: false);
      await tester.pump();
      expect(requests, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a free turn offers the next action', (tester) async {
    var requests = 0;
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(
          status: V2CollabTurnBannerStatus.empty,
          holderName: '',
          timeLeftFraction: null,
          queue: const [],
        ),
        onRequestTurn: () => requests++,
      ),
      OTheme.dark(),
    );

    expect(find.text('Turn is free'), findsOneWidget);
    expect(find.text('Take the turn'), findsOneWidget);
    expect(find.text('Nobody is sending right now.'), findsOneWidget);
    expect(find.textContaining('One message at a time'), findsOneWidget);

    await tester.tap(find.text('Take the turn'));
    await tester.pump();
    expect(requests, 1);
  });

  testWidgets('a ready banner without a holder falls back to the free turn', (
    tester,
  ) async {
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(holderName: '', timeLeftFraction: null, queue: const []),
      ),
      OTheme.light(),
    );

    expect(find.text('Turn is free'), findsOneWidget);
    expect(find.text('Current turn'), findsNothing);
  });

  testWidgets('error state offers a retry that fires', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(status: V2CollabTurnBannerStatus.error),
        onRetry: () => retries++,
      ),
      OTheme.light(),
    );

    expect(find.text('We could not load the turn.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
  });

  testWidgets('loading state shows placeholders instead of stale turn data', (
    tester,
  ) async {
    await _pump(
      tester,
      CollabTurnBanner(data: _data(status: V2CollabTurnBannerStatus.loading)),
      OTheme.light(),
    );

    expect(find.text('Rahul Verma'), findsNothing);
    expect(find.text('Request turn'), findsNothing);
    expect(find.byType(OSkeleton), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long queues collapse into a view-all row', (tester) async {
    var viewed = 0;
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(
          maxVisibleQueue: 2,
          queue: const [
            V2CollabTurnWaiter(name: 'Priya Patel'),
            V2CollabTurnWaiter(name: 'Elena Chen'),
            V2CollabTurnWaiter(name: 'Marcus Vance'),
            V2CollabTurnWaiter(name: 'Kenji Sato'),
            V2CollabTurnWaiter(name: 'Lena Fischer'),
          ],
        ),
        onViewQueue: () => viewed++,
      ),
      OTheme.light(),
    );

    expect(find.text('5 people'), findsOneWidget);
    expect(find.text('Priya Patel'), findsOneWidget);
    expect(find.text('Elena Chen'), findsOneWidget);
    expect(find.text('Marcus Vance'), findsNothing);
    expect(find.text('+3 more waiting'), findsOneWidget);

    await tester.ensureVisible(find.text('View all'));
    await tester.pump();
    await tester.tap(find.text('View all'));
    await tester.pump();
    expect(viewed, 1);
  });

  testWidgets('an empty queue says so and keeps the request action', (
    tester,
  ) async {
    await _pump(
      tester,
      CollabTurnBanner(data: _data(queue: const [])),
      OTheme.light(),
    );

    expect(
      find.text('Nobody else is waiting. Request the turn to go next.'),
      findsOneWidget,
    );
    expect(find.text('Request turn'), findsOneWidget);
  });

  testWidgets('a free turn still lists the people waiting', (tester) async {
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(
          status: V2CollabTurnBannerStatus.empty,
          holderName: '',
          timeLeftFraction: null,
        ),
      ),
      OTheme.dark(),
    );

    expect(find.text('Turn is free'), findsOneWidget);
    expect(find.text('2 people'), findsOneWidget);
    expect(find.text('Priya Patel'), findsOneWidget);
    expect(find.text('Take the turn'), findsOneWidget);
  });

  testWidgets('a free turn you already hold counts the people after you', (
    tester,
  ) async {
    await _pump(
      tester,
      CollabTurnBanner(
        data: _data(
          status: V2CollabTurnBannerStatus.empty,
          holderName: 'Aarav',
          timeLeftFraction: null,
          isMyTurn: true,
        ),
      ),
      OTheme.light(),
    );

    expect(find.text('Your turn'), findsOneWidget);
    expect(find.text('You have the turn'), findsOneWidget);
    expect(find.text('2 people are waiting next.'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });

  testWidgets('fits 320 dp at 200 % text in light and dark', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const longQueue = [
      V2CollabTurnWaiter(
        name: 'Priya Patel-Ramanathan',
        waitLabel: 'about 1m 12s',
      ),
      V2CollabTurnWaiter(
        name: 'Elena Chen-Washington',
        waitLabel: 'about 2m 40s',
        isYou: true,
      ),
      V2CollabTurnWaiter(name: 'Marcus Vance', waitLabel: 'about 4m'),
    ];

    for (final theme in [OTheme.light(), OTheme.dark()]) {
      for (final data in [
        _data(queue: longQueue, queueLabel: 'About 3m until your turn'),
        _data(holderName: 'Aarav', isMyTurn: true, queue: longQueue),
        _data(turnRequested: true, queue: longQueue),
        _data(
          status: V2CollabTurnBannerStatus.empty,
          holderName: '',
          timeLeftFraction: null,
          queue: const [],
        ),
        _data(status: V2CollabTurnBannerStatus.error),
        _data(status: V2CollabTurnBannerStatus.loading),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CollabTurnBanner(
                  data: data,
                  onRequestTurn: () {},
                  onRetry: () {},
                  onViewQueue: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 900));

        expect(tester.takeException(), isNull, reason: 'status ${data.status}');
        if (data.status == V2CollabTurnBannerStatus.ready) {
          expect(
            find.textContaining('One message at a time'),
            findsOneWidget,
            reason: 'status ${data.status}',
          );
        }
      }
    }
  });

  testWidgets('reduced motion still renders the banner', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.dark(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: CollabTurnBanner(
                data: _data(holderName: 'Aarav', isMyTurn: true),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Rahul Verma'), findsNothing);
    expect(find.text('Aarav (you)'), findsOneWidget);
    expect(find.text('Request turn'), findsNothing);
  });
}
