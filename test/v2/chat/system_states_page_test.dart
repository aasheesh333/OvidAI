import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/states/system_states_page.dart';

Widget _app(Widget home, {bool dark = false}) =>
    MaterialApp(theme: dark ? OTheme.dark() : OTheme.light(), home: home);

Future<void> _tall(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('renders all four calm states in light', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(find.text('System states'), findsOneWidget);
    expect(find.text('Start with a hello'), findsOneWidget);
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Daily limit reached'), findsOneWidget);
    expect(find.text('Resets soon'), findsOneWidget);
    expect(find.text('See plans'), findsOneWidget);
    expect(
      find.text(
        'Your chats and files stay safe in every state. Nothing is lost.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders all four states in dark', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage(), dark: true));
    await tester.pumpAndSettle();

    expect(find.text('Start with a hello'), findsOneWidget);
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Daily limit reached'), findsOneWidget);
  });

  testWidgets('every state action fires', (tester) async {
    await _tall(tester);
    var examples = 0;
    var retries = 0;
    var again = 0;
    var details = 0;
    var plans = 0;
    await tester.pumpWidget(
      _app(
        V2SystemStatesPage(
          onTryExample: () => examples++,
          onRetryConnection: () => retries++,
          onTryAgain: () => again++,
          onViewErrorDetails: () => details++,
          onSeePlans: () => plans++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Try an example prompt'));
    await tester.tap(find.text('Retry connection'));
    await tester.tap(find.text('Try again'));
    await tester.tap(find.text('View error details'));
    await tester.tap(find.text('See plans'));

    expect(examples, 1);
    expect(retries, 1);
    expect(again, 1);
    expect(details, 1);
    expect(plans, 1);
  });

  testWidgets('reset countdown comes from injected data', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(
      _app(
        const V2SystemStatesPage(
          data: V2SystemStatesData(limitResetLabel: 'Resets in 2h 05m'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Resets in 2h 05m'), findsOneWidget);
    expect(find.text('Resets soon'), findsNothing);
  });

  testWidgets('actions without callbacks are disabled and announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(
      tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
      isNull,
    );
    final node = tester.getSemantics(find.bySemanticsLabel('See plans').first);
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    handle.dispose();
  });

  for (final dark in [false, true]) {
    testWidgets(
      '320 dp at 200% text lays out cleanly (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: const MediaQuery(
              data: MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: V2SystemStatesPage(),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        for (final error in errors) {
          debugPrint(error.toString());
        }
        expect(errors, isEmpty);

        // The body scrolls, so every state and action stays reachable.
        await tester.scrollUntilVisible(
          find.text('See plans'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('See plans'), findsOneWidget);
      },
    );
  }

  testWidgets('offline copy promises messages will send later', (tester) async {
    await _tall(tester);
    await tester.pumpWidget(_app(const V2SystemStatesPage()));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No internet connection detected. Your messages will send when you reconnect.',
      ),
      findsOneWidget,
    );
  });
}
