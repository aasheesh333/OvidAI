import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/app_lock_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime(2026, 10, 21, 12);
  });

  AppLock newLock() => AppLock(now: () => now, random: Random(5));

  Future<AppLock> lockedLock({String pin = '1234'}) async {
    final lock = newLock();
    await lock.load();
    await lock.setPin(pin);
    await lock.markBackgrounded(at: now);
    now = now.add(const Duration(minutes: 3));
    await lock.markResumed(at: now);
    expect(lock.locked, isTrue);
    return lock;
  }

  Widget app({
    required AppLock lock,
    bool dark = false,
    Widget? child,
    BiometricCheck? biometric,
    VoidCallback? onSignOut,
  }) {
    return MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: AppLockGate(
        lock: lock,
        biometric: biometric,
        onSignOut: onSignOut,
        child:
            child ?? const Scaffold(body: Center(child: Text('Secret chat'))),
      ),
    );
  }

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final digit in pin.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
  }

  testWidgets('cold start with a PIN never locks the first frame', (
    tester,
  ) async {
    final lock = newLock();
    await lock.load();
    await lock.setPin('1234');

    await tester.pumpWidget(app(lock: lock));
    await tester.pump();

    expect(find.text('Secret chat'), findsOneWidget);
    expect(find.text('App locked'), findsNothing);
    expect(lock.locked, isFalse);
  });

  testWidgets('locked gate hides the child and unlocks with the PIN', (
    tester,
  ) async {
    final lock = await lockedLock();
    await tester.pumpWidget(app(lock: lock));
    await tester.pump();

    expect(find.text('App locked'), findsOneWidget);
    expect(find.text('Secret chat'), findsNothing);

    await enterPin(tester, '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    await tester.pump();

    expect(lock.locked, isFalse);
    expect(find.text('Secret chat'), findsOneWidget);
    expect(find.text('App locked'), findsNothing);
  });

  testWidgets('a wrong PIN shows an error and clears the entry', (
    tester,
  ) async {
    final lock = await lockedLock();
    await tester.pumpWidget(app(lock: lock));
    await tester.pump();

    await enterPin(tester, '0000');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Wrong PIN. Try again.'), findsOneWidget);
    expect(find.text('App locked'), findsOneWidget);
    expect(lock.locked, isTrue);

    // The entry was cleared: four correct digits still unlock.
    await enterPin(tester, '1234');
    await tester.tap(find.text('Unlock'));
    await tester.pump();
    await tester.pump();
    expect(lock.locked, isFalse);
  });

  testWidgets('five failures show the cooldown countdown and disable unlock', (
    tester,
  ) async {
    final lock = await lockedLock();
    for (var i = 0; i < AppLock.maxAttempts; i++) {
      expect(await lock.unlock('0000'), isFalse);
    }
    expect(lock.inCooldown, isTrue);

    await tester.pumpWidget(app(lock: lock));
    await tester.pump();

    expect(find.textContaining('Too many attempts'), findsOneWidget);
    expect(find.textContaining('30s'), findsOneWidget);

    final unlock = tester.widget<OButton>(
      find.widgetWithText(OButton, 'Unlock'),
    );
    expect(unlock.onPressed, isNull);

    // A digit press during the cooldown does not change the entry.
    await tester.tap(find.text('1'));
    await tester.pump();
    expect(find.text('Wrong PIN. Try again.'), findsNothing);

    // Dispose the gate so its countdown timer is cancelled.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('biometrics button only renders with a hook and unlocks', (
    tester,
  ) async {
    final lock = await lockedLock();
    await tester.pumpWidget(app(lock: lock));
    await tester.pump();
    expect(find.text('Use biometrics'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    final lockAgain = await lockedLock();
    var checks = 0;
    await tester.pumpWidget(
      app(
        lock: lockAgain,
        biometric: () async {
          checks++;
          return true;
        },
      ),
    );
    await tester.pump();

    expect(find.text('Use biometrics'), findsOneWidget);
    await tester.tap(find.text('Use biometrics'));
    await tester.pump();
    await tester.pump();

    expect(checks, 1);
    expect(lockAgain.locked, isFalse);
    expect(find.text('Secret chat'), findsOneWidget);
  });

  testWidgets('a failed biometric check keeps the lock and explains why', (
    tester,
  ) async {
    final lock = await lockedLock();
    await tester.pumpWidget(app(lock: lock, biometric: () async => false));
    await tester.pump();

    await tester.tap(find.text('Use biometrics'));
    await tester.pump();
    await tester.pump();

    expect(lock.locked, isTrue);
    expect(find.text('Biometrics did not match.'), findsOneWidget);
  });

  testWidgets('sign out instead invokes the host callback', (tester) async {
    final lock = await lockedLock();
    var signedOut = false;
    await tester.pumpWidget(app(lock: lock, onSignOut: () => signedOut = true));
    await tester.pump();

    expect(find.text('Sign out instead'), findsOneWidget);
    await tester.tap(find.text('Sign out instead'));
    await tester.pump();
    expect(signedOut, isTrue);
    expect(lock.locked, isTrue, reason: 'the gate never signs out on its own');
  });

  testWidgets('sign out is hidden when the host provides no callback', (
    tester,
  ) async {
    final lock = await lockedLock();
    await tester.pumpWidget(app(lock: lock));
    await tester.pump();
    expect(find.text('Sign out instead'), findsNothing);
  });

  testWidgets('lifecycle: inactive is ignored, a real pause locks on resume', (
    tester,
  ) async {
    final lock = newLock();
    await lock.load();
    await lock.setPin('1234');
    await tester.pumpWidget(app(lock: lock));
    await tester.pump();
    expect(find.text('Secret chat'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    now = now.add(const Duration(minutes: 5));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(lock.locked, isFalse, reason: 'inactive is transient, not a pause');
    expect(find.text('Secret chat'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    now = now.add(const Duration(minutes: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(lock.locked, isTrue);
    expect(find.text('App locked'), findsOneWidget);
    expect(find.text('Secret chat'), findsNothing);

    // Restore the binding for the remaining tests.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  for (final dark in [false, true]) {
    testWidgets(
      'lock screen survives 320 dp / 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final lock = await lockedLock();
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: AppLockGate(
                lock: lock,
                child: const Scaffold(body: Center(child: Text('Secret chat'))),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.text('App locked'), findsOneWidget);

        for (final digit in ['1', '2', '3', '4']) {
          await tester.ensureVisible(find.text(digit));
          await tester.tap(find.text(digit));
          await tester.pump();
        }
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('Unlock'));
        await tester.tap(find.text('Unlock'));
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(lock.locked, isFalse);
        expect(find.text('Secret chat'), findsOneWidget);
      },
    );
  }
}
