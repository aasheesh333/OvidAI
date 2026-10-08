import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/usage_attempt.dart';

void main() {
  test('unknown and explicitly reported zero remain distinguishable', () {
    expect(UsageTokenCount.unknown().value, isNull);
    expect(UsageTokenCount.reported(0).value, 0);
    expect(UsageTokenCount.unknown().provenance, UsageProvenance.unknown);
    expect(
      UsageTokenCount.reported(0).provenance,
      UsageProvenance.providerReported,
    );
  });

  test('attempt round trips all fields and mixed token provenance', () {
    final attempt = UsageAttempt(
      attemptId: 'attempt-123',
      requestId: 'request-123',
      revision: 2,
      sourceDevice: 'device-abc',
      provider: 'openai',
      requestedModel: 'auto',
      reportedModel: 'gpt-5-mini',
      purpose: 'chat',
      sessionId: 'session-1',
      runId: 'run-1',
      startedAt: DateTime.utc(2026, 10, 8, 12, 0),
      completedAt: DateTime.utc(2026, 10, 8, 12, 0, 1),
      elapsed: const Duration(milliseconds: 1000),
      dispatchStage: UsageDispatchStage.completed,
      outcome: UsageOutcome.succeeded,
      inputTokens: UsageTokenCount.reported(10),
      outputTokens: UsageTokenCount.estimated(5),
      totalTokens: UsageTokenCount.derived(15),
    );

    final restored = UsageAttempt.fromJson(attempt.toJson());

    expect(restored, attempt);
    expect(restored.toJson(), attempt.toJson());
  });

  test('round trip preserves an unknown model identity', () {
    final attempt = UsageAttempt(
      attemptId: 'attempt-unknown-model',
      requestId: 'request-unknown-model',
      revision: 1,
      sourceDevice: 'device-abc',
      provider: 'custom-provider',
      requestedModel: 'auto',
      reportedModel: null,
      purpose: 'title',
      startedAt: DateTime.utc(2026, 10, 8),
      completedAt: null,
      elapsed: null,
      dispatchStage: UsageDispatchStage.prepared,
      outcome: UsageOutcome.pending,
    );

    expect(UsageAttempt.fromJson(attempt.toJson()).reportedModel, isNull);
  });

  test('rejects negative token counts', () {
    expect(() => UsageTokenCount.reported(-1), throwsArgumentError);
  });

  test('rejects negative elapsed durations before serialization', () {
    expect(
      () => UsageAttempt(
        attemptId: 'attempt-negative-duration',
        requestId: 'request-negative-duration',
        revision: 1,
        sourceDevice: 'device-1',
        provider: 'openai',
        requestedModel: 'gpt-5',
        purpose: 'chat',
        startedAt: DateTime.utc(2026, 10, 8),
        elapsed: const Duration(microseconds: -1),
        dispatchStage: UsageDispatchStage.prepared,
        outcome: UsageOutcome.pending,
      ),
      throwsArgumentError,
    );
  });

  test('rejects elapsed durations finer than supported millisecond precision', () {
    expect(
      () => UsageAttempt(
        attemptId: 'attempt-sub-ms-duration',
        requestId: 'request-sub-ms-duration',
        revision: 1,
        sourceDevice: 'device-1',
        provider: 'openai',
        requestedModel: 'gpt-5',
        purpose: 'chat',
        startedAt: DateTime.utc(2026, 10, 8),
        elapsed: const Duration(microseconds: 1001),
        dispatchStage: UsageDispatchStage.prepared,
        outcome: UsageOutcome.pending,
      ),
      throwsArgumentError,
    );
  });

  test('rejects contradictory token provenance and value', () {
    expect(
      () => UsageTokenCount(value: 1, provenance: UsageProvenance.unknown),
      throwsArgumentError,
    );
    expect(
      () => UsageTokenCount(value: null, provenance: UsageProvenance.derived),
      throwsArgumentError,
    );
  });

  test('rejects malformed identity fields', () {
    expect(
      () => UsageAttempt(
        attemptId: 'attempt bad',
        requestId: 'request-1',
        revision: 1,
        sourceDevice: 'device-1',
        provider: 'openai',
        requestedModel: 'gpt-5',
        purpose: 'chat',
        startedAt: DateTime.utc(2026, 10, 8),
        dispatchStage: UsageDispatchStage.prepared,
        outcome: UsageOutcome.pending,
      ),
      throwsArgumentError,
    );
  });

  test('rejects a non-integer schema version', () {
    final json = <String, dynamic>{
      'schemaVersion': 1.0,
      'attemptId': 'attempt-1',
      'requestId': 'request-1',
      'revision': 1,
      'sourceDevice': 'device-1',
      'provider': 'openai',
      'requestedModel': 'gpt-5',
      'purpose': 'chat',
      'startedAt': '2026-10-08T00:00:00.000Z',
      'dispatchStage': 'prepared',
      'outcome': 'pending',
    };

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });

  test('rejects an unsupported integer schema version', () {
    final json = <String, dynamic>{
      'schemaVersion': 99,
      'attemptId': 'attempt-1',
      'requestId': 'request-1',
      'revision': 1,
      'sourceDevice': 'device-1',
      'provider': 'openai',
      'requestedModel': 'gpt-5',
      'reportedModel': null,
      'purpose': 'chat',
      'sessionId': null,
      'runId': null,
      'startedAt': '2026-10-08T00:00:00.000Z',
      'completedAt': null,
      'elapsedMilliseconds': null,
      'dispatchStage': 'prepared',
      'outcome': 'pending',
      'inputTokens': null,
      'outputTokens': null,
      'totalTokens': null,
    };

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });

  test('rejects unknown record fields independently of schema validation', () {
    final json = UsageAttempt(
      attemptId: 'attempt-1',
      requestId: 'request-1',
      revision: 1,
      sourceDevice: 'device-1',
      provider: 'openai',
      requestedModel: 'gpt-5',
      purpose: 'chat',
      startedAt: DateTime.utc(2026, 10, 8),
      dispatchStage: UsageDispatchStage.prepared,
      outcome: UsageOutcome.pending,
    ).toJson()
      ..['payload'] = {'secret': 'must not be accepted'};

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });

  test('rejects timestamps without an explicit timezone', () {
    final json = _validJson()..['startedAt'] = '2026-10-08T00:00:00.000';

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });

  test('rejects timestamps that Dart normalizes', () {
    final json = _validJson()..['startedAt'] = '2026-02-30T00:00:00.000Z';

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });

  test('rejects timestamps with overflow components', () {
    final json = _validJson()..['startedAt'] = '2026-10-08T24:00:00.000Z';

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });
}

Map<String, dynamic> _validJson() => UsageAttempt(
      attemptId: 'attempt-valid',
      requestId: 'request-valid',
      revision: 1,
      sourceDevice: 'device-1',
      provider: 'openai',
      requestedModel: 'gpt-5',
      purpose: 'chat',
      startedAt: DateTime.utc(2026, 10, 8),
      dispatchStage: UsageDispatchStage.prepared,
      outcome: UsageOutcome.pending,
    ).toJson();
