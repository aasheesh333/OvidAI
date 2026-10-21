import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure storage whose reads fail the way an invalidated Keystore does.
class _FailingStorage implements FlutterSecureStorage {
  _FailingStorage();

  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('keystore invalidated');
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  Future<void> failWindow(
    AppLock target, {
    int times = AppLock.maxAttempts,
  }) async {
    for (var i = 0; i < times; i++) {
      expect(await target.unlock('000000'), isFalse);
    }
  }

  group('PIN storage', () {
    test('stores a salted PBKDF2 digest with its iteration count', () async {
      await lock.load();
      expect(await lock.setPin('012345'), isTrue);
      expect(lock.enabled, isTrue);
      expect(lock.locked, isFalse);

      final salt = await storage.read(key: AppLock.saltStorageKey);
      final hash = await storage.read(key: AppLock.hashStorageKey);
      expect(salt, isNotNull);
      expect(hash, isNotNull);
      expect(
        hash,
        startsWith('pbkdf2-sha256\$${AppLock.kdfIterations}\$'),
        reason: 'the work factor must travel with the digest',
      );
      expect(
        RegExp(r'^pbkdf2-sha256\$\d+\$[0-9a-f]{64}$').hasMatch(hash!),
        isTrue,
      );
      expect(hash, isNot('012345'));
      expect(hash, isNot(sha256.convert(utf8.encode('012345')).toString()));
      expect(
        hash,
        isNot(sha256.convert(utf8.encode('$salt:012345')).toString()),
      );

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(
          '${prefs.get(key)}',
          isNot(contains('012345')),
          reason: 'preference $key must not contain the PIN',
        );
      }
      expect(salt, isNot(contains('012345')));
    });

    test('regenerates the salt when the PIN changes', () async {
      await lock.load();
      expect(await lock.setPin('123456'), isTrue);
      final firstSalt = await storage.read(key: AppLock.saltStorageKey);
      final firstHash = await storage.read(key: AppLock.hashStorageKey);

      expect(await lock.setPin('567890', currentPin: '123456'), isTrue);
      final secondSalt = await storage.read(key: AppLock.saltStorageKey);
      final secondHash = await storage.read(key: AppLock.hashStorageKey);

      expect(secondSalt, isNot(firstSalt));
      expect(secondHash, isNot(firstHash));
    });

    test('new PINs must be exactly six digits', () async {
      await lock.load();
      for (final bad in [
        '',
        '123',
        '1234',
        '12345',
        '1234567',
        '12a456',
        ' 123456',
        '123456 ',
      ]) {
        expect(await lock.setPin(bad), isFalse, reason: 'accepted "$bad"');
        expect(lock.enabled, isFalse);
      }
      expect(await lock.setPin('000000'), isTrue);
      expect(await lock.setPin('999999', currentPin: '000000'), isTrue);
    });

    test('changing a PIN requires the current one', () async {
      await lock.load();
      await lock.setPin('123456');
      expect(await lock.setPin('567890'), isFalse);
      expect(lock.failedAttempts, 1);
      expect(await lock.setPin('567890', currentPin: '000000'), isFalse);
      expect(await lock.setPin('567890', currentPin: '123456'), isTrue);

      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);
      expect(await lock.unlock('123456'), isFalse);
      expect(await lock.unlock('567890'), isTrue);
    });

    test(
      'legacy 4-digit PIN still verifies and is re-hashed to PBKDF2',
      () async {
        await lock.load();
        // Enable the feature first, then replace the stored secret with the
        // digest an older build wrote: SHA-256(salt:pin), 4-digit PIN.
        await lock.setPin('123456');
        final legacySalt = base64Encode(List<int>.generate(16, (i) => i));
        final legacyHash = sha256
            .convert(utf8.encode('$legacySalt:1234'))
            .toString();
        await storage.write(key: AppLock.saltStorageKey, value: legacySalt);
        await storage.write(key: AppLock.hashStorageKey, value: legacyHash);

        // A fresh instance loads only what is on disk, like an app restart.
        final migrated = AppLock(now: () => now, random: Random(3));
        await migrated.load();
        expect(migrated.enabled, isTrue);
        expect(migrated.locked, isFalse);

        await backgroundFor(migrated, const Duration(minutes: 3));
        expect(migrated.locked, isTrue);
        expect(await migrated.unlock('1234'), isTrue);
        expect(migrated.locked, isFalse);

        final upgraded = await storage.read(key: AppLock.hashStorageKey);
        expect(upgraded, isNotNull);
        expect(
          upgraded,
          startsWith('pbkdf2-sha256\$${AppLock.kdfIterations}\$'),
        );
        expect(upgraded, isNot(legacyHash));

        // The migrated digest keeps verifying the legacy PIN.
        await backgroundFor(migrated, const Duration(minutes: 3));
        expect(await migrated.unlock('1234'), isTrue);
      },
    );

