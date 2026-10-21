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
  testWidgets('take control sheet shows the countdown and both choices', (
    tester,
  ) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(countdownLabel: 'Ovid is driving this page'),
        onStart: () {},
        onStayWatching: () {},
        onToggleKeyboard: () {},
        onToggleTrackpad: () {},
      ),
    );

    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Ovid is driving this page'), findsOneWidget);
    expect(find.text('Start controlling'), findsOneWidget);
    expect(find.text('Stay watching'), findsOneWidget);
    expect(find.text('Show keyboard'), findsOneWidget);
    expect(find.text('Trackpad'), findsOneWidget);
  });

  testWidgets('take control sheet renders in dark theme', (tester) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(countdownLabel: 'Ovid is driving this page'),
        onStart: () {},
        onStayWatching: () {},
      ),
      theme: OTheme.dark(),
    );

    expect(find.text('Take control'), findsOneWidget);
    expect(find.text('Ovid is driving this page'), findsOneWidget);
  });

  testWidgets('ended session shows an empty state and a way back', (
    tester,
  ) async {
    var stays = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(status: V2TakeControlStatus.ended),
        onStayWatching: () => stays++,
      ),
    );

    expect(find.text('Session ended'), findsOneWidget);
    expect(find.text('Back to browser'), findsOneWidget);

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

  testWidgets('trackpad chip toggles the control tool', (tester) async {
    var toggles = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onToggleTrackpad: () => toggles++,
      ),
    );

    await tester.tap(find.text('Trackpad'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(toggles, 1);
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

  testWidgets('sheet explains what pauses and when Ovid resumes', (
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

    expect(find.text('What pauses'), findsOneWidget);
    expect(
      find.text(
        'Clicks and scrolling · Typing and form entries · '
        'Opening new pages',
      ),
      findsOneWidget,
    );
    // No invented 45 s deadline: the server puts no timer on human control.
    expect(
      find.text('Ovid stays paused until you hand control back.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('45 s'),
      findsNothing,
    );
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

  testWidgets('keyboard chip toggles the control tool', (tester) async {
    var toggles = 0;
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(),
        onToggleKeyboard: () => toggles++,
      ),
    );

    await tester.tap(find.text('Show keyboard'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(toggles, 1);
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
        onToggleKeyboard: () {},
        onToggleTrackpad: () {},
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
      TakeControlSheet(data: const V2TakeControlData()),
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

  testWidgets('countdown pill is not clipped at 200 % text', (tester) async {
    await _pumpNarrow(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(
          countdownLabel: 'Ovid is driving this page',
        ),
        onStart: () {},
        onStayWatching: () {},
      ),
    );

    final pill = find.text('Ovid is driving this page');
    expect(pill, findsOneWidget);
    final textHeight = tester.getSize(pill).height;
    // A 12 pt caption at 200 % needs ~33.6 dp of line box; anything less means
    // the label was squeezed or clipped.
    expect(textHeight, greaterThanOrEqualTo(32));
  });

  testWidgets('control chips expose one clean semantics node', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(keyboard: true),
        onToggleKeyboard: () {},
      ),
    );

    expect(
      tester.getSemantics(find.text('Show keyboard')),
      matchesSemantics(
        label: 'Show keyboard',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a chip with no callback is not rendered', (tester) async {
    await _pump(tester, TakeControlSheet(data: const V2TakeControlData()));

    // A tool that cannot drive the page is not offered at all.
    expect(find.text('Trackpad'), findsNothing);
    expect(find.text('Show keyboard'), findsNothing);
    expect(find.text('Start controlling'), findsNothing);
    expect(find.text('Stay watching'), findsNothing);
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

  testWidgets('the trackpad chip mirrors the state handed over by the page', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(keyboard: true, trackpad: true),
        onToggleKeyboard: () {},
        onToggleTrackpad: () {},
      ),
    );

    expect(
      tester.getSemantics(find.text('Trackpad')),
      matchesSemantics(
        label: 'Trackpad',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('an ended session drops the stale countdown', (tester) async {
    await _pump(
      tester,
      TakeControlSheet(
        data: const V2TakeControlData(
          status: V2TakeControlStatus.ended,
          countdownLabel: 'Ovid is driving this page',
        ),
      ),
    );

    expect(find.text('Ovid is driving this page'), findsNothing);
    expect(find.text('Session ended'), findsOneWidget);
  });
}
