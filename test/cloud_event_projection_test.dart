// P8 Task 7 — EventTranscriptProjector / TranscriptProjection. Every event
// shape asserted here was reconciled against the BUILT server code (the
// contract, not the plan sketches):
//   - payload field names (camelCase) — cloud/apps/worker/src/runProcessor.ts
//     event-contract block (lines 25–71):
//       run_started {runId} · message_delta {runId, text} ·
//       run_started_retry {attempt, nextBackoffMs} ·
//       message_completed {messageId, content} · run_completed {runId} ·
//       run_failed {code, message?} · system_note {code, message, command}
//   - the full type union — cloud/packages/shared/src/events.ts: members
//     LANDED but absent from the Task 7 fold table (tool_started,
//     tool_completed, approval_requested, run_cancelled, …) must pass
//     through as NO-OPs (forward compatibility); a type outside the union
//     entirely ('job_started') must too.
//   - Message/MsgKind — lib/core/state.dart (the KEPT model, unmodified).

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/event_projection.dart';
import 'package:ovid_ai/core/state.dart';

/// One session event, built through the WIRE parser so the camelCase field
/// names of the event envelope itself stay pinned.
CloudSessionEvent _ev(
  String type,
  Map<String, dynamic> payload, {
  String seq = '1-1',
}) =>
    CloudSessionEvent.fromJson(<String, dynamic>{
      'sessionId': 'sess-1',
      'seq': seq,
      'type': type,
      'payload': payload,
      'ts': '2026-10-16T10:00:00.000Z',
    });

/// Deterministic clock source (the projector takes an injectable clock so
/// `elapsedMs` is pinnable).
DateTime _at(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000 + ms, isUtc: true);

Message _hist(String role, String content, String id) => Message(
      role: role,
      kind: MsgKind.text,
      content: content,
      privateSyncId: id,
    );