    test('a lower-work-factor PBKDF2 digest is upgraded on success', () async {
      await lock.load();
      await lock.setPin('123456');
      final salt = (await storage.read(key: AppLock.saltStorageKey))!;
      // A digest written by a build that used a weaker iteraction count.
      await storage.write(
        key: AppLock.hashStorageKey,
        value: 'pbkdf2-sha256\$1000\$${_pbkdf2Hex('123456', salt, 1000)}',
      );

      final upgradedLock = AppLock(now: () => now, random: Random(4));
      await upgradedLock.load();
      await backgroundFor(upgradedLock, const Duration(minutes: 3));
      expect(await upgradedLock.unlock('123456'), isTrue);

      final stored = await storage.read(key: AppLock.hashStorageKey);
      expect(stored, startsWith('pbkdf2-sha256\$${AppLock.kdfIterations}\$'));
    });

    test('a failed secure-storage read fails closed', () async {
      await lock.load();
      await lock.setPin('123456');

      final brokenStorage = _FailingStorage();
      final broken = AppLock(
        storage: brokenStorage,
        now: () => now,
        random: Random(5),
      );
      await broken.load();

      expect(broken.enabled, isTrue, reason: 'the lock must stay enabled');
      expect(broken.recoveryRequired, isTrue);
      expect(broken.locked, isTrue, reason: 'fail closed, never fail open');
      expect(await broken.unlock('123456'), isFalse);
      expect(broken.locked, isTrue);

      // The enabled flag is never rewritten to false: a transient error must
      // not silently disable the feature.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ovid_app_lock_enabled'), isTrue);

      // The explicit re-auth reset clears the unrecoverable secret.
      expect(await broken.resetAfterReauth(), isTrue);
      expect(broken.enabled, isFalse);
      expect(broken.locked, isFalse);
      expect(brokenStorage.values, isEmpty);

      // A working lock is never reset by a plain sign-out.
      await lock.load();
      expect(await lock.resetAfterReauth(), isFalse);
      expect(lock.enabled, isTrue);
    });

