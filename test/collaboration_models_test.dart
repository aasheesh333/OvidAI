import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/collaboration/models.dart';

/// Wave 1 collaboration client models: strict closed wire codecs.
///
/// Spec: docs/superpowers/specs/2026-10-09-live-collaboration-design.md
/// ("Event log and cursors", "Private payload policy").

Map<String, Object?> wire({
  String kind = 'message',
  Map<String, Object?>? payload,
  int sequence = 1,
  String eventId = 'evt-1',
  String sender = 'p-owner',
  String sessionId = 'sess-1',
  String createdAt = '2026-10-09T12:00:00Z',
}) => <String, Object?>{
  'schemaVersion': 1,
  'eventId': eventId,
  'sessionId': sessionId,
  'eventSequence': sequence,
  'senderParticipantId': sender,
  'kind': kind,
  'createdAt': createdAt,
  'payload': payload ?? <String, Object?>{'text': 'hello'},
};

Map<String, Object?> modelPayload([Map<String, Object?> overrides = const {}]) =>
    <String, Object?>{
      'providerId': 'openai',
      'requestedModel': 'gpt-5',
      'reportedModel': null,
      'displayName': 'GPT-5',
      'streaming': true,
      'status': 'running',
      ...overrides,
    };

Map<String, Object?> usagePayload([Map<String, Object?> overrides = const {}]) =>
    <String, Object?>{
      'requestId': 'req-1',
      'attemptId': 'att-1',
      'provenance': 'reported',
      'inputTokens': 10,
      'outputTokens': 20,
      ...overrides,
    };

CollaborationWireReason reasonOf(Map<String, Object?> json) {
  try {
    CollaborationEvent.fromWire(json);
  } on CollaborationWireException catch (e) {
    return e.reason;
  }
  fail('expected CollaborationWireException');
}

