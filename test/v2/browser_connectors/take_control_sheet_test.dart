import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/browser/take_control_sheet.dart';

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(_app(child, theme: theme));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Pumps the sheet on a 320 dp wide phone at 200 % text. Any RenderFlex
/// overflow surfaces as a framework exception, which fails the test.
Future<void> _pumpNarrow(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double textScale = 2,
}) async {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(320, 700),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets('ready sheet is one title, one line and two buttons', (
    tester,
  ) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStart: () {},
        onStayWatching: () {},
      ),
    );

    expect(find.text('Take control'), findsOneWidget);
    expect(
      find.text('Tap, type and scroll. Ovid pauses until you hand back.'),
      findsOneWidget,
    );
    expect(find.text('Start controlling'), findsOneWidget);
    expect(find.text('Stay watching'), findsOneWidget);

    // The old explainer blocks are gone.
    expect(find.text('What pauses'), findsNothing);
    expect(find.text('Show keyboard'), findsNothing);
    expect(find.text('Trackpad'), findsNothing);
    expect(
      find.text('Ovid stays paused until you hand control back.'),
      findsNothing,
    );
  });

  testWidgets('ready sheet renders in dark theme', (tester) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStart: () {},
        onStayWatching: () {},
      ),
      theme: OTheme.dark(),
    );

    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Start controlling'), findsOneWidget);
  });

  testWidgets('ended session shows one line and a way back', (tester) async {
    var stays = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(status: V2TakeControlStatus.ended),
        onStayWatching: () => stays++,
      ),
    );

    expect(find.text('Session ended'), findsOneWidget);
    expect(find.text('Ovid is watching this tab again.'), findsOneWidget);

    await tester.tap(find.text('Back to browser'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stays, 1);
  });

  testWidgets('start controlling is the primary callback', (tester) async {
    var starts = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStart: () => starts++,
      ),
    );

    await tester.tap(find.text('Start controlling'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(starts, 1);
  });

  testWidgets('stay watching dismisses the sheet', (tester) async {
    var stays = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStayWatching: () => stays++,
      ),
    );

    await tester.ensureVisible(find.text('Stay watching'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Stay watching'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stays, 1);
  });

  testWidgets('a sheet with no callbacks offers no dead buttons', (
    tester,
  ) async {
    await _pump(tester, TakeControlSheet(data: const V2TakeControlData()));

    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Start controlling'), findsNothing);
    expect(find.text('Stay watching'), findsNothing);
  });

  testWidgets('loading state says Ovid is pausing', (tester) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(status: V2TakeControlStatus.loading),
      ),
    );

    expect(find.text('Pausing Ovid…'), findsOneWidget);
  });

  testWidgets('error state offers a retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(status: V2TakeControlStatus.error),
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Could not pause'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(retries, 1);
  });

  testWidgets('ready sheet fits 320 dp at 200 % text', (tester) async {
    await _pumpNarrow(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStart: () {},
        onStayWatching: () {},
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Take control'), findsOneWidget);
  });

  testWidgets('ready sheet fits 320 dp at 200 % text in dark theme', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStart: () {},
        onStayWatching: () {},
      ),
      theme: OTheme.dark(),
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('loading, ended and error states fit 320 dp at 200 % text', (
    tester,
  ) async {
    for (final status in <V2TakeControlStatus>[
      V2TakeControlStatus.loading,
      V2TakeControlStatus.ended,
      V2TakeControlStatus.error,
    ]) {
      await _pumpNarrow(
        tester,
        TakeControlSheet(
          data: V2TakeControlData(status: status),
          onRetry: () {},
          onStayWatching: () {},
        ),
      );
      expect(tester.takeException(), isNull, reason: 'status $status');
    }
  });

  testWidgets('tapping the scrim stays watching', (tester) async {
    var stays = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onStayWatching: () => stays++,
      ),
    );

    await tester.tapAt(const Offset(12, 12));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stays, 1);
  });
}
