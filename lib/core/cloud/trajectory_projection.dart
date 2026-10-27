import 'dart:convert';

import 'package:flutter/foundation.dart';

const String trajectoryUnknownValue = '—';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => <Map<String, dynamic>>[
  if (value is List)
    for (final item in value)
      if (item is Map) Map<String, dynamic>.from(item),
];

String? _string(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

int? _int(Object? value) =>
    value is num && value.isFinite ? value.toInt() : null;

double? _double(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

String _numberLabel(num? value) {
  if (value == null) return trajectoryUnknownValue;
  if (value is double && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

String _textLabel(String? value) => _string(value) ?? trajectoryUnknownValue;

String _listLabel(List<String> values) =>
    values.isEmpty ? trajectoryUnknownValue : values.join(', ');

List<String> _strings(Object? value) {
  final out = <String>[];
  if (value is! List) return out;
  for (final item in value) {
    final direct = _string(item);
    if (direct != null) {
      out.add(direct);
      continue;
    }
    if (item is! Map) continue;
    for (final key in const <String>[
      'path',
      'filePath',
      'file_path',
      'id',
      'artifactId',
      'artifact_id',
      'diffId',
      'reference',
      'url',
      'diff',
    ]) {
      final reference = _string(item[key]);
      if (reference != null) {
        out.add(reference);
        break;
      }
    }
  }
  return out;
}

/// Canonical all-known-worker counts. Null means the server did not report a
/// count; it is never replaced with a fabricated zero.
@immutable
class TrajectoryCounts {
  const TrajectoryCounts({
    this.total,
    this.running,
    this.awaitingNextUserTask,
    this.completed,
    this.failed,
    this.cancelled,
    this.timeout,
  });

  final int? total;
  final int? running;
  final int? awaitingNextUserTask;
  final int? completed;
  final int? failed;
  final int? cancelled;
  final int? timeout;

  factory TrajectoryCounts.fromJson(Map<String, dynamic> json) =>
      TrajectoryCounts(
        total: _int(json['total']),
        running: _int(json['running']),
        awaitingNextUserTask: _int(json['awaiting_next_user_task']),
        completed: _int(json['completed']),
        failed: _int(json['failed']),
        cancelled: _int(json['cancelled']),
        timeout: _int(json['timeout']),
      );

  String get totalLabel => _numberLabel(total);
  String get runningLabel => _numberLabel(running);
  String get awaitingNextUserTaskLabel => _numberLabel(awaitingNextUserTask);
  String get completedLabel => _numberLabel(completed);
  String get failedLabel => _numberLabel(failed);
  String get cancelledLabel => _numberLabel(cancelled);
  String get timeoutLabel => _numberLabel(timeout);
}

@immutable
class TrajectoryUsage {
  const TrajectoryUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.costUsd,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? costUsd;

  factory TrajectoryUsage.fromJson(Map<String, dynamic> json) =>
      TrajectoryUsage(
        inputTokens: _int(json['inputTokens']),
        outputTokens: _int(json['outputTokens']),
        cacheReadTokens: _int(json['cacheReadTokens']),
        cacheWriteTokens: _int(json['cacheWriteTokens']),
        costUsd: _double(json['costUsd'] ?? json['cost']),
      );

  String get inputTokensLabel => _numberLabel(inputTokens);
  String get outputTokensLabel => _numberLabel(outputTokens);
  String get cacheReadTokensLabel => _numberLabel(cacheReadTokens);
  String get cacheWriteTokensLabel => _numberLabel(cacheWriteTokens);
  String get costLabel => _numberLabel(costUsd);
}

/// One canonical full step. Optional evidence stays optional; presentation
/// helpers expose an em dash only when the corresponding fact is absent.
@immutable
class TrajectoryStep {
  const TrajectoryStep({
    required this.cursor,
    required this.sessionId,
    required this.runId,
    required this.seq,
    required this.actorKind,
    required this.kind,
    required this.type,
    this.timestamp,
    this.prompt,
    this.output,
    this.evidence,
    this.files = const <String>[],
    this.diffs = const <String>[],
    this.artifacts = const <String>[],
    this.preview,
    this.requestedModel,
    this.providerModel,
    this.usage = const TrajectoryUsage(),
    this.canonicalMain = false,
  });

  final String cursor;
  final String sessionId;
  final String runId;
  final String seq;
  final String actorKind;
  final String kind;
  final String type;
  final DateTime? timestamp;
  final String? prompt;
  final String? output;
  final String? evidence;
  final List<String> files;
  final List<String> diffs;
  final List<String> artifacts;
  final String? preview;
  final String? requestedModel;
  final String? providerModel;
  final TrajectoryUsage usage;

  /// True only for server-provided canonical main-step DTOs. Preserved through
  /// TrajectoryRoot serialization so re-folding never turns parent lifecycle
  /// into worker activity. actorKind=worker compaction can still be canonical.
  final bool canonicalMain;

  String get filesLabel => _listLabel(files);
  String get diffsLabel => _listLabel(diffs);
  String get artifactsLabel => _listLabel(artifacts);
  String get requestedModelLabel => _textLabel(requestedModel);
  String get providerModelLabel => _textLabel(providerModel);

  factory TrajectoryStep.fromJson(Map<String, dynamic> json) {
    final payload = _map(json['payload']);
    final merged = <String, dynamic>{...json, ...payload};
    final type = _string(merged['type']) ?? '';
    final seq = '${merged['seq'] ?? merged['cursor'] ?? ''}';
    final sessionId = _string(merged['sessionId']) ?? '';
    final timestamp = _date(merged['ts'] ?? merged['timestamp']);
    final files = merged['files'] == null
        ? _strings(merged['filePaths'])
        : _strings(merged['files']);
    final artifacts = merged['artifacts'] == null
        ? _strings(merged['artifactIds'])
        : _strings(merged['artifacts']);
    return TrajectoryStep(
      cursor: _string(merged['cursor']) ?? '$sessionId:$seq',
      sessionId: sessionId,
      runId: _string(merged['runId']) ?? '',
      seq: seq,
      actorKind: _string(merged['actorKind']) ?? 'main',
      kind: _string(merged['kind']) ?? _stepKind(type),
      type: type,
      timestamp: timestamp,
      prompt: _string(merged['prompt']),
      output:
          _string(merged['output']) ??
          _string(merged['content']) ??
          _string(merged['summary']),
      evidence: _string(merged['evidence'] ?? merged['result']),
      files: files,
      diffs: _strings(merged['diffs'] ?? merged['diff']),
      artifacts: artifacts,
      preview: _string(merged['preview'] ?? merged['previewUrl']),
      requestedModel: _string(merged['requestedModel']),
      providerModel: _string(merged['providerModel'] ?? merged['model']),
      usage: TrajectoryUsage.fromJson(_map(merged['usage'] ?? merged)),
      canonicalMain: merged['canonicalMain'] == true,
    );
  }
}

String _stepKind(String type) {
  if (type.startsWith('tool_')) return 'tool';
  if (type.startsWith('subagent_')) return 'subagent';
  if (type.startsWith('message_') || type.startsWith('run_')) return 'model';
  return 'system';
}

/// The exact six-key structured report from §6.3. In particular,
/// `key_findings` is one bounded string, not the legacy list shape.
@immutable
class TrajectoryReport {
  const TrajectoryReport({
    required this.subagentId,
    required this.status,
    required this.filesModified,
    required this.artifactsCreated,
    required this.keyFindings,
    required this.errorIfAny,
  });

  static const Set<String> keys = <String>{
    'subagent_id',
    'status',
    'files_modified',
    'artifacts_created',
    'key_findings',
    'error_if_any',
  };

  static const Set<String> statuses = <String>{
    'completed',
    'failed',
    'cancelled',
    'timeout',
  };

  final String subagentId;
  final String status;
  final List<String> filesModified;
  final List<String> artifactsCreated;
  final String keyFindings;
  final String? errorIfAny;

  factory TrajectoryReport.fromJson(Map<String, dynamic> json) {
    if (json.keys.toSet().length != keys.length ||
        !json.keys.toSet().containsAll(keys)) {
      throw const FormatException('Expected the exact six-key report.');
    }
    final subagentId = _string(json['subagent_id']);
    final status = _string(json['status']);
    final keyFindings = json['key_findings'];
    final error = json['error_if_any'];
    final files = json['files_modified'];
    final artifacts = json['artifacts_created'];
    if (subagentId == null ||
        status == null ||
        !statuses.contains(status) ||
        keyFindings is! String ||
        keyFindings.length > 4000 ||
        (error != null && (error is! String || error.length > 4000)) ||
        !_validStringList(files) ||
        !_validStringList(artifacts)) {
      throw const FormatException('Malformed structured subagent report.');
    }
    return TrajectoryReport(
      subagentId: subagentId,
      status: status,
      filesModified: _strings(files),
      artifactsCreated: _strings(artifacts),
      keyFindings: keyFindings,
      errorIfAny: error as String?,
    );
  }

  static bool _validStringList(Object? value) =>
      value is List &&
      value.every((item) => item is String && item.trim().isNotEmpty);

  Map<String, Object?> toJson() => <String, Object?>{
    'subagent_id': subagentId,
    'status': status,
    'files_modified': filesModified,
    'artifacts_created': artifactsCreated,
    'key_findings': keyFindings,
    'error_if_any': errorIfAny,
  };
}

/// Operational compaction metadata only. There is deliberately no thought,
/// narrative, cutoff, or ordinary-chat payload in this projection.
@immutable
class CompactionMetadataDto {
  const CompactionMetadataDto({
    required this.type,
    required this.sessionId,
    required this.runId,
    required this.compactionId,
    required this.checkpointId,
    required this.timestamp,
    required this.model,
    required this.contextLimit,
    required this.beforeTokens,
    required this.afterTokens,
    required this.usageSource,
    required this.continuation,
    this.workerId,
    this.actorKind,
  });

  final String type;
  final String sessionId;
  final String? workerId;
  final String runId;
  final String compactionId;
  final String checkpointId;
  final DateTime timestamp;
  final String model;
  final int contextLimit;
  final int beforeTokens;
  final int afterTokens;
  final String usageSource;
  final String continuation;
  final String? actorKind;

  factory CompactionMetadataDto.fromJson(Map<String, dynamic> json) {
    final type = _string(json['type']);
    final sessionId = _string(json['sessionId']);
    final workerId = _string(json['workerId']);
    final runId = _string(json['runId']);
    final compactionId = _string(json['compactionId']);
    final checkpointId = _string(json['checkpointId']);
    final timestamp = _date(json['ts']);
    final model = _string(json['model']);
    final contextLimit = _int(json['contextLimit']);
    final beforeTokens = _int(json['beforeTokens']);
    final afterTokens = _int(json['afterTokens']);
    final usageSource = _string(json['usageSource']);
    final continuation = _string(json['continuation']);
    final actorKind = _string(json['actorKind']);
    final validType =
        type == 'subagent_compacted' || type == 'compaction_completed';
    if (!validType ||
        sessionId == null ||
        runId == null ||
        compactionId == null ||
        checkpointId == null ||
        timestamp == null ||
        model == null ||
        contextLimit == null ||
        contextLimit <= 0 ||
        beforeTokens == null ||
        beforeTokens < 0 ||
        afterTokens == null ||
        afterTokens < 0 ||
        (usageSource != 'measured' &&
            usageSource != 'deterministic_fallback') ||
        continuation != 'continuing_existing_task' ||
        (type == 'subagent_compacted' && workerId == null)) {
      throw const FormatException('Malformed compaction metadata.');
    }
    return CompactionMetadataDto(
      type: type!,
      sessionId: sessionId,
      workerId: workerId,
      runId: runId,
      compactionId: compactionId,
      checkpointId: checkpointId,
      timestamp: timestamp,
      model: model,
      contextLimit: contextLimit,
      beforeTokens: beforeTokens,
      afterTokens: afterTokens,
      usageSource: usageSource!,
      continuation: continuation!,
      actorKind: actorKind,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'sessionId': sessionId,
    'workerId': ?workerId,
    'runId': runId,
    'compactionId': compactionId,
    'checkpointId': checkpointId,
    'ts': timestamp.toUtc().toIso8601String(),
    'model': model,
    'contextLimit': contextLimit,
    'beforeTokens': beforeTokens,
    'afterTokens': afterTokens,
    'usageSource': usageSource,
    'continuation': continuation,
    'actorKind': ?actorKind,
  };
}

@immutable
class TrajectoryWorker {
  const TrajectoryWorker({
    this.logicalWorkerId,
    this.childSessionId,
    this.childRunId,
    this.attemptId,
    this.attemptNumber,
    this.rootTaskRunId,
    this.parentRunId,
    this.batchId,
    this.deferredRequestId,
    this.agentType,
    this.launchReason,
    this.schedulingReason,
    this.prompt,
    this.summary,
    this.error,
    this.requestedAt,
    this.deferredAt,
    this.admittedAt,
    this.startedAt,
    this.endedAt,
    this.startKnown = false,
    this.status = 'unknown',
    this.lastActivity,
    this.lastActivityAt,
    this.lastCursor,
    this.report,
    this.logAvailable,
    this.compaction,
    this.steps = const <TrajectoryStep>[],
  });

  final String? logicalWorkerId;
  final String? childSessionId;
  final String? childRunId;
  final String? attemptId;
  final int? attemptNumber;
  final String? rootTaskRunId;
  final String? parentRunId;
  final String? batchId;
  final String? deferredRequestId;
  final String? agentType;
  final String? launchReason;
  final String? schedulingReason;
  final String? prompt;
  final String? summary;
  final String? error;
  final DateTime? requestedAt;
  final DateTime? deferredAt;
  final DateTime? admittedAt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final bool startKnown;
  final String status;
  final String? lastActivity;
  final DateTime? lastActivityAt;
  final String? lastCursor;
  final TrajectoryReport? report;
  final bool? logAvailable;
  final CompactionMetadataDto? compaction;
  final List<TrajectoryStep> steps;

  bool get isDeferred => status == 'awaiting_next_user_task';
  bool get hasTranscript => childSessionId != null && !isDeferred;

  factory TrajectoryWorker.fromJson(Map<String, dynamic> json) {
    final steps =
        <TrajectoryStep>[
          for (final step in _maps(json['steps']))
            TrajectoryStep.fromJson(step),
        ]..sort(
          (a, b) => _compareRecords(
            _Record(_stepJson(a), const <String, dynamic>{}),
            _Record(_stepJson(b), const <String, dynamic>{}),
          ),
        );
    TrajectoryReport? report;
    final rawReport = json['structuredReport'] ?? json['report'];
    if (rawReport is Map) {
      try {
        report = TrajectoryReport.fromJson(_map(rawReport));
      } on FormatException {
        report = null;
      }
    }
    CompactionMetadataDto? compaction;
    if (json['compaction'] is Map) {
      try {
        compaction = CompactionMetadataDto.fromJson(_map(json['compaction']));
      } on FormatException {
        compaction = null;
      }
    }
    final status = _status(json['status']);
    final deferred = status == 'awaiting_next_user_task';
    return TrajectoryWorker(
      logicalWorkerId: _string(json['logicalWorkerId']),
      childSessionId: deferred ? null : _string(json['childSessionId']),
      childRunId: deferred ? null : _string(json['childRunId']),
      attemptId: _string(json['attemptId']),
      attemptNumber: _int(json['attemptNumber']),
      rootTaskRunId: _string(json['rootTaskRunId']),
      parentRunId: _string(json['parentRunId']),
      batchId: _string(json['batchId']),
      deferredRequestId: _string(json['deferredRequestId']),
      agentType: _string(json['agentType']),
      launchReason: _string(json['launchReason']),
      schedulingReason: _string(json['schedulingReason']),
      prompt: _string(json['prompt']),
      summary: _string(json['summary']),
      error: _string(json['error']),
      requestedAt: _date(json['requestedAt']),
      deferredAt: _date(json['deferredAt']),
      admittedAt: deferred ? null : _date(json['admittedAt']),
      startedAt: deferred ? null : _date(json['startedAt']),
      endedAt: deferred ? null : _date(json['endedAt']),
      startKnown: json['startKnown'] == true && !deferred,
      status: status,
      lastActivity: _string(json['lastActivity']),
      lastActivityAt: _date(json['lastActivityAt']),
      lastCursor: _string(json['lastCursor']),
      report: report,
      logAvailable: json['logAvailable'] is bool
          ? json['logAvailable'] as bool
          : null,
      compaction: compaction,
      steps: steps,
    );
  }
}

String _status(Object? value) {
  final status = _string(value)?.toLowerCase();
  return switch (status) {
    'awaiting_next_user_task' => 'awaiting_next_user_task',
    'running' => 'running',
    'completed' || 'done' || 'succeeded' || 'success' => 'completed',
    'failed' || 'error' => 'failed',
    'cancelled' || 'canceled' || 'stopped' => 'cancelled',
    'timeout' || 'timed_out' || 'timed out' => 'timeout',
    null => 'unknown',
    _ => status,
  };
}

/// Runtime is measured only when startKnown proves a real start. Terminal
/// runtime additionally requires a real end; a running row may use the clock.
Duration? workerRuntimeDuration(TrajectoryWorker worker, {DateTime? now}) {
  final started = worker.startedAt;
  if (!worker.startKnown || started == null) return null;
  final end =
      worker.endedAt ??
      (worker.status == 'running' ? (now ?? DateTime.now().toUtc()) : null);
  if (end == null) return null;
  final duration = end.toUtc().difference(started.toUtc());
  return duration.isNegative ? null : duration;
}

/// Waiting age is explicitly not execution time. Only deferred work has it.
Duration? workerDeferredAge(TrajectoryWorker worker, {DateTime? now}) {
  if (!worker.isDeferred) return null;
  final from = worker.deferredAt ?? worker.requestedAt;
  if (from == null) return null;
  final duration = (now ?? DateTime.now().toUtc()).difference(from.toUtc());
  return duration.isNegative ? null : duration;
}

@immutable
class TrajectoryRoot {
  const TrajectoryRoot({
    this.counts = const TrajectoryCounts(),
    this.mainSteps = const <TrajectoryStep>[],
    this.workers = const <TrajectoryWorker>[],
    this.diagnostics = const <CompactionMetadataDto>[],
    this.nextCursor,
    this.earlierCursor,
    this.canonicalRoster = false,
  });

  final TrajectoryCounts counts;
  final List<TrajectoryStep> mainSteps;
  final List<TrajectoryWorker> workers;
  final List<CompactionMetadataDto> diagnostics;
  final String? nextCursor;
  final String? earlierCursor;

  /// Whether [workers] came from the canonical `/subagents` roster rather
  /// than the durable-event fallback.
  final bool canonicalRoster;
}

class _Record {
  _Record(this.json, this.page);

  final Map<String, dynamic> json;
  final Map<String, dynamic> page;

  String get key {
    final sessionId = _string(json['sessionId']) ?? '';
    final seq = '${json['seq'] ?? json['cursor'] ?? ''}';
    return '$sessionId\u0000$seq';
  }
}

class _WorkerMerge {
  _WorkerMerge();

  Map<String, dynamic> data = <String, dynamic>{};
  final Set<String> aliases = <String>{};
  final Set<String> eventKeys = <String>{};
  bool startEventKnown = false;
  bool admissionKnown = false;
}

String? _iso(DateTime? value) => value?.toUtc().toIso8601String();

Map<String, dynamic> _workerJson(TrajectoryWorker worker) => <String, dynamic>{
  'logicalWorkerId': worker.logicalWorkerId,
  'childSessionId': worker.childSessionId,
  'childRunId': worker.childRunId,
  'attemptId': worker.attemptId,
  'attemptNumber': worker.attemptNumber,
  'rootTaskRunId': worker.rootTaskRunId,
  'parentRunId': worker.parentRunId,
  'batchId': worker.batchId,
  'deferredRequestId': worker.deferredRequestId,
  'agentType': worker.agentType,
  'launchReason': worker.launchReason,
  'schedulingReason': worker.schedulingReason,
  'prompt': worker.prompt,
  'summary': worker.summary,
  'error': worker.error,
  'requestedAt': _iso(worker.requestedAt),
  'deferredAt': _iso(worker.deferredAt),
  'admittedAt': _iso(worker.admittedAt),
  'startedAt': _iso(worker.startedAt),
  'endedAt': _iso(worker.endedAt),
  'startKnown': worker.startKnown,
  'status': worker.status,
  'lastActivity': worker.lastActivity,
  'lastActivityAt': _iso(worker.lastActivityAt),
  'lastCursor': worker.lastCursor,
  'structuredReport': worker.report?.toJson(),
  'logAvailable': worker.logAvailable,
  'compaction': worker.compaction?.toJson(),
  'steps': [for (final step in worker.steps) _stepJson(step)],
};

Map<String, dynamic> _stepJson(TrajectoryStep step) => <String, dynamic>{
  'cursor': step.cursor,
  'sessionId': step.sessionId,
  'runId': step.runId,
  'seq': step.seq,
  'actorKind': step.actorKind,
  'kind': step.kind,
  'type': step.type,
  'ts': _iso(step.timestamp),
  'prompt': step.prompt,
  'output': step.output,
  'evidence': step.evidence,
  'files': step.files,
  'diffs': step.diffs,
  'artifacts': step.artifacts,
  'preview': step.preview,
  'requestedModel': step.requestedModel,
  'providerModel': step.providerModel,
  'canonicalMain': step.canonicalMain,
  'usage': <String, Object?>{
    'inputTokens': step.usage.inputTokens,
    'outputTokens': step.usage.outputTokens,
    'cacheReadTokens': step.usage.cacheReadTokens,
    'cacheWriteTokens': step.usage.cacheWriteTokens,
    'costUsd': step.usage.costUsd,
  },
};

List<String> _workerAliases(Map<String, dynamic> json) => <String>[
  for (final key in const <String>[
    'logicalWorkerId',
    'workerId',
    'childRunId',
    'childSessionId',
    'deferredRequestId',
  ])
    if (_string(json[key]) != null)
      key == 'logicalWorkerId' || key == 'workerId'
          ? 'logical:${_string(json[key])}'
          : '$key:${_string(json[key])}',
];

void _copyKnown(
  Map<String, dynamic> target,
  Map<String, dynamic> source, {
  bool nullOverwrites = false,
}) {
  for (final entry in source.entries) {
    if (entry.key == 'payload' || entry.key == 'type' || entry.key == 'seq') {
      continue;
    }
    if (entry.value != null ||
        (nullOverwrites && !target.containsKey(entry.key))) {
      target[entry.key] = entry.value;
    }
  }
}

bool _canonicalMainStep(_Record record) =>
    record.json['canonicalMain'] == true &&
    _string(record.page['childSessionId']) == null;

int _compareRecords(_Record a, _Record b) {
  final aSeq = '${a.json['seq'] ?? ''}';
  final bSeq = '${b.json['seq'] ?? ''}';
  final aParts = aSeq.split('-');
  final bParts = bSeq.split('-');
  final aMs = int.tryParse(aParts.first);
  final bMs = int.tryParse(bParts.first);
  if (aMs != null && bMs != null && aMs != bMs) return aMs.compareTo(bMs);
  if (aParts.length > 1 && bParts.length > 1) {
    final aSub = int.tryParse(aParts[1]);
    final bSub = int.tryParse(bParts[1]);
    if (aSub != null && bSub != null && aSub != bSub) {
      return aSub.compareTo(bSub);
    }
  }
  final aTime = _date(a.json['ts']);
  final bTime = _date(b.json['ts']);
  if (aTime != null && bTime != null) {
    final byTime = aTime.compareTo(bTime);
    if (byTime != 0) return byTime;
  }
  return aSeq.compareTo(bSeq);
}

/// Folds canonical summary DTOs, optional full-step DTOs and event pages.
/// Events are deduplicated by `(sessionId,seq)` before chronological folding,
/// so an older page may arrive after a completion without regressing it.
TrajectoryRoot foldTrajectoryPages(Iterable<Object?> pages) {
  var counts = const TrajectoryCounts();
  final summaries = <Map<String, dynamic>>[];
  final snapshotSummaries = <Map<String, dynamic>>[];
  final recordsByKey = <String, _Record>{};
  final diagnostics = <CompactionMetadataDto>[];
  String? nextCursor;
  String? earlierCursor;
  var hasCanonicalRoster = false;

  for (final rawPage in pages) {
    if (rawPage is TrajectoryRoot) {
      hasCanonicalRoster = hasCanonicalRoster || rawPage.canonicalRoster;
      counts = rawPage.counts;
      snapshotSummaries.addAll([
        for (final worker in rawPage.workers) _workerJson(worker),
      ]);
      diagnostics.addAll(rawPage.diagnostics);
      nextCursor = rawPage.nextCursor ?? nextCursor;
      earlierCursor = rawPage.earlierCursor ?? earlierCursor;
      for (final step in rawPage.mainSteps) {
        final json = _stepJson(step);
        final record = _Record(json, const <String, dynamic>{});
        recordsByKey.putIfAbsent(record.key, () => record);
      }
      continue;
    }
    final page = _map(rawPage);
    final summary = _map(page['summary']);
    final countsJson = _map(
      page['counts'] ??
          summary['counts'] ??
          (summary.containsKey('total') ? summary : null),
    );
    if (countsJson.isNotEmpty) counts = TrajectoryCounts.fromJson(countsJson);
    if (page.containsKey('workers') ||
        page.containsKey('items') ||
        summary.containsKey('items')) {
      hasCanonicalRoster = true;
    }
    summaries.addAll(
      _maps(page['workers'] ?? page['items'] ?? summary['items']),
    );
    nextCursor = _string(page['nextCursor']) ?? nextCursor;
    earlierCursor =
        _string(page['earlierCursor'] ?? page['nextBefore']) ?? earlierCursor;

    for (final step in _maps(page['steps'])) {
      final normalized = <String, dynamic>{
        ...step,
        'ts': step['ts'] ?? step['timestamp'],
        'canonicalMain': _string(page['childSessionId']) == null,
      };
      final record = _Record(normalized, page);
      if (record.key.endsWith('\u0000')) continue;
      recordsByKey.putIfAbsent(record.key, () => record);
    }
    for (final event in _maps(page['events'])) {
      final payload = _map(event['payload']);
      final normalized = <String, dynamic>{
        ...event,
        ...payload,
        'type': event['type'] ?? payload['type'],
        'sessionId': payload['sessionId'] ?? event['sessionId'],
        'seq': event['seq'] ?? payload['seq'],
        'ts': event['ts'] ?? payload['ts'],
        'payload': payload,
        // Raw payloads cannot claim canonical-main provenance. Only canonical
        // step pages/serialized roots may carry that marker.
        'canonicalMain': false,
      };
      if (_string(page['childSessionId']) != null) {
        normalized['childSessionId'] = page['childSessionId'];
      }
      final record = _Record(normalized, page);
      if (record.key.endsWith('\u0000')) continue;
      recordsByKey.putIfAbsent(record.key, () => record);
    }
  }

  final records = recordsByKey.values.toList()..sort(_compareRecords);
  final workerMerges = <_WorkerMerge>[];
  final pendingRequests = <_Record>[];

  _WorkerMerge mergeFor(Map<String, dynamic> json) {
    final aliases = _workerAliases(json).toSet();
    final matches = <_WorkerMerge>[
      for (final worker in workerMerges)
        if (worker.aliases.any(aliases.contains)) worker,
    ];
    final _WorkerMerge target;
    if (matches.isEmpty) {
      target = _WorkerMerge();
      workerMerges.add(target);
    } else {
      target = matches.first;
      for (final other in matches.skip(1)) {
        _copyKnown(target.data, other.data);
        target.aliases.addAll(other.aliases);
        target.eventKeys.addAll(other.eventKeys);
        target.startEventKnown =
            target.startEventKnown || other.startEventKnown;
        target.admissionKnown = target.admissionKnown || other.admissionKnown;
        workerMerges.remove(other);
      }
    }
    target.aliases.addAll(aliases);
    return target;
  }

  for (final summary in snapshotSummaries) {
    final worker = mergeFor(summary);
    _copyKnown(worker.data, summary);
    if (summary['startKnown'] == true) worker.startEventKnown = true;
    if (summary['startKnown'] == false) worker.data['startKnown'] = false;
  }

  for (final record in records) {
    final json = record.json;
    final type = _string(json['type']) ?? '';
    if (_canonicalMainStep(record) && type.startsWith('subagent_')) {
      // Canonical parent lifecycle DTOs are main chronology only. They carry
      // no child-scoped activity stream and cannot create worker rows/cursors.
      continue;
    }
    if (type.startsWith('subagent_') &&
        _string(record.page['childSessionId']) == null &&
        hasCanonicalRoster) {
      final aliases = _workerAliases(json).toSet();
      final known = workerMerges.any(
        (worker) => worker.aliases.any(aliases.contains),
      );
      if (!known) {
        // The canonical roster is authoritative. Parent-scoped raw lifecycle
        // events are a legacy fallback only when that roster is unavailable;
        // they must not add a phantom worker beside a complete roster.
        continue;
      }
    }
    if (type == 'compaction_completed') {
      try {
        diagnostics.add(CompactionMetadataDto.fromJson(json));
      } on FormatException {
        // Legacy diagnostics without the rich fields remain available only
        // through Show raw; they do not become ordinary steps.
      }
      continue;
    }
    if (type == 'subagent_compacted') {
      CompactionMetadataDto? compaction;
      try {
        compaction = CompactionMetadataDto.fromJson(json);
      } on FormatException {
        compaction = null;
      }
      if (compaction != null) {
        final worker = mergeFor(json);
        worker.data['compaction'] = compaction.toJson();
        worker.data['logicalWorkerId'] = compaction.workerId;
        worker.data['lastActivity'] = type;
        worker.data['lastActivityAt'] = json['ts'];
        worker.eventKeys.add(record.key);
      }
      continue;
    }

    if (type == 'subagent_requested' && _workerAliases(json).isEmpty) {
      // A request without a canonical request/worker alias cannot yet be a
      // worker row. Hold it until the real deferred/admitted/start lineage is
      // known; if that lineage is ambiguous it remains only a main request.
      pendingRequests.add(record);
      continue;
    }

    final isWorkerEvent =
        type.startsWith('subagent_') ||
        _string(record.page['childSessionId']) != null;
    if (isWorkerEvent) {
      final worker = mergeFor(json);
      _copyKnown(worker.data, json);
      if (type.startsWith('subagent_')) {
        worker.data['parentRunId'] = json['runId'];
      }
      if (type == 'subagent_deferred') {
        worker.data['deferredAt'] = json['deferredAt'] ?? json['ts'];
        worker.data['admittedAt'] = null;
        worker.data['startedAt'] = null;
        worker.data['endedAt'] = null;
        worker.data['childSessionId'] = null;
        worker.data['childRunId'] = null;
      }
      if (type == 'subagent_admitted') {
        // Admission is a real scheduler transition, but not an execution
        // start. The canonical status has no separate admitted value.
        worker.admissionKnown = true;
        worker.data['status'] = 'running';
      }
      if (type == 'subagent_started') {
        worker.admissionKnown = true;
        worker.startEventKnown = true;
        worker.data['startedAt'] = json['startedAt'];
      }
      if (type == 'subagent_completed') {
        worker.admissionKnown = true;
        worker.data['endedAt'] = json['endedAt'] ?? json['ts'];
      }
      if (type == 'subagent_requested') {
        worker.data['requestedAt'] = json['requestedAt'] ?? json['ts'];
      }
      if (json['status'] != null) worker.data['status'] = json['status'];
      worker.data['lastActivity'] =
          _string(json['lastActivity'] ?? json['name']) ?? type;
      worker.data['lastActivityAt'] = json['lastActivityAt'] ?? json['ts'];
      final childSessionId = _string(record.page['childSessionId']);
      if (childSessionId != null) {
        // Parent lifecycle events carry the parent session's seq. That seq is
        // not a valid child-stream cursor and must never advance lastCursor.
        if (_string(record.page['nextCursor']) != null) {
          worker.data['lastCursor'] = record.page['nextCursor'];
        } else if (_string(json['seq']) != null) {
          worker.data['lastCursor'] = json['seq'];
        }
        final steps = _maps(worker.data['steps']);
        final duplicate = steps.any((step) {
          final sameSession = step['sessionId'] == json['sessionId'];
          return sameSession && '${step['seq']}' == '${json['seq']}';
        });
        if (!duplicate) {
          worker.data['steps'] = <Map<String, dynamic>>[
            ...steps,
            <String, dynamic>{...json, 'actorKind': 'worker'},
          ];
        }
      }
      worker.eventKeys.add(record.key);
    }
  }

  for (final request in pendingRequests) {
    final json = request.json;
    final sessionId = _string(json['sessionId']);
    final batchId = _string(json['batchId']);
    final rootId = _string(json['rootTaskRunId'] ?? json['runId']);
    final parentRunId = _string(json['runId']);
    final candidates = <_WorkerMerge>[
      for (final worker in workerMerges)
        if (_string(worker.data['sessionId']) == sessionId &&
            batchId != null &&
            _string(worker.data['batchId']) == batchId &&
            rootId != null &&
            _string(
                  worker.data['rootTaskRunId'] ?? worker.data['parentRunId'],
                ) ==
                rootId &&
            (parentRunId == null ||
                _string(worker.data['parentRunId']) == parentRunId))
          worker,
    ];
    if (candidates.length != 1) continue;
    final worker = candidates.single;
    final previousRequest = _date(worker.data['requestedAt']);
    final requestedAt = _date(json['requestedAt'] ?? json['ts']);
    _copyKnown(worker.data, json);
    if (previousRequest != null &&
        requestedAt != null &&
        previousRequest.isBefore(requestedAt)) {
      worker.data['requestedAt'] = previousRequest.toIso8601String();
    }
    worker.data['parentRunId'] = parentRunId;
    worker.eventKeys.add(request.key);
  }

  for (final summary in summaries) {
    final worker = mergeFor(summary);
    final previousStatus = worker.data['status'];
    _copyKnown(worker.data, summary);
    if (summary['status'] == 'awaiting_next_user_task' &&
        worker.admissionKnown &&
        previousStatus != null) {
      // A stale deferred DTO cannot undo a later real admission. Conversely,
      // canonical current summaries still win over older terminal events.
      worker.data['status'] = previousStatus;
    }
    if (summary['startKnown'] == true) worker.startEventKnown = true;
    if (summary.containsKey('startKnown') && summary['startKnown'] == false) {
      worker.data['startKnown'] = false;
    }
  }

  bool consistentStart(Map<String, dynamic> data, DateTime startedAt) {
    for (final key in const <String>['requestedAt', 'admittedAt']) {
      final earlier = _date(data[key]);
      if (earlier != null && earlier.isAfter(startedAt)) return false;
    }
    final endedAt = _date(data['endedAt']);
    return endedAt == null || !endedAt.isBefore(startedAt);
  }

  final workers =
      <TrajectoryWorker>[
        for (final merged in workerMerges)
          TrajectoryWorker.fromJson(<String, dynamic>{
            ...merged.data,
            'startKnown': (() {
              final startedAt = _date(merged.data['startedAt']);
              if (startedAt != null &&
                  !consistentStart(merged.data, startedAt)) {
                return false;
              }
              // The real start event is evidence even when the legacy payload
              // has no timestamp. Its missing startedAt must stay unknown; a
              // stale summary false cannot erase either kind of start evidence.
              return merged.startEventKnown ||
                  (startedAt != null && merged.data['startKnown'] == true);
            })(),
          }),
      ]..sort((a, b) {
        final aAt = a.requestedAt ?? a.startedAt ?? a.lastActivityAt;
        final bAt = b.requestedAt ?? b.startedAt ?? b.lastActivityAt;
        if (aAt != null && bAt != null) return aAt.compareTo(bAt);
        if (aAt != null) return -1;
        if (bAt != null) return 1;
        return 0;
      });

  final workerEventKeys = <String>{
    for (final worker in workerMerges) ...worker.eventKeys,
  };
  final mainSteps = <TrajectoryStep>[
    for (final record in records)
      if (_string(record.json['type']) != 'compaction_completed' &&
          (_string(record.json['type']) != 'subagent_compacted' ||
              _canonicalMainStep(record)))
        if (!workerEventKeys.contains(record.key) ||
            _string(record.json['actorKind']) == 'main' ||
            record.page['childSessionId'] == null)
          if (_string(record.json['type']) != 'message_delta')
            TrajectoryStep.fromJson(record.json),
  ];

  return TrajectoryRoot(
    counts: counts,
    mainSteps: mainSteps,
    workers: workers,
    diagnostics: diagnostics,
    nextCursor: nextCursor,
    earlierCursor: earlierCursor,
    canonicalRoster: hasCanonicalRoster,
  );
}

@immutable
class RawTrajectoryEntry {
  const RawTrajectoryEntry({
    required this.id,
    required this.value,
    this.offset,
    this.truncated = false,
  });

  final String id;
  final Object? value;

  /// Exact-history chunks for one entry can continue at several offsets.
  final int? offset;
  final bool truncated;

  String get dedupeKey => offset == null ? id : '$id@$offset';
}

/// A page from the authenticated, owner-authorized server-redacted raw view.
/// The second boundary redacts structured content and withholds non-decodable
/// fragments instead of guessing across credentials or JSON properties.
@immutable
class RawTrajectoryPage {
  const RawTrajectoryPage({
    required this.entries,
    this.nextCursor,
    this.truncated = false,
  });

  final List<RawTrajectoryEntry> entries;
  final String? nextCursor;
  final bool truncated;

  factory RawTrajectoryPage.fromJson(Map<String, dynamic> json) {
    final entries = <RawTrajectoryEntry>[];
    for (final item in _maps(json['items'] ?? json['events'])) {
      final id = _safeRawIdentifier(
        item['id'] ?? item['stableId'] ?? item['eventCursor'],
        entries.length,
      );
      final value = item.containsKey('value') ? item['value'] : item;
      entries.add(
        RawTrajectoryEntry(
          id: id,
          value: _redact(value),
          truncated: item['truncated'] == true,
        ),
      );
    }
    for (final chunk in _maps(json['chunks'])) {
      final item = _map(chunk['item']);
      final projected = _redactRawChunkData(chunk['data']);
      final value = <String, dynamic>{
        'item': _redact(item),
        'offset': _int(chunk['offset']),
        'data': projected.data,
        'nextOffset': _int(chunk['nextOffset']),
        if (projected.withheld) ...<String, Object?>{
          'withheld': true,
          'withholdReason':
              'Fragmented raw content cannot be safely projected.',
        },
      };
      entries.add(
        RawTrajectoryEntry(
          id: _safeRawIdentifier(item['stableId'], entries.length),
          value: value,
          offset: _int(chunk['offset']),
          truncated: chunk['truncated'] == true,
        ),
      );
    }
    return RawTrajectoryPage(
      entries: entries,
      nextCursor: _safeRawCursor(json['nextCursor']),
      truncated:
          json['truncated'] == true || entries.any((entry) => entry.truncated),
    );
  }

  String get displayText =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'items': <Object?>[
          for (final entry in entries)
            <String, Object?>{
              'id': entry.id,
              'value': entry.value,
              if (entry.truncated) 'truncated': true,
            },
        ],
        'nextCursor': nextCursor,
        if (truncated) 'truncated': true,
      });
}

final RegExp _patPattern = RegExp(
  r'(?:github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|sk-[A-Za-z0-9_-]+)',
);
final RegExp _bearerPattern = RegExp(
  r'Bearer\s+[^\s,;]+',
  caseSensitive: false,
);
final RegExp _jwtPattern = RegExp(
  r'\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b',
);
final RegExp _headerPattern = RegExp(
  r'(^|\r?\n)\s*([A-Za-z][A-Za-z0-9-]*)\s*:\s*[^\r\n]+',
  multiLine: true,
);
final RegExp _namedSecretPattern = RegExp(
  r'\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|signature|sig|key)=)[^\s&]+',
  caseSensitive: false,
);

const Set<String> _secretKeys = <String>{
  'authorization',
  'proxyauthorization',
  'token',
  'accesstoken',
  'refreshtoken',
  'idtoken',
  'apikey',
  'xapikey',
  'secret',
  'secretkey',
  'clientsecret',
  'password',
  'cookie',
  'setcookie',
  'signature',
  'credential',
  'xamzsignature',
  'xamzcredential',
  'xamzsecuritytoken',
  'googsignature',
  'thought',
  'thoughts',
  'thinking',
  'reasoning',
  'privatethought',
  'privatethoughts',
};

String _keyName(String key) =>
    key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

bool _sensitiveKey(String key) {
  final normalized = _keyName(key);
  return _secretKeys.contains(normalized) ||
      normalized.endsWith('apitoken') ||
      normalized.endsWith('accesstoken') ||
      normalized.endsWith('refreshtoken') ||
      normalized.endsWith('apikey') ||
      normalized.endsWith('clientsecret') ||
      normalized.endsWith('privatekey') ||
      normalized.endsWith('signature') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('token') ||
      normalized == 'providerbaseurl' ||
      normalized == 'baseurl';
}

Object? _redact(Object? value) {
  if (value is Map) {
    final entries = <MapEntry<String, Object?>>[];
    final used = <String>{};
    for (final entry in value.entries) {
      final originalKey = '${entry.key}';
      final baseKey = _redactString(originalKey);
      var projectedKey = baseKey;
      var suffix = 1;
      while (!used.add(projectedKey)) {
        projectedKey = '$baseKey-${suffix++}';
      }
      entries.add(
        MapEntry<String, Object?>(
          projectedKey,
          _sensitiveKey(originalKey) ? '[redacted]' : _redact(entry.value),
        ),
      );
    }
    return Map<String, Object?>.fromEntries(entries);
  }
  if (value is List) return <Object?>[for (final item in value) _redact(item)];
  if (value is String) {
    if (_sensitiveJsonPrimitive(value)) return '[redacted]';
    return _redactString(value);
  }
  return value;
}

Object? _redactText(Object? value) {
  if (value is! String) return _redact(value);
  try {
    final decoded = jsonDecode(value);
    return jsonEncode(_redact(decoded));
  } catch (_) {
    return _redactString(value);
  }
}

/// A fragment of serialized JSON is not a safe structured projection boundary.
/// Keep complete decodable chunks on the full redactor; withhold every other
/// slice rather than leaking sensitive properties or split credentials.
final RegExp _jsonPropertyPrefix = RegExp(
  r'^\s*\{?\s*"([A-Za-z][A-Za-z0-9_-]*)"\s*:',
);

bool _sensitiveJsonPrimitive(String value) {
  final match = _jsonPropertyPrefix.firstMatch(value);
  return match != null && _sensitiveKey(match.group(1)!);
}

({Object? data, bool withheld}) _redactRawChunkData(Object? value) {
  if (value is! String) return (data: _redactText(value), withheld: false);
  try {
    final decoded = jsonDecode(value);
    if (decoded is String && _sensitiveJsonPrimitive(decoded)) {
      return (data: null, withheld: true);
    }
    return (data: _redactText(value), withheld: false);
  } catch (_) {
    return (data: null, withheld: true);
  }
}

final RegExp _plainUrlPattern = RegExp(
  r'https?://[^\s<>"\]]+',
  caseSensitive: false,
);
final RegExp _encodedUrlPattern = RegExp(
  r'https?%3A%2F%2F[^\s<>"\]]+',
  caseSensitive: false,
);

String _redactString(String value) {
  final masked = value
      .replaceAll(_patPattern, '[redacted]')
      .replaceAll(_bearerPattern, 'Bearer [redacted]')
      .replaceAll(_jwtPattern, '[redacted]')
      .replaceAllMapped(_headerPattern, (match) {
        final key = match.group(2)!;
        return _sensitiveKey(key)
            ? '${match.group(1)}$key: [redacted]'
            : match.group(0)!;
      });
  final encodedSafe = masked.replaceAllMapped(_encodedUrlPattern, (match) {
    final encoded = match.group(0)!;
    try {
      final decoded = Uri.decodeComponent(encoded);
      return Uri.encodeComponent(_redactString(decoded));
    } catch (_) {
      return '[redacted]';
    }
  });
  return encodedSafe
      .replaceAllMapped(_plainUrlPattern, (match) {
        final candidate = match.group(0)!;
        final uri = Uri.tryParse(candidate);
        if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
          return _redactWholeUri(candidate) ? '[redacted]' : candidate;
        }
        return _redactUri(uri, fallback: candidate);
      })
      .replaceAllMapped(
        _namedSecretPattern,
        (match) => '${match.group(1)}[redacted]',
      );
}

bool _redactWholeUri(String value) {
  final lower = value.toLowerCase();
  return lower.contains('signature=') ||
      lower.contains('credential=') ||
      lower.contains('token=') ||
      lower.contains('apikey=') ||
      lower.contains('api_key=') ||
      lower.contains('client_secret=');
}

String _redactUri(Uri uri, {required String fallback}) {
  final sensitiveQuery = uri.queryParameters.keys.any(_sensitiveKey);
  if (!sensitiveQuery && uri.userInfo.isEmpty) return fallback;
  final safeQuery = <String, String>{
    for (final entry in uri.queryParameters.entries)
      if (!_sensitiveKey(entry.key))
        entry.key: entry.value
            .replaceAll(_patPattern, '[redacted]')
            .replaceAll(_bearerPattern, 'Bearer [redacted]'),
  };
  return uri.replace(userInfo: '', queryParameters: safeQuery).toString();
}

String _safeRawIdentifier(Object? value, int index) {
  final fallback = 'raw-$index';
  final candidate = _string(value);
  if (candidate == null) return fallback;
  final redacted = _redactString(candidate);
  return redacted == candidate ? candidate : fallback;
}

String? _safeRawCursor(Object? value) {
  final candidate = _string(value);
  if (candidate == null) return null;
  // A credential-shaped cursor is neither displayed nor sent back to the
  // gateway. Dropping pagination is safer than projecting a bearer capability.
  return _redactString(candidate) == candidate ? candidate : null;
}
