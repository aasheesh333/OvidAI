/// Closed v1 wire DTOs for private account sync.
///
/// Every class is immutable, validates on construction, and round-trips
/// through `fromWire`/`toWire` using the exact camelCase wire names from
/// `docs/superpowers/specs/2026-10-08-private-account-sync-design.md`.
/// Unknown, missing, mistyped and out-of-range fields are rejected. Transcript
/// text is preserved verbatim; no redaction is applied.
///
/// Pure data code: no Flutter UI, HTTP, app state, or executable imports, and
/// no credential fields.
library;

import 'dart:typed_data';

import 'canonical.dart';
import 'endpoint_policy.dart';

/// The only supported wire schema version.
const int syncSchemaVersion = 1;

const int maxInt32 = 2147483647;
const int maxUint32 = 4294967295;
const int maxElapsedMilliseconds = 604800000;

/// Typed DTO rejection. [code] is one of the closed sync error codes
/// (`invalid_record`, `schema_version_unsupported`, `endpoint_rejected`).
/// The message is fixed and never contains input values.
class SyncDtoException extends FormatException {
  const SyncDtoException(this.code, String message) : super(message);

  final String code;

  @override
  String toString() => 'SyncDtoException($code): $message';
}

Never _invalid(String message) =>
    throw SyncDtoException('invalid_record', message);

// ---------------------------------------------------------------------------
// Enums

enum SyncRecordType {
  transcript('transcript'),
  providerMetadata('providerMetadata'),
  usage('usage'),
  activity('activity'),
  tombstone('tombstone');

  const SyncRecordType(this.wire);
  final String wire;
}

enum TranscriptKind {
  user('user'),
  assistant('assistant'),
  system('system'),
  tool('tool');

  const TranscriptKind(this.wire);
  final String wire;
}

enum UsageOutcome {
  pending('pending'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled'),
  interrupted('interrupted'),
  unknown('unknown');

  const UsageOutcome(this.wire);
  final String wire;
}

enum UsageProvenance {
  providerReported('providerReported'),
  locallyEstimated('locallyEstimated'),
  derived('derived'),
  unknown('unknown'),
  legacyUnspecified('legacyUnspecified');

  const UsageProvenance(this.wire);
  final String wire;
}

enum ActivityKind {
  request('request'),
  tool('tool'),
  mcp('mcp'),
  plugin('plugin'),
  browser('browser'),
  build('build'),
  system('system');

  const ActivityKind(this.wire);
  final String wire;
}

enum ActivityStatus {
  queued('queued'),
  started('started'),
  succeeded('succeeded'),
  failed('failed'),
  cancelled('cancelled'),
  interrupted('interrupted'),
  unknown('unknown');

  const ActivityStatus(this.wire);
  final String wire;
}

enum TombstoneReason {
  user('user'),
  account('account'),
  retention('retention'),
  conflict('conflict'),
  admin('admin');

  const TombstoneReason(this.wire);
  final String wire;
}

// ---------------------------------------------------------------------------
// Field validators (shared by constructors and decoders)

/// IDs: printable ASCII (0x21–0x7E), 1–[max] bytes.
String _id(Object? value, {int max = 128}) {
  if (value is! String) _invalid('identifier must be a string');
  if (value.isEmpty || value.length > max) {
    _invalid('identifier length out of range');
  }
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c < 0x21 || c > 0x7E) _invalid('identifier must be printable ASCII');
  }
  return value;
}

String? _idOrNull(Object? value, {int max = 128}) =>
    value == null ? null : _id(value, max: max);

/// Text bounded in Unicode scalar values; lone surrogates are rejected.
String _text(Object? value, int min, int max) {
  if (value is! String) _invalid('text must be a string');
  var scalars = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= value.length) _invalid('lone surrogate');
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) _invalid('lone surrogate');
      i++;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      _invalid('lone surrogate');
    }
    scalars++;
  }
  if (scalars < min || scalars > max) _invalid('text length out of range');
  return value;
}

