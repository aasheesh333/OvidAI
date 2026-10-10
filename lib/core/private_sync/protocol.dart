/// Typed private-sync request and response envelopes.
library;

import 'dto.dart';

const _errorMessages = <String, String>{
  'invalid_request': 'The request is malformed.',
  'unauthenticated': 'Authentication is required.',
  'device_revoked': 'This device is no longer authorized for private sync.',
  'account_fenced': 'This account is not currently available for sync.',
  'not_found': 'The requested resource was not found.',
  'integrity_conflict':
      'The record conflicts with the stored canonical record.',
  'payload_too_large': 'The request or record exceeds the allowed size.',
  'schema_version_unsupported': 'The schema version is not supported.',
  'invalid_record': 'The record does not match the sync contract.',
  'endpoint_rejected':
      'The provider endpoint is not an allowed endpoint identity.',
  'rate_limited': 'Too many requests. Retry later.',
  'quota_exhausted': 'The sync quota is exhausted.',
  'temporarily_unavailable': 'The sync service is temporarily unavailable.',
  'reset_required': 'The sync state must be reset.',
};

Never _protocolInvalid() => throw const SyncDtoException(
  'invalid_record',
  'The sync protocol envelope is invalid.',
);

Map<String, Object?> _closed(Object? value, Set<String> fields) {
  if (value is! Map) _protocolInvalid();
  if (value.keys.any((key) => key is! String || !fields.contains(key))) {
    _protocolInvalid();
  }
  if (fields.any((field) => !value.containsKey(field))) _protocolInvalid();
  return value.cast<String, Object?>();
}

Map<String, Object?> _versioned(Object? value, Set<String> fields) {
  final map = _closed(value, fields);
  if (map['schemaVersion'] != syncSchemaVersion ||
      map['schemaVersion'] is! int) {
    _protocolInvalid();
  }
  return map;
}

String _text(Object? value, {bool empty = false}) {
  if (value is! String || (!empty && value.isEmpty) || value.length > 128) {
    _protocolInvalid();
  }
  for (final unit in value.codeUnits) {
    if (unit >= 0xD800 && unit <= 0xDFFF) _protocolInvalid();
  }
  return value;
}

int _positiveInt(Object? value) {
  if (value is! int || value < 1) _protocolInvalid();
  return value;
}

enum SyncRecordOutcomeStatus {
  accepted('accepted'),
  duplicate('duplicate'),
  rejected('rejected'),
  conflict('conflict'),
  retryable('retryable');

  const SyncRecordOutcomeStatus(this.wire);
  final String wire;

  static SyncRecordOutcomeStatus fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    _protocolInvalid();
  }
}

enum SyncEnrollmentStatus {
  active('active'),
  revoked('revoked');

  const SyncEnrollmentStatus(this.wire);
  final String wire;

  static SyncEnrollmentStatus fromWire(Object? value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    _protocolInvalid();
  }
}

enum SyncErrorCode {
  invalidRequest('invalid_request'),
  unauthenticated('unauthenticated'),
  deviceRevoked('device_revoked'),
  accountFenced('account_fenced'),
  notFound('not_found'),
  integrityConflict('integrity_conflict'),
  payloadTooLarge('payload_too_large'),
  schemaVersionUnsupported('schema_version_unsupported'),
  invalidRecord('invalid_record'),
  endpointRejected('endpoint_rejected'),
  rateLimited('rate_limited'),
  quotaExhausted('quota_exhausted'),
  temporarilyUnavailable('temporarily_unavailable'),
  resetRequired('reset_required');

  const SyncErrorCode(this.wire);
  final String wire;

  static SyncErrorCode fromWire(Object? value) {
    for (final code in values) {
      if (code.wire == value) return code;
    }
    _protocolInvalid();
  }
}

class SyncBatchRequest {
  SyncBatchRequest({
    required String idempotencyKey,
    required List<SyncUploadRecord> records,
  }) : idempotencyKey = _text(idempotencyKey),
       records = List.unmodifiable(records);

