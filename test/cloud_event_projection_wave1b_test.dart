// Wave 1b — the projection renders the agent's work: tool cards, artifact
// chips, todos/goal/plan, subagent activity cards, compaction rows, turn
// separation (CH-004, CH-005, CH-018, CH-028, CT-002), the mid-run resume
// (CH-002) and the rich history rebuild (CH-003, CH-006, CT-003).
// Payload shapes mirror the BUILT emitters: agent-core loop.ts (tool_*,
// message_segment, run_completed.usage), subagents.ts, goalsTodos.ts,
// compactor.ts, storage artifacts.ts.

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/event_projection.dart';
import 'package:ovid_ai/core/cloud/tool_labels.dart';
import 'package:ovid_ai/core/state.dart';

int _seq = 0;

CloudSessionEvent _ev(
  String type,
  Map<String, dynamic> payload, {
  String? seq,
  DateTime? ts,
}) =>
    CloudSessionEvent.fromJson(<String, dynamic>{
      'sessionId': 'sess-1',
      'seq': seq ?? '1000-${_seq++}',
      'type': type,
      'payload': payload,
      'ts': (ts ?? DateTime.utc(2026, 10, 19, 10)).toIso8601String(),
    });

(TranscriptProjection, EventTranscriptProjector) _fresh() {
  final p = TranscriptProjection();
  return (p, EventTranscriptProjector(p));
}

