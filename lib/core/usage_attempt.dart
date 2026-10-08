/// Device-local accounting records for individual provider requests.
enum UsageProvenance {
  providerReported,
  locallyEstimated,
  derived,
  unknown,
  legacyUnspecified,
}

enum UsageOutcome { pending, succeeded, failed, cancelled, interrupted }

enum UsageDispatchStage { prepared, transmitted, completed }

class UsageTokenCount {
  UsageTokenCount({required this.value, required this.provenance}) {
    if (value != null && value! < 0) {
      throw ArgumentError('Token value must not be negative');
    }
    if ((provenance == UsageProvenance.unknown) != (value == null)) {
      throw ArgumentError('Token value and provenance contradict each other');
    }
  }

  factory UsageTokenCount.unknown() => UsageTokenCount(
        value: null,
        provenance: UsageProvenance.unknown,
      );

  factory UsageTokenCount.reported(int value) => UsageTokenCount(
        value: value,
        provenance: UsageProvenance.providerReported,
      );

  factory UsageTokenCount.estimated(int value) => UsageTokenCount(
        value: value,
        provenance: UsageProvenance.locallyEstimated,
      );

  factory UsageTokenCount.derived(int value) => UsageTokenCount(
        value: value,
        provenance: UsageProvenance.derived,
      );

  factory UsageTokenCount.legacy(int value) => UsageTokenCount(
        value: value,
        provenance: UsageProvenance.legacyUnspecified,
      );

  final int? value;
  final UsageProvenance provenance;

  Map<String, dynamic> toJson() => {
        'value': value,
        'provenance': _provenanceToJson(provenance),
      };

  factory UsageTokenCount.fromJson(Map<String, dynamic> json) {
    _requireKeys(json, const {'value', 'provenance'});
    final value = json['value'];
    if (value != null && value is! int) {
      throw ArgumentError('Token value must be an integer or null');
    }
    final provenance = _provenanceFromJson(json['provenance']);
    return UsageTokenCount(value: value as int?, provenance: provenance);
  }

  @override
  bool operator ==(Object other) =>
      other is UsageTokenCount &&
      other.value == value &&
      other.provenance == provenance;

  @override
  int get hashCode => Object.hash(value, provenance);
}

class UsageAttempt {
  static const schemaVersion = 1;

  UsageAttempt({
    required this.attemptId,
    required this.requestId,
    required this.revision,
    required this.sourceDevice,
    required this.provider,
    required this.requestedModel,
    this.reportedModel,
    required this.purpose,
    required this.startedAt,
    this.completedAt,
    this.elapsed,
    required this.dispatchStage,
    required this.outcome,
    this.sessionId,
    this.runId,
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
  }) {
    _requireIdentity('attemptId', attemptId);
    _requireIdentity('requestId', requestId);
    _requireIdentity('sourceDevice', sourceDevice);
    _requireIdentity('provider', provider);
    _requireIdentity('requestedModel', requestedModel);
    _requireIdentity('purpose', purpose);
    if (reportedModel != null) _requireIdentity('reportedModel', reportedModel!);
    if (sessionId != null) _requireIdentity('sessionId', sessionId!);
    if (runId != null) _requireIdentity('runId', runId!);
    if (revision < 1) throw ArgumentError('revision must be positive');
    if (elapsed != null) {
      _validateElapsed(elapsed!);
    }
  }