    test('a missing secret with the flag set fails closed too', () async {
      await lock.load();
      await lock.setPin('123456');
      await storage.delete(key: AppLock.saltStorageKey);
      await storage.delete(key: AppLock.hashStorageKey);

      final cold = AppLock(now: () => now, random: Random(6));
      await cold.load();
      expect(cold.enabled, isTrue);
      expect(cold.recoveryRequired, isTrue);
      expect(cold.locked, isTrue);
      expect(await cold.unlock('123456'), isFalse);
    });
  });

  group('unlock', () {
    test('wrong PIN keeps the lock, correct PIN removes it', () async {
      await lock.load();
      await lock.setPin('123456');
      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);

      expect(await lock.unlock('999999'), isFalse);
      expect(lock.locked, isTrue);
      expect(lock.failedAttempts, 1);

      expect(await lock.unlock('123456'), isTrue);
      expect(lock.locked, isFalse);
      expect(lock.failedAttempts, 0);
    });

    test('unlock is a no-op while the app is not locked', () async {
      await lock.load();
      await lock.setPin('123456');
      expect(await lock.unlock('000000'), isTrue);
      expect(lock.locked, isFalse);
      expect(lock.failedAttempts, 0);
    });
  });

  group('rate limit', () {
    test('five wrong attempts start a 30 second cooldown', () async {
      await lock.load();
      await lock.setPin('123456');
      await backgroundFor(lock, const Duration(minutes: 3));

      for (var i = 1; i < AppLock.maxAttempts; i++) {
        expect(await lock.unlock('000000'), isFalse);
        expect(lock.inCooldown, isFalse, reason: 'cooldown after $i attempts');
        expect(lock.attemptsRemaining, AppLock.maxAttempts - i);
      }
      expect(await lock.unlock('000000'), isFalse);

      expect(lock.inCooldown, isTrue);
      expect(lock.attemptsRemaining, 0);
      expect(lock.cooldownRemaining, greaterThan(const Duration(seconds: 29)));
      expect(lock.cooldownSecondsRemaining, 30);

      // Even the right PIN is refused while the countdown runs.
      expect(await lock.unlock('123456'), isFalse);
      expect(lock.locked, isTrue);

      now = now.add(const Duration(seconds: 30));
      expect(lock.inCooldown, isFalse);
      expect(await lock.unlock('123456'), isTrue);
      expect(lock.locked, isFalse);
    });

    test(
      'cumulative attempts escalate then require an account re-auth',
      () async {
        await lock.load();
        await lock.setPin('123456');
        await backgroundFor(lock, const Duration(minutes: 3));

        // Window 1: 30 seconds.
        await failWindow(lock);
        expect(lock.inCooldown, isTrue);
        expect(lock.currentCooldown, const Duration(seconds: 30));
        expect(lock.locked, isTrue);
        now = now.add(const Duration(seconds: 31));

        // Window 2: 5 minutes.
        await failWindow(lock);
        expect(lock.inCooldown, isTrue);
        expect(lock.currentCooldown, const Duration(minutes: 5));
        expect(lock.cooldownRemaining, greaterThan(const Duration(minutes: 4)));
        now = now.add(const Duration(minutes: 5, seconds: 1));

        // Window 3: 15 minutes.
        await failWindow(lock);
        expect(lock.inCooldown, isTrue);
        expect(lock.currentCooldown, const Duration(minutes: 15));
        now = now.add(const Duration(minutes: 15, seconds: 1));

        // Window 4: the 1 hour cap.
        await failWindow(lock);
        expect(lock.inCooldown, isTrue);
        expect(lock.currentCooldown, const Duration(hours: 1));
        expect(
          lock.cooldownRemaining,
          greaterThan(const Duration(minutes: 59)),
        );
        now = now.add(const Duration(hours: 1, seconds: 1));

        // Window 5: the local PIN is exhausted.
        await failWindow(lock);
        expect(lock.reauthRequired, isTrue);
        expect(lock.inCooldown, isFalse);
        expect(lock.locked, isTrue);
        expect(lock.totalFailures, AppLock.reauthThreshold);
        expect(
          await lock.unlock('123456'),
          isFalse,
          reason: 'a correct PIN is refused once re-auth is required',
        );

        // The cap survives a process restart.
        final restarted = AppLock(now: () => now, random: Random(14));
        await restarted.load();
        expect(restarted.reauthRequired, isTrue);
        expect(restarted.locked, isTrue);

        // A successful platform authentication is the escape hatch.
        expect(await restarted.unlockWithBiometrics(() async => true), isTrue);
        expect(restarted.reauthRequired, isFalse);
        expect(restarted.totalFailures, 0);
        expect(restarted.locked, isFalse);
      },
    );

    test('attempts and the cooldown survive a process restart', () async {
      await lock.load();
      await lock.setPin('123456');
      await backgroundFor(lock, const Duration(minutes: 3));

      for (var i = 0; i < 3; i++) {
        expect(await lock.unlock('000000'), isFalse);
      }

      final restarted = AppLock(now: () => now, random: Random(7));
      await restarted.load();
      expect(restarted.enabled, isTrue);
      expect(restarted.locked, isFalse);
      expect(restarted.failedAttempts, 3);
      expect(restarted.attemptsRemaining, 2);

      await backgroundFor(restarted, const Duration(minutes: 3));
      expect(restarted.locked, isTrue);
      expect(await restarted.unlock('000000'), isFalse);
      expect(await restarted.unlock('000000'), isFalse);
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
      expect(await restartedAgain.unlock('123456'), isFalse);

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
      await lock.setPin('123456');

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
      await lock.setPin('123456');
      await lock.setLockAfter(const Duration(seconds: 30));

      final restarted = AppLock(now: () => now, random: Random(11));
      await restarted.load();
      expect(restarted.lockAfter, const Duration(seconds: 30));

      await backgroundFor(restarted, const Duration(seconds: 31));
      expect(restarted.locked, isTrue);
    });

    test('inactive alone never locks the app', () async {
      await lock.load();
      await lock.setPin('123456');

      await lock.handleLifecycleState(AppLifecycleState.inactive);
      now = now.add(const Duration(hours: 1));
      await lock.handleLifecycleState(AppLifecycleState.resumed);

      expect(lock.locked, isFalse);
    });

    test('paused then resumed after the timeout locks', () async {
      await lock.load();
      await lock.setPin('123456');

      await lock.handleLifecycleState(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 3));
      await lock.handleLifecycleState(AppLifecycleState.resumed);
      expect(lock.locked, isTrue);
    });

    test('hidden counts as backgrounded on non-mobile platforms', () async {
      final desktop = AppLock(
        now: () => now,
        random: Random(15),
        treatHiddenAsBackground: true,
      );
      await desktop.load();
      await desktop.setPin('123456');

      await desktop.handleLifecycleState(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 3));
      await desktop.handleLifecycleState(AppLifecycleState.resumed);
      expect(desktop.locked, isTrue, reason: 'a tab switch must lock');
    });

    test('hidden alone does not lock on mobile', () async {
      final mobile = AppLock(
        now: () => now,
        random: Random(16),
        treatHiddenAsBackground: false,
      );
      await mobile.load();
      await mobile.setPin('123456');

      await mobile.handleLifecycleState(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 3));
      await mobile.handleLifecycleState(AppLifecycleState.resumed);
      expect(
        mobile.locked,
        isFalse,
        reason: 'mobile emits hidden right before paused',
      );
    });

    test('a cold start without a background never locks', () async {
      await lock.load();
      await lock.setPin('123456');

      final cold = AppLock(now: () => now, random: Random(12));
      await cold.load();
      expect(cold.enabled, isTrue);
      expect(cold.locked, isFalse);
      expect(await cold.markResumed(at: now), isFalse);
    });

    test('a cold start after a real background locks', () async {
      await lock.load();
      await lock.setPin('123456');
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
      expect(await lock.unlock('123456'), isTrue);

      await backgroundFor(lock, const Duration(hours: 1));
      expect(lock.locked, isFalse);
    });

    test('requires the current PIN and removes the stored secret', () async {
      await lock.load();
      await lock.setPin('123456');
      await backgroundFor(lock, const Duration(minutes: 3));
      expect(lock.locked, isTrue);

      expect(await lock.disable('000000'), isFalse);
      expect(lock.enabled, isTrue);
      expect(lock.failedAttempts, 1);

      expect(await lock.disable('123456'), isTrue);
      expect(lock.enabled, isFalse);
      expect(lock.locked, isFalse);
      expect(await storage.read(key: AppLock.saltStorageKey), isNull);
      expect(await storage.read(key: AppLock.hashStorageKey), isNull);

      await backgroundFor(lock, const Duration(hours: 1));
      expect(lock.locked, isFalse);
    });

    test('is refused during the cooldown', () async {
      await lock.load();
      await lock.setPin('123456');
      await backgroundFor(lock, const Duration(minutes: 3));
      for (var i = 0; i < AppLock.maxAttempts; i++) {
        await lock.unlock('000000');
      }
      expect(lock.inCooldown, isTrue);
      expect(await lock.disable('123456'), isFalse);
      expect(lock.enabled, isTrue);
    });
  });

  group('biometrics', () {
    test('unlocks with a supplied hook and fails closed without one', () async {
      await lock.load();
      await lock.setPin('123456');
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
      await lock.setPin('123456');
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

/// PBKDF2-HMAC-SHA256 test helper, kept independent of the implementation.
String _pbkdf2Hex(String pin, String saltText, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(pin));
  final salt = utf8.encode(saltText);
  final first = <int>[...salt, 0, 0, 0, 1];
  var u = hmac.convert(first).bytes;
  final acc = List<int>.of(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < acc.length; j++) {
      acc[j] ^= u[j];
    }
  }
  return acc.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