String? _textOrNull(Object? value, int min, int max) =>
    value == null ? null : _text(value, min, max);

final _timestampPattern = RegExp(
    r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]{1,9})?Z$');

/// UTC RFC 3339 with uppercase `T`/`Z`, optional 1–9 fractional digits,
/// at most 30 bytes, valid calendar date, no leap second.
String _timestamp(Object? value) {
  if (value is! String) _invalid('timestamp must be a string');
  if (value.length > 30) _invalid('timestamp too long');
  final match = _timestampPattern.firstMatch(value);
  if (match == null) _invalid('timestamp must be UTC RFC 3339');
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  if (month < 1 || month > 12) _invalid('timestamp out of range');
  final leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final maxDay = month == 2 && leap ? 29 : days[month - 1];
  if (day < 1 || day > maxDay) _invalid('timestamp out of range');
  if (hour > 23 || minute > 59 || second > 59) {
    _invalid('timestamp out of range');
  }
  return value;
}

String? _timestampOrNull(Object? value) =>
    value == null ? null : _timestamp(value);

/// Integer (never bool or double) within [min, max].
int _int(Object? value, int min, int max) {
  if (value is! int) _invalid('expected an integer');
  if (value < min || value > max) _invalid('integer out of range');
  return value;
}

int? _intOrNull(Object? value, int min, int max) =>
    value == null ? null : _int(value, min, max);

bool _bool(Object? value) {
  if (value is! bool) _invalid('expected a boolean');
  return value;
}

T _enum<T extends Enum>(Object? value, List<T> values, String Function(T) wire) {
  if (value is! String) _invalid('expected an enum string');
  for (final candidate in values) {
    if (wire(candidate) == value) return candidate;
  }
  _invalid('unknown enum value');
}

/// Closed-object reader: rejects non-maps, missing keys and unknown keys.
Map<String, Object?> _closed(Object? value, Set<String> fields) {
  if (value is! Map) _invalid('expected an object');
  for (final key in value.keys) {
    if (key is! String || !fields.contains(key)) _invalid('unknown field');
  }
  for (final field in fields) {
    if (!value.containsKey(field)) _invalid('missing field');
  }
  return value.cast<String, Object?>();
}

// ---------------------------------------------------------------------------
// Payloads

/// Base class of the five closed payload types.
sealed class SyncPayload {
  const SyncPayload();

  SyncRecordType get recordType;

  /// Exact wire map (unmodifiable), including explicit nulls.
  Map<String, Object?> toWire();

  static SyncPayload fromWire(SyncRecordType type, Object? value) =>
      switch (type) {
        SyncRecordType.transcript => TranscriptPayload.fromWire(value),
        SyncRecordType.providerMetadata =>
          ProviderMetadataPayload.fromWire(value),
        SyncRecordType.usage => UsagePayload.fromWire(value),
        SyncRecordType.activity => ActivityPayload.fromWire(value),
        SyncRecordType.tombstone => TombstonePayload.fromWire(value),
      };

  @override
  bool operator ==(Object other) =>
      other is SyncPayload &&
      other.recordType == recordType &&
      canonicalJsonString(other.toWire()) == canonicalJsonString(toWire());

  @override
  int get hashCode => canonicalJsonString(toWire()).hashCode;
}

class TranscriptPayload extends SyncPayload {
  TranscriptPayload({
    required String messageId,
    required String? parentMessageId,
    required this.kind,
    required String text,
    required String? providerMetadataRecordId,
    required String? requestPurpose,
    required String? displayTitle,
  })  : messageId = _id(messageId),
        parentMessageId = _idOrNull(parentMessageId),
        text = _text(text, 0, 262144),
        providerMetadataRecordId = _idOrNull(providerMetadataRecordId),
        requestPurpose = _textOrNull(requestPurpose, 0, 128),
        displayTitle = _textOrNull(displayTitle, 0, 256);

