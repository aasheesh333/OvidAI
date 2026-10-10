import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/canonical.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';

const secretText = 'my key is sk-live-THIS_LOOKS_SECRET and '
    'Authorization: Bearer abc.def.ghi \u{1F600}\n\tpassword=hunter2';

Map<String, Object?> transcriptPayload() => {
      'messageId': 'msg-1',
      'parentMessageId': null,
      'kind': 'user',
      'text': secretText,
      'providerMetadataRecordId': null,
      'requestPurpose': null,
      'displayTitle': null,
    };

Map<String, Object?> providerPayload() => {
      'providerId': 'openai',
      'modelId': 'gpt-x',
      'endpoint': 'https://api.example.com/v1',
      'requestPurpose': 'chat',
      'displayName': 'Example',
      'supportsStreaming': true,
    };

Map<String, Object?> usagePayload() => {
      'logicalRequestId': 'req-1',
      'attemptId': 'att-1',
      'requestedModel': 'gpt-x',
      'reportedModel': null,
      'outcome': 'succeeded',
      'inputTokens': 0,
      'outputTokens': null,
      'totalTokens': 4294967295,
      'usageProvenance': 'providerReported',
      'startedAt': '2026-10-08T12:00:00Z',
      'completedAt': '2026-10-08T12:00:01.123456789Z',
      'elapsedMilliseconds': 604800000,
    };

Map<String, Object?> activityPayload() => {
      'logicalRequestId': 'req-1',
      'attemptId': 'att-1',
      'kind': 'tool',
      'status': 'started',
      'updatedAt': '2026-10-08T12:00:00Z',
      'title': '',
      'detail': '',
      'usageRecordId': 'att-1',
    };

Map<String, Object?> tombstonePayload() => {
      'targetRecordId': 'rec-old',
      'deletionRevision': 1,
      'deletedAt': '2026-10-08T12:00:00Z',
      'reason': 'user',
    };

Map<String, Object?> upload(String type, Map<String, Object?> payload,
        {String recordId = 'rec-1'}) =>
    {
      'schemaVersion': 1,
      'recordId': recordId,
      'sourceDeviceId': 'dev-1',
      'recordType': type,
      'conversationId': 'conv-1',
      'createdAt': '2026-10-08T12:00:00Z',
      'revision': 1,
      'payload': payload,
    };

Map<String, Object?> replay(Map<String, Object?> up) =>
    {...up, 'accountId': 'acct-1', 'changeSequence': 42};

final samples = <String, Map<String, Object?>>{
  'transcript': upload('transcript', transcriptPayload()),
  'providerMetadata': upload('providerMetadata', providerPayload()),
  'usage': upload('usage', usagePayload(), recordId: 'att-1'),
  'activity': upload('activity', activityPayload()),
  'tombstone': upload('tombstone', tombstonePayload()),
};

Matcher throwsCode(String code) => throwsA(
    isA<SyncDtoException>().having((e) => e.code, 'code', code));

Map<String, Object?> withPayload(
    String type, Map<String, Object?> Function(Map<String, Object?>) edit) {
  final base = samples[type]!;
  return {
    ...base,
    'payload': edit(Map<String, Object?>.of(base['payload'] as Map<String, Object?>)),
  };
}

