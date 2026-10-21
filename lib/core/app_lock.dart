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
/// * The PIN is never stored. Only a random salt and a PBKDF2-HMAC-SHA256
///   digest (`pbkdf2-sha256$<iterations>$<hex>`) live in [FlutterSecureStorage];
///   the salt is regenerated on every PIN change. The iteration count is stored
///   with the digest so a future upgrade can re-hash on the next success.
/// * Legacy v1 digests (`SHA-256(salt:pin)`) still verify for users who set a
///   PIN before the KDF upgrade; they are re-hashed to PBKDF2 on first success.
/// * New PINs must be six digits. Four-digit PINs set by older builds keep
///   working until the next successful verification.
/// * Five consecutive wrong attempts start a 30 s cooldown. Both the attempt
///   count and the cooldown deadline are persisted, so killing the process
///   does not reset the rate limit.
/// * Cumulative failures escalate the cooldown (30 s → 5 m → 15 m → 1 h) and
///   eventually require an account re-authentication: the local PIN is no
///   longer accepted until the host clears the flag after re-authenticating.
/// * A secure-storage read failure (Keystore invalidation, corruption) fails
///   closed: the app stays locked and the UI asks for a PIN reset instead of
///   silently disabling the lock. See [recoveryRequired].
/// * `inactive` is ignored on purpose. System dialogs and permission sheets
///   flip the app to `inactive` and must never lock the user out. `hidden` is
///   treated as backgrounded on non-mobile platforms (desktop/web window
///   switches never emit `paused`).
/// * A cold start only locks when a background timestamp was persisted; a
///   first launch (or a launch that never left the foreground) stays unlocked.
///
/// This is a privacy lock for a shared device, not a cryptographic boundary
/// against a rooted attacker: the digest lives in platform secure storage, and
/// the UI is the only thing that verifies it.
class AppLock extends ChangeNotifier {
  AppLock({
    FlutterSecureStorage? storage,
    Future<SharedPreferences> Function()? prefsFactory,
    DateTime Function()? now,
    Random? random,
    bool? treatHiddenAsBackground,
  }) : _storage = storage ?? ovidSecureStorage(),
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure(),
       _prefsFactory = prefsFactory ?? SharedPreferences.getInstance,
       _treatHiddenAsBackground =
           treatHiddenAsBackground ?? _hiddenMeansBackgrounded;

  /// Production singleton. Tests build their own instance so they never share
  /// state with the running app.
  static final AppLock I = AppLock();

  /// Number of wrong attempts allowed before the cooldown starts.
  static const int maxAttempts = 5;

  /// First cooldown length; later windows escalate through [lockoutLadder].
  static const Duration cooldown = Duration(seconds: 30);

