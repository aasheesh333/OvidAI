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

  test('rejects unsupported schema and arbitrary payload fields', () {
    final json = <String, dynamic>{
      'schemaVersion': 99,
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
      'payload': {'secret': 'must not be accepted'},
    };

    expect(() => UsageAttempt.fromJson(json), throwsArgumentError);
  });
}
