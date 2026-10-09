/// Live collaboration client models (Wave 1).
///
/// Pure, immutable, inert data. Every wire codec is closed: unknown fields,
/// unknown kinds, wrong types, invalid bounds, credential-shaped keys/values,
/// local paths, attachment bytes, and executable request kinds are rejected
/// with a fixed, non-sensitive [CollaborationWireException].
///
/// Spec: docs/superpowers/specs/2026-10-09-live-collaboration-design.md
library;

import 'dart:convert';

/// v1 envelope schema version.
const int collaborationSchemaVersion = 1;

/// Hard cap on active members, including the owner.
const int maxActiveMembers = 10;

/// 256 KiB canonical UTF-8 bytes per event.
const int maxEventCanonicalBytes = 256 * 1024;

const int _maxIdLength = 128;
const int _maxLabelLength = 256;
const int _maxTokenCount = 1000000000000;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Fixed rejection reasons. Messages never echo field values.
enum CollaborationWireReason {
  unknownField,
  missingField,
  wrongType,
  invalidValue,
  unknownKind,
  executableKind,
  credentialField,
  executableField,
  localPath,
  attachment,
  credentialValue,
  tooLarge,
}

class CollaborationWireException implements Exception {
  const CollaborationWireException(this.reason);

  final CollaborationWireReason reason;

  @override
  String toString() => 'CollaborationWireException(${reason.name})';
}

Never _reject(CollaborationWireReason reason) =>
    throw CollaborationWireException(reason);

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

enum CollaborationEventType { message, modelStatus, usage, presence, membership, system }

enum MemberRole { owner, participant }

enum MemberStatus { active, left, revoked }

enum SessionLifecycle { active, closing, closed }

enum ModelExecutionStatus { idle, queued, running, completed, failed, cancelled, interrupted }

enum UsageProvenance { reported, estimated, unknown }

enum PresenceState { online, away, offline }

enum MembershipAction { joined, left, revoked }

enum SystemCode { sessionClosing, sessionClosed }

// ---------------------------------------------------------------------------
// Key / value screening
// ---------------------------------------------------------------------------

String _normalizeKey(String key) => key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

const _credentialKeyParts = <String>[
  'apikey',
  'auth',
  'cookie',
  'token',
  'secret',
  'password',
  'passwd',
  'grant',
  'credential',
  'bearer',
  'privatekey',
  'session',
];

const _executableKeyParts = <String>[
  'command',
  'cmd',
  'tool',
  'shell',
  'script',
  'mcp',
  'plugin',
  'browser',
  'exec',
  'queue',
  'callback',
  'process',
  'spawn',
  'eval',
  'invoke',
  'handler',
  'build',
  'clone',
  'agent',
];

const _pathKeyParts = <String>['path', 'cwd', 'dir', 'workspace', 'folder', 'file'];

const _attachmentKeyParts = <String>['attach', 'bytes', 'base64', 'blob', 'image', 'binary'];

/// Classifies a key that is not in the closed field set.
Never _rejectUnknownKey(String key) {
  final k = _normalizeKey(key);
  bool hit(List<String> parts) => parts.any(k.contains);
  if (hit(_credentialKeyParts)) _reject(CollaborationWireReason.credentialField);
  if (hit(_executableKeyParts)) _reject(CollaborationWireReason.executableField);
  if (hit(_pathKeyParts)) _reject(CollaborationWireReason.localPath);
  if (hit(_attachmentKeyParts)) _reject(CollaborationWireReason.attachment);
  _reject(CollaborationWireReason.unknownField);
}

const _executableKindParts = <String>[
  'tool',
  'exec',
  'shell',
  'command',
  'cmd',
  'browser',
  'mcp',
  'plugin',
  'run',
  'agent',
  'process',
  'build',
  'clone',
  'request',
  'invoke',
  'call',
  'spawn',
  'script',
];