  factory SyncBatchRequest.fromWire(Object? value) {
    final map = _versioned(value, {
      'schemaVersion',
      'idempotencyKey',
      'records',
    });
    final key = _text(map['idempotencyKey']);
    final raw = map['records'];
    if (raw is! List) _protocolInvalid();
    return SyncBatchRequest(
      idempotencyKey: key,
      records: raw.map(SyncUploadRecord.fromWire).toList(),
    );
  }

  final String idempotencyKey;
  final List<SyncUploadRecord> records;
  int get schemaVersion => syncSchemaVersion;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'idempotencyKey': idempotencyKey,
    'records': List.unmodifiable(records.map((record) => record.toWire())),
  });
}

class SyncFailure {
  SyncFailure({required this.code, required Object? retryAfterSeconds})
    : message = _errorMessages[code.wire]!,
      retryAfterSeconds = retryAfterSeconds == null
          ? null
          : _boundedRetry(retryAfterSeconds);

  factory SyncFailure.fromWire(Object? value) {
    final map = _versioned(value, {
      'schemaVersion',
      'code',
      'message',
      'retryAfterSeconds',
    });
    final code = SyncErrorCode.fromWire(map['code']);
    if (map['message'] != _errorMessages[code.wire]) _protocolInvalid();
    return SyncFailure(code: code, retryAfterSeconds: map['retryAfterSeconds']);
  }

  static int _boundedRetry(Object? value) {
    if (value is! int || value < 0 || value > 86400) _protocolInvalid();
    return value;
  }

  final SyncErrorCode code;
  final String message;
  final int? retryAfterSeconds;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'code': code.wire,
    'message': message,
    'retryAfterSeconds': retryAfterSeconds,
  });
}

class SyncResetRequired implements Exception {
  const SyncResetRequired();
}

class SyncRecordOutcome {
  SyncRecordOutcome({
    required String recordId,
    required this.status,
    required this.revision,
    required this.changeSequence,
    required this.error,
  }) : recordId = _text(recordId);

  factory SyncRecordOutcome.fromWire(Object? value) {
    final map = _closed(value, {
      'recordId',
      'status',
      'revision',
      'changeSequence',
      'error',
    });
    final status = SyncRecordOutcomeStatus.fromWire(map['status']);
    final revision = map['revision'] == null
        ? null
        : _positiveInt(map['revision']);
    final sequence = map['changeSequence'] == null
        ? null
        : _positiveInt(map['changeSequence']);
    final error = map['error'] == null
        ? null
        : SyncFailure.fromWire(map['error']);
    final successful =
        status == SyncRecordOutcomeStatus.accepted ||
        status == SyncRecordOutcomeStatus.duplicate;
    if (successful != (revision != null && sequence != null && error == null)) {
      _protocolInvalid();
    }
    if (!successful &&
        !(error != null && revision == null && sequence == null)) {
      _protocolInvalid();
    }
    return SyncRecordOutcome(
      recordId: map['recordId'] as String,
      status: status,
      revision: revision,
      changeSequence: sequence,
      error: error,
    );
  }

  final String recordId;
  final SyncRecordOutcomeStatus status;
  final int? revision;
  final int? changeSequence;
  final SyncFailure? error;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'recordId': recordId,
    'status': status.wire,
    'revision': revision,
    'changeSequence': changeSequence,
    'error': error?.toWire(),
  });
}

class SyncBatchResult {
  SyncBatchResult({required List<SyncRecordOutcome> results})
    : results = List.unmodifiable(results);

  factory SyncBatchResult.fromWire(Object? value) {
    final map = _versioned(value, {'schemaVersion', 'results'});
    final raw = map['results'];
    if (raw is! List) _protocolInvalid();
    return SyncBatchResult(
      results: raw.map(SyncRecordOutcome.fromWire).toList(),
    );
  }

