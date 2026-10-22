import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';

/// Pumps [child] at a real viewport size with a real text scale.
///
/// The size is applied to the test view, so [MediaQuery.sizeOf] and the actual
/// layout constraints agree: a 600 dp test really lays out at 600 dp.
Future<void> pumpAt(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(412, 900),
  double textScale = 1,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, appChild) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: appChild!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 400));
}

/// 320 dp at 200 % text: the tightest supported layout.
Future<void> pumpNarrow(
  WidgetTester tester,
  Widget child, {
  bool dark = false,
}) => pumpAt(
  tester,
  child,
  size: const Size(320, 640),
  textScale: 2,
  dark: dark,
);

/// 900 dp wide: the desktop band where content must centre and cap.
Future<void> pumpTablet(WidgetTester tester, Widget child) =>
    pumpAt(tester, child, size: const Size(900, 900));

/// Exactly 600 dp: the first width in the tablet band.
Future<void> pumpAt600(WidgetTester tester, Widget child) =>
    pumpAt(tester, child, size: const Size(600, 900));

/// Width of the first [finder] widget.
double widthOf(WidgetTester tester, Finder finder) =>
    tester.getSize(finder).width;