void main() {
  group('fold table', () {
    test('run_started: busy, activeRunId, live streaming bubble appended',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);

      proj.apply(_ev('run_started', <String, dynamic>{'runId': 'run-9'}));

      expect(p.busy, isTrue);
      expect(p.activeRunId, 'run-9');
      expect(p.statusLine, isNull);
      expect(p.messages, hasLength(1));
      final bubble = p.messages.single;
      expect(bubble.role, 'assistant');
      expect(bubble.kind, MsgKind.streaming);
      expect(bubble.thinking, isTrue);
      expect(bubble.content, isEmpty);
      expect(notified, 1);
    });

    test('run_started clears a standing statusLine', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-1'}, seq: '1-1'));
      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-2'));
      expect(p.statusLine, 'Retrying in 3s… (attempt 2)');

      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-2'}, seq: '1-3'));
      expect(p.statusLine, isNull);
    });

    test('message_delta: appends text to the live bubble, ticks once each',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'Hel'}, seq: '1-2'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'lo!'}, seq: '1-3'));

      expect(p.messages.single.content, 'Hello!');
      expect(p.liveBubbleTicks.value, 2);
    });

    test(
        'message_completed: replaces the bubble with the server-authoritative '
        'text message, clears activeRunId, stays busy until run_completed',
        () {
      final p = TranscriptProjection();
      var now = _at(0);
      final proj = EventTranscriptProjector(p, clock: () => now);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'partial'}, seq: '1-2'));

      now = _at(2500);
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'Hello world'},
              seq: '1-3'));

      // REPLACED in place — one finalized bubble, not bubble + final.
      expect(p.messages, hasLength(1));
      final m = p.messages.single;
      expect(m.role, 'assistant');
      expect(m.kind, MsgKind.text);
      expect(m.content, 'Hello world'); // server content authoritative
      expect(m.privateSyncId, 'msg-7'); // server id authoritative
      expect(m.thinking, isFalse);
      expect(m.elapsedMs, 2500); // now - runStartedAt
      expect(p.activeRunId, isNull); // the double-apply guard depends on this
      expect(p.busy, isTrue); // run_completed has not landed yet
      expect(p.liveBubbleTicks.value, 1); // completion does not tick

      proj.apply(
          _ev('run_completed', <String, dynamic>{'runId': 'run-9'}, seq: '1-4'));
      expect(p.busy, isFalse);
    });

    test('run_started_retry: composer status line, stays busy', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-2'));
      expect(p.statusLine, 'Retrying in 3s… (attempt 2)');
      expect(p.busy, isTrue);

      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 4, 'nextBackoffMs': 60000},
          seq: '1-3'));
      expect(p.statusLine, 'Retrying in 60s… (attempt 4)');
      expect(p.busy, isTrue);
    });

    test('run_failed: busy false, error fields, verbatim-message turn tail',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'partial'}, seq: '1-2'));

      proj.apply(
          _ev('run_failed',
              <String, dynamic>{'code': 'cancelled', 'message': 'Stopped by user.'},
              seq: '1-3'));

      expect(p.busy, isFalse);
      expect(p.lastErrorCode, 'cancelled');
      expect(p.lastErrorMessage, 'Stopped by user.');
      final tail = p.messages.last;
      expect(tail.role, 'assistant');
      expect(tail.kind, MsgKind.turnTail);
      expect(tail.content, 'Stopped by user.'); // verbatim server string
    });

    test(
        'run_failed settles the live bubble: partial text kept as a settled '
        'text row, never left shimmering', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'partial'}, seq: '1-2'));

      proj.apply(_ev('run_failed',
          <String, dynamic>{'code': 'model_terminal', 'message': 'Upstream 500'},
          seq: '1-3'));

      expect(p.messages, hasLength(2)); // settled partial + turn tail
      final settled = p.messages[0];
      expect(settled.kind, MsgKind.text);
      expect(settled.thinking, isFalse);
      expect(settled.content, 'partial');
      expect(p.messages[1].kind, MsgKind.turnTail);
      expect(p.messages[1].content, 'Upstream 500');

      // No live bubble remains: a late delta has nowhere to fold.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'late'}, seq: '1-4'));
      expect(p.messages[0].content, 'partial');
    });

    test('run_failed removes an EMPTY live bubble (no blank shimmer row)',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(
          _ev('run_failed', <String, dynamic>{'code': 'key_not_minted'}, seq: '1-2'));

      expect(p.messages, hasLength(1)); // only the turn tail
      expect(p.messages.single.kind, MsgKind.turnTail);
      expect(p.messages.single.content,
          'No model API key is provisioned for this account.');
    });

    test('run_failed clears the retry status line and activeRunId', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-2'));

      proj.apply(_ev('run_failed',
          <String, dynamic>{'code': 'model_transient_exhausted'}, seq: '1-3'));

      expect(p.statusLine, isNull); // never a retry line for a dead run
      expect(p.activeRunId, isNull); // terminal
      expect(p.messages.last.content, 'model_transient_exhausted');
    });

    test('run_completed: busy false, statusLine cleared', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 9000},
          seq: '1-2'));
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'done'},
              seq: '1-3'));
      expect(p.statusLine, 'Retrying in 9s… (attempt 2)'); // still up

      proj.apply(
          _ev('run_completed', <String, dynamic>{'runId': 'run-9'}, seq: '1-4'));

      expect(p.busy, isFalse);
      expect(p.statusLine, isNull);
      expect(p.activeRunId, isNull);
    });

    test('system_note: turn tail with the payload message', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(_ev('system_note',
          <String, dynamic>{'code': 'command_blocked', 'message': 'Command refused.', 'command': 'rm -rf /'}));

      expect(p.messages, hasLength(1));
      final note = p.messages.single;
      expect(note.role, 'assistant');
      expect(note.kind, MsgKind.turnTail);
      expect(note.content, 'Command refused.');
    });

    test('system_note: falls back to the payload text, then empty', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('system_note', <String, dynamic>{'text': 'Scheduler note'}));
      expect(p.messages.single.content, 'Scheduler note');

      proj.apply(_ev('system_note', <String, dynamic>{}, seq: '1-2'));
      expect(p.messages.last.content, isEmpty);
      expect(p.messages, hasLength(2));
    });
  });

  group('epoch and idempotence guards', () {
    test('message_delta with a stale runId is dropped (epoch gate)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final before = notified;

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-OLD', 'text': 'x'}, seq: '1-2'));

      expect(p.messages.single.content, isEmpty);
      expect(p.liveBubbleTicks.value, 0);
      expect(notified, before); // dropped before any mutation
    });

    test('message_delta after the run finalized is dropped', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'final'},
              seq: '1-2'));

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'late'}, seq: '1-3'));

      expect(p.messages, hasLength(1));
      expect(p.messages.single.content, 'final');
      expect(p.liveBubbleTicks.value, 0);
    });

    test('message_completed twice folds once (single finalized bubble)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final completed = _ev('message_completed',
          <String, dynamic>{'messageId': 'msg-7', 'content': 'final'},
          seq: '1-2');

      proj.apply(completed);
      proj.apply(completed); // the SAME event object twice

      expect(p.messages, hasLength(1));
      expect(p.messages.single.content, 'final');

      // A DIFFERENT event object replaying the completion (fresh seq): the
      // activeRunId == null guard is the brief's named double-apply guard.
      proj.apply(_ev('message_completed',
          <String, dynamic>{'messageId': 'msg-7', 'content': 'final'},
          seq: '9-9'));
      expect(p.messages, hasLength(1));
    });

    test('run_started for the run already active appends one bubble only',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-2'));

      expect(p.messages, hasLength(1));
      expect(p.messages.single.kind, MsgKind.streaming);
    });

    test('re-feeding an earlier event after later ones mutates nothing '
        '(monotonic seq guard)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final d1 = _ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'a'}, seq: '1-2');
      proj.apply(d1);
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'b'}, seq: '1-3'));

      proj.apply(d1); // seq '1-2' is at-or-below the folded cursor '1-3'

      expect(p.messages.single.content, 'ab');
    });

    test('a terminal re-apply with nothing left to settle notifies nothing',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'final'},
              seq: '1-2'));
      proj.apply(
          _ev('run_completed', <String, dynamic>{'runId': 'run-9'}, seq: '1-3'));
      final after = notified;

      proj.apply(
          _ev('run_completed', <String, dynamic>{'runId': 'run-9'}, seq: '1-4'));

      expect(notified, after); // nothing changed → no rebuild storm
    });
  });

  group('forward compatibility', () {
    test("unknown type 'job_started': no throw, no mutation, no notify", () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);

      proj.apply(_ev('job_started', <String, dynamic>{'jobId': 'j-1'}));

      expect(p.messages, isEmpty);
      expect(p.busy, isFalse);
      expect(p.activeRunId, isNull);
      expect(p.statusLine, isNull);
      expect(p.lastErrorCode, isNull);
      expect(p.liveBubbleTicks.value, 0);
      expect(notified, 0);
    });

    test('LANDED union members absent from the fold table pass through as '
        'no-ops', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final len = p.messages.length;
      final ticks = p.liveBubbleTicks.value;
      var notifications = 0;
      p.addListener(() => notifications++);

      // Shapes per shared/src/events.ts union members a later P8 task folds.
      proj.apply(_ev('tool_started',
          <String, dynamic>{'runId': 'run-9', 'callId': 'c1', 'name': 'run_shell', 'input': {}},
          seq: '1-2'));
      proj.apply(_ev('tool_completed',
          <String, dynamic>{'runId': 'run-9', 'callId': 'c1', 'name': 'run_shell', 'isError': false, 'content': 'ok', 'truncated': false},
          seq: '1-3'));
      proj.apply(_ev('approval_requested',
          <String, dynamic>{'runId': 'run-9', 'callId': 'c1', 'name': 'fs_edit'},
          seq: '1-4'));
      proj.apply(_ev('run_cancelled',
          <String, dynamic>{'runId': 'run-9'}, seq: '1-5'));
      proj.apply(_ev('compaction_completed',
          <String, dynamic>{'kept': 10}, seq: '1-6'));

      expect(p.messages, hasLength(len));
      expect(p.liveBubbleTicks.value, ticks);
      expect(p.busy, isTrue); // untouched
      expect(p.activeRunId, 'run-9');
      expect(notifications, 0);
    });
  });

  group('seedFromHistory', () {
    test('cached messages first, run_started appends after them', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);

      p.seedFromHistory([
        _hist('user', 'hi', 'u-1'),
        _hist('assistant', 'hello', 'a-1'),
      ]);
      expect(p.messages, hasLength(2));

      proj.apply(_ev('run_started', <String, dynamic>{'runId': 'run-2'}));

      expect(p.messages, hasLength(3));
      expect(p.messages[0].privateSyncId, 'u-1');
      expect(p.messages[1].privateSyncId, 'a-1');
      expect(p.messages[2].kind, MsgKind.streaming);
    });

    test('replaces the current contents (a re-seed is not an append)', () {
      final p = TranscriptProjection();
      p.seedFromHistory([_hist('user', 'first', 'u-1')]);
      p.seedFromHistory([_hist('user', 'second', 'u-2'), _hist('assistant', 'answer', 'a-2')]);

      expect(p.messages, hasLength(2));
      expect(p.messages.map((m) => m.privateSyncId), ['u-2', 'a-2']);
    });

    test('an in-flight live bubble stays at the tail and keeps folding', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'partial'}, seq: '1-2'));

      p.seedFromHistory([_hist('user', 'hi', 'u-1')]);

      expect(p.messages, hasLength(2));
      expect(p.messages.first.kind, MsgKind.text);
      expect(p.messages.last.kind, MsgKind.streaming);
      expect(p.messages.last.content, 'partial');

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': ' more'}, seq: '1-3'));
      expect(p.messages.last.content, 'partial more');

      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'final'},
              seq: '1-4'));
      expect(p.messages, hasLength(2));
      expect(p.messages.last.content, 'final');
    });
  });

  group('publication discipline', () {
    test('message_delta publishes via liveBubbleTicks, not notifyListeners',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final afterStart = notified;

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'token'}, seq: '1-2'));

      expect(p.liveBubbleTicks.value, 1);
      expect(notified, afterStart); // the tick IS the publication
    });

    test('liveBubbleTicks exposes its own listenable value', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var ticks = 0;
      p.liveBubbleTicks.addListener(() => ticks++);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'a'}, seq: '1-2'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'b'}, seq: '1-3'));

      expect(ticks, 2);
    });
  });

  test('dispose is safe', () {
    final p = TranscriptProjection();
    p.dispose();
  });
}
