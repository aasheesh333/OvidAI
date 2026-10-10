/// Durable, account-scoped private sync upload outbox.
library;

import 'dart:async';

import 'canonical.dart';
import 'dto.dart';

/// The storage primitive required by [PrivateSyncOutbox]. Implementations must
/// replace the previous value atomically, including across process crashes.
abstract interface class OutboxPersistence {
  Future<List<int>?> read();

  Future<void> writeAtomically(List<int> bytes);
}

enum OutboxState { pending, retryable, acknowledged, terminal }

class OutboxFencedException implements Exception {
  const OutboxFencedException();

  @override
  String toString() => 'OutboxFencedException';
}

class OutboxStateException implements Exception {
  const OutboxStateException(this.message);
  final String message;

  @override
  String toString() => 'OutboxStateException: $message';
}

class OutboxFormatException extends FormatException {
  const OutboxFormatException(super.message);
}

class OutboxEntry {
  const OutboxEntry({
    required this.idempotencyKey,
    required this.envelope,
    required this.state,
    required this.attempts,
    required this.error,
  });

  final String idempotencyKey;
  final SyncUploadRecord envelope;
  final OutboxState state;
  final int attempts;
  final String? error;
}

class PrivateSyncOutbox {
  PrivateSyncOutbox._(
    this._persistence,
    this._accountId,
    this._ownerId,
    this._entries,
  );

  static const _version = 1;
  static const _maxIdLength = 256;

  final OutboxPersistence _persistence;
  final String _accountId;
  final String _ownerId;
  final Map<String, OutboxEntry> _entries;
  Future<void> _writeTail = Future<void>.value();

  static Future<PrivateSyncOutbox> open(
    OutboxPersistence persistence, {
    required String accountId,
    required String ownerId,
  }) async {
    _validateId(accountId);
    _validateId(ownerId);
    final bytes = await persistence.read();
    final decoded = bytes == null ? null : decodeStrictJsonUtf8(bytes);
    final data = decoded == null ? null : _map(decoded);
    if (data != null && data['accountId'] != accountId) {
      throw const OutboxFormatException('account mismatch');
    }

    final entries = <String, OutboxEntry>{};
    if (data != null) {
      if (data['schemaVersion'] != _version) {
        throw const OutboxFormatException('unsupported outbox version');
      }
      for (final raw in _list(data['entries'])) {
        final entry = _decodeEntry(raw);
        if (entries.containsKey(entry.idempotencyKey)) {
          throw const OutboxFormatException('duplicate idempotency key');
        }
        entries[entry.idempotencyKey] = entry;
      }
    }

    final outbox = PrivateSyncOutbox._(
      persistence,
      accountId,
      ownerId,
      entries,
    );
    if (data == null || data['ownerId'] != ownerId) {
      await outbox._persist();
    }
    return outbox;
  }

  Future<List<OutboxEntry>> entries() async =>
      List.unmodifiable(_entries.values);

  Future<OutboxEntry> enqueue(
    String idempotencyKey,
    SyncUploadRecord envelope,
  ) async {
    _validateId(idempotencyKey);
    await _fence();
    final existing = _entries[idempotencyKey];
    if (existing != null) return existing;
    final entry = OutboxEntry(
      idempotencyKey: idempotencyKey,
      envelope: envelope,
      state: OutboxState.pending,
      attempts: 0,
      error: null,
    );
    final next = Map<String, OutboxEntry>.of(_entries)
      ..[idempotencyKey] = entry;
    await _persist(next);
    _entries
      ..clear()
      ..addAll(next);
    return entry;
  }

  Future<OutboxEntry> acknowledge(String idempotencyKey) async {
    return _transition(idempotencyKey, OutboxState.acknowledged);
  }

  Future<OutboxEntry> retry(String idempotencyKey) async {
    await _fence();
    final old = _required(idempotencyKey);
    if (old.state == OutboxState.acknowledged ||
        old.state == OutboxState.terminal) {
      throw const OutboxStateException('entry is terminal');
    }
    final entry = OutboxEntry(
      idempotencyKey: old.idempotencyKey,
      envelope: old.envelope,
      state: OutboxState.retryable,
      attempts: old.attempts + 1,
      error: null,
    );
    return _replace(entry);
  }