final _credentialValuePatterns = <RegExp>[
  RegExp(r'\bsk-[A-Za-z0-9_\-]{8,}'),
  RegExp(r'bearer\s', caseSensitive: false),
  RegExp(r'basic\s+[A-Za-z0-9+/=]{8,}', caseSensitive: false),
  RegExp(r'://[^/\s]*@'),
  RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}'),
  RegExp(r'\bxox[abprs]-[A-Za-z0-9-]{8,}'),
  RegExp(r'\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.'),
  RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
  RegExp(r'\bAIza[0-9A-Za-z_\-]{20,}'),
  RegExp(
    r'[?&#](api[_-]?key|key|token|access[_-]?token|secret|sig|signature|password|auth)=',
    caseSensitive: false,
  ),
  RegExp(r'-----BEGIN [A-Z ]*KEY-----'),
];

final _localPathValuePatterns = <RegExp>[
  RegExp(r'^\s*/'),
  RegExp(r'^\s*~'),
  RegExp(r'^\s*[A-Za-z]:[\\/]'),
  RegExp(r'^\s*\\\\'),
  RegExp(r'^\s*file:', caseSensitive: false),
  RegExp(r'(^|[\\/])\.\.?[\\/]'),
];

final _attachmentValuePatterns = <RegExp>[
  RegExp(r'^\s*data:', caseSensitive: false),
  RegExp(r';base64,', caseSensitive: false),
];

/// Screens a descriptive metadata value (never message text).
void _screenMetadataValue(String value) {
  if (_attachmentValuePatterns.any((p) => p.hasMatch(value))) {
    _reject(CollaborationWireReason.attachment);
  }
  if (_credentialValuePatterns.any((p) => p.hasMatch(value))) {
    _reject(CollaborationWireReason.credentialValue);
  }
  if (_localPathValuePatterns.any((p) => p.hasMatch(value))) {
    _reject(CollaborationWireReason.localPath);
  }
}

// ---------------------------------------------------------------------------
// Closed map reader
// ---------------------------------------------------------------------------

final _idPattern = RegExp(r'^[A-Za-z0-9._:\-]+$');
final _timestampPattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$');
final _controlChars = RegExp(r'[\x00-\x1F\x7F]');

class _Closed {
  _Closed(Object? raw, Set<String> allowed) : _map = _asMap(raw) {
    for (final key in _map.keys) {
      if (!allowed.contains(key)) _rejectUnknownKey(key);
    }
    for (final key in allowed) {
      if (!_map.containsKey(key)) _reject(CollaborationWireReason.missingField);
    }
  }

  final Map<String, Object?> _map;

  static Map<String, Object?> _asMap(Object? raw) {
    if (raw is! Map) _reject(CollaborationWireReason.wrongType);
    final out = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) _reject(CollaborationWireReason.wrongType);
      out[key] = entry.value;
    }
    return out;
  }

  Object? raw(String key) => _map[key];

  String string(String key) {
    final v = _map[key];
    if (v is! String) _reject(CollaborationWireReason.wrongType);
    return v;
  }

  String id(String key) {
    final v = string(key);
    if (v.isEmpty || v.length > _maxIdLength || !_idPattern.hasMatch(v)) {
      _reject(CollaborationWireReason.invalidValue);
    }
    _screenMetadataValue(v);
    return v;
  }

  String label(String key) {
    final v = string(key);
    _screenMetadataValue(v);
    if (v.trim().isEmpty || v.length > _maxLabelLength || _controlChars.hasMatch(v)) {
      _reject(CollaborationWireReason.invalidValue);
    }
    return v;
  }

  String? nullableLabel(String key) => _map[key] == null ? null : label(key);

  bool boolean(String key) {
    final v = _map[key];
    if (v is! bool) _reject(CollaborationWireReason.wrongType);
    return v;
  }

  int integer(String key) {
    final v = _map[key];
    if (v is! int) _reject(CollaborationWireReason.wrongType);
    return v;
  }

  int? nullableCount(String key) {
    final v = _map[key];
    if (v == null) return null;
    if (v is! int) _reject(CollaborationWireReason.wrongType);
    if (v < 0 || v > _maxTokenCount) _reject(CollaborationWireReason.invalidValue);
    return v;
  }

  T enumValue<T extends Enum>(String key, List<T> values) {
    final v = string(key);
    for (final value in values) {
      if (value.name == v) return value;
    }
    _reject(CollaborationWireReason.invalidValue);
  }

  T? nullableEnum<T extends Enum>(String key, List<T> values) =>
      _map[key] == null ? null : enumValue(key, values);

  String timestamp(String key) {
    final v = string(key);
    if (!_timestampPattern.hasMatch(v) || DateTime.tryParse(v) == null) {
      _reject(CollaborationWireReason.invalidValue);
    }
    return v;
  }

  void schemaVersion() {
    if (integer('schemaVersion') != collaborationSchemaVersion) {
      _reject(CollaborationWireReason.invalidValue);
    }
  }
}