void main() {
  group('round trips', () {
    for (final entry in samples.entries) {
      test('${entry.key} upload and replay round-trip exactly', () {
        final up = SyncUploadRecord.fromWire(entry.value);
        expect(up.toWire(), entry.value);
        expect(up.recordType.wire, entry.key);
        final rep = SyncReplayRecord.fromWire(replay(entry.value));
        expect(rep.toWire(), replay(entry.value));
        expect(rep.accountId, 'acct-1');
        expect(rep.changeSequence, 42);
        expect(canonicalJsonString(rep.toWire()),
            canonicalJsonString(replay(entry.value)));
      });
    }

    test('canonical bytes parse back to an equal record', () {
      final up = SyncUploadRecord.fromWire(samples['usage']);
      final again = SyncUploadRecord.fromCanonicalBytes(up.canonicalBytes());
      expect(again, up);
      expect(again.hashCode, up.hashCode);
    });

    test('transcript text containing secrets is preserved verbatim', () {
      final up = SyncUploadRecord.fromWire(samples['transcript']);
      final payload = up.payload as TranscriptPayload;
      expect(payload.text, secretText);
      expect(canonicalJsonString(up.toWire()), contains('sk-live-THIS_LOOKS_SECRET'));
      expect(canonicalJsonString(up.toWire()), contains('password=hunter2'));
    });

    test('maximum transcript text (262144 non-BMP scalars) is accepted', () {
      final big = '\u{1F600}' * 262144;
      final rec = withPayload('transcript', (p) => p..['text'] = big);
      expect((SyncUploadRecord.fromWire(rec).payload as TranscriptPayload).text, big);
      expect(() => SyncUploadRecord.fromWire(
              withPayload('transcript', (p) => p..['text'] = '${big}a')),
          throwsCode('invalid_record'));
    });

    test('toWire maps are unmodifiable', () {
      final wire = SyncUploadRecord.fromWire(samples['activity']).toWire();
      expect(() => wire['x'] = 1, throwsUnsupportedError);
    });
  });

  group('envelope', () {
    test('schemaVersion other than integer 1', () {
      for (final v in [2, 0, -1]) {
        expect(() => SyncUploadRecord.fromWire({...samples['activity']!, 'schemaVersion': v}),
            throwsCode('schema_version_unsupported'));
      }
      for (final v in [true, 1.0, '1', null]) {
        expect(() => SyncUploadRecord.fromWire({...samples['activity']!, 'schemaVersion': v}),
            throwsCode('invalid_record'), reason: '$v');
      }
    });

    test('unknown, missing and server-derived fields', () {
      final base = samples['activity']!;
      expect(() => SyncUploadRecord.fromWire({...base, 'apiKey': 'x'}),
          throwsCode('invalid_record'));
      expect(() => SyncUploadRecord.fromWire({...base, 'accountId': 'acct'}),
          throwsCode('invalid_record'));
      expect(() => SyncUploadRecord.fromWire({...base, 'changeSequence': 1}),
          throwsCode('invalid_record'));
      for (final key in base.keys) {
        expect(() => SyncUploadRecord.fromWire(Map.of(base)..remove(key)),
            throwsCode('invalid_record'),
            reason: key);
      }
      expect(() => SyncReplayRecord.fromWire(base), throwsCode('invalid_record'));
      expect(() => SyncReplayRecord.fromWire({...replay(base), 'runtimeQueue': []}),
          throwsCode('invalid_record'));
      expect(() => SyncUploadRecord.fromWire('nope'), throwsCode('invalid_record'));
      expect(() => SyncUploadRecord.fromWire([base]), throwsCode('invalid_record'));
    });

    test('rejection is a FormatException with a fixed message', () {
      try {
        SyncUploadRecord.fromWire({...samples['transcript']!, 'leak': secretText});
        fail('expected rejection');
      } on FormatException catch (e) {
        expect(e.message, isNot(contains('sk-live')));
        expect(e.toString(), isNot(contains('sk-live')));
        expect(e.source, isNull);
      }
    });

    test('ID rules', () {
      final base = samples['activity']!;
      final ok = ['a', 'x' * 128, 'A-z_0.9:~!'];
      for (final id in ok) {
        expect(SyncUploadRecord.fromWire({...base, 'recordId': id}).recordId, id);
      }
      final bad = <Object?>['', 'x' * 129, 'caf\u00e9', 'a b', 'a\nb', 'a\u0000', 1, null];
      for (final id in bad) {
        expect(() => SyncUploadRecord.fromWire({...base, 'recordId': id}),
            throwsCode('invalid_record'), reason: '$id');
        expect(() => SyncUploadRecord.fromWire({...base, 'sourceDeviceId': id}),
            throwsCode('invalid_record'), reason: '$id');
      }
      expect(SyncUploadRecord.fromWire({...base, 'conversationId': null}).conversationId,
          isNull);
      expect(() => SyncReplayRecord.fromWire({...replay(base), 'accountId': ''}),
          throwsCode('invalid_record'));
    });

    test('timestamp rules', () {
      final base = samples['activity']!;
      final ok = [
        '2026-10-08T12:00:00Z',
        '2024-02-29T23:59:59.999Z',
        '2026-10-08T12:00:00.123456789Z',
      ];
      for (final t in ok) {
        expect(SyncUploadRecord.fromWire({...base, 'createdAt': t}).createdAt, t);
      }
      final bad = <Object?>[
        '2026-10-08T12:00:00+00:00',
        '2026-10-08T12:00:00',
        '2026-10-08t12:00:00z',
        '2026-10-08 12:00:00Z',
        '2026-10-08T12:00:00.Z',
        '2026-10-08T12:00:00.1234567890123Z',
        '2025-02-29T00:00:00Z',
        '2026-13-01T00:00:00Z',
        '2026-10-32T00:00:00Z',
        '2026-10-08T24:00:00Z',
        '2026-10-08T12:60:00Z',
        '2026-10-08T12:00:60Z',
        '26-10-08T12:00:00Z',
        '',
        1,
        null,
      ];
      for (final t in bad) {
        expect(() => SyncUploadRecord.fromWire({...base, 'createdAt': t}),
            throwsCode('invalid_record'), reason: '$t');
      }
    });

    test('revision and changeSequence bounds and int-not-bool', () {
      final base = samples['activity']!;
      expect(SyncUploadRecord.fromWire({...base, 'revision': 2147483647}).revision,
          2147483647);
      for (final v in <Object?>[0, -1, 2147483648, true, 1.0, '1', null]) {
        expect(() => SyncUploadRecord.fromWire({...base, 'revision': v}),
            throwsCode('invalid_record'), reason: '$v');
      }
      final rep = replay(base);
      expect(SyncReplayRecord.fromWire({...rep, 'changeSequence': 9007199254740991})
          .changeSequence, 9007199254740991);
      for (final v in <Object?>[0, -1, 9007199254740992, false, 42.0, null]) {
        expect(() => SyncReplayRecord.fromWire({...rep, 'changeSequence': v}),
            throwsCode('invalid_record'), reason: '$v');
      }
    });

    test('recordType must match payload shape', () {
      expect(() => SyncUploadRecord.fromWire(
              {...samples['activity']!, 'recordType': 'usage'}),
          throwsCode('invalid_record'));
      expect(() => SyncUploadRecord.fromWire(
              {...samples['activity']!, 'recordType': 'session'}),
          throwsCode('invalid_record'));
    });

    test('usage recordId must equal attemptId', () {
      expect(() => SyncUploadRecord.fromWire({...samples['usage']!, 'recordId': 'other'}),
          throwsCode('invalid_record'));
    });

    test('tombstone recordId must not equal targetRecordId', () {
      expect(
        () => SyncUploadRecord.fromWire(
          {...samples['tombstone']!, 'recordId': 'rec-old'},
        ),
        throwsCode('invalid_record'),
      );
    });
  });

  group('payloads', () {
    test('provider and model text round trips Unicode scalar bounds', () {
      final payload = {...providerPayload(), 'providerId': '😀' * 64,
        'modelId': 'model 😀 name'};
      expect(ProviderMetadataPayload.fromWire(payload).toWire(), payload);
      expect(() => ProviderMetadataPayload.fromWire({...payload, 'providerId': '😀' * 65}),
          throwsCode('invalid_record'));
    });
    void accepts(String type, String field, Object? value) {
      final rec = withPayload(type, (p) => p..[field] = value);
      final parsed = SyncUploadRecord.fromWire(rec);
      expect((parsed.toWire()['payload'] as Map)[field], value,
          reason: '$type.$field=$value');
    }

    void rejects(String type, String field, Object? value) {
      expect(() => SyncUploadRecord.fromWire(withPayload(type, (p) => p..[field] = value)),
          throwsCode('invalid_record'),
          reason: '$type.$field=$value');
    }

    test('every payload field is required and closed', () {
      for (final type in samples.keys) {
        final payload = samples[type]!['payload'] as Map<String, Object?>;
        for (final key in payload.keys) {
          expect(() => SyncUploadRecord.fromWire(
                  withPayload(type, (p) => p..remove(key))),
              throwsCode('invalid_record'), reason: '$type missing $key');
        }
        for (final extra in ['apiKey', 'path', 'runtimeQueue', 'attachmentBytes', 'display']) {
          rejects(type, extra, 'x');
        }
        expect(() => SyncUploadRecord.fromWire({...samples[type]!, 'payload': 'x'}),
            throwsCode('invalid_record'));
        expect(() => SyncUploadRecord.fromWire({...samples[type]!, 'payload': null}),
            throwsCode('invalid_record'));
      }
    });

    test('transcript bounds', () {
      for (final k in ['user', 'assistant', 'system', 'tool']) {
        accepts('transcript', 'kind', k);
      }
      rejects('transcript', 'kind', 'developer');
      rejects('transcript', 'kind', 'User');
      accepts('transcript', 'messageId', 'm' * 128);
      rejects('transcript', 'messageId', 'm' * 129);
      rejects('transcript', 'messageId', null);
      accepts('transcript', 'parentMessageId', 'p');
      rejects('transcript', 'parentMessageId', '');
      accepts('transcript', 'text', '');
      rejects('transcript', 'text', null);
      rejects('transcript', 'text', 5);
      accepts('transcript', 'providerMetadataRecordId', 'pm-1');
      accepts('transcript', 'requestPurpose', '');
      accepts('transcript', 'requestPurpose', '\u00e9' * 128);
      rejects('transcript', 'requestPurpose', '\u00e9' * 129);
      accepts('transcript', 'displayTitle', '\u{1F600}' * 256);
      rejects('transcript', 'displayTitle', '\u{1F600}' * 257);
    });

    test('text containing lone surrogates is rejected', () {
      rejects('transcript', 'text', 'a\ud800');
      rejects('activity', 'title', '\udc00');
    });

    test('provider metadata bounds', () {
      accepts('providerMetadata', 'providerId', 'p' * 64);
      rejects('providerMetadata', 'providerId', 'p' * 65);
      rejects('providerMetadata', 'providerId', '');
      accepts('providerMetadata', 'providerId', 'provider with spaces');
      accepts('providerMetadata', 'modelId', 'model with spaces/é');
      accepts('providerMetadata', 'modelId', null);
      rejects('providerMetadata', 'modelId', '');
      accepts('providerMetadata', 'supportsStreaming', false);
      rejects('providerMetadata', 'supportsStreaming', 1);
      rejects('providerMetadata', 'supportsStreaming', null);
      accepts('providerMetadata', 'displayName', null);
      accepts('providerMetadata', 'requestPurpose', null);
      rejects('providerMetadata', 'endpoint', null);
    });

    test('usage model identifiers use bounded text semantics', () {
      accepts('usage', 'requestedModel', 'model with spaces/é');
      accepts('usage', 'reportedModel', 'model with spaces/é');
    });

    test('provider endpoint is validated and must already be canonical', () {
      for (final bad in [
        'http://api.example.com/v1',
        'https://user:pw@api.example.com/',
        'https://api.example.com/?api_key=x',
        'https://API.example.com/v1',
        'https://api.example.com:443/v1',
        'https://api.example.com',
      ]) {
        expect(
            () => SyncUploadRecord.fromWire(
                withPayload('providerMetadata', (p) => p..['endpoint'] = bad)),
            throwsCode('endpoint_rejected'),
            reason: bad);
      }
      rejects('providerMetadata', 'endpoint', 'https://${'a' * 2040}.com/');
      rejects('providerMetadata', 'endpoint', '');
      accepts('providerMetadata', 'endpoint', 'https://api.example.com/');
      try {
        SyncUploadRecord.fromWire(withPayload('providerMetadata',
            (p) => p..['endpoint'] = 'https://api.example.com/?token=SENTINEL'));
        fail('expected rejection');
      } on SyncDtoException catch (e) {
        expect(e.code, 'endpoint_rejected');
        expect(e.toString(), isNot(contains('SENTINEL')));
      }
    });

    test('usage bounds', () {
      for (final o in ['pending', 'succeeded', 'failed', 'cancelled', 'interrupted', 'unknown']) {
        accepts('usage', 'outcome', o);
      }
      rejects('usage', 'outcome', 'ok');
      for (final p in ['providerReported', 'locallyEstimated', 'derived', 'unknown', 'legacyUnspecified']) {
        accepts('usage', 'usageProvenance', p);
      }
      rejects('usage', 'usageProvenance', 'measured');
      accepts('usage', 'inputTokens', 2147483647);
      rejects('usage', 'inputTokens', 2147483648);
      rejects('usage', 'inputTokens', -1);
      rejects('usage', 'inputTokens', true);
      rejects('usage', 'inputTokens', 1.0);
      rejects('usage', 'inputTokens', 1.5);
      accepts('usage', 'outputTokens', 0);
      rejects('usage', 'outputTokens', 2147483648);
      accepts('usage', 'totalTokens', null);
      rejects('usage', 'totalTokens', 4294967296);
      accepts('usage', 'elapsedMilliseconds', 0);
      accepts('usage', 'elapsedMilliseconds', null);
      rejects('usage', 'elapsedMilliseconds', 604800001);
      accepts('usage', 'startedAt', null);
      rejects('usage', 'startedAt', '2026-10-08T12:00:00+01:00');
      accepts('usage', 'requestedModel', null);
      rejects('usage', 'requestedModel', '');
      rejects('usage', 'logicalRequestId', null);
      rejects('usage', 'attemptId', null);
    });

    test('usage explicit zero is distinct from null', () {
      final zero = SyncUploadRecord.fromWire(samples['usage']).payload as UsagePayload;
      expect(zero.inputTokens, 0);
      expect(zero.outputTokens, isNull);
    });

    test('activity bounds', () {
      for (final k in ['request', 'tool', 'mcp', 'plugin', 'browser', 'build', 'system']) {
        accepts('activity', 'kind', k);
      }
      rejects('activity', 'kind', 'shell');
      for (final s in ['queued', 'started', 'succeeded', 'failed', 'cancelled', 'interrupted', 'unknown']) {
        accepts('activity', 'status', s);
      }
      rejects('activity', 'status', 'running');
      accepts('activity', 'title', '\u{1F600}' * 256);
      rejects('activity', 'title', '\u{1F600}' * 257);
      accepts('activity', 'detail', 'd' * 2048);
      rejects('activity', 'detail', 'd' * 2049);
      rejects('activity', 'title', null);
      rejects('activity', 'updatedAt', null);
      accepts('activity', 'logicalRequestId', null);
      accepts('activity', 'attemptId', null);
      accepts('activity', 'usageRecordId', null);
      rejects('activity', 'usageRecordId', '');
    });

    test('tombstone bounds', () {
      for (final r in ['user', 'account', 'retention', 'conflict', 'admin']) {
        accepts('tombstone', 'reason', r);
      }
      rejects('tombstone', 'reason', 'other');
      accepts('tombstone', 'deletionRevision', 2147483647);
      rejects('tombstone', 'deletionRevision', 0);
      rejects('tombstone', 'deletionRevision', 2147483648);
      rejects('tombstone', 'deletionRevision', true);
      rejects('tombstone', 'targetRecordId', null);
      rejects('tombstone', 'deletedAt', 'yesterday');
    });

    test('typed construction validates the same rules', () {
      expect(
        () => ActivityPayload(
          logicalRequestId: null,
          attemptId: null,
          kind: ActivityKind.tool,
          status: ActivityStatus.started,
          updatedAt: 'bad',
          title: '',
          detail: '',
          usageRecordId: null,
        ),
        throwsCode('invalid_record'),
      );
      final ok = TombstonePayload(
        targetRecordId: 'rec-old',
        deletionRevision: 1,
        deletedAt: '2026-10-08T12:00:00Z',
        reason: TombstoneReason.user,
      );
      expect(ok.toWire(), tombstonePayload());
    });
  });
}
