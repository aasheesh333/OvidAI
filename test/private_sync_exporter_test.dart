import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/exporter.dart';

const _secretTranscript =
    'Reasoning contains sk-live-DO_NOT_REDACT and password=hunter2';

void main() {
  const envelope = ExportEnvelope(
    recordId: 'record-1',
    sourceDeviceId: 'device-1',
    conversationId: 'conversation-1',
    createdAt: '2026-10-09T12:00:00Z',
    revision: 1,
  );

  test(
    'exports every transcript field verbatim and only as transcript DTO fields',
    () {
      final payload = TranscriptPayload(
        messageId: 'message-1',
        parentMessageId: 'parent-1',
        kind: TranscriptKind.assistant,
        text: _secretTranscript,
        providerMetadataRecordId: 'provider-record-1',
        requestPurpose: 'chat',
        displayTitle: 'Answer',
      );

      final record = PrivateSyncExporter.transcript(envelope, payload);

      expect(record.toWire(), {
        'schemaVersion': 1,
        'recordId': 'record-1',
        'sourceDeviceId': 'device-1',
        'recordType': 'transcript',
        'conversationId': 'conversation-1',
        'createdAt': '2026-10-09T12:00:00Z',
        'revision': 1,
        'payload': {
          'messageId': 'message-1',
          'parentMessageId': 'parent-1',
          'kind': 'assistant',
          'text': _secretTranscript,
          'providerMetadataRecordId': 'provider-record-1',
          'requestPurpose': 'chat',
          'displayTitle': 'Answer',
        },
      });
    },
  );

  test('exports usage, activity, and provider metadata field by field', () {
    final usage = PrivateSyncExporter.usage(
      envelope.copyWith(recordId: 'attempt-1'),
      UsagePayload(
        logicalRequestId: 'request-1',
        attemptId: 'attempt-1',
        requestedModel: 'gpt-x',
        reportedModel: 'gpt-x-2026',
        outcome: UsageOutcome.succeeded,
        inputTokens: 10,
        outputTokens: 20,
        totalTokens: 30,
        usageProvenance: UsageProvenance.providerReported,
        startedAt: '2026-10-09T12:00:00Z',
        completedAt: '2026-10-09T12:00:01Z',
        elapsedMilliseconds: 1000,
      ),
    );
    final activity = PrivateSyncExporter.activity(
      envelope,
      ActivityPayload(
        logicalRequestId: 'request-1',
        attemptId: 'attempt-1',
        kind: ActivityKind.request,
        status: ActivityStatus.succeeded,
        updatedAt: '2026-10-09T12:00:01Z',
        title: 'Request complete',
        detail: 'Done',
        usageRecordId: 'attempt-1',
      ),
    );
    final provider = PrivateSyncExporter.providerMetadata(
      envelope,
      ProviderMetadataPayload(
        providerId: 'openai',
        modelId: 'gpt-x',
        endpoint: 'https://api.example.com/v1',
        requestPurpose: 'chat',
        displayName: 'Example',
        supportsStreaming: true,
      ),
    );

    expect(usage.recordType, SyncRecordType.usage);
    expect(usage.toWire()['payload'], {
      'logicalRequestId': 'request-1',
      'attemptId': 'attempt-1',
      'requestedModel': 'gpt-x',
      'reportedModel': 'gpt-x-2026',
      'outcome': 'succeeded',
      'inputTokens': 10,
      'outputTokens': 20,
      'totalTokens': 30,
      'usageProvenance': 'providerReported',
      'startedAt': '2026-10-09T12:00:00Z',
      'completedAt': '2026-10-09T12:00:01Z',
      'elapsedMilliseconds': 1000,
    });
    expect(activity.recordType, SyncRecordType.activity);
    expect(provider.recordType, SyncRecordType.providerMetadata);
  });

  test('does not add credential, queue, path, or session fields', () {
    final record = PrivateSyncExporter.providerMetadata(
      envelope,
      ProviderMetadataPayload(
        providerId: 'openai',
        modelId: null,
        endpoint: 'https://api.example.com/v1',
        requestPurpose: null,
        displayName: null,
        supportsStreaming: false,
      ),
    );
    final wire = record.toWire();
    expect(
      wire.keys,
      containsAll(const [
        'schemaVersion',
        'recordId',
        'sourceDeviceId',
        'recordType',
        'conversationId',
        'createdAt',
        'revision',
        'payload',
      ]),
    );
    expect(
      wire.keys,
      isNot(
        anyOf(
          contains('apiKey'),
          contains('runtimeQueue'),
          contains('session'),
        ),
      ),
    );
    expect(
      (wire['payload'] as Map).keys,
      isNot(
        anyOf(
          contains('apiKey'),
          contains('runtimeQueue'),
          contains('path'),
          contains('session'),
        ),
      ),
    );
  });
}
