import 'dart:async';
import 'dart:io';

import 'usage_attempt.dart';

typedef UsageAttemptWriter =
    Future<bool> Function(UsageAttempt attempt, {Object? owner});

enum UsageAttemptCaptureStage { prepared, update, terminal }

/// Bounded journal-write status; raw storage errors are never retained.
class UsageAttemptCaptureResult {
  const UsageAttemptCaptureResult({
    required this.stage,
    required this.captured,
  });

  final UsageAttemptCaptureStage stage;
  final bool captured;
}

/// Owns the lifecycle of one physical provider request.
///
/// The recorder deliberately knows nothing about retry policy or transport
/// errors. It only turns the transport's observable facts into an immutable
/// prepared row followed by a single terminal upsert.
class UsageAttemptRecorder {
  UsageAttemptRecorder({required this.owner, required this.write});

  final Object owner;
  final UsageAttemptWriter write;

  Future<UsageAttemptHandle?> begin({
    required String requestId,
    required String provider,
    required String requestedModel,
    required String purpose,
    required String? sessionId,
    required String? runId,
  }) async {
    final startedAt = DateTime.now().toUtc();
    final base = UsageAttempt(
      attemptId: _id('attempt'),
      requestId: _identity(requestId, 'request'),
      revision: 1,
      sourceDevice: _identity(Platform.operatingSystem, 'unknown'),
      provider: _identity(provider, 'unknown'),
      requestedModel: _identity(requestedModel, 'unknown'),
      purpose: _identity(purpose, 'agent'),
      sessionId: _optionalIdentity(sessionId),
      runId: _optionalIdentity(runId),
      startedAt: startedAt,
      dispatchStage: UsageDispatchStage.prepared,
      outcome: UsageOutcome.pending,
    );
    final handle = UsageAttemptHandle(this, base);
    // Preparation is durable bookkeeping, not provider transport. Queue it
    // without making request admission wait for a slow journal.
    unawaited(handle._prepare());
    return handle;
  }

  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  static int _sequence = 0;
}

class UsageAttemptHandle {
  UsageAttemptHandle(this._recorder, this._prepared);

  final UsageAttemptRecorder _recorder;
  final UsageAttempt _prepared;
  bool _finished = false;
  int _revision = 1;
  Map<String, dynamic>? _usage;
  String? _reportedModel;
  int? _transportElapsedMilliseconds;
  Timer? _updateTimer;
  Future<void> _writeTail = Future<void>.value();
  UsageAttemptCaptureResult _captureResult = const UsageAttemptCaptureResult(
    stage: UsageAttemptCaptureStage.prepared,
    captured: false,
  );

  String get attemptId => _prepared.attemptId;
  UsageAttemptCaptureResult get captureResult => _captureResult;

  Future<void> _prepare() async {
    final write = _writeTail.then((_) async {
      try {
        final captured = await _recorder.write(
          _prepared,
          owner: _recorder.owner,
        );
        _recordResult(UsageAttemptCaptureStage.prepared, captured);
      } catch (_) {
        _recordResult(UsageAttemptCaptureStage.prepared, false);
      }
    });
    _writeTail = write;
    await write;
  }

  /// Records monotonic transport time, excluding journal persistence latency.
  void setTransportElapsed(int milliseconds) {
    if (milliseconds >= 0) _transportElapsedMilliseconds = milliseconds;
  }

  Future<void> markTransmitted() {
    // Transmission is on the provider's critical path. Queue the journal
    // update, but let the request continue without waiting for storage.
    unawaited(
      _enqueueSave(
        dispatchStage: UsageDispatchStage.transmitted,
        outcome: UsageOutcome.pending,
      ),
    );
    return Future<void>.value();
  }

  Future<void> updateUsage({
    Map<String, dynamic>? usage,
    String? reportedModel,
  }) {
    if (usage != null) _usage = Map<String, dynamic>.from(usage);
    if (reportedModel != null) _reportedModel = reportedModel;
    if (_finished || _updateTimer != null) return Future<void>.value();
    _updateTimer = Timer(const Duration(milliseconds: 10), () {
      _updateTimer = null;
      if (!_finished) {
        unawaited(
          _enqueueSave(
            dispatchStage: UsageDispatchStage.transmitted,
            outcome: UsageOutcome.pending,
          ),
        );
      }
    });
    return Future<void>.value();
  }

  Future<void> complete({
    required UsageOutcome outcome,
    String? reportedModel,
    Map<String, dynamic>? usage,
  }) async {
    if (_finished) return;
    _updateTimer?.cancel();
    _updateTimer = null;
    _finished = true;
    if (usage != null) _usage = Map<String, dynamic>.from(usage);
    if (reportedModel != null) _reportedModel = reportedModel;
    await _enqueueSave(
      dispatchStage: UsageDispatchStage.completed,
      outcome: outcome,
    );
  }

  Future<void> _enqueueSave({
    required UsageDispatchStage dispatchStage,
    required UsageOutcome outcome,
  }) async {
    if (_finished && outcome == UsageOutcome.pending) return;
    final input = _token(_usage, 'prompt_tokens');
    final output = _token(_usage, 'completion_tokens');
    final total = _token(_usage, 'total_tokens');
    final completedAt = DateTime.now().toUtc();
    final elapsed = _transportElapsedMilliseconds == null
        ? null
        : Duration(milliseconds: _transportElapsedMilliseconds!);
    final completed = UsageAttempt(
      attemptId: _prepared.attemptId,
      requestId: _prepared.requestId,
      revision: ++_revision,
      sourceDevice: _prepared.sourceDevice,
      provider: _prepared.provider,
      requestedModel: _prepared.requestedModel,
      reportedModel: _optionalIdentity(_reportedModel),
      purpose: _prepared.purpose,
      sessionId: _prepared.sessionId,
      runId: _prepared.runId,
      startedAt: _prepared.startedAt,
      completedAt: dispatchStage == UsageDispatchStage.completed
          ? completedAt
          : null,
      elapsed: dispatchStage == UsageDispatchStage.completed ? elapsed : null,
      dispatchStage: dispatchStage,
      outcome: outcome,
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
    );
    final write = _writeTail.then((_) async {
      try {
        final captured = await _recorder.write(
          completed,
          owner: _recorder.owner,
        );
        _recordResult(
          dispatchStage == UsageDispatchStage.completed
              ? UsageAttemptCaptureStage.terminal
              : UsageAttemptCaptureStage.update,
          captured,
        );
      } catch (_) {
        _recordResult(
          dispatchStage == UsageDispatchStage.completed
              ? UsageAttemptCaptureStage.terminal
              : UsageAttemptCaptureStage.update,
          false,
        );
      }
    });
    _writeTail = write;
    await write;
  }

  void _recordResult(UsageAttemptCaptureStage stage, bool captured) {
    _captureResult = UsageAttemptCaptureResult(
      stage: stage,
      captured: captured,
    );
  }
}

UsageTokenCount? _token(Map<String, dynamic>? usage, String key) {
  if (usage == null || !usage.containsKey(key)) return null;
  final value = usage[key];
  if (value is! num || value < 0) return null;
  return UsageTokenCount.reported(value.toInt());
}

String _identity(String value, String fallback) {
  final normalized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_');
  if (normalized.isEmpty) return fallback;
  return RegExp(r'^[A-Za-z0-9]').hasMatch(normalized)
      ? normalized
      : '${fallback}_$normalized';
}

String? _optionalIdentity(String? value) =>
    value == null || value.trim().isEmpty ? null : _identity(value, 'unknown');