  final String attemptId;
  final String requestId;
  final int revision;
  final String sourceDevice;
  final String provider;
  final String requestedModel;
  final String? reportedModel;
  final String purpose;
  final String? sessionId;
  final String? runId;
  final DateTime startedAt;
  final DateTime? completedAt;
  final Duration? elapsed;
  final UsageDispatchStage dispatchStage;
  final UsageOutcome outcome;
  final UsageTokenCount? inputTokens;
  final UsageTokenCount? outputTokens;
  final UsageTokenCount? totalTokens;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'attemptId': attemptId,
        'requestId': requestId,
        'revision': revision,
        'sourceDevice': sourceDevice,
        'provider': provider,
        'requestedModel': requestedModel,
        'reportedModel': reportedModel,
        'purpose': purpose,
        'sessionId': sessionId,
        'runId': runId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'completedAt': completedAt?.toUtc().toIso8601String(),
        'elapsedMilliseconds': elapsed == null ? null : _elapsedMilliseconds(elapsed!),
        'dispatchStage': dispatchStage.name,
        'outcome': outcome.name,
        'inputTokens': inputTokens?.toJson(),
        'outputTokens': outputTokens?.toJson(),
        'totalTokens': totalTokens?.toJson(),
      };

  factory UsageAttempt.fromJson(Map<String, dynamic> json) {
    const keys = {
      'schemaVersion',
      'attemptId',
      'requestId',
      'revision',
      'sourceDevice',
      'provider',
      'requestedModel',
      'reportedModel',
      'purpose',
      'sessionId',
      'runId',
      'startedAt',
      'completedAt',
      'elapsedMilliseconds',
      'dispatchStage',
      'outcome',
      'inputTokens',
      'outputTokens',
      'totalTokens',
    };
    _requireKeys(json, keys);
    if (json['schemaVersion'] is! int ||
        json['schemaVersion'] != schemaVersion) {
      throw ArgumentError('Unsupported usage attempt schema');
    }
    String stringValue(String key) {
      final value = json[key];
      if (value is! String) throw ArgumentError('$key must be a string');
      return value;
    }

    final elapsed = json['elapsedMilliseconds'];
    if (elapsed != null && elapsed is! int) {
      throw ArgumentError('elapsedMilliseconds must be an integer or null');
    }
    UsageTokenCount? token(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! Map) throw ArgumentError('$key must be an object or null');
      return UsageTokenCount.fromJson(Map<String, dynamic>.from(value));
    }

    final reported = json['reportedModel'];
    final session = json['sessionId'];
    final run = json['runId'];
    return UsageAttempt(
      attemptId: stringValue('attemptId'),
      requestId: stringValue('requestId'),
      revision: _intValue(json, 'revision'),
      sourceDevice: stringValue('sourceDevice'),
      provider: stringValue('provider'),
      requestedModel: stringValue('requestedModel'),
      reportedModel: _nullableString(reported, 'reportedModel'),
      purpose: stringValue('purpose'),
      sessionId: _nullableString(session, 'sessionId'),
      runId: _nullableString(run, 'runId'),
      startedAt: _dateValue(json, 'startedAt'),
      completedAt: _nullableDateValue(json, 'completedAt'),
      elapsed: elapsed == null ? null : Duration(milliseconds: elapsed),
      dispatchStage: _dispatchFromJson(json['dispatchStage']),
      outcome: _outcomeFromJson(json['outcome']),
      inputTokens: token('inputTokens'),
      outputTokens: token('outputTokens'),
      totalTokens: token('totalTokens'),
    );
  }

  @override
  bool operator ==(Object other) => other is UsageAttempt &&
      other.attemptId == attemptId &&
      other.requestId == requestId &&
      other.revision == revision &&
      other.sourceDevice == sourceDevice &&
      other.provider == provider &&
      other.requestedModel == requestedModel &&
      other.reportedModel == reportedModel &&
      other.purpose == purpose &&
      other.sessionId == sessionId &&
      other.runId == runId &&
      other.startedAt == startedAt &&
      other.completedAt == completedAt &&
      other.elapsed == elapsed &&
      other.dispatchStage == dispatchStage &&
      other.outcome == outcome &&
      other.inputTokens == inputTokens &&
      other.outputTokens == outputTokens &&
      other.totalTokens == totalTokens;

  @override
  int get hashCode => Object.hashAll([
        attemptId,
        requestId,
        revision,
        sourceDevice,
        provider,
        requestedModel,
        reportedModel,
        purpose,
        sessionId,
        runId,
        startedAt,
        completedAt,
        elapsed,
        dispatchStage,
        outcome,
        inputTokens,
        outputTokens,
        totalTokens,
      ]);
}

void _requireKeys(Map<String, dynamic> json, Set<String> expected) {
  if (!json.keys.every(expected.contains) || json.length != expected.length) {
    throw ArgumentError('Unexpected or missing usage record fields');
  }
}

void _requireIdentity(String name, String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]*$').hasMatch(value)) {
    throw ArgumentError('Malformed $name');
  }
}

String _provenanceToJson(UsageProvenance value) => value.name;

UsageProvenance _provenanceFromJson(Object? value) => UsageProvenance.values
    .firstWhere((item) => item.name == value, orElse: () => throw ArgumentError('Unknown provenance'));

String? _nullableString(Object? value, String name) {
  if (value == null) return null;
  if (value is! String) throw ArgumentError('$name must be a string or null');
  return value;
}

DateTime _dateValue(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw ArgumentError('$key must be an ISO timestamp');
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})(\d{3})?Z$',
  ).firstMatch(value);
  if (match == null) throw ArgumentError('$key must be an ISO timestamp');
  try {
    final parsed = DateTime.parse(value);
    final expected = <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
      int.parse('${match.group(7)}${match.group(8) ?? '000'}'),
    ];
    final actual = <int>[
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond * 1000 + parsed.microsecond,
    ];
    if (! _sameInts(expected, actual) || !parsed.isUtc) {
      throw ArgumentError('$key must be a valid UTC timestamp');
    }
    return parsed;
  } catch (_) {
    throw ArgumentError('$key must be a valid UTC timestamp');
  }
}

DateTime? _nullableDateValue(Map<String, dynamic> json, String key) {
  if (json[key] == null) return null;
  return _dateValue(json, key);
}

int _intValue(Map<String, dynamic> json, String key) {
  if (json[key] is! int) throw ArgumentError('$key must be an integer');
  return json[key] as int;
}

UsageDispatchStage _dispatchFromJson(Object? value) => UsageDispatchStage.values
    .firstWhere((item) => item.name == value, orElse: () => throw ArgumentError('Unknown dispatch stage'));

UsageOutcome _outcomeFromJson(Object? value) => UsageOutcome.values
    .firstWhere((item) => item.name == value, orElse: () => throw ArgumentError('Unknown outcome'));

void _validateElapsed(Duration value) {
  if (value.inMicroseconds < 0) {
    throw ArgumentError('elapsed must not be negative');
  }
  if (value.inMicroseconds % Duration.microsecondsPerMillisecond != 0) {
    throw ArgumentError('elapsed supports millisecond precision only');
  }
}

int _elapsedMilliseconds(Duration value) {
  _validateElapsed(value);
  return value.inMilliseconds;
}

bool _sameInts(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
