import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();
  late DateTime now;
  late AppLock lock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime(2026, 10, 21, 12);
    lock = AppLock(now: () => now, random: Random(42));
  });

  Future<void> backgroundFor(AppLock target, Duration elapsed) async {
    await target.markBackgrounded(at: now);
    now = now.add(elapsed);
    await target.markResumed(at: now);
  }

  group('PIN storage', () {
    test('stores a salted SHA-256 hash and never the plaintext PIN', () async {
      await lock.load();
      expect(await lock.setPin('0123'), isTrue);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isFalse);

      final salt = await storage.read(key: AppLock.saltStorageKey);
      final hash = await storage.read(key: AppLock.hashStorageKey);
      expect(salt, isNotNull);
      expect(hash, isNotNull);
      expect(hash, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(hash, isNot('0123'));
      expect(hash, isNot(sha256.convert(utf8.encode('0123')).toString()));
      expect(hash, sha256.convert(utf8.encode('$salt:0123')).toString());

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(
          '${prefs.get(key)}',
          isNot(contains('0123')),
          reason: 'preference $key must not contain the PIN',
        );
      }
      expect(salt, isNot(contains('0123')));
    });

    test('regenerates the salt when the PIN changes', () async {
      await lock.load();
      expect(await lock.setPin('1234'), isTrue);
      final firstSalt = await storage.read(key: AppLock.saltStorageKey);
      final firstHash = await storage.read(key: AppLock.hashStorageKey);

      expect(await lock.setPin('5678', currentPin: '1234'), isTrue);
      final secondSalt = await storage.read(key: AppLock.saltStorageKey);
      final secondHash = await storage.read(key: AppLock.hashStorageKey);

      expect(secondSalt, isNot(firstSalt));
      expect(secondHash, isNot(firstHash));
    });

    test('rejects PINs outside 4–6 digits', () async {
      await lock.load();
      for (final bad in ['', '123', '1234567', '12a4', ' 1234', '1234 ']) {
        expect(await lock.setPin(bad), isFalse, reason: 'accepted "$bad"');
        expect(lock.enabled, isFalse);
      }
      expect(await lock.setPin('0000'), isTrue);
      expect(await lock.setPin('999999', currentPin: '0000'), isTrue);
    });

    test('changing a PIN requires the current one', () async {
      await lock.load();
      await lock.setPin('1234');
      expect(await lock.setPin('5678'), isFalse);
      expect(lock.failedAttempts, 1);
      expect(await lock.setPin('5678', currentPin: '0000'), isFalse);
      expect(await lock.setPin('5678', currentPin: '1234'), isTrue);

      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);
      expect(await lock.unlock('1234'), isFalse);
      expect(await lock.unlock('5678'), isTrue);
    });
  });

  group('unlock', () {
    test('wrong PIN keeps the lock, correct PIN removes it', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);

      expect(await lock.unlock('9999'), isFalse);
      expect(lock.locked, isTrue);
      expect(lock.failedAttempts, 1);

      expect(await lock.unlock('1234'), isTrue);
      expect(lock.locked, isFalse);
      expect(lock.failedAttempts, 0);
    });

    test('unlock is a no-op while the app is not locked', () async {
      await lock.load();
      await lock.setPin('1234');
      expect(await lock.unlock('0000'), isTrue);
      expect(lock.locked, isFalse);
      expect(lock.failedAttempts, 0);
    });
  });

  group('rate limit', () {
    test('five wrong attempts start a 30 second cooldown', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));

      for (var i = 1; i < AppLock.maxAttempts; i++) {
        expect(await lock.unlock('0000'), isFalse);
        expect(lock.inCooldown, isFalse, reason: 'cooldown after $i attempts');
        expect(lock.attemptsRemaining, AppLock.maxAttempts - i);
      }
      expect(await lock.unlock('0000'), isFalse);

      expect(lock.inCooldown, isTrue);
      expect(lock.attemptsRemaining, 0);
      expect(lock.cooldownRemaining, greaterThan(const Duration(seconds: 29)));
      expect(lock.cooldownSecondsRemaining, 30);

      // Even the right PIN is refused while the countdown runs.
      expect(await lock.unlock('1234'), isFalse);
      expect(lock.locked, isTrue);

      now = now.add(const Duration(seconds: 30));
      expect(lock.inCooldown, isFalse);
      expect(await lock.unlock('1234'), isTrue);
      expect(lock.locked, isFalse);
    });

    test('attempts and the cooldown survive a process restart', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));

      for (var i = 0; i < 3; i++) {
        expect(await lock.unlock('0000'), isFalse);
      }

      final restarted = AppLock(now: () => now, random: Random(7));
      await restarted.load();
      expect(restarted.enabled, isTrue);
      expect(restarted.locked, isFalse);
      expect(restarted.failedAttempts, 3);
      expect(restarted.attemptsRemaining, 2);

      await backgroundFor(restarted, const Duration(minutes: 3));
      expect(restarted.locked, isTrue);
      expect(await restarted.unlock('0000'), isFalse);
      expect(await restarted.unlock('0000'), isFalse);
      expect(restarted.inCooldown, isTrue);

      final restartedAgain = AppLock(now: () => now, random: Random(8));
      await restartedAgain.load();
      expect(restartedAgain.inCooldown, isTrue);
      expect(
        restartedAgain.cooldownRemaining,
        greaterThan(const Duration(seconds: 29)),
      );
      // Lock again without waiting out the cooldown: zero idle timeout.
      await restartedAgain.setLockAfter(Duration.zero);
      await restartedAgain.markBackgrounded(at: now);
      now = now.add(const Duration(seconds: 1));
      await restartedAgain.markResumed(at: now);
      expect(restartedAgain.locked, isTrue);
      expect(await restartedAgain.unlock('1234'), isFalse);

      now = now.add(const Duration(seconds: 31));
      final afterCooldown = AppLock(now: () => now, random: Random(9));
      await afterCooldown.load();
      expect(afterCooldown.inCooldown, isFalse);
      // A restart does not lock the app; unlock() reports the existing state.
      expect(afterCooldown.locked, isFalse);
      expect(afterCooldown.failedAttempts, 0);
    });
  });

  group('timeout', () {
    test('defaults to two minutes and respects the boundary', () async {
      await lock.load();
      expect(lock.lockAfter, const Duration(minutes: 2));
      await lock.setPin('1234');

      await backgroundFor(lock, const Duration(minutes: 2));
      expect(
        lock.locked,
        isFalse,
        reason: 'elapsed == lockAfter does not lock',
      );

      await backgroundFor(lock, const Duration(minutes: 2, milliseconds: 1));
      expect(lock.locked, isTrue);
    });

    test('a shorter lockAfter is persisted', () async {
      await lock.load();
      await lock.setPin('1234');
      await lock.setLockAfter(const Duration(seconds: 30));

      final restarted = AppLock(now: () => now, random: Random(11));
      await restarted.load();
      expect(restarted.lockAfter, const Duration(seconds: 30));

      await backgroundFor(restarted, const Duration(seconds: 31));
      expect(restarted.locked, isTrue);
    });

    test('inactive alone never locks the app', () async {
      await lock.load();
      await lock.setPin('1234');

      await lock.handleLifecycleState(AppLifecycleState.inactive);
      now = now.add(const Duration(hours: 1));
      await lock.handleLifecycleState(AppLifecycleState.resumed);

      expect(lock.locked, isFalse);
    });

    test('paused then resumed after the timeout locks', () async {
      await lock.load();
      await lock.setPin('1234');

      await lock.handleLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 3));
      await lock.handleLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('a cold start without a background never locks', () async {
      await lock.load();
      await lock.setPin('1234');

      final cold = AppLock(now: () => now, random: Random(12));
      await cold.load();
      expect(cold.enabled, isTrue);
      expect(cold.locked, isFalse);
      expect(await cold.markResumed(at: now), isFalse);
    });

    test('a cold start after a real background locks', () async {
      await lock.load();
      await lock.setPin('1234');
      await lock.markBackgrounded(at: now);
      now = now.add(const Duration(minutes: 5));

      final cold = AppLock(now: () => now, random: Random(13));
      await cold.load();
      expect(cold.locked, isTrue);
    });
  });

  group('disable', () {
    test('disabled by default and never locks', () async {
      await lock.load();
      expect(lock.enabled, isFalse);
      expect(await lock.unlock('1234'), isTrue);

      await backgroundFor(lock, const Duration(hours: 1));
      expect(lock.locked, isFalse);
    });

    test('requires the current PIN and removes the stored secret', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);

      expect(await lock.disable('0000'), isFalse);
      expect(lock.enabled, isTrue);
      expect(lock.failedAttempts, 1);

      expect(await lock.disable('1234'), isTrue);
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      expect(await storage.read(key: AppLock.saltStorageKey), isNull);
      expect(await storage.read(key: AppLock.hashStorageKey), isNull);

      await backgroundFor(lock, const Duration(hours: 1));
      expect(lock.locked, isFalse);
    });

    test('is refused during the cooldown', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));
      for (var i = 0; i < AppLock.maxAttempts; i++) {
        await lock.unlock('0000');
      }
      expect(lock.inCooldown, isTrue);
      expect(await lock.disable('1234'), isFalse);
      expect(lock.enabled, isTrue);
    });
  });

  group('biometrics', () {
    test('unlocks with a supplied hook and fails closed without one', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);

      expect(await lock.unlockWithBiometrics(), isFalse);
      expect(lock.locked, isTrue);

      expect(await lock.unlockWithBiometrics(() async => false), isFalse);
      expect(lock.locked, isTrue);

      expect(await lock.unlockWithBiometrics(() async => true), isTrue);
      expect(lock.locked, isFalse);
    });

    test('a throwing hook does not unlock or crash', () async {
      await lock.load();
      await lock.setPin('1234');
      await backgroundFor(lock, const Duration(minutes: 3));

      expect(
        await lock.unlockWithBiometrics(
          () async => throw StateError('no sensor'),
        ),
        isFalse,
      );
      expect(lock.locked, isTrue);
    });
  });
}
