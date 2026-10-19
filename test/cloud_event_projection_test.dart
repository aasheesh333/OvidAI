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
//     tool_completed, approval_requested, subagent_started, …) must pass
//     through as NO-OPs (forward compatibility); a type outside the union
//     entirely ('job_started') must too. run_cancelled LEFT that list: the
//     full processor emits it as its own terminal (agent-core loop.ts
//     `cancelled()`), so it folds like run_failed — see the fold-table
//     tests below.
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
        'the FIRST message_delta flips the bubble out of thinking — the '
        'answer renders via the answer path, not inside the Thinking… card',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      expect(p.messages.single.thinking, isTrue); // armed by run_started

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'Hel'}, seq: '1-2'));
      expect(p.messages.single.thinking, isFalse);
      expect(p.messages.single.content, 'Hel');

      // Idempotent: later deltas never re-flip.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'lo!'}, seq: '1-3'));
      expect(p.messages.single.thinking, isFalse);
      expect(p.messages.single.content, 'Hello!');
      expect(p.messages, hasLength(1)); // an empty pre-delta bubble adds no row
    });

    test(
        'pre-delta bubble content is kept as a reasoning row above the '
        'answer, never prefixed to the answer body', () {
      final p = TranscriptProjection();
      var now = _at(0);
      final proj = EventTranscriptProjector(p, clock: () => now);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      // No built emitter puts content in the bubble before the first answer
      // delta (the worker streams answer text only); write pre-answer noise
      // straight into the armed bubble to pin the fold for a future
      // reasoning-phase emitter.
      p.messages.single.content = 'let me think…';
      now = _at(1500);

      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'Hel'}, seq: '1-2'));

      // The noise became a settled reasoning row (the transcript model's
      // reasoning carrier — `_ReasoningCard` renders its content as the
      // collapsed "Thought for Ns" block) DIRECTLY above the bubble.
      expect(p.messages, hasLength(2));
      final thought = p.messages[0];
      expect(thought.kind, MsgKind.reasoning);
      expect(thought.content, 'let me think…');
      expect(thought.thinking, isFalse);
      expect(thought.elapsedMs, 1500); // pre-answer phase length → the label
      final live = p.messages[1];
      expect(live.kind, MsgKind.streaming);
      expect(live.thinking, isFalse);
      expect(live.content, 'Hel'); // the noise never leaks into the answer

      now = _at(4000);
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'Hello!'},
              seq: '1-3'));
      // The reasoning row SURVIVES the server-authoritative replace — the
      // Thought-for block stays above the finalized answer.
      expect(p.messages, hasLength(2));
      expect(p.messages[0].kind, MsgKind.reasoning);
      expect(p.messages[1].kind, MsgKind.text);
      expect(p.messages[1].content, 'Hello!');
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

    test(
        'run_started_retry discards the failed attempt\'s partial and '
        're-arms a fresh bubble; the retry\'s deltas build fresh text '
        '(retry succeeds — ruling 1, _discardLiveAttempt parity)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'attempt-1 partial'},
          seq: '1-2'));
      final firstBubble = p.messages.single;

      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-3'));

      // A FRESH empty streaming bubble is re-armed (a bare remove would
      // swallow the retry's whole stream — deltas drop with no bubble), and
      // the failed attempt's partial is gone.
      expect(p.messages, hasLength(1));
      final reArmed = p.messages.single;
      expect(reArmed, isNot(same(firstBubble)));
      expect(reArmed.kind, MsgKind.streaming);
      expect(reArmed.thinking, isTrue);
      expect(reArmed.content, isEmpty);
      // busy/activeRunId are KEPT (a retry is not a terminal); the same
      // event sets the status line.
      expect(p.busy, isTrue);
      expect(p.activeRunId, 'run-9');
      expect(p.statusLine, 'Retrying in 3s… (attempt 2)');

      // The retry's deltas append to the FRESH bubble — no concatenation
      // with the failed attempt's partial.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'attempt-2 answer'},
          seq: '1-4'));
      expect(p.messages.single.content, 'attempt-2 answer');
      expect(p.liveBubbleTicks.value, 2);

      // Success: message_completed replaces with the server-authoritative
      // text; run_completed settles busy.
      proj.apply(
          _ev('message_completed',
              <String, dynamic>{'messageId': 'msg-7', 'content': 'final answer'},
              seq: '1-5'));
      expect(p.messages, hasLength(1));
      expect(p.messages.single.kind, MsgKind.text);
      expect(p.messages.single.content, 'final answer');
      proj.apply(
          _ev('run_completed', <String, dynamic>{'runId': 'run-9'}, seq: '1-6'));
      expect(p.busy, isFalse);
    });

    test(
        'retry exhaustion settles only the LAST attempt\'s partial — no '
        'cross-attempt concatenation baked into a permanent row (ruling 1)',
        () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'attempt-1 partial'},
          seq: '1-2'));
      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-3'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'attempt-2 partial'},
          seq: '1-4'));

      // Exhausted: run_failed{model_transient_exhausted} — NO
      // message_completed ever arrives on this path.
      proj.apply(_ev('run_failed',
          <String, dynamic>{'code': 'model_transient_exhausted'}, seq: '1-5'));

      // Terminal-settle lands ONLY attempt 2's partial above the turn tail.
      expect(p.messages, hasLength(2));
      expect(p.messages[0].kind, MsgKind.text);
      expect(p.messages[0].thinking, isFalse);
      expect(p.messages[0].content, 'attempt-2 partial');
      expect(p.messages[1].kind, MsgKind.turnTail);
      // CH-019: plain language, never the raw code.
      expect(p.messages[1].content,
          'The model provider failed to answer. Try again or pick another model.');
      expect(p.busy, isFalse);
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
      // CH-019: provider text is detail only — the row reads as plain language.
      expect(p.messages[1].content,
          'The model provider failed to answer. Try again or pick another model.');

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
          'Ovid could not set up model access for your account. Try again in a moment.');
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
      expect(p.messages.last.content,
          'The model provider failed to answer. Try again or pick another model.');
    });

    test(
        'run_cancelled: terminal settle — busy false, activeRunId cleared, '
        'retry line down, cancelled turn tail (compat run_failed{cancelled} '
        'parity)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      proj.apply(_ev('run_started_retry',
          <String, dynamic>{'attempt': 2, 'nextBackoffMs': 3000},
          seq: '1-2'));
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'partial'}, seq: '1-3'));

      // Full-processor shape (loop.ts cancelled()): {runId, reason?} — no
      // code/message.
      proj.apply(_ev('run_cancelled',
          <String, dynamic>{'runId': 'run-9'}, seq: '1-4'));

      expect(p.busy, isFalse);
      expect(p.activeRunId, isNull); // a late delta has nowhere to land
      expect(p.statusLine, isNull); // never a retry line for a dead run
      // Same error fields the compat spelling (run_failed{code:'cancelled',
      // message:'Stopped by user.'}) always produced.
      expect(p.lastErrorCode, 'cancelled');
      expect(p.lastErrorMessage, 'Stopped by user.');
      expect(p.messages, hasLength(2)); // settled partial + turn tail
      expect(p.messages[0].kind, MsgKind.text);
      expect(p.messages[0].thinking, isFalse);
      expect(p.messages[0].content, 'partial'); // the partial stays visible
      final tail = p.messages[1];
      expect(tail.role, 'assistant');
      expect(tail.kind, MsgKind.turnTail);
      expect(tail.content, 'Stopped by user.');

      // No live bubble remains: a late delta must never land.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'late'}, seq: '1-5'));
      expect(p.messages[0].content, 'partial');
    });

    test('run_cancelled renders the server reason verbatim', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));

      proj.apply(_ev('run_cancelled',
          <String, dynamic>{'runId': 'run-9', 'reason': 'parent run cancelled'},
          seq: '1-2'));

      expect(p.busy, isFalse);
      expect(p.messages.single.kind, MsgKind.turnTail);
      expect(p.messages.single.content, 'parent run cancelled');
      expect(p.lastErrorMessage, 'parent run cancelled');
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

    test('system_note: falls back to the payload text; nothing to say renders '
        'NOTHING (CH-018)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('system_note', <String, dynamic>{'text': 'Scheduler note'}));
      expect(p.messages.single.content, 'Scheduler note');

      proj.apply(_ev('system_note', <String, dynamic>{}, seq: '1-2'));
      proj.apply(_ev('system_note', <String, dynamic>{'code': 'hook_block_ignored', 'reason': 'x'},
          seq: '1-3'));
      expect(p.messages, hasLength(1));
    });

    test('system_note: known codes get plain copy (run_merged, schedule)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(_ev('system_note', <String, dynamic>{
        'code': 'run_merged',
        'mergedRunId': 'r2',
        'runId': 'r1',
      }));
      proj.apply(_ev('system_note',
          <String, dynamic>{'scheduleId': 's1', 'status': 'completed'},
          seq: '1-2'));
      expect(p.messages.map((m) => m.content), [
        'Your follow-up was added to the running task.',
        'Scheduled run finished.',
      ]);
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
    test(
        'message_delta publishes per token via liveBubbleTicks; the FIRST '
        "delta's thinking flip is the one structural notify", () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-9'}, seq: '1-1'));
      final afterStart = notified;

      // First delta: flips the bubble out of thinking — a structural change
      // (the render gate switches to the answer path), republished once
      // through the apply-level flush like message_completed's replace.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': 'First'}, seq: '1-2'));
      expect(p.liveBubbleTicks.value, 1);
      expect(notified, afterStart + 1);

      // Every later delta: the tick IS the publication.
      proj.apply(_ev('message_delta',
          <String, dynamic>{'runId': 'run-9', 'text': ' token'}, seq: '1-3'));
      expect(p.liveBubbleTicks.value, 2);
      expect(notified, afterStart + 1);
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

  group('approval affordance (P3 Task 12 fold)', () {
    test('approval_requested sets pendingApproval from the payload, adds no '
        'transcript row', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);

      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 'Run rm -rf /tmp/build',
        'detail': 'rm -rf /tmp/build',
        'allowAlways': true,
        'expiresAt': '2026-10-16T10:02:00.000Z',
      }));

      final prompt = p.pendingApproval;
      expect(prompt, isNotNull);
      expect(prompt!.approvalId, 'ap-1');
      expect(prompt.tool, 'bash');
      expect(prompt.kind, 'tool');
      expect(prompt.summary, 'Run rm -rf /tmp/build');
      expect(prompt.detail, 'rm -rf /tmp/build');
      expect(prompt.allowAlways, isTrue);
      expect(prompt.expiresAt,
          DateTime.parse('2026-10-16T10:02:00.000Z'));
      // The affordance is the dock's, not a transcript row.
      expect(p.messages, isEmpty);
      expect(notified, 1);
    });

    test('approval_resolved clears the matching prompt; a mismatched id keeps '
        'it; nothing pending is a no-op', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }, seq: '1-1'));

      // A resolved for a different (superseded) approval never clears the
      // live prompt.
      proj.apply(_ev('approval_resolved',
          <String, dynamic>{'approvalId': 'ap-0', 'decision': 'deny'},
          seq: '1-2'));
      expect(p.pendingApproval?.approvalId, 'ap-1');

      proj.apply(_ev('approval_resolved',
          <String, dynamic>{'approvalId': 'ap-1', 'decision': 'deny'},
          seq: '1-3'));
      expect(p.pendingApproval, isNull);
      expect(notified, 2);

      // Duplicate/late resolved with nothing pending: no throw, no notify.
      proj.apply(_ev('approval_resolved',
          <String, dynamic>{'approvalId': 'ap-1', 'decision': 'deny'},
          seq: '1-4'));
      expect(notified, 2);
    });

    test('the timeout-deny spelling (reason) clears like any resolved', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-9',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }, seq: '1-1'));
      proj.apply(_ev('approval_resolved', <String, dynamic>{
        'approvalId': 'ap-9',
        'decision': 'deny',
        'reason': 'timeout',
      }, seq: '1-2'));
      expect(p.pendingApproval, isNull);
    });

    test('terminal events clear a standing prompt (run_failed, '
        'run_cancelled, run_completed)', () {
      // run_failed / run_cancelled.
      for (final terminal in const ['run_failed', 'run_cancelled']) {
        final p = TranscriptProjection();
        final proj = EventTranscriptProjector(p);
        proj.apply(_ev('run_started',
            <String, dynamic>{'runId': 'run-1'}, seq: '1-1'));
        proj.apply(_ev('approval_requested', <String, dynamic>{
          'approvalId': 'ap-1',
          'tool': 'bash',
          'kind': 'tool',
          'summary': 's',
          'detail': 'd',
          'allowAlways': false,
        }, seq: '1-2'));
        expect(p.pendingApproval, isNotNull);
        proj.apply(_ev(terminal,
            terminal == 'run_failed'
                ? <String, dynamic>{'code': 'internal', 'message': 'boom'}
                : <String, dynamic>{'runId': 'run-1', 'reason': 'Stopped.'},
            seq: '1-3'));
        expect(p.pendingApproval, isNull, reason: terminal);
      }
      // run_completed.
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(
          _ev('run_started', <String, dynamic>{'runId': 'run-1'}, seq: '1-1'));
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'exit_plan_mode',
        'kind': 'plan',
        'summary': 'Plan complete?',
        'detail': 'the recap',
        'allowAlways': false,
      }, seq: '1-2'));
      proj.apply(_ev('run_completed', <String, dynamic>{'runId': 'run-1'},
          seq: '1-3'));
      expect(p.pendingApproval, isNull);
    });

    test('an off-contract payload (no approvalId) is a defensive no-op', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }));
      expect(p.pendingApproval, isNull);
      expect(p.messages, isEmpty);
    });

    test('re-folding the SAME approvalId keeps the standing prompt (no churn '
        'through the dock arm guard)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }, seq: '1-1'));
      final first = p.pendingApproval;
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }, seq: '1-2'));
      expect(identical(p.pendingApproval, first), isTrue);
      expect(notified, 1);
    });

    test('clearPendingApproval clears + notifies on the live id, ignores a '
        'stale one (the facade optimistic dismiss)', () {
      final p = TranscriptProjection();
      final proj = EventTranscriptProjector(p);
      var notified = 0;
      p.addListener(() => notified++);
      proj.apply(_ev('approval_requested', <String, dynamic>{
        'approvalId': 'ap-1',
        'tool': 'bash',
        'kind': 'tool',
        'summary': 's',
        'detail': 'd',
        'allowAlways': false,
      }));
      final afterFold = notified;

      p.clearPendingApproval('ap-other');
      expect(p.pendingApproval?.approvalId, 'ap-1');
      expect(notified, afterFold);

      p.clearPendingApproval('ap-1');
      expect(p.pendingApproval, isNull);
      expect(notified, afterFold + 1);
    });
  });

  test('dispose is safe', () {
    final p = TranscriptProjection();
    p.dispose();
  });
}