// ---------------------------------------------------------------------------
// Session / member
// ---------------------------------------------------------------------------

/// Bounded session descriptor. The opaque route `SessionToken` is deliberately
/// not part of this model so it cannot leak through state snapshots.
class CollaborationSession {
  const CollaborationSession({
    required this.sessionId,
    required this.ownerParticipantId,
    required this.lifecycle,
  });

  factory CollaborationSession.fromWire(Map<String, Object?> json) {
    final r = _Closed(json, const {'schemaVersion', 'sessionId', 'ownerParticipantId', 'lifecycle'});
    r.schemaVersion();
    return CollaborationSession(
      sessionId: r.id('sessionId'),
      ownerParticipantId: r.id('ownerParticipantId'),
      lifecycle: r.enumValue('lifecycle', SessionLifecycle.values),
    );
  }

  final String sessionId;
  final String ownerParticipantId;
  final SessionLifecycle lifecycle;

  CollaborationSession withLifecycle(SessionLifecycle next) => CollaborationSession(
    sessionId: sessionId,
    ownerParticipantId: ownerParticipantId,
    lifecycle: next,
  );

  Map<String, Object?> toWire() => {
    'schemaVersion': collaborationSchemaVersion,
    'sessionId': sessionId,
    'ownerParticipantId': ownerParticipantId,
    'lifecycle': lifecycle.name,
  };

  @override
  bool operator ==(Object other) =>
      other is CollaborationSession &&
      other.sessionId == sessionId &&
      other.ownerParticipantId == ownerParticipantId &&
      other.lifecycle == lifecycle;

  @override
  int get hashCode => Object.hash(sessionId, ownerParticipantId, lifecycle);
}

class Member {
  const Member({required this.participantId, required this.role, required this.status});

  factory Member.fromWire(Map<String, Object?> json) {
    final r = _Closed(json, const {'participantId', 'role', 'status'});
    return Member(
      participantId: r.id('participantId'),
      role: r.enumValue('role', MemberRole.values),
      status: r.enumValue('status', MemberStatus.values),
    );
  }

  final String participantId;
  final MemberRole role;
  final MemberStatus status;

  bool get isActive => status == MemberStatus.active;

  Member withStatus(MemberStatus next) =>
      Member(participantId: participantId, role: role, status: next);

  Map<String, Object?> toWire() => {
    'participantId': participantId,
    'role': role.name,
    'status': status.name,
  };

  @override
  bool operator ==(Object other) =>
      other is Member &&
      other.participantId == participantId &&
      other.role == role &&
      other.status == status;

  @override
  int get hashCode => Object.hash(participantId, role, status);
}

// ---------------------------------------------------------------------------
// Usage / model state
// ---------------------------------------------------------------------------

/// Approved usage projection reference. Unknown usage is never a number.
class UsageSummary {
  const UsageSummary({
    required this.requestId,
    required this.attemptId,
    required this.provenance,
    required this.inputTokens,
    required this.outputTokens,
  });

  static const _fields = {'requestId', 'attemptId', 'provenance', 'inputTokens', 'outputTokens'};

  factory UsageSummary.fromWire(Object? json) {
    final r = _Closed(json, _fields);
    final provenance = r.enumValue('provenance', UsageProvenance.values);
    final input = r.nullableCount('inputTokens');
    final output = r.nullableCount('outputTokens');
    if (provenance == UsageProvenance.unknown && (input != null || output != null)) {
      _reject(CollaborationWireReason.invalidValue);
    }
    return UsageSummary(
      requestId: r.id('requestId'),
      attemptId: r.id('attemptId'),
      provenance: provenance,
      inputTokens: input,
      outputTokens: output,
    );
  }

  final String requestId;
  final String attemptId;
  final UsageProvenance provenance;
  final int? inputTokens;
  final int? outputTokens;