  /// Escalating cooldowns applied after each full window of [maxAttempts]
  /// failures. The first window uses entry 0, the second entry 1, and so on.
  static const List<Duration> lockoutLadder = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(hours: 1),
  ];

  /// Cumulative failures at which the local PIN stops being accepted at all;
  /// the host has to re-authenticate the account ([completeAccountReauth]).
  static const int reauthThreshold = maxAttempts * 5; // 25

  /// Hard cap on the persisted counter so it can never grow without bound.
  static const int maxTrackedFailures = reauthThreshold * 4;

  /// Target PBKDF2-HMAC-SHA256 work factor for new and upgraded digests.
  static const int kdfIterations = 100000;

  /// Upper bound accepted when parsing a stored iteration count, so a tampered
  /// value cannot turn verification into a denial of service.
  @visibleForTesting
  static const int maxStoredIterations = 5000000;

  /// New PINs are six digits.
  static const int pinLength = 6;

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
  static const String _totalAttemptsKey = 'ovid_app_lock_total_failures';
  static const String _reauthKey = 'ovid_app_lock_reauth_required';

  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  final Random _random;
  final Future<SharedPreferences> Function() _prefsFactory;
  final bool _treatHiddenAsBackground;

  /// Optional biometric check used by [unlockWithBiometrics]. The gate may
  /// also pass its own hook, which takes precedence.
  BiometricCheck? biometric;

  bool _enabled = false;
  bool _locked = false;
  bool _recoveryRequired = false;
  bool _reauthRequired = false;
  Duration _lockAfter = defaultLockAfter;
  int _failedAttempts = 0;
  int _totalFailures = 0;
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

  /// True when the lock is enabled but the stored secret could not be read
  /// (Keystore invalidation, corruption, permission error).
  ///
  /// The lock fails closed: it stays engaged, no PIN is accepted, and the user
  /// has to re-authenticate the account ([resetAfterReauth]) or reset the PIN
  /// after proving who they are. The gate surfaces this state.
  bool get recoveryRequired => _recoveryRequired;

  /// True when the cumulative failure cap has been reached. The local PIN is
  /// refused until the host completes an account re-authentication
  /// ([completeAccountReauth]) or a biometric check succeeds.
  bool get reauthRequired => _reauthRequired;

  /// Wrong attempts across every window since the last successful unlock.
  int get totalFailures => _totalFailures;

  /// Wrong attempts recorded in the current window. Reports [maxAttempts]
  /// while the cooldown is active and zero once it has expired.
  int get failedAttempts {
    if (inCooldown) return maxAttempts;
    if (_cooldownUntil != null) return 0;
    return _failedAttempts;
  }

  int get attemptsRemaining => max(0, maxAttempts - failedAttempts);

  /// Cooldown that applies to the current escalation step. Capped by
  /// [lockoutLadder] so repeated windows cannot extend it indefinitely.
  Duration get currentCooldown {
    final step = _totalFailures ~/ maxAttempts;
    if (step <= 0) return cooldown;
    final index = step - 1;
    return index < lockoutLadder.length
        ? lockoutLadder[index]
        : lockoutLadder.last;
  }

  /// Remaining cooldown, clamped to [currentCooldown] so a backwards clock
  /// jump can never lock the user out for longer than the configured window.
  Duration get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final left = until.difference(_now());
    if (left <= Duration.zero) return Duration.zero;
    return left > currentCooldown ? currentCooldown : left;
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
      _totalFailures = prefs.getInt(_totalAttemptsKey) ?? 0;
      if (_totalFailures < 0) _totalFailures = 0;
      if (_totalFailures > maxTrackedFailures) {
        _totalFailures = maxTrackedFailures;
      }
      _reauthRequired = prefs.getBool(_reauthKey) ?? false;
      if (_totalFailures >= reauthThreshold) _reauthRequired = true;

      final untilMs = prefs.getInt(_cooldownKey);
      if (untilMs != null) {
        final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
        // A clock jump (or a corrupted value) must not extend the lockout.
        final latest = _now().add(currentCooldown);
        _cooldownUntil = until.isAfter(latest) ? latest : until;
        if (!_cooldownUntil!.isAfter(_now())) {
          // The window elapsed while the process was dead.
          _cooldownUntil = null;
          _failedAttempts = 0;
        }
      }

      if (!wanted) {
        _enabled = false;
        return;
      }

      // A PIN was configured: never skip the secure-storage reads. A failure
      // or a missing secret must fail closed, not silently disable the lock.
      final salt = await _readSecure(saltStorageKey);
      final hash = await _readSecure(hashStorageKey);
      final unreadable =
          salt.failed ||
          hash.failed ||
          salt.value == null ||
          hash.value == null;

      _enabled = true;
      if (unreadable) {
        _recoveryRequired = true;
        _locked = true;
        return;
      }
      if (_reauthRequired) {
        _locked = true;
        return;
      }

      if (_backgroundedAt == null) {
        final bgMs = prefs.getInt(_backgroundedKey);
        if (bgMs != null) {
          final bg = DateTime.fromMillisecondsSinceEpoch(bgMs);
          _backgroundedAt = bg;
          final elapsed = _now().difference(bg);
          if (elapsed.isNegative || elapsed > _lockAfter) _locked = true;
        }
      }
    } catch (e) {
      Diag.swallow('app_lock.load', e);
      // The preferences read itself failed: if the last known state said the
      // lock was on, keep failing closed by staying locked.
      if (_enabled) _locked = true;
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Stores a new PIN and enables the lock.
  ///
  /// New PINs must be [pinLength] digits ([isValidNewPin]). Changing an
  /// existing PIN requires [currentPin]; a wrong current PIN is counted by the
  /// same rate limiter as an unlock attempt. Returns false for an invalid PIN,
  /// a wrong current PIN, an active cooldown, or a state that requires the
  /// account to re-authenticate first.
  ///
  /// When [recoveryRequired] the stored secret is unrecoverable, so no current
  /// PIN can be demanded: setting a new one is the PIN reset. Reaching this
  /// method still requires the user to get past the lock (biometrics) or to
  /// sign in again.
  Future<bool> setPin(String pin, {String? currentPin}) async {
    await load();
    if (!isValidNewPin(pin)) return false;
    _expireCooldownIfNeeded();
    if (inCooldown || _reauthRequired) return false;
    if (_enabled && !_recoveryRequired) {
      if (currentPin == null || !await _verify(currentPin)) {
        await _registerFailure();
        return false;
      }
    }

    if (!await _writeSecret(pin)) return false;

    _enabled = true;
    _locked = false;
    _recoveryRequired = false;
    _reauthRequired = false;
    _backgroundedAt = null;
    _failedAttempts = 0;
    _totalFailures = 0;
    _cooldownUntil = null;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Removes the PIN. Requires the current PIN, and is refused during the
  /// cooldown so an attacker cannot reset the rate limit by disabling.
  ///
  /// When [recoveryRequired] there is no verifiable secret left, so the reset
  /// needs no PIN; the user still had to get past the lock to be here.
  Future<bool> disable(String pin) async {
    await load();
    if (!_enabled) return true;
    if (_reauthRequired) return false;
    _expireCooldownIfNeeded();
    if (inCooldown) return false;
    if (!_recoveryRequired && !await _verify(pin)) {
      await _registerFailure();
      return false;
    }

    await _clearSecret();

    _enabled = false;
    _locked = false;
    _recoveryRequired = false;
    _reauthRequired = false;
    _backgroundedAt = null;
    _failedAttempts = 0;
    _totalFailures = 0;
    _cooldownUntil = null;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Verifies [pin] and, when correct, removes the lock screen.
  ///
  /// Returns true when the app is (or becomes) unlocked. During the cooldown
  /// even the correct PIN is refused — the countdown is the point. Once the
  /// cumulative cap is reached ([reauthRequired]) the PIN is refused until the
  /// account is re-authenticated, even though it is correct.
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
    if (_recoveryRequired || _reauthRequired) return false;
    _expireCooldownIfNeeded();
    if (inCooldown) return false;

    if (await _verify(pin)) {
      _locked = false;
      _failedAttempts = 0;
      _totalFailures = 0;
      _cooldownUntil = null;
      notifyListeners();
      await _persist();
      return true;
    }

    await _registerFailure();
    return false;
  }

  /// Unlocks through the injected [hook] (or [biometric]). Biometrics bypass
  /// the PIN cooldown and the cumulative cap: a successful platform
  /// authentication is stronger than the local PIN and cannot be brute-forced
  /// through this API. It is also the escape hatch when the stored secret is
  /// unreadable ([recoveryRequired]).
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
    _totalFailures = 0;
    _cooldownUntil = null;
    _reauthRequired = false;
    notifyListeners();
    await _persist();
    return true;
  }

  /// Clears the escalating lockout after the host re-authenticated the account
  /// (for example after a fresh sign-in). The PIN stays configured; only the
  /// failure counters and the [reauthRequired] flag are cleared.
  Future<void> completeAccountReauth() async {
    await load();
    _failedAttempts = 0;
    _totalFailures = 0;
    _cooldownUntil = null;
    _reauthRequired = false;
    // The account credential proved who the user is: drop the lock screen. An
    // unrecoverable secret still needs the explicit reset path.
    if (!_recoveryRequired) _locked = false;
    notifyListeners();
    await _persist();
  }

  /// Removes an unrecoverable secret after the host re-authenticated the
  /// account. Returns true when a reset actually happened.
  ///
  /// This is a no-op unless [recoveryRequired] or [reauthRequired] is set, so
  /// a normal sign-out never silently disables a working lock. Call it after a
  /// successful sign-out/sign-in: the account credential is the re-auth.
  Future<bool> resetAfterReauth() async {
    await load();
    if (!_enabled) return false;
    if (!_recoveryRequired && !_reauthRequired) return false;
    await _clearSecret();
    _enabled = false;
    _locked = false;
    _recoveryRequired = false;
    _reauthRequired = false;
    _backgroundedAt = null;
    _failedAttempts = 0;
    _totalFailures = 0;
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

  /// Records the moment the app left the foreground. Called for `paused` (and
  /// for `hidden` on non-mobile platforms) — never for `inactive`.
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
  /// `inactive`/`detached` are intentionally ignored: dialogs, permission
  /// sheets and the app switcher peek must not cover chat content. `hidden` is
  /// ignored on mobile (it precedes `paused`, and the app switcher emits it)
  /// but treated as backgrounded on desktop/web, where a window or tab switch
  /// never emits `paused`.
  Future<void> handleLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused ||
        (state == AppLifecycleState.hidden && _treatHiddenAsBackground)) {
      await markBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      await markResumed();
    }
  }

  /// A PIN is 4–6 ASCII digits. Leading zeros are valid.
  ///
  /// Kept for verifying PINs that were set before six digits became mandatory.
  /// New PINs must pass [isValidNewPin].
  static bool isValidPin(String pin) => RegExp(r'^\d{4,6}$').hasMatch(pin);

  /// A new PIN is exactly [pinLength] digits.
  static bool isValidNewPin(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

  static bool get _hiddenMeansBackgrounded {
    if (kIsWeb) return true;
    return defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS;
  }

  List<int> _newSalt() =>
      List<int>.generate(16, (_) => _random.nextInt(256), growable: false);

  /// `pbkdf2-sha256$<iterations>$<hex digest>`; the iteration count travels
  /// with the digest so a later upgrade can re-hash on the next success.
  static String _encodeHash(String pin, String saltText, int iterations) =>
      '${_ParsedHash.prefix}\$$iterations\$${_derivePin(pin, saltText, iterations)}';

  /// PBKDF2-HMAC-SHA256, 32-byte output (one block).
  static String _derivePin(String pin, String saltText, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(pin));
    final salt = utf8.encode(saltText);
    // Block index 1, big endian.
    final first = Uint8List(salt.length + 4)..setAll(0, salt);
    first[first.length - 1] = 1;

    var u = hmac.convert(first).bytes;
    final acc = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < acc.length; j++) {
        acc[j] ^= u[j];
      }
    }
    final hex = StringBuffer();
    for (final byte in acc) {
      hex.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  Future<bool> _verify(String pin) async {
    try {
      final saltText = await _storage.read(key: saltStorageKey);
      final stored = await _storage.read(key: hashStorageKey);
      if (saltText == null || stored == null) return false;

      final parsed = _ParsedHash.parse(stored);
      if (parsed == null) {
        // Legacy v1 digest: one plain SHA-256 over `salt:pin`.
        final legacy = sha256.convert(utf8.encode('$saltText:$pin')).toString();
        if (!_constantTimeEquals(legacy, stored)) return false;
        // Upgrade on the first successful legacy verification.
        await _rehash(pin);
        return true;
      }

      final actual = _derivePin(pin, saltText, parsed.iterations);
      if (!_constantTimeEquals(actual, parsed.digest)) return false;
      if (parsed.iterations < kdfIterations) await _rehash(pin);
      return true;
    } catch (e) {
      Diag.swallow('app_lock.verify', e);
      return false;
    }
  }

  /// Writes a fresh salt and a current-work-factor digest. Failure is
  /// swallowed: an already verified unlock must not be lost because the
  /// upgrade could not be persisted (the old digest still verifies).
  Future<void> _rehash(String pin) async {
    await _writeSecret(pin);
  }

  Future<bool> _writeSecret(String pin) async {
    final saltText = base64Encode(_newSalt());
    final hashText = _encodeHash(pin, saltText, kdfIterations);
    try {
      await _storage.write(key: saltStorageKey, value: saltText);
      await _storage.write(key: hashStorageKey, value: hashText);
      return true;
    } catch (e) {
      Diag.swallow('app_lock.setPin', e);
      return false;
    }
  }

  Future<void> _clearSecret() async {
    try {
      await _storage.delete(key: saltStorageKey);
      await _storage.delete(key: hashStorageKey);
    } catch (e) {
      Diag.swallow('app_lock.disable', e);
    }
  }

  Future<void> _registerFailure() async {
    _expireCooldownIfNeeded();
    if (_totalFailures < maxTrackedFailures) _totalFailures += 1;

    if (_totalFailures >= reauthThreshold) {
      // Capped: no more cooldown cycles, the local PIN is done.
      _reauthRequired = true;
      _locked = true;
      _cooldownUntil = null;
      _failedAttempts = maxAttempts;
    } else {
      _failedAttempts += 1;
      if (_failedAttempts >= maxAttempts) {
        _failedAttempts = maxAttempts;
        _cooldownUntil = _now().add(currentCooldown);
      }
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

  Future<_SecureRead> _readSecure(String key) async {
    try {
      return _SecureRead.value(await _storage.read(key: key));
    } catch (e) {
      Diag.swallow('app_lock.read', e);
      return const _SecureRead.failed();
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefsFactory();
      await prefs.setBool(_enabledKey, _enabled);
      await prefs.setInt(_lockAfterKey, _lockAfter.inMilliseconds);
      await prefs.setInt(_attemptsKey, _failedAttempts);
      await prefs.setInt(_totalAttemptsKey, _totalFailures);
      await prefs.setBool(_reauthKey, _reauthRequired);
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

/// Result of a secure-storage read that must distinguish "absent" from
/// "the platform refused to answer".
class _SecureRead {
  const _SecureRead.value(this.value) : failed = false;
  const _SecureRead.failed() : value = null, failed = true;

  final String? value;
  final bool failed;
}

/// Parsed `pbkdf2-sha256$<iterations>$<hex>` digest.
class _ParsedHash {
  const _ParsedHash(this.iterations, this.digest);

  static const String prefix = 'pbkdf2-sha256';
  static final RegExp _pattern = RegExp(
    '^$prefix'
    r'\$(\d{1,8})\$([0-9a-f]{64})$',
  );

  final int iterations;
  final String digest;

  static _ParsedHash? parse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    final iterations = int.tryParse(match.group(1)!);
    if (iterations == null ||
        iterations < 1 ||
        iterations > AppLock.maxStoredIterations) {
      return null;
    }
    return _ParsedHash(iterations, match.group(2)!);
  }
}
