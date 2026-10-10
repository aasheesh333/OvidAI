/// Explicit adapters from the typed private-sync payloads to upload records.
///
/// This module deliberately accepts only the closed payload DTOs. It does not
/// accept runtime state, sessions, queues, credentials, or generic maps.
library;

import 'dto.dart';

/// Client-owned fields needed to construct one sync upload envelope.
class ExportEnvelope {
  const ExportEnvelope({
    required this.recordId,
    required this.sourceDeviceId,
    required this.conversationId,
    required this.createdAt,
    required this.revision,
  });

  final String recordId;
  final String sourceDeviceId;
  final String? conversationId;
  final String createdAt;
  final int revision;

  ExportEnvelope copyWith({
    String? recordId,
    String? sourceDeviceId,
    String? conversationId,
    String? createdAt,
    int? revision,
  }) => ExportEnvelope(
    recordId: recordId ?? this.recordId,
    sourceDeviceId: sourceDeviceId ?? this.sourceDeviceId,
    conversationId: conversationId ?? this.conversationId,
    createdAt: createdAt ?? this.createdAt,
    revision: revision ?? this.revision,
  );
}

/// Builds upload DTOs without reflecting over or serializing source objects.
class PrivateSyncExporter {
  const PrivateSyncExporter._();

  static SyncUploadRecord transcript(
    ExportEnvelope envelope,
    TranscriptPayload source,
  ) {
    final payload = TranscriptPayload(
      messageId: source.messageId,
      parentMessageId: source.parentMessageId,
      kind: source.kind,
      text: source.text,
      providerMetadataRecordId: source.providerMetadataRecordId,
      requestPurpose: source.requestPurpose,
      displayTitle: source.displayTitle,
    );
    return _record(envelope, payload);
  }

  static SyncUploadRecord usage(ExportEnvelope envelope, UsagePayload source) {
    final payload = UsagePayload(
      logicalRequestId: source.logicalRequestId,
      attemptId: source.attemptId,
      requestedModel: source.requestedModel,
      reportedModel: source.reportedModel,
      outcome: source.outcome,
      inputTokens: source.inputTokens,
      outputTokens: source.outputTokens,
      totalTokens: source.totalTokens,
      usageProvenance: source.usageProvenance,
      startedAt: source.startedAt,
      completedAt: source.completedAt,
      elapsedMilliseconds: source.elapsedMilliseconds,
    );
    return _record(envelope, payload);
  }

  static SyncUploadRecord activity(
    ExportEnvelope envelope,
    ActivityPayload source,
  ) {
    final payload = ActivityPayload(
      logicalRequestId: source.logicalRequestId,
      attemptId: source.attemptId,
      kind: source.kind,
      status: source.status,
      updatedAt: source.updatedAt,
      title: source.title,
      detail: source.detail,
      usageRecordId: source.usageRecordId,
    );
    return _record(envelope, payload);
  }

  static SyncUploadRecord providerMetadata(
    ExportEnvelope envelope,
    ProviderMetadataPayload source,
  ) {
    final payload = ProviderMetadataPayload(
      providerId: source.providerId,
      modelId: source.modelId,
      endpoint: source.endpoint,
      requestPurpose: source.requestPurpose,
      displayName: source.displayName,
      supportsStreaming: source.supportsStreaming,
    );
    return _record(envelope, payload);
  }

  static SyncUploadRecord _record(
    ExportEnvelope envelope,
    SyncPayload payload,
  ) => SyncUploadRecord(
    recordId: envelope.recordId,
    sourceDeviceId: envelope.sourceDeviceId,
    conversationId: envelope.conversationId,
    createdAt: envelope.createdAt,
    revision: envelope.revision,
    payload: payload,
  );
}