  static const fields = {
    'messageId',
    'parentMessageId',
    'kind',
    'text',
    'providerMetadataRecordId',
    'requestPurpose',
    'displayTitle',
  };

  factory TranscriptPayload.fromWire(Object? value) {
    final m = _closed(value, fields);
    return TranscriptPayload(
      messageId: _id(m['messageId']),
      parentMessageId: _idOrNull(m['parentMessageId']),
      kind: _enum(m['kind'], TranscriptKind.values, (e) => e.wire),
      text: _text(m['text'], 0, 262144),
      providerMetadataRecordId: _idOrNull(m['providerMetadataRecordId']),
      requestPurpose: _textOrNull(m['requestPurpose'], 0, 128),
      displayTitle: _textOrNull(m['displayTitle'], 0, 256),
    );
  }

  final String messageId;
  final String? parentMessageId;
  final TranscriptKind kind;

  /// Complete private transcript text, verbatim. May contain secrets.
  final String text;
  final String? providerMetadataRecordId;
  final String? requestPurpose;
  final String? displayTitle;

  @override
  SyncRecordType get recordType => SyncRecordType.transcript;

  @override
  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'messageId': messageId,
        'parentMessageId': parentMessageId,
        'kind': kind.wire,
        'text': text,
        'providerMetadataRecordId': providerMetadataRecordId,
        'requestPurpose': requestPurpose,
        'displayTitle': displayTitle,
      });
}

class ProviderMetadataPayload extends SyncPayload {
  ProviderMetadataPayload({
    required String providerId,
    required String? modelId,
    required String endpoint,
    required String? requestPurpose,
    required String? displayName,
    required bool supportsStreaming,
  })  : providerId = _id(providerId, max: 64),
        modelId = _idOrNull(modelId),
        endpoint = _endpoint(endpoint, providerId),
        requestPurpose = _textOrNull(requestPurpose, 0, 128),
        displayName = _textOrNull(displayName, 0, 256),
        supportsStreaming = _bool(supportsStreaming);

  static const fields = {
    'providerId',
    'modelId',
    'endpoint',
    'requestPurpose',
    'displayName',
    'supportsStreaming',
  };

  factory ProviderMetadataPayload.fromWire(Object? value) {
    final m = _closed(value, fields);
    final providerId = _id(m['providerId'], max: 64);
    final endpoint = m['endpoint'];
    if (endpoint is! String) _invalid('endpoint must be a string');
    return ProviderMetadataPayload(
      providerId: providerId,
      modelId: _idOrNull(m['modelId']),
      endpoint: endpoint,
      requestPurpose: _textOrNull(m['requestPurpose'], 0, 128),
      displayName: _textOrNull(m['displayName'], 0, 256),
      supportsStreaming: _bool(m['supportsStreaming']),
    );
  }

  /// Endpoints are validated on every construction and import, and must
  /// already be in canonical credential-free form. Callers canonicalize with
  /// `canonicalProviderEndpoint` before building a record.
  static String _endpoint(String value, String providerId) {
    if (value.isEmpty || value.length > maxEndpointBytes) {
      _invalid('endpoint length out of range');
    }
    if (!isCanonicalProviderEndpoint(value, providerId)) {
      throw const SyncDtoException(
          'endpoint_rejected', 'endpoint is not a canonical allowed endpoint');
    }
    return value;
  }

  final String providerId;
  final String? modelId;
  final String endpoint;
  final String? requestPurpose;
  final String? displayName;
  final bool supportsStreaming;

  @override
  SyncRecordType get recordType => SyncRecordType.providerMetadata;

  @override
  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'providerId': providerId,
        'modelId': modelId,
        'endpoint': endpoint,
        'requestPurpose': requestPurpose,
        'displayName': displayName,
        'supportsStreaming': supportsStreaming,
      });
}

