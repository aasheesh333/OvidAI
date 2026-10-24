import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../diag.dart';
import '../secret_scrub.dart';

typedef PushDeviceRegister = Future<void> Function(String uid, String token);
typedef PushDeviceUnregister = Future<void> Function(String uid, String token);
typedef PushTokenReader = Future<String?> Function();
typedef PushTokenInvalidator = Future<void> Function();

/// Independent facts about push readiness. [registered] is set by the
/// coordinator only for the current token after an actual gateway 2xx (or
/// after matching a restored acknowledgement to the current FCM token).
class PushHealthSnapshot {
  const PushHealthSnapshot({
    this.osPermissionGranted,
    this.channelsReady,
    this.tokenAvailable = false,
    this.desiredUid,
    this.acknowledgedUid,
    this.acknowledgedToken,
    this.generation = 0,
    this.retryCount = 0,
    this.retryPending = false,
    this.registered = false,
    this.lastError,
  });

  final bool? osPermissionGranted;
  final bool? channelsReady;
  final bool tokenAvailable;
  final String? desiredUid;
  final String? acknowledgedUid;
  final String? acknowledgedToken;
  final int generation;
  final int retryCount;
  final bool retryPending;
  final bool registered;
  final String? lastError;
}

/// Durable registration facts. This record deliberately has no auth-token or
/// authorization-header field. The FCM acknowledgement is device state, not a
/// credential used by this coordinator.
class PushRegistrationRecord {
  const PushRegistrationRecord({
    this.desiredUid,
    this.acknowledgedUid,
    this.acknowledgedToken,
    this.generation = 0,
  });

  final String? desiredUid;
  final String? acknowledgedUid;
  final String? acknowledgedToken;
  final int generation;

  Map<String, Object?> toJson() => {
    'desiredUid': desiredUid,
    'acknowledgedUid': acknowledgedUid,
    'acknowledgedToken': acknowledgedToken,
    'generation': generation,
  };

  static PushRegistrationRecord? fromJson(Object? value) {
    if (value is! Map) return null;
    String? uid(String key) {
      final raw = value[key];
      if (raw == null) return null;
      if (raw is! String || raw.trim().isEmpty) {
        throw const FormatException('Invalid push registration identity.');
      }
      return raw;
    }

    final generation = value['generation'];
    if (generation is! int || generation < 0) {
      throw const FormatException('Invalid push registration generation.');
    }
    final acknowledgedUid = uid('acknowledgedUid');
    final acknowledgedToken = uid('acknowledgedToken');
    if ((acknowledgedUid == null) != (acknowledgedToken == null)) {
      throw const FormatException('Incomplete push acknowledgement.');
    }
    return PushRegistrationRecord(
      desiredUid: uid('desiredUid'),
      acknowledgedUid: acknowledgedUid,
      acknowledgedToken: acknowledgedToken,
      generation: generation,
    );
  }
}

abstract class PushRegistrationStore {
  Future<PushRegistrationRecord?> read();
  Future<void> write(PushRegistrationRecord record);
}

class SharedPreferencesPushRegistrationStore implements PushRegistrationStore {
  static const storageKey = 'ovid_push_registration_v1';

  @override
  Future<PushRegistrationRecord?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(storageKey);
    if (raw == null) return null;
    try {
      return PushRegistrationRecord.fromJson(jsonDecode(raw));
    } catch (_) {
      Diag.swallow(
        'push.registration_restore',
        StateError('Saved push registration state was invalid.'),
      );
      return null;
    }
  }

  @override
  Future<void> write(PushRegistrationRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(storageKey, jsonEncode(record.toJson()));
  }
}

/// One serialized queue for account binding, unbinding, replacement tokens and
/// account switches. Public methods fence older generations synchronously;
/// network completion can therefore never resurrect an older account.
class PushRegistrationCoordinator {
  PushRegistrationCoordinator._({
    required this._register,
    required this._unregister,
    required this._getToken,
    required this._deleteToken,
    required this._store,
    required PushRegistrationRecord record,
    required int maxAttempts,
    required Duration initialBackoff,
    required Duration maxBackoff,
    required this._delay,
  }) : _desiredUid = record.desiredUid,
       _acknowledgedUid = record.acknowledgedUid,
       _acknowledgedToken = record.acknowledgedToken,
       _generation = record.generation,
       _maxAttempts = maxAttempts,
       _initialBackoff = initialBackoff,
       _maxBackoff = maxBackoff {
    if (maxAttempts < 1) throw ArgumentError.value(maxAttempts, 'maxAttempts');
    if (initialBackoff.isNegative || maxBackoff.isNegative) {
      throw ArgumentError('Push retry delays cannot be negative.');
    }
    final uid = record.acknowledgedUid;
    final token = record.acknowledgedToken;
    if (uid != null && token != null) _knownTokens[uid] = {token};
  }