  Map<String, Object?> toWire() => {
    'requestId': requestId,
    'attemptId': attemptId,
    'provenance': provenance.name,
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
  };
}

/// Display-safe model label and execution status for one participant.
/// Holds no credentials, endpoints, prompts, or provider configuration.
class ParticipantModelState {
  const ParticipantModelState({
    required this.participantId,
    required this.providerId,
    required this.requestedModel,
    required this.reportedModel,
    required this.displayName,
    required this.streaming,
    required this.status,
    required this.usage,
  });

  factory ParticipantModelState.fromWire(Map<String, Object?> json) {
    final r = _Closed(json, const {
      'participantId',
      'providerId',
      'requestedModel',
      'reportedModel',
      'displayName',
      'streaming',
      'status',
      'usage',
    });
    return ParticipantModelState(
      participantId: r.id('participantId'),
      providerId: r.label('providerId'),
      requestedModel: r.label('requestedModel'),
      reportedModel: r.nullableLabel('reportedModel'),
      displayName: r.label('displayName'),
      streaming: r.boolean('streaming'),
      status: r.enumValue('status', ModelExecutionStatus.values),
      usage: r.raw('usage') == null ? null : UsageSummary.fromWire(r.raw('usage')),
    );
  }

  final String participantId;
  final String providerId;
  final String requestedModel;
  final String? reportedModel;
  final String displayName;
  final bool streaming;
  final ModelExecutionStatus status;
  final UsageSummary? usage;

  ParticipantModelState withUsage(UsageSummary? next) => ParticipantModelState(
    participantId: participantId,
    providerId: providerId,
    requestedModel: requestedModel,
    reportedModel: reportedModel,
    displayName: displayName,
    streaming: streaming,
    status: status,
    usage: next,
  );

  Map<String, Object?> toWire() => {
    'participantId': participantId,
    'providerId': providerId,
    'requestedModel': requestedModel,
    'reportedModel': reportedModel,
    'displayName': displayName,
    'streaming': streaming,
    'status': status.name,
    'usage': usage?.toWire(),
  };
}

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

sealed class CollaborationPayload {
  const CollaborationPayload();

  Map<String, Object?> toWire();

  static CollaborationPayload fromWire(CollaborationEventType type, Object? json) =>
      switch (type) {
        CollaborationEventType.message => MessagePayload._fromWire(json),
        CollaborationEventType.modelStatus => ModelStatusPayload._fromWire(json),
        CollaborationEventType.usage => UsagePayload(UsageSummary.fromWire(json)),
        CollaborationEventType.presence => PresencePayload._fromWire(json),
        CollaborationEventType.membership => MembershipPayload._fromWire(json),
        CollaborationEventType.system => SystemPayload._fromWire(json),
      };
}

/// Private message text, preserved verbatim (no redaction, no screening).
class MessagePayload extends CollaborationPayload {
  const MessagePayload(this.text);

  factory MessagePayload._fromWire(Object? json) =>
      MessagePayload(_Closed(json, const {'text'}).string('text'));

  final String text;

  @override
  Map<String, Object?> toWire() => {'text': text};
}

class ModelStatusPayload extends CollaborationPayload {
  const ModelStatusPayload({
    required this.providerId,
    required this.requestedModel,
    required this.reportedModel,
    required this.displayName,
    required this.streaming,
    required this.status,
  });

  factory ModelStatusPayload._fromWire(Object? json) {
    final r = _Closed(json, const {
      'providerId',
      'requestedModel',
      'reportedModel',
      'displayName',
      'streaming',
      'status',
    });
    return ModelStatusPayload(
      providerId: r.label('providerId'),
      requestedModel: r.label('requestedModel'),
      reportedModel: r.nullableLabel('reportedModel'),
      displayName: r.label('displayName'),
      streaming: r.boolean('streaming'),
      status: r.enumValue('status', ModelExecutionStatus.values),
    );
  }

  final String providerId;
  final String requestedModel;
  final String? reportedModel;
  final String displayName;
  final bool streaming;
  final ModelExecutionStatus status;

  @override
  Map<String, Object?> toWire() => {
    'providerId': providerId,
    'requestedModel': requestedModel,
    'reportedModel': reportedModel,
    'displayName': displayName,
    'streaming': streaming,
    'status': status.name,
  };
}

