import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/main.dart' show ShareLinkOpener;

void main() {
  final token = 'A' * 43;
  final uri = Uri.parse('https://ovidsi.com/s/$token');

  Route<void> viewer(String t) => MaterialPageRoute<void>(
    builder: (_) => Scaffold(body: Text('viewer $t')),
  );

  testWidgets('same link twice with a pop in between pushes twice', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    var pushes = 0;
    final opener = ShareLinkOpener(
      navigatorKey: key,
      routeBuilder: (t) {
        pushes++;
        return viewer(t);
      },
    );
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Text('home')),
    );

    opener.open(uri);
    // A duplicate while the first open is in flight is ignored.
    opener.open(uri);
    await tester.pumpAndSettle();
    expect(pushes, 1);
    expect(find.text('viewer $token'), findsOneWidget);

    key.currentState!.pop();
    await tester.pumpAndSettle();
    expect(opener.inFlightTokens, isEmpty);

    opener.open(uri);
    await tester.pumpAndSettle();
    expect(pushes, 2);
    expect(find.text('viewer $token'), findsOneWidget);
  });

  testWidgets('waits for a late navigator without a pointer event', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    final opener = ShareLinkOpener(navigatorKey: key, routeBuilder: viewer);
    await tester.pumpWidget(const SizedBox());

    opener.open(uri);
    // Navigator absent for a few frames; each retry schedules its own frame.
    for (var i = 0; i < 3; i++) {
      expect(tester.binding.hasScheduledFrame, isTrue);
      await tester.pump();
    }
    expect(opener.inFlightTokens, contains(token));

    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Text('home')),
    );
    await tester.pumpAndSettle();
    expect(find.text('viewer $token'), findsOneWidget);
  });

  testWidgets('gives up after the retry cap and releases the token', (
    tester,
  ) async {
    final key = GlobalKey<NavigatorState>();
    final opener = ShareLinkOpener(
      navigatorKey: key,
      routeBuilder: viewer,
      maxAttempts: 3,
    );
    await tester.pumpWidget(const SizedBox());
    opener.open(uri);
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(opener.inFlightTokens, isEmpty);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
