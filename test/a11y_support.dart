import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';

export 'package:flutter_test/flutter_test.dart';

/// Pumps [child] wrapped in a [MaterialApp] using the Ovid Si theme.
///
/// [size] sets the physical window size; [textScaler] sets the ambient text
/// scaler. Both are reset on tear down.
Future<void> pumpA11yScreen(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double textScale = 1.0,
  bool dark = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      debugShowCheckedModeBanner: false,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

/// Asserts the three built-in a11y guidelines against the current widget tree.
Future<void> expectA11yGuidelines(
  WidgetTester tester,
  String scope, {
  bool tapTarget = true,
  bool labeled = true,
  bool contrast = true,
}) async {
  if (tapTarget) {
    await expectLater(
      tester,
      meetsGuideline(androidTapTargetGuideline),
      reason: '$scope failed androidTapTargetGuideline',
    );
  }
  if (labeled) {
    await expectLater(
      tester,
      meetsGuideline(labeledTapTargetGuideline),
      reason: '$scope failed labeledTapTargetGuideline',
    );
  }
  if (contrast) {
    await expectLater(
      tester,
      meetsGuideline(textContrastGuideline),
      reason: '$scope failed textContrastGuideline',
    );
  }
}

/// Runs a11y guideline checks for [textScale] values 1.0, 1.5 and 2.0.
///
/// The [pump] callback must pump the widget at the requested scale and the
/// [name] is used in failure messages.
Future<void> expectA11yAtScales(
  WidgetTester tester,
  String name,
  Future<void> Function(double scale) pump,
) async {
  for (final scale in const [1.0, 1.5, 2.0]) {
    await pump(scale);
    final handle = tester.ensureSemantics();
    await expectA11yGuidelines(tester, '$name scale=$scale');
    handle.dispose();
  }
}