void main() {
  test('message event round-trips through fromWire/toWire', () {
    final json = wire();
    final event = CollaborationEvent.fromWire(json);
    expect(event.sequence, 1);
    expect(event.clientEventId, 'evt-1');
    expect(event.author, 'p-owner');
    expect(event.type, CollaborationEventType.message);
    expect(event.payload, isA<MessagePayload>());
    expect(event.toWire(), json);
  });

  test('every v1 kind parses and round-trips', () {
    final cases = <Map<String, Object?>>[
      wire(kind: 'modelStatus', payload: modelPayload()),
      wire(kind: 'usage', payload: usagePayload()),
      wire(kind: 'presence', payload: {'state': 'online'}),
      wire(
        kind: 'membership',
        payload: {'action': 'joined', 'participantId': 'p-2', 'role': 'participant'},
      ),
      wire(
        kind: 'membership',
        payload: {'action': 'revoked', 'participantId': 'p-2', 'role': null},
      ),
      wire(kind: 'system', payload: {'code': 'sessionClosed'}),
    ];
    for (final json in cases) {
      expect(CollaborationEvent.fromWire(json).toWire(), json, reason: '${json['kind']}');
    }
  });

  test('rejects unknown and missing envelope fields', () {
    expect(reasonOf({...wire(), 'extra': 1}), CollaborationWireReason.unknownField);
    expect(reasonOf(Map.of(wire())..remove('createdAt')), CollaborationWireReason.missingField);
  });

  test('rejects wrong envelope types and bounds', () {
    expect(reasonOf({...wire(), 'schemaVersion': 2}), CollaborationWireReason.invalidValue);
    expect(reasonOf({...wire(), 'schemaVersion': '1'}), CollaborationWireReason.wrongType);
    expect(reasonOf(wire(sequence: 0)), CollaborationWireReason.invalidValue);
    expect(reasonOf({...wire(), 'eventSequence': 1.5}), CollaborationWireReason.wrongType);
    expect(reasonOf(wire(createdAt: '2026-10-09T12:00:00+02:00')),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(createdAt: 'yesterday')), CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(eventId: '')), CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(eventId: 'has space')), CollaborationWireReason.invalidValue);
    expect(reasonOf({...wire(), 'payload': 'text'}), CollaborationWireReason.wrongType);
  });

  test('rejects unknown kinds', () {
    expect(reasonOf(wire(kind: 'reaction')), CollaborationWireReason.unknownKind);
    expect(reasonOf(wire(kind: 'model_changed')), CollaborationWireReason.unknownKind);
  });

  test('rejects execution / tool / shell / browser / MCP / plugin request kinds', () {
    for (final kind in [
      'toolCall',
      'tool_request',
      'execute',
      'shellCommand',
      'browserAction',
      'mcpCall',
      'pluginInvoke',
      'runAgent',
      'process',
      'buildRequest',
      'cloneRepo',
      'modelRequest',
    ]) {
      expect(reasonOf(wire(kind: kind)), CollaborationWireReason.executableKind, reason: kind);
    }
  });

  test('rejects unknown payload fields and nested values', () {
    expect(reasonOf(wire(payload: {'text': 'x', 'mood': 'happy'})),
        CollaborationWireReason.unknownField);
    expect(reasonOf(wire(payload: {'text': {'nested': 'x'}})), CollaborationWireReason.wrongType);
    expect(reasonOf(wire(payload: {})), CollaborationWireReason.missingField);
  });

  test('rejects credential-shaped payload keys', () {
    for (final key in [
      'apiKey',
      'api_key',
      'authorization',
      'cookie',
      'refreshToken',
      'accessToken',
      'password',
      'clientSecret',
      'grant',
      'credentials',
    ]) {
      expect(reasonOf(wire(payload: {'text': 'x', key: 'v'})),
          CollaborationWireReason.credentialField, reason: key);
    }
    expect(reasonOf({...wire(), 'authorization': 'Bearer abc'}),
        CollaborationWireReason.credentialField);
  });

  test('rejects execution-shaped payload keys', () {
    for (final key in [
      'command',
      'toolName',
      'shell',
      'script',
      'mcpServer',
      'plugin',
      'browserUrl',
      'exec',
      'queue',
      'callback',
    ]) {
      expect(reasonOf(wire(payload: {'text': 'x', key: 'v'})),
          CollaborationWireReason.executableField, reason: key);
    }
  });

  test('rejects local path and attachment payload keys', () {
    for (final key in ['path', 'workspacePath', 'cwd', 'filePath', 'workspace']) {
      expect(reasonOf(wire(payload: {'text': 'x', key: 'v'})),
          CollaborationWireReason.localPath, reason: key);
    }
    for (final key in ['attachment', 'attachments', 'bytes', 'base64', 'imageData']) {
      expect(reasonOf(wire(payload: {'text': 'x', key: 'v'})),
          CollaborationWireReason.attachment, reason: key);
    }
  });

  test('rejects credential-shaped values in model metadata', () {
    for (final value in [
      'sk-abcdefghijklmnop1234',
      'Bearer abc.def',
      'https://user:pw@api.example.com',
      'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig',
      'AKIAABCDEFGHIJKLMNOP',
      'https://api.example.com/v1?api_key=abc',
      '-----BEGIN PRIVATE KEY-----',
    ]) {
      expect(reasonOf(wire(kind: 'modelStatus', payload: modelPayload({'displayName': value}))),
          CollaborationWireReason.credentialValue, reason: value);
    }
    expect(reasonOf(wire(kind: 'modelStatus', payload: modelPayload({'providerId': 'sk-abcdefghijklmnop1234'}))),
        CollaborationWireReason.credentialValue);
  });

  test('rejects local path values in model metadata', () {
    for (final value in ['/root/models/x.gguf', '~/models', r'C:\models\x', 'file:///x', r'\\host\share']) {
      expect(reasonOf(wire(kind: 'modelStatus', payload: modelPayload({'requestedModel': value}))),
          CollaborationWireReason.localPath, reason: value);
    }
  });

  test('rejects attachment bytes in metadata values', () {
    expect(
      reasonOf(wire(kind: 'modelStatus',
          payload: modelPayload({'displayName': 'data:image/png;base64,iVBORw0KGgo='}))),
      CollaborationWireReason.attachment,
    );
  });

  test('accepts provider-namespaced model ids with slashes', () {
    final event = CollaborationEvent.fromWire(wire(
      kind: 'modelStatus',
      payload: modelPayload({'requestedModel': 'meta-llama/Llama-3.1-70B'}),
    ));
    expect((event.payload as ModelStatusPayload).requestedModel, 'meta-llama/Llama-3.1-70B');
  });

  test('private message text is preserved verbatim, including secret-like text', () {
    const text = 'my key is sk-abcdefghijklmnop1234 and it lives in /root/.env\n🙂';
    final event = CollaborationEvent.fromWire(wire(payload: {'text': text}));
    expect((event.payload as MessagePayload).text, text);
    expect(event.toWire()['payload'], {'text': text});
  });

  test('rejects invalid enum values in payloads', () {
    expect(reasonOf(wire(kind: 'modelStatus', payload: modelPayload({'status': 'hacking'}))),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(kind: 'presence', payload: {'state': 'busy'})),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(kind: 'membership',
            payload: {'action': 'promoted', 'participantId': 'p-2', 'role': null})),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(kind: 'membership',
            payload: {'action': 'joined', 'participantId': 'p-2', 'role': null})),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(kind: 'system', payload: {'code': 'runScript'})),
        CollaborationWireReason.invalidValue);
  });

  test('usage keeps zero, null, and unknown distinguishable', () {
    final zero = CollaborationEvent.fromWire(
        wire(kind: 'usage', payload: usagePayload({'inputTokens': 0, 'outputTokens': 0})));
    final nul = CollaborationEvent.fromWire(
        wire(kind: 'usage', payload: usagePayload({'inputTokens': null, 'outputTokens': null})));
    final unknown = CollaborationEvent.fromWire(wire(
        kind: 'usage',
        payload: usagePayload({'provenance': 'unknown', 'inputTokens': null, 'outputTokens': null})));
    expect((zero.payload as UsagePayload).usage.inputTokens, 0);
    expect((nul.payload as UsagePayload).usage.inputTokens, isNull);
    expect((unknown.payload as UsagePayload).usage.provenance, UsageProvenance.unknown);
    // Unknown usage is never represented as a number (spec: never zero).
    expect(reasonOf(wire(kind: 'usage', payload: usagePayload({'provenance': 'unknown', 'inputTokens': 0}))),
        CollaborationWireReason.invalidValue);
    expect(reasonOf(wire(kind: 'usage', payload: usagePayload({'inputTokens': -1}))),
        CollaborationWireReason.invalidValue);
  });

  test('rejects events over the 256 KiB canonical limit', () {
    final big = 'a' * (256 * 1024);
    expect(reasonOf(wire(payload: {'text': big})), CollaborationWireReason.tooLarge);
  });

  test('canonical event size counts UTF-8 bytes', () {
    final text = '€' * (maxEventCanonicalBytes ~/ 3 + 10);
    expect(reasonOf(wire(payload: {'text': text})), CollaborationWireReason.tooLarge);
  });

  test('counts Unicode label length in code points like Python', () {
    final accepted = CollaborationEvent.fromWire(wire(
      kind: 'modelStatus',
      payload: modelPayload({'displayName': '🙂' * 256}),
    ));
    expect((accepted.payload as ModelStatusPayload).displayName.runes.length, 256);

    expect(
      reasonOf(wire(
        kind: 'modelStatus',
        payload: modelPayload({'displayName': '🙂' * 257}),
      )),
      CollaborationWireReason.invalidValue,
    );
  });

  test('rejects lone surrogates as invalid Unicode', () {
    expect(reasonOf(wire(payload: {'text': '\uD800'})), CollaborationWireReason.invalidValue);
    expect(
      reasonOf(wire(kind: 'modelStatus', payload: modelPayload({'displayName': '\uD800'}))),
      CollaborationWireReason.invalidValue,
    );
  });

  test('wire exceptions never echo payload contents', () {
    const sentinel = 'SENTINEL-sk-abcdefghijklmnop1234';
    try {
      CollaborationEvent.fromWire(
          wire(kind: 'modelStatus', payload: modelPayload({'displayName': sentinel})));
      fail('expected rejection');
    } on CollaborationWireException catch (e) {
      expect(e.toString(), isNot(contains('SENTINEL')));
      expect(e.toString(), isNot(contains('sk-')));
    }
  });

  test('Member round-trips and rejects unknown fields', () {
    final json = {'participantId': 'p-1', 'role': 'owner', 'status': 'active'};
    final member = Member.fromWire(json);
    expect(member.role, MemberRole.owner);
    expect(member.status, MemberStatus.active);
    expect(member.toWire(), json);
    expect(() => Member.fromWire({...json, 'apiKey': 'x'}), throwsA(isA<CollaborationWireException>()));
    expect(() => Member.fromWire({...json, 'role': 'admin'}), throwsA(isA<CollaborationWireException>()));
  });

  test('CollaborationSession round-trips and rejects unknown fields', () {
    final json = {
      'schemaVersion': 1,
      'sessionId': 'sess-1',
      'ownerParticipantId': 'p-owner',
      'lifecycle': 'active',
    };
    final session = CollaborationSession.fromWire(json);
    expect(session.lifecycle, SessionLifecycle.active);
    expect(session.toWire(), json);
    expect(() => CollaborationSession.fromWire({...json, 'sessionToken': 'x'}),
        throwsA(isA<CollaborationWireException>()));
  });

  test('ParticipantModelState holds labels and usage reference only', () {
    final json = {
      'participantId': 'p-1',
      'providerId': 'anthropic',
      'requestedModel': 'claude-x',
      'reportedModel': 'claude-x-2026',
      'displayName': 'Claude',
      'streaming': false,
      'status': 'completed',
      'usage': usagePayload(),
    };
    final state = ParticipantModelState.fromWire(json);
    expect(state.status, ModelExecutionStatus.completed);
    expect(state.usage!.attemptId, 'att-1');
    expect(state.toWire(), json);
    expect(() => ParticipantModelState.fromWire({...json, 'apiKey': 'x'}),
        throwsA(isA<CollaborationWireException>()));
    expect(() => ParticipantModelState.fromWire({...json, 'endpoint': 'https://u:p@h'}),
        throwsA(isA<CollaborationWireException>()));
    expect(() => ParticipantModelState.fromWire({...json, 'displayName': 'Bearer abcdef'}),
        throwsA(isA<CollaborationWireException>()));
  });

  test('parsed events are immutable', () {
    final event = CollaborationEvent.fromWire(wire());
    final out = event.toWire();
    out['kind'] = 'tampered';
    expect(event.type, CollaborationEventType.message);
  });
}