class UsagePayload extends SyncPayload {
  UsagePayload({
    required String logicalRequestId,
    required String attemptId,
    required String? requestedModel,
    required String? reportedModel,
    required this.outcome,
    required int? inputTokens,
    required int? outputTokens,
    required int? totalTokens,
    required this.usageProvenance,
    required String? startedAt,
    required String? completedAt,
    required int? elapsedMilliseconds,
  })  : logicalRequestId = _id(logicalRequestId),
        attemptId = _id(attemptId),
        requestedModel = _idOrNull(requestedModel),
        reportedModel = _idOrNull(reportedModel),
        inputTokens = _intOrNull(inputTokens, 0, maxInt32),
        outputTokens = _intOrNull(outputTokens, 0, maxInt32),
        totalTokens = _intOrNull(totalTokens, 0, maxUint32),
        startedAt = _timestampOrNull(startedAt),
        completedAt = _timestampOrNull(completedAt),
        elapsedMilliseconds =
            _intOrNull(elapsedMilliseconds, 0, maxElapsedMilliseconds);

  static const fields = {
    'logicalRequestId',
    'attemptId',
    'requestedModel',
    'reportedModel',
    'outcome',
    'inputTokens',
    'outputTokens',
    'totalTokens',
    'usageProvenance',
    'startedAt',
    'completedAt',
    'elapsedMilliseconds',
  };

  factory UsagePayload.fromWire(Object? value) {
    final m = _closed(value, fields);
    return UsagePayload(
      logicalRequestId: _id(m['logicalRequestId']),
      attemptId: _id(m['attemptId']),
      requestedModel: _idOrNull(m['requestedModel']),
      reportedModel: _idOrNull(m['reportedModel']),
      outcome: _enum(m['outcome'], UsageOutcome.values, (e) => e.wire),
      inputTokens: _intOrNull(m['inputTokens'], 0, maxInt32),
      outputTokens: _intOrNull(m['outputTokens'], 0, maxInt32),
      totalTokens: _intOrNull(m['totalTokens'], 0, maxUint32),
      usageProvenance:
          _enum(m['usageProvenance'], UsageProvenance.values, (e) => e.wire),
      startedAt: _timestampOrNull(m['startedAt']),
      completedAt: _timestampOrNull(m['completedAt']),
      elapsedMilliseconds:
          _intOrNull(m['elapsedMilliseconds'], 0, maxElapsedMilliseconds),
    );
  }

  final String logicalRequestId;

  /// Equals the enclosing record's `recordId` (one usage record per attempt).
  final String attemptId;
  final String? requestedModel;
  final String? reportedModel;
  final UsageOutcome outcome;
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;

  /// Observational only; never establishes allowance or billing.
  final UsageProvenance usageProvenance;
  final String? startedAt;
  final String? completedAt;
  final int? elapsedMilliseconds;

  @override
  SyncRecordType get recordType => SyncRecordType.usage;

  @override
  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'logicalRequestId': logicalRequestId,
        'attemptId': attemptId,
        'requestedModel': requestedModel,
        'reportedModel': reportedModel,
        'outcome': outcome.wire,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'totalTokens': totalTokens,
        'usageProvenance': usageProvenance.wire,
        'startedAt': startedAt,
        'completedAt': completedAt,
        'elapsedMilliseconds': elapsedMilliseconds,
      });
}

class ActivityPayload extends SyncPayload {
  ActivityPayload({
    required String? logicalRequestId,
    required String? attemptId,
    required this.kind,
    required this.status,
    required String updatedAt,
    required String title,
    required String detail,
    required String? usageRecordId,
  })  : logicalRequestId = _idOrNull(logicalRequestId),
        attemptId = _idOrNull(attemptId),
        updatedAt = _timestamp(updatedAt),
        title = _text(title, 0, 256),
        detail = _text(detail, 0, 2048),
        usageRecordId = _idOrNull(usageRecordId);

  static const fields = {
    'logicalRequestId',
    'attemptId',
    'kind',
    'status',
    'updatedAt',
    'title',
    'detail',
    'usageRecordId',
  };