  static Future<PushRegistrationCoordinator> open({
    required PushDeviceRegister register,
    required PushDeviceUnregister unregister,
    required PushTokenReader getToken,
    required PushTokenInvalidator deleteToken,
    PushRegistrationStore? store,
    int maxAttempts = 3,
    Duration initialBackoff = const Duration(milliseconds: 250),
    Duration maxBackoff = const Duration(seconds: 2),
    Future<void> Function(Duration delay)? delay,
  }) async {
    final actualStore = store ?? SharedPreferencesPushRegistrationStore();
    final record = await actualStore.read();
    return PushRegistrationCoordinator._(
      register: register,
      unregister: unregister,
      getToken: getToken,
      deleteToken: deleteToken,
      store: actualStore,
      record: record ?? const PushRegistrationRecord(),
      maxAttempts: maxAttempts,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      delay: delay ?? Future<void>.delayed,
    );
  }

  final PushDeviceRegister _register;
  final PushDeviceUnregister _unregister;
  final PushTokenReader _getToken;
  final PushTokenInvalidator _deleteToken;
  final PushRegistrationStore _store;
  final int _maxAttempts;
  final Duration _initialBackoff;
  final Duration _maxBackoff;
  final Future<void> Function(Duration delay) _delay;

  String? _desiredUid;
  String? _acknowledgedUid;
  String? _acknowledgedToken;
  String? _currentToken;
  int _tokenRevision = 0;
  int _generation;
  int _retryCount = 0;
  bool _retryPending = false;
  bool _registered = false;
  String? _lastError;
  bool? _osPermissionGranted;
  bool? _channelsReady;

  final _knownTokens = <String, Set<String>>{};
  final _retiredTokens = <String>{};
  Future<void> _tail = Future<void>.value();

  PushHealthSnapshot get health => PushHealthSnapshot(
    osPermissionGranted: _osPermissionGranted,
    channelsReady: _channelsReady,
    tokenAvailable: _currentToken != null && _currentToken!.isNotEmpty,
    desiredUid: _desiredUid,
    acknowledgedUid: _acknowledgedUid,
    acknowledgedToken: _acknowledgedToken,
    generation: _generation,
    retryCount: _retryCount,
    retryPending: _retryPending,
    registered: _registered,
    lastError: _lastError,
  );

  void updateReadiness({bool? osPermissionGranted, bool? channelsReady}) {
    if (osPermissionGranted != null) {
      _osPermissionGranted = osPermissionGranted;
    }
    if (channelsReady != null) _channelsReady = channelsReady;
  }

  Future<int> bindAccount(String uid) {
    final cleanUid = _validUid(uid);
    final generation = _beginOperation();
    _desiredUid = cleanUid;
    _currentToken = null;
    return _enqueue(() => _bind(cleanUid, generation)).then((_) => generation);
  }

  Future<void> unbindAccount({
    Duration timeout = const Duration(seconds: 6),
    String? expectedUid,
    int? expectedGeneration,
  }) {
    final uid = expectedUid ?? _desiredUid ?? _acknowledgedUid;
    final generation = expectedGeneration ?? _generation;
    // Revalidate before advancing state: A's teardown may have waited for an
    // auth/listener boundary while B became the desired/acknowledged account.
    if (generation != _generation ||
        uid == null ||
        (expectedUid != null &&
            _desiredUid != expectedUid &&
            _acknowledgedUid != expectedUid)) {
      return Future<void>.value();
    }
    final tokens = _tokensForAccount(uid);
    final tokenRevision = _tokenRevision;
    _beginOperation();
    final operationGeneration = _generation;
    _desiredUid = null;
    _currentToken = null;
    return _enqueue(() async {
      await _persistSafely();
      // Newer desired generations may queue behind this cleanup, but they must
      // not suppress retirement of the outgoing token they could otherwise read.
      await _cleanupAccount(
        uid,
        tokens,
        tokenRevision,
        timeout,
        operationGeneration,
      );
      if (operationGeneration == _generation) await _persistSafely();
    });
  }