  final List<SyncRecordOutcome> results;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'results': List.unmodifiable(results.map((result) => result.toWire())),
  });
}

class SyncChangePage {
  SyncChangePage({
    required String nextCursor,
    required this.hasMore,
    required List<SyncReplayRecord> records,
  }) : nextCursor = _text(nextCursor, empty: true),
       records = List.unmodifiable(records);

  factory SyncChangePage.fromWire(Object? value) {
    final map = _versioned(value, {
      'schemaVersion',
      'nextCursor',
      'hasMore',
      'records',
    });
    final raw = map['records'];
    if (raw is! List || map['hasMore'] is! bool) _protocolInvalid();
    return SyncChangePage(
      nextCursor: map['nextCursor'] as String,
      hasMore: map['hasMore'] as bool,
      records: raw.map(SyncReplayRecord.fromWire).toList(),
    );
  }

  final String nextCursor;
  final bool hasMore;
  final List<SyncReplayRecord> records;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'nextCursor': nextCursor,
    'hasMore': hasMore,
    'records': List.unmodifiable(records.map((record) => record.toWire())),
  });
}

class SyncEnrollment {
  SyncEnrollment({
    required String deviceId,
    required String deviceName,
    required String createdAt,
    required this.status,
  }) : deviceId = _text(deviceId),
       deviceName = _text(deviceName, empty: true),
       createdAt = _timestamp(createdAt);

  factory SyncEnrollment.fromWire(Object? value) {
    final map = _versioned(value, {
      'schemaVersion',
      'deviceId',
      'deviceName',
      'createdAt',
      'status',
    });
    return SyncEnrollment(
      deviceId: map['deviceId'] as String,
      deviceName: map['deviceName'] as String,
      createdAt: map['createdAt'] as String,
      status: SyncEnrollmentStatus.fromWire(map['status']),
    );
  }

  final String deviceId;
  final String deviceName;
  final String createdAt;
  final SyncEnrollmentStatus status;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'createdAt': createdAt,
    'status': status.wire,
  });
}

class SyncStatePage {
  SyncStatePage({
    required String accountId,
    required String currentCursor,
    required List<SyncReplayRecord> records,
    required String enrollmentStatus,
    required List<String> retentionMarkers,
  }) : accountId = _text(accountId),
       currentCursor = _text(currentCursor, empty: true),
       records = List.unmodifiable(records),
       enrollmentStatus = _text(enrollmentStatus),
       retentionMarkers = List.unmodifiable(retentionMarkers.map(_text));

  factory SyncStatePage.fromWire(Object? value) {
    final map = _versioned(value, {
      'schemaVersion',
      'accountId',
      'currentCursor',
      'records',
      'enrollmentStatus',
      'retentionMarkers',
    });
    final records = map['records'];
    final markers = map['retentionMarkers'];
    if (records is! List || markers is! List) _protocolInvalid();
    return SyncStatePage(
      currentCursor: map['currentCursor'] as String,
      accountId: map['accountId'] as String,
      records: records.map(SyncReplayRecord.fromWire).toList(),
      enrollmentStatus: map['enrollmentStatus'] as String,
      retentionMarkers: markers.cast<String>(),
    );
  }

  final String currentCursor;
  final String accountId;
  final List<SyncReplayRecord> records;
  final String enrollmentStatus;
  final List<String> retentionMarkers;

  Map<String, Object?> toWire() => Map.unmodifiable({
    'schemaVersion': syncSchemaVersion,
    'accountId': accountId,
    'currentCursor': currentCursor,
    'records': List.unmodifiable(records.map((record) => record.toWire())),
    'enrollmentStatus': enrollmentStatus,
    'retentionMarkers': List.unmodifiable(retentionMarkers),
  });
}

String _timestamp(Object? value) {
  if (value is! String ||
      !value.endsWith('Z') ||
      value.length > 30 ||
      value.codeUnits.any((unit) => unit > 0x7F)) {
    _protocolInvalid();
  }
  return value;
}