  factory ActivityPayload.fromWire(Object? value) {
    final m = _closed(value, fields);
    return ActivityPayload(
      logicalRequestId: _idOrNull(m['logicalRequestId']),
      attemptId: _idOrNull(m['attemptId']),
      kind: _enum(m['kind'], ActivityKind.values, (e) => e.wire),
      status: _enum(m['status'], ActivityStatus.values, (e) => e.wire),
      updatedAt: _timestamp(m['updatedAt']),
      title: _text(m['title'], 0, 256),
      detail: _text(m['detail'], 0, 2048),
      usageRecordId: _idOrNull(m['usageRecordId']),
    );
  }

  final String? logicalRequestId;
  final String? attemptId;
  final ActivityKind kind;
  final ActivityStatus status;
  final String updatedAt;
  final String title;
  final String detail;

  /// References a usage record's `recordId` (which equals its `attemptId`).
  final String? usageRecordId;

  @override
  SyncRecordType get recordType => SyncRecordType.activity;

  @override
  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'logicalRequestId': logicalRequestId,
        'attemptId': attemptId,
        'kind': kind.wire,
        'status': status.wire,
        'updatedAt': updatedAt,
        'title': title,
        'detail': detail,
        'usageRecordId': usageRecordId,
      });
}

class TombstonePayload extends SyncPayload {
  TombstonePayload({
    required String targetRecordId,
    required int deletionRevision,
    required String deletedAt,
    required this.reason,
  })  : targetRecordId = _id(targetRecordId),
        deletionRevision = _int(deletionRevision, 1, maxInt32),
        deletedAt = _timestamp(deletedAt);

  static const fields = {
    'targetRecordId',
    'deletionRevision',
    'deletedAt',
    'reason',
  };

  factory TombstonePayload.fromWire(Object? value) {
    final m = _closed(value, fields);
    return TombstonePayload(
      targetRecordId: _id(m['targetRecordId']),
      deletionRevision: _int(m['deletionRevision'], 1, maxInt32),
      deletedAt: _timestamp(m['deletedAt']),
      reason: _enum(m['reason'], TombstoneReason.values, (e) => e.wire),
    );
  }

  final String targetRecordId;
  final int deletionRevision;
  final String deletedAt;
  final TombstoneReason reason;

  @override
  SyncRecordType get recordType => SyncRecordType.tombstone;

  @override
  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'targetRecordId': targetRecordId,
        'deletionRevision': deletionRevision,
        'deletedAt': deletedAt,
        'reason': reason.wire,
      });
}

// ---------------------------------------------------------------------------
// Envelopes

const _uploadFields = {
  'schemaVersion',
  'recordId',
  'sourceDeviceId',
  'recordType',
  'conversationId',
  'createdAt',
  'revision',
  'payload',
};

const _replayFields = {..._uploadFields, 'accountId', 'changeSequence'};

/// Checks `schemaVersion` before the closed-field check so that a future
/// version with new fields is reported as unsupported, not malformed.
void _checkSchemaVersion(Object? value) {
  if (value is! Map) _invalid('expected an object');
  final version = value['schemaVersion'];
  if (version is int && version != syncSchemaVersion) {
    throw const SyncDtoException(
        'schema_version_unsupported', 'unsupported schema version');
  }
  if (version is! int) _invalid('schemaVersion must be integer 1');
}

/// Upload envelope: omits server-derived `accountId` and `changeSequence`.
class SyncUploadRecord {
  SyncUploadRecord({
    required String recordId,
    required String sourceDeviceId,
    required String? conversationId,
    required String createdAt,
    required int revision,
    required this.payload,
  })  : recordId = _id(recordId),
        sourceDeviceId = _id(sourceDeviceId),
        conversationId = _idOrNull(conversationId),
        createdAt = _timestamp(createdAt),
        revision = _int(revision, 1, maxInt32) {
    _checkIdentity(this.recordId, payload);
  }