  Future<void> switchAccount(
    String oldUid,
    String newUid, {
    Duration timeout = const Duration(seconds: 6),
  }) {
    final previous = _validUid(oldUid);
    final replacement = _validUid(newUid);
    final previousTokens = _tokensForAccount(previous);
    final previousTokenRevision = _tokenRevision;
    final generation = _beginOperation();
    _desiredUid = replacement;
    _currentToken = null;
    return _enqueue(() async {
      await _persistSafely();
      if (previous != replacement) {
        await _cleanupAccount(
          previous,
          previousTokens,
          previousTokenRevision,
          timeout,
          generation,
        );
      }
      if (!_isCurrent(replacement, generation)) return;
      await _bind(replacement, generation);
    });
  }

  Future<void> refreshToken(String token, {required int generation}) {
    final replacement = token.trim();
    final uid = _desiredUid;
    if (replacement.isEmpty || uid == null || generation != _generation) {
      return Future<void>.value();
    }
    if (_retiredTokens.contains(replacement)) return Future<void>.value();
    return _enqueue(() => _refresh(uid, replacement, generation));
  }

  Future<void> drain() => _tail;

  int _beginOperation() {
    _generation++;
    _registered = false;
    _retryCount = 0;
    _retryPending = false;
    _lastError = null;
    return _generation;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _tail.then((_) async {
      try {
        await operation();
      } catch (error) {
        _recordError('push.registration_queue', error);
      }
    });
    _tail = next;
    return next;
  }

  Future<void> _bind(String uid, int generation) async {
    if (!_isCurrent(uid, generation)) return;
    await _persistSafely();
    String? token;
    try {
      token = (await _getToken())?.trim();
    } catch (error) {
      if (_isCurrent(uid, generation)) _recordError('push.token_read', error);
      return;
    }
    if (!_isCurrent(uid, generation)) return;
    if (token == null || token.isEmpty || _retiredTokens.contains(token)) {
      _currentToken = null;
      _registered = false;
      return;
    }
    _tokenRevision++;
    _currentToken = token;
    (_knownTokens[uid] ??= {}).add(token);
    final previous = _acknowledgedUid == uid ? _acknowledgedToken : null;
    if (_acknowledgedUid == uid && _acknowledgedToken == token) {
      _registered = true;
      _retryCount = 0;
      _retryPending = false;
      _lastError = null;
      await _persistSafely();
      return;
    }
    if (!await _registerWithRetry(uid, token, generation)) return;
    await _cleanupReplacedToken(uid, previous, token, generation);
  }

  Future<void> _refresh(String uid, String token, int generation) async {
    if (!_isCurrent(uid, generation) || _retiredTokens.contains(token)) return;
    final previous =
        _currentToken ?? (_acknowledgedUid == uid ? _acknowledgedToken : null);
    _tokenRevision++;
    _currentToken = token;
    _registered = false;
    _retryCount = 0;
    _retryPending = false;
    _lastError = null;
    (_knownTokens[uid] ??= {}).add(token);

    if (_acknowledgedUid == uid && _acknowledgedToken == token) {
      _registered = true;
      return;
    }
    if (!await _registerWithRetry(uid, token, generation)) return;
    await _cleanupReplacedToken(uid, previous, token, generation);
  }

  Future<void> _cleanupReplacedToken(
    String uid,
    String? previous,
    String replacement,
    int generation,
  ) async {
    if (previous == null || previous == replacement) return;

    // Register first: a failed replacement must not create a coverage gap by
    // deleting the still-valid server registration. Never call FCM deleteToken
    // here; that would invalidate the replacement we just acknowledged.
    _retiredTokens.add(previous);
    try {
      await _unregister(uid, previous);
      _knownTokens[uid]?.remove(previous);
    } catch (error) {
      if (_isCurrent(uid, generation)) {
        _recordError('push.unregister_replaced_token', error);
      }
    }
    await _persistSafely();
  }