  Future<OutboxEntry> terminal(String idempotencyKey, String error) async {
    if (error.isEmpty) throw const OutboxStateException('error is required');
    return _transition(idempotencyKey, OutboxState.terminal, error: error);
  }

  Future<void> clearAccount() async {
    await _fence();
    await _persist(<String, OutboxEntry>{});
    _entries.clear();
  }

  Future<OutboxEntry> _transition(
    String key,
    OutboxState state, {
    String? error,
  }) async {
    await _fence();
    final old = _required(key);
    if (old.state == OutboxState.acknowledged ||
        old.state == OutboxState.terminal) {
      throw const OutboxStateException('entry is terminal');
    }
    return _replace(
      OutboxEntry(
        idempotencyKey: old.idempotencyKey,
        envelope: old.envelope,
        state: state,
        attempts: old.attempts,
        error: error,
      ),
    );
  }

  Future<OutboxEntry> _replace(OutboxEntry entry) async {
    final next = Map<String, OutboxEntry>.of(_entries)
      ..[entry.idempotencyKey] = entry;
    await _persist(next);
    _entries
      ..clear()
      ..addAll(next);
    return entry;
  }

  OutboxEntry _required(String key) =>
      _entries[key] ?? (throw const OutboxStateException('entry not found'));

  Future<void> _fence() async {
    final bytes = await _persistence.read();
    if (bytes == null) throw const OutboxFencedException();
    final data = _map(decodeStrictJsonUtf8(bytes));
    if (data['accountId'] != _accountId || data['ownerId'] != _ownerId) {
      throw const OutboxFencedException();
    }
  }

  Future<void> _persist([Map<String, OutboxEntry>? values]) {
    final data = <String, Object?>{
      'schemaVersion': _version,
      'accountId': _accountId,
      'ownerId': _ownerId,
      'entries': (values ?? _entries).values.map(_encodeEntry).toList(),
    };
    final bytes = canonicalSyncBytes(data);
    final operation = _writeTail.then(
      (_) => _persistence.writeAtomically(bytes),
    );
    _writeTail = operation.catchError((Object _) {});
    return operation;
  }
}

Map<String, Object?> _encodeEntry(OutboxEntry entry) => {
  'idempotencyKey': entry.idempotencyKey,
  'envelope': entry.envelope.toWire(),
  'state': entry.state.name,
  'attempts': entry.attempts,
  'error': entry.error,
};

OutboxEntry _decodeEntry(Object? value) {
  final map = _map(value);
  final key = _string(map['idempotencyKey']);
  _validateId(key);
  final stateName = _string(map['state']);
  final state = OutboxState.values.firstWhere(
    (s) => s.name == stateName,
    orElse: () => throw const OutboxFormatException('invalid state'),
  );
  final attempts = map['attempts'];
  if (attempts is! int || attempts < 0) {
    throw const OutboxFormatException('invalid attempts');
  }
  final error = map['error'];
  if (error != null && error is! String) {
    throw const OutboxFormatException('invalid error');
  }
  return OutboxEntry(
    idempotencyKey: key,
    envelope: SyncUploadRecord.fromWire(map['envelope']),
    state: state,
    attempts: attempts,
    error: error as String?,
  );
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map) throw const OutboxFormatException('expected object');
  return value.cast<String, Object?>();
}

List<Object?> _list(Object? value) {
  if (value is! List) throw const OutboxFormatException('expected list');
  return value.cast<Object?>();
}

String _string(Object? value) {
  if (value is! String) throw const OutboxFormatException('expected string');
  return value;
}

void _validateId(String value) {
  if (value.isEmpty || value.length > PrivateSyncOutbox._maxIdLength) {
    throw const OutboxFormatException('invalid identifier');
  }
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) < 0x21 || value.codeUnitAt(i) > 0x7e) {
      throw const OutboxFormatException('invalid identifier');
    }
  }
}
