import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/main.dart' as app;

/// A blank surface is indistinguishable from a frozen app. This guards the
/// boot path: whatever the platform does, the first frames must paint.
void main() {
  testWidgets('boot paints a screen even when lock state never answers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const app.OvidApp());
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    }

    expect(AppLock.I.loaded, isTrue, reason: 'lock state must settle');
    expect(
      find.byType(Scaffold),
      findsWidgets,
      reason: 'boot must paint a Scaffold, not an empty surface',
    );
  });
}
