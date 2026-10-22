import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/main.dart' as app;

/// A blank surface is indistinguishable from a frozen app. This guards the
/// boot path: whatever the platform does, the first frames must paint.
void main() {
  // The boot path starts services the app expects to live for the process
  // (lock state, push, account features). A widget test must hand them back,
  // or their timers outlive the tree and fail the next teardown.
  tearDown(() {
    AppLock.I.dispose();
    AppState.resetTestInstance();
  });

  testWidgets('boot paints a screen even when lock state never answers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const app.OvidApp());
    // Pump past every boot bound *in sequence*: the auth initialize bound is
    // 30 s, and only after it elapses is the 10 s store bound armed. A hung
    // dependency must still leave a painted screen, and no timer may outlive
    // the frame it was armed for.
    for (var i = 0; i < 460; i++) {
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
