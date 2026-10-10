import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/protocol.dart';

Map<String, Object?> replayWire() => {
  'schemaVersion': 1,
  'recordId': 'rec-1',
  'sourceDeviceId': 'dev-1',
  'recordType': 'activity',
  'conversationId': null,
  'createdAt': '2026-10-08T12:00:00Z',
  'revision': 1,
  'payload': {
    'logicalRequestId': null,
    'attemptId': null,
    'kind': 'tool',
    'status': 'started',
    'updatedAt': '2026-10-08T12:00:00Z',
    'title': '',
    'detail': '',
    'usageRecordId': null,
  },
  'accountId': 'acct-1',
  'changeSequence': 42,
};

void main() {
  test('batch request round-trips the server request envelope', () {
    final request = SyncBatchRequest.fromWire({
      'schemaVersion': 1,
      'idempotencyKey': 'batch-1',
      'records': [
        replayWire()
          ..remove('accountId')
          ..remove('changeSequence'),
      ],
    });

    expect(request.schemaVersion, 1);
    expect(request.idempotencyKey, 'batch-1');
    expect(request.records.single, isA<SyncUploadRecord>());
    expect(request.toWire()['idempotencyKey'], 'batch-1');
  });

  test(
    'batch result parses typed outcomes and preserves exact wire fields',
    () {
      final raw = {
        'schemaVersion': 1,
        'results': [
          {
            'recordId': 'rec-1',
            'status': 'accepted',
            'revision': 2,
            'changeSequence': 43,
            'error': null,
          },
          {
            'recordId': 'rec-2',
            'status': 'retryable',
            'revision': null,
            'changeSequence': null,
            'error': {
              'schemaVersion': 1,
              'code': 'temporarily_unavailable',
              'message': 'The sync service is temporarily unavailable.',
              'retryAfterSeconds': 30,
            },
          },
        ],
      };

      final result = SyncBatchResult.fromWire(raw);
      expect(result.results[0].status, SyncRecordOutcomeStatus.accepted);
      expect(result.results[0].revision, 2);
      expect(
        result.results[1].error?.code,
        SyncErrorCode.temporarilyUnavailable,
      );
      expect(result.toWire(), raw);
    },
  );

  test('change, state, and enrollment pages parse typed replay records', () {
    final replay = replayWire();
    final change = SyncChangePage.fromWire({
      'schemaVersion': 1,
      'nextCursor': 'cursor-2',
      'hasMore': true,
      'records': [replay],
    });
    final state = SyncStatePage.fromWire({
      'schemaVersion': 1,
      'accountId': 'acct-1',
      'currentCursor': 'cursor-2',
      'records': [replay],
      'enrollmentStatus': 'active',
      'retentionMarkers': ['marker-1'],
    });
    final enrollment = SyncEnrollment.fromWire({
      'schemaVersion': 1,
      'deviceId': 'dev-2',
      'deviceName': 'Laptop',
      'createdAt': '2026-10-08T12:00:00Z',
      'status': 'active',
    });

    expect(change.records.single, isA<SyncReplayRecord>());
    expect(state.records.single.changeSequence, 42);
    expect(enrollment.status, SyncEnrollmentStatus.active);
    expect(enrollment.toWire()['deviceName'], 'Laptop');
  });

  test('failure validates fixed server message and retry hint', () {
    final failure = SyncFailure.fromWire({
      'schemaVersion': 1,
      'code': 'rate_limited',
      'message': 'Too many requests. Retry later.',
      'retryAfterSeconds': 60,
    });

    expect(failure.code, SyncErrorCode.rateLimited);
    expect(failure.message, 'Too many requests. Retry later.');
    expect(failure.toWire()['retryAfterSeconds'], 60);
  });

  test('reset_required parses as a fixed failure', () {
    final failure = SyncFailure.fromWire({
      'schemaVersion': 1,
      'code': 'reset_required',
      'message': 'The sync state must be reset.',
      'retryAfterSeconds': null,
    });
    expect(failure.code, SyncErrorCode.resetRequired);
  });

  test('protocol envelopes reject schema, fields, and status combinations', () {
    expect(
      () => SyncChangePage.fromWire({
        'schemaVersion': 2,
        'nextCursor': '',
        'hasMore': false,
        'records': [],
      }),
      throwsA(isA<SyncDtoException>()),
    );
    expect(
      () => SyncBatchResult.fromWire({
        'schemaVersion': 1,
        'results': [
          {
            'recordId': 'r',
            'status': 'accepted',
            'revision': null,
            'changeSequence': 1,
            'error': null,
          },
        ],
      }),
      throwsA(isA<SyncDtoException>()),
    );
    expect(
      () => SyncFailure.fromWire({
        'schemaVersion': 1,
        'code': 'rate_limited',
        'message': 'leaked',
        'retryAfterSeconds': null,
      }),
      throwsA(isA<SyncDtoException>()),
    );
  });
}
