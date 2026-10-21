import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/app_lock_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Secure storage whose reads fail the way an invalidated Keystore does.
class _FailingStorage implements FlutterSecureStorage {
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
  }) async => throw StateError('keystore invalidated');

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
    throw StateError('keystore invalidated');
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
    throw StateError('keystore invalidated');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Working in-memory secure storage.
class _MemoryStorage implements FlutterSecureStorage {
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
  }) async => values[key];

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

Future<void> _pump(
  WidgetTester tester,
  AppLock lock, {
  Future<bool> Function()? reauthenticate,
  double width = 400,
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AppLockSettingsPage(
        lock: lock,
        reauthenticate: reauthenticate ?? () async => true,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _seedLegacyPin(
  _MemoryStorage storage, {
  String pin = '1234',
}) async {
  const salt = 'bGVnYWN5LXNhbHQ=';
  storage.values[AppLock.saltStorageKey] = salt;
  storage.values[AppLock.hashStorageKey] = sha256
      .convert(utf8.encode('$salt:$pin'))
      .toString();
  SharedPreferences.setMockInitialValues(<String, Object>{
    'ovid_app_lock_enabled': true,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime(2026, 10, 21, 12);
  });

  testWidgets('new PINs must be exactly six digits', (tester) async {
    final lock = AppLock(now: () => now, random: Random(7));
    await _pump(tester, lock);

    await tester.tap(find.byKey(const ValueKey<String>('app-lock-switch')));
    await tester.pumpAndSettle();

    expect(find.text('6-digit PIN'), findsOneWidget);
    expect(find.text('PIN (4–6 digits)'), findsNothing);

    final field = find.byKey(const ValueKey<String>('app-lock-pin-field'));
    final confirm = find.byKey(
      const ValueKey<String>('app-lock-pin-confirm-field'),
    );
    final save = find.byKey(const ValueKey<String>('app-lock-pin-save'));

    await tester.enterText(field, '1234');
    await tester.enterText(confirm, '1234');
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNull);

    await tester.enterText(field, '123456');
    await tester.enterText(confirm, '123456');
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);

    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(lock.enabled, isTrue);
    expect(lock.recoveryRequired, isFalse);
    expect(find.text('App lock is on.'), findsOneWidget);
  });

  testWidgets('a legacy four-digit PIN still verifies for a PIN change', (
    tester,
  ) async {
    final storage = _MemoryStorage();
    await _seedLegacyPin(storage);
    final lock = AppLock(
      storage: storage,
      now: () => now,
      random: Random(8),
    );
    await _pump(tester, lock);
    await lock.load();
    expect(lock.enabled, isTrue);

    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-change-pin')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('app-lock-pin-field')),
      '654321',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('app-lock-pin-confirm-field')),
      '654321',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-pin-save')),
    );
    await tester.pumpAndSettle();

    // The current-PIN prompt accepts the old four digits.
    expect(find.text('Current PIN (4–6 digits)'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey<String>('app-lock-pin-field')),
      '1234',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-pin-save')),
    );
    await tester.pumpAndSettle();

    expect(find.text('PIN updated.'), findsOneWidget);
    expect(await lock.disable('654321'), isTrue);
  });

  testWidgets('recovery offers a real reset after re-authentication', (
    tester,
  ) async {
    final storage = _FailingStorage();
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_app_lock_enabled': true,
    });
    final lock = AppLock(storage: storage, now: () => now);
    var verified = false;
    await _pump(
      tester,
      lock,
      reauthenticate: () async {
        verified = true;
        return true;
      },
    );
    await lock.load();

    expect(lock.recoveryRequired, isTrue);
    expect(
      find.byKey(const ValueKey<String>('app-lock-recovery-card')),
      findsOneWidget,
    );
    expect(find.text('PIN reset required'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-reset-pin')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reset app lock PIN?'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-confirm-reauth')),
    );
    await tester.pumpAndSettle();

    expect(verified, isTrue);
    expect(lock.recoveryRequired, isFalse);
    expect(lock.enabled, isFalse);
    // The page offers a fresh six-digit PIN immediately after the reset.
    expect(find.text('Set a 6-digit PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('a re-auth lockout keeps the working PIN', (tester) async {
    final storage = _MemoryStorage();
    final first = AppLock(
      storage: storage,
      now: () => now,
      random: Random(9),
    );
    expect(await first.setPin('123456'), isTrue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('ovid_app_lock_reauth_required', true);

    final lock = AppLock(storage: storage, now: () => now);
    await _pump(tester, lock, reauthenticate: () async => true);
    await lock.load();

    expect(lock.reauthRequired, isTrue);
    expect(find.text('PIN locked'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-reset-pin')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('app-lock-confirm-reauth')),
    );
    await tester.pumpAndSettle();

    expect(lock.reauthRequired, isFalse);
    expect(lock.enabled, isTrue);
    expect(lock.locked, isFalse);
    expect(await lock.disable('123456'), isTrue);
  });

  testWidgets('recovery card fits 320 dp at 200% text in both themes', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      final storage = _FailingStorage();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'ovid_app_lock_enabled': true,
      });
      final lock = AppLock(storage: storage, now: () => now);
      await _pump(
        tester,
        lock,
        width: 320,
        textScale: 2,
        dark: dark,
      );
      await lock.load();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('PIN reset required'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('app-lock-reset-pin')),
        findsOneWidget,
      );
    }
  });

  testWidgets('the six-digit prompt fits 320 dp at 200% text', (tester) async {
    final lock = AppLock(now: () => now, random: Random(10));
    await _pump(tester, lock, width: 320, textScale: 2);

    await tester.tap(find.byKey(const ValueKey<String>('app-lock-switch')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('6-digit PIN'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
}