  factory SyncUploadRecord.fromWire(Object? value) {
    _checkSchemaVersion(value);
    final m = _closed(value, _uploadFields);
    return _uploadFromMap(m);
  }

  /// Strictly decodes canonical (or any valid) UTF-8 JSON bytes, rejecting
  /// duplicate keys.
  factory SyncUploadRecord.fromCanonicalBytes(List<int> bytes) =>
      SyncUploadRecord.fromWire(_decode(bytes));

  final String recordId;
  final String sourceDeviceId;
  final String? conversationId;
  final String createdAt;
  final int revision;
  final SyncPayload payload;

  int get schemaVersion => syncSchemaVersion;
  SyncRecordType get recordType => payload.recordType;

  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        'schemaVersion': syncSchemaVersion,
        'recordId': recordId,
        'sourceDeviceId': sourceDeviceId,
        'recordType': recordType.wire,
        'conversationId': conversationId,
        'createdAt': createdAt,
        'revision': revision,
        'payload': payload.toWire(),
      });

  /// RFC 8785 canonical UTF-8 bytes; the hashing and quota unit.
  Uint8List canonicalBytes() => canonicalSyncBytes(toWire());

  @override
  bool operator ==(Object other) =>
      other is SyncUploadRecord &&
      canonicalJsonString(other.toWire()) == canonicalJsonString(toWire());

  @override
  int get hashCode => canonicalJsonString(toWire()).hashCode;
}

/// Replay envelope: an upload record plus server-derived fields.
class SyncReplayRecord {
  SyncReplayRecord({
    required String accountId,
    required int changeSequence,
    required this.record,
  })  : accountId = _id(accountId),
        changeSequence = _int(changeSequence, 1, maxSafeInteger);

  factory SyncReplayRecord.fromWire(Object? value) {
    _checkSchemaVersion(value);
    final m = _closed(value, _replayFields);
    return SyncReplayRecord(
      accountId: _id(m['accountId']),
      changeSequence: _int(m['changeSequence'], 1, maxSafeInteger),
      record: _uploadFromMap(m),
    );
  }

  factory SyncReplayRecord.fromCanonicalBytes(List<int> bytes) =>
      SyncReplayRecord.fromWire(_decode(bytes));

  final String accountId;
  final int changeSequence;
  final SyncUploadRecord record;

  String get recordId => record.recordId;
  SyncRecordType get recordType => record.recordType;
  SyncPayload get payload => record.payload;

  Map<String, Object?> toWire() => Map.unmodifiable(<String, Object?>{
        ...record.toWire(),
        'accountId': accountId,
        'changeSequence': changeSequence,
      });

  Uint8List canonicalBytes() => canonicalSyncBytes(toWire());

  @override
  bool operator ==(Object other) =>
      other is SyncReplayRecord &&
      canonicalJsonString(other.toWire()) == canonicalJsonString(toWire());

  @override
  int get hashCode => canonicalJsonString(toWire()).hashCode;
}

SyncUploadRecord _uploadFromMap(Map<String, Object?> m) {
  final type =
      _enum(m['recordType'], SyncRecordType.values, (e) => e.wire);
  return SyncUploadRecord(
    recordId: _id(m['recordId']),
    sourceDeviceId: _id(m['sourceDeviceId']),
    conversationId: _idOrNull(m['conversationId']),
    createdAt: _timestamp(m['createdAt']),
    revision: _int(m['revision'], 1, maxInt32),
    payload: SyncPayload.fromWire(type, m['payload']),
  );
}

/// Identity rule: a usage record's `recordId` is its `attemptId`.
void _checkIdentity(String recordId, SyncPayload payload) {
  if (payload is UsagePayload && payload.attemptId != recordId) {
    _invalid('usage recordId must equal attemptId');
  }
}

Object? _decode(List<int> bytes) {
  try {
    return decodeStrictJsonUtf8(bytes);
  } on CanonicalJsonException {
    _invalid('malformed JSON');
  }
}
