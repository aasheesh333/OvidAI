import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';

/// Accessibility ratchet for every registered v2 screen: the smallest phone
/// width we support, doubled text, light and dark. Any overflow, unbounded
/// constraint or build exception fails the gate.
///
/// The loop is empty until `v2_registry.dart` is populated; that is deliberate
/// so the gate lands before the screens do and cannot be skipped later.
void main() {
  for (final entry in v2Screens) {
    for (final dark in [false, true]) {
      testWidgets(
        '${entry.id} survives 320 dp and 200% text (${dark ? 'dark' : 'light'})',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          Widget child = Builder(builder: entry.builder);
          if (entry.isSheet) {
            child = Scaffold(body: child);
          }
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? OTheme.dark() : OTheme.light(),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 640),
                  textScaler: TextScaler.linear(2),
                ),
                child: child,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));

          expect(
            tester.takeException(),
            isNull,
            reason: '${entry.title} overflows at 320 dp / 200% text',
          );
        },
      );
    }
  }
}