  Future<bool> _registerWithRetry(
    String uid,
    String token,
    int generation,
  ) async {
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (!_isCurrent(uid, generation)) return false;
      _retryPending = false;
      try {
        await _register(uid, token);
        // Even a stale successful call has a real server side effect. Remember
        // it for outgoing-account cleanup, but never publish its ack to health.
        (_knownTokens[uid] ??= {}).add(token);
        if (!_isCurrent(uid, generation)) return false;
        _acknowledgedUid = uid;
        _acknowledgedToken = token;
        _tokenRevision++;
        _currentToken = token;
        _registered = true;
        _retryCount = 0;
        _retryPending = false;
        _lastError = null;
        await _persistSafely();
        return true;
      } catch (error) {
        if (!_isCurrent(uid, generation)) return false;
        _lastError = _sanitize(error);
        _retryCount = attempt;
        if (attempt + 1 >= _maxAttempts) {
          _retryPending = false;
          Diag.swallow('push.register_device', StateError(_lastError!));
          return false;
        }
        _retryCount = attempt + 1;
        _retryPending = true;
        final backoff = _backoff(attempt);
        await _delay(backoff);
      }
    }
    return false;
  }

  Duration _backoff(int retry) {
    var duration = _initialBackoff * (1 << retry);
    if (duration > _maxBackoff) duration = _maxBackoff;
    return duration;
  }

  Set<String> _tokensForAccount(String uid) => {
    ...?_knownTokens[uid],
    if (_acknowledgedUid == uid && _acknowledgedToken != null)
      _acknowledgedToken!,
  };

  Future<void> _cleanupAccount(
    String uid,
    Set<String> tokens,
    int tokenRevision,
    Duration timeout,
    int generation,
  ) async {
    for (final token in tokens) {
      try {
        await _unregister(uid, token).timeout(timeout);
        _knownTokens[uid]?.remove(token);
      } catch (error) {
        if (generation == _generation) {
          _recordError('push.unregister_device', error);
        }
      }
      _retiredTokens.add(token);
    }

    // Clear only the outgoing identities captured above. A replacement may
    // already own desired/ack/current state; stale A must never clear it.
    if (_acknowledgedUid == uid && tokens.contains(_acknowledgedToken)) {
      _acknowledgedUid = null;
      _acknowledgedToken = null;
    }
    final remaining = _knownTokens[uid];
    remaining?.removeAll(tokens);
    if (remaining != null && remaining.isEmpty) _knownTokens.remove(uid);
    if (_currentToken != null && tokens.contains(_currentToken)) {
      _currentToken = null;
      _registered = false;
    } else if (generation == _generation) {
      _registered = false;
    }

    // Queue serialization means a queued replacement has not acquired a token
    // yet. If a newer token nevertheless exists, never invalidate it. Failed
    // deletion still leaves every outgoing token retired, so it cannot rebind.
    final canDeleteCurrent =
        _currentToken == null || tokens.contains(_currentToken);
    if (tokens.isNotEmpty &&
        _tokenRevision == tokenRevision &&
        canDeleteCurrent) {
      try {
        await _deleteToken().timeout(timeout);
      } catch (error) {
        if (generation == _generation) {
          _recordError('push.delete_token', error);
        }
      }
    }
  }

  bool _isCurrent(String uid, int generation) =>
      generation == _generation && uid == _desiredUid;

  Future<void> _persistSafely() async {
    try {
      await _store.write(
        PushRegistrationRecord(
          desiredUid: _desiredUid,
          acknowledgedUid: _acknowledgedUid,
          acknowledgedToken: _acknowledgedToken,
          generation: _generation,
        ),
      );
    } catch (error) {
      _recordError('push.registration_persist', error);
    }
  }

  void _recordError(String context, Object error) {
    final sanitized = _sanitize(error);
    _lastError = sanitized;
    Diag.swallow(context, StateError(sanitized));
  }

  String _sanitize(Object error) {
    var text = scrubSecretsInText('$error');
    final secrets = <String>{
      ?_currentToken,
      ?_acknowledgedToken,
      for (final tokens in _knownTokens.values) ...tokens,
      ..._retiredTokens,
    };
    for (final secret in secrets) {
      if (secret.isNotEmpty) text = text.replaceAll(secret, kScrubbed);
    }
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }

  String _validUid(String uid) {
    final clean = uid.trim();
    if (clean.isEmpty) {
      throw ArgumentError.value(uid, 'uid', 'Must not be empty');
    }
    return clean;
  }
}
