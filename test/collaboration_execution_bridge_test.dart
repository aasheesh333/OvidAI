import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/collaboration/execution_bridge.dart';
import 'package:ovid_ai/core/collaboration/models.dart';

void main() {
  test('publishes typed message, status, and usage observations locally', () {
    final bridge = LocalObservationalPublicationAdapter();
    const message = MessagePayload('hello');
    const status = ModelStatusPayload(
      providerId: 'openai',
      requestedModel: 'gpt-5',
      reportedModel: 'gpt-5-2026',
      displayName: 'GPT-5',
      streaming: true,
      status: ModelExecutionStatus.running,
    );
    const usage = UsagePayload(
      UsageSummary(
        requestId: 'req-1',
        attemptId: 'attempt-1',
        provenance: UsageProvenance.reported,
        inputTokens: 3,
        outputTokens: 5,
      ),
    );

    bridge.publishMessage(message);
    bridge.publishStatus(status);
    bridge.publishUsage(usage);

    expect(bridge.publications, [
      isA<LocalMessagePublication>()
          .having((publication) => publication.payload, 'payload', same(message)),
      isA<LocalStatusPublication>()
          .having((publication) => publication.payload, 'payload', same(status)),
      isA<LocalUsagePublication>()
          .having((publication) => publication.payload, 'payload', same(usage)),
    ]);
  });

  test('exposes an immutable typed publication view', () {
    final bridge = LocalObservationalPublicationAdapter();
    bridge.publishMessage(const MessagePayload('hello'));

    final publications = bridge.publications;
    expect(() => publications.add(const LocalMessagePublication(MessagePayload('x'))),
        throwsUnsupportedError);

    bridge.publishUsage(
      const UsagePayload(
        UsageSummary(
          requestId: 'req-2',
          attemptId: 'attempt-2',
          provenance: UsageProvenance.unknown,
          inputTokens: null,
          outputTokens: null,
        ),
      ),
    );
    expect(publications, hasLength(1));
    expect(bridge.publications, hasLength(2));
  });
}
