import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'diag.dart';
import 'secure_store.dart';

/// A biometric / device-credential check supplied by the host app.
///
/// The lock deliberately does not depend on `local_auth`: the host injects a
/// platform prompt and returns whether the user authenticated. When no hook is
/// supplied the gate simply never renders the biometrics affordance.
typedef BiometricCheck = Future<bool> Function();

/// Local app lock: a 4–6 digit PIN that hides the UI after the app has been in
/// the background longer than [lockAfter].
///
/// Security properties:
/// * The PIN is never stored. Only a random salt and `SHA-256(salt:pin)` live
///   in [FlutterSecureStorage]; the salt is regenerated on every PIN change.
/// * Five consecutive wrong attempts start a 30 s cooldown. Both the attempt
///   count and the cooldown deadline are persisted, so killing the process
///   does not reset the rate limit.
/// * `inactive` is ignored on purpose. System dialogs and permission sheets
///   flip the app to `inactive` and must never lock the user out.
/// * A cold start only locks when a background timestamp was persisted; a
///   first launch (or a launch that never left the foreground) stays unlocked.
///
/// This is a privacy lock for a shared device, not a cryptographic boundary
/// against a rooted attacker: the hash lives in platform secure storage, and
/// the UI is the only thing that verifies it.
class AppLock extends ChangeNotifier {
  AppLock({
    FlutterSecureStorage? storage,
    Future<SharedPreferences> Function()? prefsFactory,
    DateTime Function()? now,
    Random? random,
  }) : _storage = storage ?? ovidSecureStorage(),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure(),
       _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  /// Production singleton. Tests build their own instance so they never share
  /// state with the running app.
  static final AppLock I = AppLock();

  /// Number of wrong attempts allowed before the cooldown starts.
  static const int maxAttempts = 5;

  /// How long the keypad stays locked after [maxAttempts] failures.
  static const Duration cooldown = Duration(seconds: 30);

  /// Default idle time before a resume requires the PIN again.
  static const Duration defaultLockAfter = Duration(minutes: 2);

  @visibleForTesting
  static const String saltStorageKey = 'ovid_app_lock_salt_v1';

  @visibleForTesting
  static const String hashStorageKey = 'ovid_app_lock_hash_v1';

  static const String _enabledKey = 'ovid_app_lock_enabled';
  static const String _lockAfterKey = 'ovid_app_lock_lock_after_ms';
  static const String _attemptsKey = 'ovid_app_lock_failed_attempts';
  static const String _cooldownKey = 'ovid_app_lock_cooldown_until_ms';
  static const String _backgroundedKey = 'ovid_app_lock_backgrounded_at_ms';

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  final Random _random;
  final Future<SharedPreferences> Function() _prefsFactory;

  /// Optional biometric check used by [unlockWithBiometrics]. The gate may
  /// also pass its own hook, which takes precedence.
  BiometricCheck? biometric;

  bool _enabled = false;
  bool _locked = false;
  Duration _lockAfter = defaultLockAfter;
  int _failedAttempts = 0;
  DateTime? _cooldownUntil;
  DateTime? _backgroundedAt;
  bool _loaded = false;
  Future<void>? _loadFuture;

  /// Whether a PIN has been configured and the lock is active.
  bool get enabled => _enabled;

  /// Whether the UI is currently covered by the lock screen.
  bool get locked => _locked;

  /// Whether the persisted state has been read. The gate shows a neutral
  /// surface until this is true, so a cold start never flashes chat content.
  bool get loaded => _loaded;

  /// Idle time that triggers the lock. `Duration.zero` locks on every resume.
  Duration get lockAfter => _lockAfter;

  /// Whether the PIN is stored (used to decide if settings can offer disable).
  bool get hasPin => _enabled;

  /// Wrong attempts recorded in the current window. Reports [maxAttempts]
  /// while the cooldown is active and zero once it has expired.
  int get failedAttempts {
    if (inCooldown) return maxAttempts;
    if (_cooldownUntil != null) return 0;
    return _failedAttempts;
  }

  int get attemptsRemaining => max(0, maxAttempts - failedAttempts);