void main() {
  setUp(() => _seq = 0);

  group('turn separation (CH-005)', () {
    test('tool_started closes the streamed text; the next turn streams below '
        'the tool row; message_completed replaces only the last bubble', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'Let me look.'}));
      proj.apply(_ev('message_segment', {'runId': 'r1', 'content': 'Let me look.'}));
      proj.apply(_ev('tool_started', {
        'runId': 'r1',
        'callId': 'c1',
        'name': 'web_search',
        'args': {'query': 'stripe pricing'},
      }));
      proj.apply(_ev('tool_completed', {
        'runId': 'r1',
        'callId': 'c1',
        'name': 'web_search',
        'isError': false,
        'content': 'Result one\nResult two',
        'truncated': false,
      }));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'Here is '}));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'the summary.'}));
      expect(p.messages.map((m) => m.kind), [
        MsgKind.text,
        MsgKind.tool,
        MsgKind.streaming,
      ]);
      expect(p.messages.first.content, 'Let me look.');
      expect(p.messages.last.content, 'Here is the summary.');

      proj.apply(_ev('message_completed',
          {'messageId': 'm1', 'content': 'Here is the summary.'}));
      proj.apply(_ev('run_completed', {'runId': 'r1'}));
      expect(p.messages.map((m) => m.content).toList(), [
        'Let me look.',
        '',
        'Here is the summary.',
      ]);
      expect(p.messages[0].kind, MsgKind.text);
      expect(p.messages[2].privateSyncId, 'm1');
      expect(p.busy, isFalse);
    });

    test('without a segment (older server) the bubble still settles at the '
        'tool row instead of concatenating turns', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'First.'}));
      proj.apply(_ev('tool_started',
          {'runId': 'r1', 'callId': 'c1', 'name': 'run_shell', 'input': {'command': 'ls'}}));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'Second.'}));
      expect(p.messages.map((m) => m.content).toList(), ['First.', '', 'Second.']);
    });
  });

  group('tool cards (CH-004)', () {
    test('tool_started appends a running row with labels; tool_completed '
        'settles it with detail and summary', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('tool_started', {
        'runId': 'r1',
        'callId': 'c1',
        'name': 'fs_edit',
        'args': {'path': 'lib/main.dart', 'old_str': 'a', 'new_str': 'b'},
      }));
      final row = p.messages.singleWhere((m) => m.kind == MsgKind.tool);
      expect(row.toolName, 'fs_edit');
      expect(row.toolTitle, 'Edit');
      expect(row.toolSummary, 'lib/main.dart');
      expect(row.toolState, 'running');
      expect(row.privateSyncId, 'tool:c1');
      expect(p.activity, 'Editing lib/main.dart');

      proj.apply(_ev('tool_completed', {
        'callId': 'c1',
        'name': 'fs_edit',
        'isError': true,
        'content': 'no match',
        'truncated': true,
      }));
      expect(row.toolState, 'error');
      expect(row.toolDetail, contains('no match'));
      expect(row.toolDetail, contains('truncated'));
      expect(p.activity, isNull);
    });

    test('a terminal never leaves a spinner (stopped on cancel)', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('tool_started',
          {'runId': 'r1', 'callId': 'c1', 'name': 'run_shell', 'args': {'command': 'sleep 99'}}));
      proj.apply(_ev('run_cancelled', {'runId': 'r1'}));
      expect(p.messages.firstWhere((m) => m.kind == MsgKind.tool).toolState,
          'stopped');
    });
  });

  group('artifacts, todos, goal, plan, compaction, usage', () {
    test('artifact_created → one chip row per burst, kept above the live bubble', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('artifact_created', {
        'artifactId': 'a1',
        'name': 'report.pdf',
        'sizeBytes': 2048,
        'contentType': 'application/pdf',
        'url': 'https://r2/x/artifacts/s/a1-report.pdf',
        'expiresAt': '2026-10-19T11:00:00Z',
      }));
      proj.apply(_ev('artifact_created', {
        'artifactId': 'a2',
        'name': 'chart.png',
        'sizeBytes': 10,
        'url': 'https://r2/x/artifacts/s/a2-chart.png',
      }));
      final chips = p.messages.where((m) => m.toolName == kArtifactRowTool).toList();
      expect(chips, hasLength(1));
      expect(chips.single.attachments.map((a) => a.name), ['report.pdf', 'chart.png']);
      expect(chips.single.attachments.first.size, 2048);
      expect(p.messages.last.kind, MsgKind.streaming);
    });

    test('todo_updated / goal_updated / plan_mode_changed fold into state', () {
      final (p, proj) = _fresh();
      expect(p.todos, isNull);
      proj.apply(_ev('todo_updated', {
        'runId': 'r1',
        'todos': [
          {'content': 'Write tests', 'status': 'completed'},
          {'content': 'Ship', 'status': 'in_progress'},
        ],
      }));
      expect(p.todos, [
        {'content': 'Write tests', 'status': 'completed'},
        {'content': 'Ship', 'status': 'in_progress'},
      ]);
      proj.apply(_ev('goal_updated', {
        'runId': 'r1',
        'goal': {'objective': 'Launch', 'notes': ''},
      }));
      expect(p.goal, {'objective': 'Launch', 'notes': ''});
      expect(p.goalFolded, isTrue);
      proj.apply(_ev('plan_mode_changed', {'runId': 'r1', 'planMode': false}));
      expect(p.planMode, isFalse);
    });

    test('compaction_completed adds a compaction row; run_completed usage is kept', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('compaction_completed',
          {'runId': 'r1', 'folded': 40, 'retained': 12, 'narrative': true}));
      proj.apply(_ev('message_completed', {'messageId': 'm1', 'content': 'ok'}));
      proj.apply(_ev('run_completed', {
        'runId': 'r1',
        'usage': {
          'inputTokens': 250,
          'outputTokens': 30,
          'cacheReadTokens': 40,
          'contextTokens': 170,
        },
      }));
      expect(p.messages.first.kind, MsgKind.compact);
      expect(p.messages.first.content, contains('40 earlier messages'));
      expect(p.lastUsage!.contextTokens, 170);
      expect(p.lastUsage!.inputTokens, 250);
    });

    test('workspace_hibernated makes the next run show "Waking your workspace"', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('workspace_hibernated', {'sessionId': 'sess-1'}));
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      expect(p.activity, 'Waking your workspace');
      proj.apply(_ev('workspace_hydrated', {'sessionId': 'sess-1'}));
      expect(p.activity, isNull);
    });
  });

  group('subagent activity cards', () {
    test('subagent_started links the running dispatch row; completed settles it', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('tool_started', {
        'runId': 'r1',
        'callId': 'd1',
        'name': 'dispatch_agent',
        'args': {'prompt': 'Edit four files', 'agentType': 'CodeSubagent'},
      }));
      proj.apply(_ev('subagent_started', {
        'runId': 'r1',
        'childSessionId': 'child-1',
        'childRunId': 'cr-1',
        'prompt': 'Edit four files',
        'agentType': 'CodeSubagent',
      }));
      final card = p.messages.singleWhere((m) => m.toolName == 'dispatch_agent');
      expect(card.toolSessionId, 'child-1');
      expect(card.toolTitle, 'CodeSubagent');
      expect(card.toolState, 'running');
      expect(p.childRunOf('child-1'), 'cr-1');
      expect(p.activity, 'Working with CodeSubagent');

      proj.apply(_ev('subagent_completed', {'childRunId': 'cr-1', 'status': 'failed'}));
      expect(card.toolState, 'error');
    });

    test('a subagent with no dispatch row still gets a card', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('subagent_started', {
        'childSessionId': 'child-2',
        'childRunId': 'cr-2',
        'prompt': 'Browse',
        'agentType': 'BrowserSubagent',
      }));
      final card = p.messages.single;
      expect(card.toolName, 'dispatch_agent');
      expect(card.toolTitle, 'BrowserSubagent');
      expect(card.toolSessionId, 'child-2');
    });
  });

  group('mid-run resume (CH-002)', () {
    test('deltas of a run whose run_started was never seen start it implicitly', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('message_delta', {'runId': 'r9', 'text': 'Counting 1 2'}));
      expect(p.busy, isTrue);
      expect(p.activeRunId, 'r9');
      expect(p.messages.single.content, 'Counting 1 2');
      proj.apply(_ev('message_completed', {'messageId': 'm9', 'content': 'Counting 1 2 3'}));
      proj.apply(_ev('run_completed', {'runId': 'r9'}));
      expect(p.messages.single.content, 'Counting 1 2 3');
      expect(p.busy, isFalse);
    });

    test('message_completed with no active run still lands (appended, deduped)', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('message_completed', {'messageId': 'm1', 'content': 'answer'}));
      proj.apply(_ev('message_completed', {'messageId': 'm1', 'content': 'answer'}));
      expect(p.messages, hasLength(1));
      expect(p.messages.single.privateSyncId, 'm1');
    });

    test('a late delta of a finished run never resurrects a bubble', () {
      final (p, proj) = _fresh();
      proj.apply(_ev('run_started', {'runId': 'r1'}));
      proj.apply(_ev('message_completed', {'messageId': 'm1', 'content': 'done'}));
      proj.apply(_ev('run_completed', {'runId': 'r1'}));
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'late'}));
      expect(p.messages, hasLength(1));
      expect(p.busy, isFalse);
    });
  });

  group('history rebuild (CH-003 / CH-006)', () {
    final t0 = DateTime.utc(2026, 10, 19, 9);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    Message row(String role, String content, String id, int s,
            {List<MessageAttachment> attachments = const []}) =>
        Message(
          role: role,
          content: content,
          privateSyncId: id,
          time: at(s),
          attachments: attachments,
        );

    test('rows and events interleave by time; the answer comes from its event; '
        'cursor ends at the watermark', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      final rows = [
        row('user', 'plan a trip', 'u1', 0,
            attachments: [MessageAttachment(name: 'map.png', size: 9)]),
        row('assistant', 'Here you go', 'a1', 9),
      ];
      final events = [
        _ev('run_started', {'runId': 'r1'}, seq: '10-0', ts: at(1)),
        _ev('message_segment', {'runId': 'r1', 'content': 'Searching.'}, seq: '10-1', ts: at(2)),
        _ev('tool_started', {'runId': 'r1', 'callId': 'c1', 'name': 'web_search', 'args': {'query': 'x'}},
            seq: '10-2', ts: at(3)),
        _ev('tool_completed', {'callId': 'c1', 'name': 'web_search', 'isError': false, 'content': 'ok'},
            seq: '10-3', ts: at(4)),
        _ev('message_completed', {'messageId': 'a1', 'content': 'Here you go'}, seq: '10-4', ts: at(10)),
        _ev('run_completed', {'runId': 'r1'}, seq: '10-5', ts: at(11)),
        _ev('run_started', {'runId': 'r2'}, seq: '11-0', ts: at(20)),
        _ev('run_failed', {'code': 'run_lost'}, seq: '11-1', ts: at(21)),
      ];
      EventTranscriptProjector.rebuild(p, proj,
          rows: rows, events: events, watermark: '12-0', activeRunId: null);
      expect(p.messages.map((m) => m.privateSyncId.split(':').first).toList(), [
        'u1',
        'seg',
        'tool',
        'a1',
        // run_failed's turn tail has a generated id
        p.messages.last.privateSyncId.split(':').first,
      ]);
      expect(p.messages.first.attachments.single.name, 'map.png');
      expect(p.messages[3].content, 'Here you go');
      expect(p.messages.last.kind, MsgKind.turnTail);
      expect(p.busy, isFalse);
      expect(proj.cursor, '12-0');
    });

    test('a run still in flight resumes busy with its live text and Stop', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      final rows = [row('user', 'count to 200', 'u1', 0)];
      final events = [
        _ev('run_started', {'runId': 'r1'}, seq: '20-0', ts: at(1)),
        _ev('message_delta', {'runId': 'r1', 'text': '1 2 3'}, seq: '20-9', ts: at(5)),
      ];
      EventTranscriptProjector.rebuild(p, proj,
          rows: rows, events: events, watermark: '20-9', activeRunId: 'r1');
      expect(p.busy, isTrue);
      expect(p.activeRunId, 'r1');
      expect(p.messages.last.kind, MsgKind.streaming);
      expect(p.messages.last.content, '1 2 3');
      // Live events after the watermark keep folding into the same bubble.
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': ' 4'}, seq: '20-10'));
      expect(p.messages.last.content, '1 2 3 4');
      proj.apply(_ev('message_delta', {'runId': 'r1', 'text': 'dup'}, seq: '20-5'));
      expect(p.messages.last.content, '1 2 3 4');
    });

    test('no active run server-side settles a fold that never saw its terminal', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      EventTranscriptProjector.rebuild(p, proj,
          rows: [row('user', 'q', 'u1', 0)],
          events: [
            _ev('run_started', {'runId': 'r1'}, seq: '30-0', ts: at(1)),
            _ev('tool_started', {'runId': 'r1', 'callId': 'c', 'name': 'run_shell', 'args': {}},
                seq: '30-1', ts: at(2)),
          ],
          watermark: '30-1',
          activeRunId: null);
      expect(p.busy, isFalse);
      expect(p.messages.any((m) => m.kind == MsgKind.streaming), isFalse);
      expect(p.messages.last.toolState, 'stopped');
    });

    test('rows without events (old server / imported) render as before', () {
      final page = EventTranscriptProjector.foldPage(rows: [
        row('user', 'hi', 'u1', 0),
        row('assistant', 'hello', 'a1', 1),
      ], events: const []);
      expect(page.messages.map((m) => m.content), ['hi', 'hello']);
    });

    test('rebuild notifies listeners once', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      EventTranscriptProjector.rebuild(p, proj,
          rows: [row('user', 'q', 'u1', 0)],
          events: [
            _ev('run_started', {'runId': 'r1'}, seq: '40-0', ts: at(1)),
            _ev('message_completed', {'messageId': 'a1', 'content': 'x'}, seq: '40-1', ts: at(2)),
            _ev('run_completed', {'runId': 'r1'}, seq: '40-2', ts: at(3)),
          ],
          watermark: '40-2',
          activeRunId: null);
      expect(notified, 1);
      expect(p.messages.map((m) => m.content), ['q', 'x']);
    });
  });

  group('tool labels', () {
    test('activity phrases match the owner examples', () {
      expect(cloudToolLabel('browser_navigate', {'url': 'https://www.stripe.com/pricing'}).activity,
          'Navigating to stripe.com');
      expect(cloudToolLabel('fs_edit', {'path': 'a.dart'}).activity, 'Editing a.dart');
      expect(cloudToolLabel('fs_edit', {'path': 'a.dart', 'command': 'view'}).title, 'Read');
      expect(cloudToolLabel('dispatch_agent', {'agentType': 'CodeSubagent', 'prompt': 'x'}).title,
          'CodeSubagent');
      expect(cloudToolLabel('mcp__linear_create_issue', {}).title, 'Linear create issue');
    });
  });
}