class UsagePayload extends CollaborationPayload {
  const UsagePayload(this.usage);

  final UsageSummary usage;

  @override
  Map<String, Object?> toWire() => usage.toWire();
}

class PresencePayload extends CollaborationPayload {
  const PresencePayload(this.state);

  factory PresencePayload._fromWire(Object? json) =>
      PresencePayload(_Closed(json, const {'state'}).enumValue('state', PresenceState.values));

  final PresenceState state;

  @override
  Map<String, Object?> toWire() => {'state': state.name};
}

/// `joined` carries role `participant`; `left`/`revoked` carry a null role.
/// Owners are never admitted by event (only by bootstrap).
class MembershipPayload extends CollaborationPayload {
  const MembershipPayload({required this.action, required this.participantId, required this.role});

  factory MembershipPayload._fromWire(Object? json) {
    final r = _Closed(json, const {'action', 'participantId', 'role'});
    final action = r.enumValue('action', MembershipAction.values);
    final role = r.nullableEnum('role', MemberRole.values);
    final valid = action == MembershipAction.joined ? role == MemberRole.participant : role == null;
    if (!valid) _reject(CollaborationWireReason.invalidValue);
    return MembershipPayload(action: action, participantId: r.id('participantId'), role: role);
  }

  final MembershipAction action;
  final String participantId;
  final MemberRole? role;

  @override
  Map<String, Object?> toWire() => {
    'action': action.name,
    'participantId': participantId,
    'role': role?.name,
  };
}

class SystemPayload extends CollaborationPayload {
  const SystemPayload(this.code);

  factory SystemPayload._fromWire(Object? json) =>
      SystemPayload(_Closed(json, const {'code'}).enumValue('code', SystemCode.values));

  final SystemCode code;

  @override
  Map<String, Object?> toWire() => {'code': code.name};
}

// ---------------------------------------------------------------------------
// Event envelope
// ---------------------------------------------------------------------------

class CollaborationEvent {
  const CollaborationEvent._({
    required this.sessionId,
    required this.sequence,
    required this.clientEventId,
    required this.author,
    required this.type,
    required this.createdAt,
    required this.payload,
  });

  static const _fields = {
    'schemaVersion',
    'eventId',
    'sessionId',
    'eventSequence',
    'senderParticipantId',
    'kind',
    'createdAt',
    'payload',
  };

  /// Strictly parses a v1 server envelope. Throws [CollaborationWireException].
  factory CollaborationEvent.fromWire(Map<String, Object?> json) {
    final r = _Closed(json, _fields);
    r.schemaVersion();
    final sequence = r.integer('eventSequence');
    if (sequence < 1) _reject(CollaborationWireReason.invalidValue);
    final type = _parseKind(r.string('kind'));
    final event = CollaborationEvent._(
      sessionId: r.id('sessionId'),
      sequence: sequence,
      clientEventId: r.id('eventId'),
      author: r.id('senderParticipantId'),
      type: type,
      createdAt: r.timestamp('createdAt'),
      payload: CollaborationPayload.fromWire(type, r.raw('payload')),
    );
    if (utf8.encode(jsonEncode(event.toWire())).length > maxEventCanonicalBytes) {
      _reject(CollaborationWireReason.tooLarge);
    }
    return event;
  }

  static CollaborationEventType _parseKind(String kind) {
    for (final t in CollaborationEventType.values) {
      if (t.name == kind) return t;
    }
    final k = _normalizeKey(kind);
    if (_executableKindParts.any(k.contains)) _reject(CollaborationWireReason.executableKind);
    _reject(CollaborationWireReason.unknownKind);
  }

  final String sessionId;
  final int sequence;
  final String clientEventId;
  final String author;
  final CollaborationEventType type;
  final String createdAt;
  final CollaborationPayload payload;

  Map<String, Object?> toWire() => {
    'schemaVersion': collaborationSchemaVersion,
    'eventId': clientEventId,
    'sessionId': sessionId,
    'eventSequence': sequence,
    'senderParticipantId': author,
    'kind': type.name,
    'createdAt': createdAt,
    'payload': payload.toWire(),
  };
}
