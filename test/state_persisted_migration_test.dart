// Persisted `ovid_sessions` JSON migration (P8 Task 18).
//
// Sessions written before the agent-core satellite strip carry fields whose
// services no longer exist (grants, compaction, plan-mode transitions, the
// local tool roster). They must load without throwing, and the next write must
// drop them. `planMode` itself is UI state and SURVIVES.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';

/// A pre-strip v1 row: every removed key is present with a realistic value.
Map<String, dynamic> _legacyFixture() => {
  'id': 'legacy-session',
  'title': 'Legacy chat',
  'model': 'claude-sonnet-4-5',
  'providerId': 'anthropic',
  'sandboxId': 'legacy-session',
  'mode': 'auto',
  'presetId': 'standard',
  'workspaceFolder': '/work/legacy',
  'workspaceFolderPinned': true,
  // ── removed by this task ──────────────────────────────────────────────
  'grants': [
    {
      'kind': 'path',
      'value': '/work',
      'scope': 'session',
      'decision': 'allow',
    },
  ],
  'compactedSummary': 'older context',
  'compactionState': {'actions': <Object?>[], 'version': 1},
  'compactedAtCount': 42,
  'planModePending': true,
  'planPreMode': 'safe',
  'agentAllowedTools': ['file_read', 'run_shell'],
  // ── survives: plan mode is UI state ───────────────────────────────────
  'planMode': true,
  'messages': [
    {
      'role': 'user',
      'kind': 'text',
      'content': 'hello',
      'time': '2026-10-01T10:00:00.000Z',
    },
  ],
  'todos': [
    {'id': 't1', 'text': 'ship it', 'done': 'false'},
  ],
  'createdAt': '2026-10-01T09:59:00.000Z',
  'analytics': <String, dynamic>{},
  // Unknown keys from future/older builds are ignored, never fatal.
  'futureField': {'nested': true},
};

void main() {
  test('a pre-strip persisted session loads without throwing', () {
    final session = ChatSession.fromJson(_legacyFixture());

    expect(session.id, 'legacy-session');
    expect(session.title, 'Legacy chat');
    expect(session.messages, hasLength(1));
    expect(session.messages.single.content, 'hello');
    // Plan mode is UI state and must survive the migration.
    expect(session.planMode, isTrue);
    // A queued transition is UI state for the composer Plan chip.
    expect(session.planModePending, isTrue);
    expect(session.workspaceFolderPinned, isTrue);
  });

  test('the next write drops every removed field and bumps the schema', () {
    final session = ChatSession.fromJson(_legacyFixture());
    final json = session.toJson();

    expect(json['schemaVersion'], ChatSession.schemaVersion);
    expect(ChatSession.schemaVersion, greaterThan(1));

    for (final dead in const [
      'grants',
      'compactedSummary',
      'compactionState',
      'compactedAtCount',
      'planPreMode',
      'agentAllowedTools',
      'futureField',
    ]) {
      expect(json.containsKey(dead), isFalse, reason: 'dropped: $dead');
    }

    // Surviving fields are still written.
    expect(json['planMode'], isTrue);
    expect(json['planModePending'], isTrue);
    expect(json['id'], 'legacy-session');
    expect(json['messages'], isA<List<dynamic>>());
  });

  test('a v2 row round-trips without losing surviving state', () {
    final first = ChatSession.fromJson(_legacyFixture());
    final restored = ChatSession.fromJson(
      jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>,
    );

    expect(restored.id, first.id);
    expect(restored.planMode, isTrue);
    expect(restored.messages.single.content, 'hello');
    expect(restored.toJson()['schemaVersion'], ChatSession.schemaVersion);
  });
}