  /// Remaining cooldown, clamped to [cooldown] so a backwards clock jump can
  /// never lock the user out for longer than the configured window.
  Duration get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    if (left <= Duration.zero) return Duration.zero;
    return left > cooldown ? cooldown : left;
  }

  bool get inCooldown => cooldownRemaining > Duration.zero;

  /// Whole seconds shown by the gate countdown (rounds up so "1s" is visible
  /// for the final second).
  int get cooldownSecondsRemaining {
    final ms = cooldownRemaining.inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  /// Reads persisted state. Safe to call repeatedly; the work happens once.
  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await _prefsFactory();
      final wanted = prefs.getBool(_enabledKey) ?? false;
      final lockAfterMs = prefs.getInt(_lockAfterKey);
      if (lockAfterMs != null && lockAfterMs >= 0) {
        _lockAfter = Duration(milliseconds: lockAfterMs);
      }
      _failedAttempts = prefs.getInt(_attemptsKey) ?? 0;
      if (_failedAttempts < 0) _failedAttempts = 0;
      if (_failedAttempts > maxAttempts) _failedAttempts = maxAttempts;

      final untilMs = prefs.getInt(_cooldownKey);
      if (untilMs != null) {
        _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(untilMs);
        // A clock jump (or a corrupted value) must not extend the lockout.
        final latest = _now().add(cooldown);
        if (_cooldownUntil!.isAfter(latest)) _cooldownUntil = latest;
      }

      // Skip the secure-storage reads entirely when the lock is off (the
      // default), so cold start pays nothing for a feature nobody enabled.
      final salt = wanted ? await _readSecure(saltStorageKey) : null;
      final hash = wanted ? await _readSecure(hashStorageKey) : null;
      _enabled = wanted && salt != null && hash != null;
      if (wanted && !_enabled) {
        // The flag survived but the secret did not: fail open, never strand
        // the user behind a PIN that cannot be verified.
        await _writeBool(_enabledKey, false);
      }

      if (_backgroundedAt == null) {
        final bgMs = prefs.getInt(_backgroundedKey);
        if (bgMs != null && _enabled) {
          final bg = DateTime.fromMillisecondsSinceEpoch(bgMs);
          _backgroundedAt = bg;
          final elapsed = _now().difference(bg);
          if (elapsed.isNegative || elapsed > _lockAfter) _locked = true;
        }
      }
    } catch (e) {
      Diag.swallow('app_lock.load', e);
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Stores a new PIN and enables the lock.
  ///
  /// Changing an existing PIN requires [currentPin]; a wrong current PIN is
  /// counted by the same rate limiter as an unlock attempt. Returns false for
  /// an invalid PIN, a wrong current PIN, or an active cooldown.
  Future<bool> setPin(String pin, {String? currentPin}) async {
    await load();
    if (!isValidPin(pin)) return false;
    _expireCooldownIfNeeded();
    if (inCooldown) return false;
    if (_enabled) {
      if (currentPin == null || !await _verify(currentPin)) {
        await _registerFailure();
        return false;
      }
    }

    final salt = _newSalt();
    final saltText = base64Encode(salt);
    final hashText = _hashPin(pin, saltText);
    try {
      await _storage.write(key: saltStorageKey, value: saltText);
      await _storage.write(key: hashStorageKey, value: hashText);
    } catch (e) {
      Diag.swallow('app_lock.setPin', e);
      return false;
    }

    _enabled = true;
    _locked = false;
    _backgroundedAt = null;
    _failedAttempts = 0;
    _cooldownUntil = null;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Removes the PIN. Requires the current PIN, and is refused during the
  /// cooldown so an attacker cannot reset the rate limit by disabling.
  Future<bool> disable(String pin) async {
    await load();
    if (!_enabled) return true;
    _expireCooldownIfNeeded();
    if (inCooldown) return false;
    if (!await _verify(pin)) {
      await _registerFailure();
      return false;
    }

    try {
      await _storage.delete(key: saltStorageKey);
      await _storage.delete(key: hashStorageKey);
    } catch (e) {
      Diag.swallow('app_lock.disable', e);
    }

    _enabled = false;
    _locked = false;
    _backgroundedAt = null;
    _failedAttempts = 0;
    _cooldownUntil = null;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Verifies [pin] and, when correct, removes the lock screen.
  ///
  /// Returns true when the app is (or becomes) unlocked. During the cooldown
  /// even the correct PIN is refused — the countdown is the point.
  Future<bool> unlock(String pin) async {
    await load();
    if (!_enabled) {
      if (_locked) {
        _locked = false;
        notifyListeners();
      }
      return true;
    }
    if (!_locked) return true;
    _expireCooldownIfNeeded();
    if (inCooldown) return false;

    if (await _verify(pin)) {
      _locked = false;
      _failedAttempts = 0;
      _cooldownUntil = null;
      notifyListeners();
      await _persist();
      return true;
    }

    await _registerFailure();
    return false;
  }

  /// Unlocks through the injected [hook] (or [biometric]). Biometrics bypass
  /// the PIN cooldown: a successful platform authentication is stronger than
  /// the local PIN and cannot be brute-forced through this API.
  Future<bool> unlockWithBiometrics([BiometricCheck? hook]) async {
    await load();
    if (!_enabled) {
      if (_locked) {
        _locked = false;
        notifyListeners();
      }
      return true;
    }
    if (!_locked) return true;
    final check = hook ?? biometric;
    if (check == null) return false;

    bool ok;
    try {
      ok = await check();
    } catch (e) {
      Diag.swallow('app_lock.biometrics', e);
      return false;
    }
    if (!ok) return false;

    _locked = false;
    _failedAttempts = 0;
    _cooldownUntil = null;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Persists a new idle timeout.
  Future<void> setLockAfter(Duration value) async {
    final next = value < Duration.zero ? Duration.zero : value;
    if (next == _lockAfter) return;
    _lockAfter = next;
    notifyListeners();
    await _persist();
  }

  /// Records the moment the app left the foreground. Called for `paused` only
  /// — never for `inactive`.
  Future<void> markBackgrounded({DateTime? at}) async {
    if (!_enabled) return;
    _backgroundedAt = at ?? _now();
    await _persist();
  }

  /// Returns whether the app is locked after this resume.
  ///
  /// The first resume without a recorded background (cold start) never locks.
  /// A resume after more than [lockAfter] hides the UI; an exactly-equal
  /// interval does not.
  Future<bool> markResumed({DateTime? at}) async {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    if (since == null) return _locked;
    if (!_enabled) {
      await _persist();
      return false;
    }
    if (_locked) {
      await _persist();
      return true;
    }

    final elapsed = (at ?? _now()).difference(since);
    // A backwards clock jump fails closed: treat it as a long absence.
    if (elapsed.isNegative || elapsed > _lockAfter) {
      _locked = true;
      notifyListeners();
    }
    await _persist();
    return _locked;
  }

  /// Maps a Flutter lifecycle state onto the lock's two transitions.
  ///
  /// `inactive`/`hidden`/`detached` are intentionally ignored: dialogs,
  /// permission sheets and the app switcher peek must not cover chat content.
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      await markBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      await markResumed();
    }
  }

  /// A PIN is 4–6 ASCII digits. Leading zeros are valid.
  static bool isValidPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  List<int> _newSalt() =>
      List<int>.generate(16, (_) => _random.nextInt(256), growable: false);

  String _hashPin(String pin, String saltText) =>
      sha256.convert(utf8.encode('$saltText:$pin')).toString();

  Future<bool> _verify(String pin) async {
    try {
      final saltText = await _storage.read(key: saltStorageKey);
      final expected = await _storage.read(key: hashStorageKey);
      if (saltText == null || expected == null) return false;
      final actual = _hashPin(pin, saltText);
      return _constantTimeEquals(actual, expected);
    } catch (e) {
      Diag.swallow('app_lock.verify', e);
      return false;
    }
  }

  Future<void> _registerFailure() async {
    _expireCooldownIfNeeded();
    _failedAttempts += 1;
    if (_failedAttempts >= maxAttempts) {
      _failedAttempts = maxAttempts;
      _cooldownUntil = _now().add(cooldown);
    }
    notifyListeners();
    await _persist();
  }

  void _expireCooldownIfNeeded() {
    final until = _cooldownUntil;
    if (until == null || _now().isBefore(until)) return;
    _cooldownUntil = null;
    _failedAttempts = 0;
    unawaited(_persist());
  }

  Future<String?> _readSecure(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      Diag.swallow('app_lock.read', e);
      return null;
    }
  }

  Future<void> _writeBool(String key, bool value) async {
    try {
      final prefs = await _prefsFactory();
      await prefs.setBool(key, value);
    } catch (e) {
      Diag.swallow('app_lock.persist', e);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefsFactory();
      await prefs.setBool(_enabledKey, _enabled);
      await prefs.setInt(_lockAfterKey, _lockAfter.inMilliseconds);
      await prefs.setInt(_attemptsKey, _failedAttempts);
      final until = _cooldownUntil;
      if (until == null) {
        await prefs.remove(_cooldownKey);
      } else {
        await prefs.setInt(_cooldownKey, until.millisecondsSinceEpoch);
      }
      final bg = _backgroundedAt;
      if (bg == null) {
        await prefs.remove(_backgroundedKey);
      } else {
        await prefs.setInt(_backgroundedKey, bg.millisecondsSinceEpoch);
      }
    } catch (e) {
      Diag.swallow('app_lock.persist', e);
    }
  }

  /// Compares two hex digests without leaking the first differing index.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
