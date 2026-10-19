/// Client-side transcript projection for Ovid Cloud session events (P8 Task 7).
///
/// Folds the multiplexer's (already seq-deduped) [CloudSessionEvent] stream
/// for ONE session into the existing KEPT transcript model (`Message` /
/// `MsgKind`, lib/core/state.dart) — the thin client's replacement for
/// the retired local service's in-process streaming pipeline. Task 8's `CloudAgentFacade`
/// creates one [TranscriptProjection] + [EventTranscriptProjector] per
/// session and feeds it from `WsMultiplexer.subscribe(sessionId)`; the
/// projector itself does no routing and no I/O.
///
/// The fold table is the binding contract (plan Task 7):
///
/// | Event | Projection |
/// |---|---|
/// | `run_started{runId}` | busy=true, activeRunId, live `streaming` bubble, statusLine cleared |
/// | `message_delta{runId,text}` | epoch-gated append into the bubble's content + [TranscriptProjection.liveBubbleTicks] tick; the run's FIRST delta also ends the bubble's thinking phase — pre-delta content is kept as a settled reasoning row above the fresh answer body (`_beginLiveAnswer`), never as the answer's first characters |
/// | `message_completed{messageId,content}` | bubble REPLACED by the server-authoritative text Message; activeRunId cleared (the double-apply guard) |
/// | `run_started_retry{attempt,nextBackoffMs}` | the composer status line; stays busy; the failed attempt's partial is DISCARDED and a fresh empty bubble re-armed (ruling 1 — parity with the retired local service's `_discardLiveAttempt`) |
/// | `run_failed{code,message?}` | busy=false, error fields, turn-tail row |
/// | `run_cancelled{runId,reason?}` | busy=false, error fields, turn-tail row (the cancelled copy) |
/// | `run_completed{runId}` | busy=false, statusLine cleared |
/// | `system_note` | turn-tail row |
/// | `approval_requested{approvalId,tool,kind,summary,detail,allowAlways,expiresAt?}` | [TranscriptProjection.pendingApproval] — the approval affordance. ONE prompt can be pending at a time: the run sits blocked in the worker's approval bridge until the user answers or the bridge timeout-denies |
/// | `approval_resolved{approvalId,decision,reason?}` | pendingApproval cleared when the ids match (the timeout-deny spelling included) |
///
/// The terminal rows also clear a pending approval: a prompt can never
/// outlive its run (the resolved event always precedes the terminal, so this
/// is the defensive belt for a wire that skips it).
///
/// Every OTHER event type is a NO-OP (forward compatibility): the LANDED
/// @ovid/shared union members the table does not cover yet (tool_started,
/// tool_completed, artifact_created, workspace_hibernated, workspace_hydrated,
/// todo_updated, goal_updated, plan_mode_changed, subagent_started,
/// subagent_completed, compaction_completed) and any future type — later P8+
/// tasks fold them.
/// `run_cancelled` is the full processor's terminal for a user-initiated
/// cancel (agent-core loop.ts `cancelled()`); the P2 compat sink still
/// renders the same cancel as `run_failed{code:'cancelled'}` — both
/// spellings fold to the same turn tail (see [_onRunCancelled]).
///
/// Payload field names mirror the BUILT emitters exactly (camelCase):
/// cloud/apps/worker/src/runProcessor.ts (event-contract block). The server
/// is the contract; when this file and the server disagree, fix this file.
library;

import 'package:flutter/foundation.dart';

import '../state.dart';
import 'cloud_ws.dart';

/// The live approval prompt folded from `approval_requested` (the P3 Task 12
/// gate, agent-core approvals.ts). Field names mirror the emitter exactly;
/// the payload carries NO runId — the prompt belongs to whichever run the
/// session had active, and the gate prompts one request at a time.
@immutable
class CloudApprovalPrompt {
  const CloudApprovalPrompt({
    required this.approvalId,
    required this.tool,
    required this.kind,
    required this.summary,
    required this.detail,
    required this.allowAlways,
    this.expiresAt,
  });

  /// The bridge's answer key — what `approval_resolved` clears by and the
  /// client's `approval_response` op echoes.
  final String approvalId;

  /// The tool asking ("bash", "exit_plan_mode", …).
  final String tool;

  /// 'tool' | 'question' | 'plan' (agent-core ports.ts ApprovalRequest).
  final String kind;

  final String summary;
  final String detail;

  /// Whether the card may offer "Always Allow" (plain tool approvals only).
  final bool allowAlways;

  /// When the bridge timeout-denies (ISO-8601), or null for an attended
  /// question/plan — those wait for the answer, there is no clock.
  final DateTime? expiresAt;
}

/// The transcript + run-status state for ONE cloud session, folded from
/// session events. Structural transcript changes (append / replace / settle /
/// seed) notify listeners; per-delta content growth does NOT — it publishes
/// through [liveBubbleTicks] instead, exactly like the retired local service's live-bubble
/// tick, so a streaming token repaints only the tail row, never every widget
/// listening to this notifier.
class TranscriptProjection extends ChangeNotifier {
  /// The transcript for this session, oldest-first.
  final List<Message> messages = <Message>[];

  /// Ticks once per accepted `message_delta` so only the live tail bubble
  /// repaints. Replaces the retired local service's liveBubbleTicksFor (Task 8).
  final ValueNotifier<int> liveBubbleTicks = ValueNotifier<int>(0);

  bool _busy = false;
  String? _activeRunId;
  String? _statusLine;
  String? _lastErrorCode;
  String? _lastErrorMessage;

  /// The run's live streaming bubble (the `MsgKind.streaming` tail row).
  /// Same library as [EventTranscriptProjector], which drives it.
  Message? _liveBubble;

  /// Wall clock of the active run's `run_started` — the `elapsedMs` source.
  DateTime? _runStartedAt;

  /// The session's live approval prompt, or null when nothing is waiting on
  /// the user. Set by the `approval_requested` fold, cleared by
  /// `approval_resolved`, the terminal folds, and [clearPendingApproval].
  CloudApprovalPrompt? _pendingApproval;

  /// The live approval affordance (see [_pendingApproval]). The UI-facing
  /// [Message] transcript is untouched by approvals — the chat renders the
  /// prompt as the approval dock above the composer, not as a transcript row.
  CloudApprovalPrompt? get pendingApproval => _pendingApproval;

  /// Clears the prompt when [approvalId] is the live one — the facade's
  /// optimistic dismiss once it has dispatched the user's
  /// `approval_response`. Unlike the projector's folds this notifies
  /// directly: it runs OUTSIDE an `apply`, so there is no apply-level
  /// [_flushNotify] to piggyback on. A stale id (already superseded or
  /// cleared) is a no-op.
  void clearPendingApproval(String approvalId) {
    final live = _pendingApproval;
    if (live == null || live.approvalId != approvalId) return;
    _pendingApproval = null;
    notifyListeners();
  }

  /// Set by the mutators below; consumed by [_flushNotify] at the end of one
  /// `apply` so a no-op fold notifies nothing.
  bool _changed = false;

  bool get busy => _busy;

  /// The run whose events fold into the live bubble, or null when no run is
  /// in flight (message_completed and the terminal events clear it — the
  /// message_completed double-apply guard depends on that clearing).
  String? get activeRunId => _activeRunId;

  /// The composer status row ("Retrying in 9s… (attempt 3)").
  String? get statusLine => _statusLine;

  String? get lastErrorCode => _lastErrorCode;

  String? get lastErrorMessage => _lastErrorMessage;

  /// Replaces the transcript with the offline/paged cache so events fold on
  /// top (Task 9 seeds before subscribing; seed-vs-live reconciliation is
  /// that task's, not this one's). A live bubble belonging to a run still in
  /// flight stays at the tail so folding remains visible.
  void seedFromHistory(List<Message> cached) {
    messages
      ..clear()
      ..addAll(cached);
    final live = _liveBubble;
    if (live != null && _busy) messages.add(live);
    notifyListeners();
  }

  @override
  void dispose() {
    liveBubbleTicks.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Internal mutators — same library as the projector, which drives them.
  // Each records whether anything actually changed so [_flushNotify] can
  // suppress notifications for no-op folds.
  // -------------------------------------------------------------------------

  void _setBusy(bool v) {
    if (_busy == v) return;
    _busy = v;
    _changed = true;
  }

  void _setActiveRunId(String? v) {
    if (_activeRunId == v) return;
    _activeRunId = v;
    _changed = true;
  }

  void _setStatusLine(String? v) {
    if (_statusLine == v) return;
    _statusLine = v;
    _changed = true;
  }

  void _setLastError(String? code, String? message) {
    if (_lastErrorCode == code && _lastErrorMessage == message) return;
    _lastErrorCode = code;
    _lastErrorMessage = message;
    _changed = true;
  }

  /// approvalId-keyed (not identity): re-folding the SAME prompt — a
  /// defensively re-emitted request — keeps the one already shown instead of
  /// churning a fresh object through the dock's arm guard.
  void _setPendingApproval(CloudApprovalPrompt? v) {
    if (_pendingApproval?.approvalId == v?.approvalId) return;
    _pendingApproval = v;
    _changed = true;
  }

  /// Appends the run's live streaming bubble, settling any leftover bubble
  /// from a previous run first (a missed terminal event must never stack a
  /// second shimmering row).
  void _appendLiveBubble(Message bubble) {
    _settleLiveBubble();
    _liveBubble = bubble;
    messages.add(bubble);
    _changed = true;
  }

  /// Replaces the live streaming bubble with the finalized message at the
  /// bubble's position (appends when no bubble is tracked — a defensive
  /// path; the wire always pairs them).
  void _replaceLiveBubble(Message finalized) {
    final live = _liveBubble;
    final idx = live == null ? -1 : messages.indexOf(live);
    if (idx >= 0) {
      messages[idx] = finalized;
    } else {
      messages.add(finalized);
    }
    _liveBubble = null;
    _changed = true;
  }

  /// Replaces an ALREADY-PRESENT message (same `privateSyncId`) with the
  /// server-authoritative [finalized] row and drops the live bubble. P8
  /// Task 9: a replayed `message_completed` can overlap a REST/cache page
  /// that already contained the message (the cache high-water-mark window);
  /// the transcript must never grow a duplicate assistant row.
  void _replaceExistingMessage(String messageId, Message finalized) {
    final live = _liveBubble;
    if (live != null) messages.remove(live);
    _liveBubble = null;
    final idx = messages.indexWhere((m) => m.privateSyncId == messageId);
    if (idx >= 0) {
      messages[idx] = finalized;
    } else {
      messages.add(finalized);
    }
    _changed = true;
  }

  void _appendMessage(Message m) {
    messages.add(m);
    _changed = true;
  }

  /// Settles the live streaming bubble: one with partial content is promoted
  /// to a settled text row (the partial output stays visible — the retired local service
  /// stopped-turn parity), an empty one is removed outright. A `thinking:`
  /// row must NEVER be left shimmering after a terminal event.
  void _settleLiveBubble() {
    final live = _liveBubble;
    if (live == null) return;
    _liveBubble = null;
    if (live.content.isEmpty) {
      if (messages.remove(live)) _changed = true;
      return;
    }
    live.kind = MsgKind.text;
    live.thinking = false;
    _changed = true;
  }

  /// Discards the run's live streaming bubble — the failed attempt's partial
  /// text can never be appended to the retry's output — and re-arms [fresh]
  /// in its place at the tail. busy / activeRunId / statusLine are untouched:
  /// a retry is not a terminal. The re-arm matters because a bare remove
  /// would swallow the next attempt's whole stream (`message_delta` drops
  /// when no bubble is tracked). No-op when no run is in flight.
  ///
  /// Controller ruling 1 (fix round 1): the retired local service's `_discardLiveAttempt`
  /// parity (it discarded the partial before every retry).
  void _resetLiveBubble(Message fresh) {
    final live = _liveBubble;
    if (live == null) return;
    messages.remove(live);
    _liveBubble = fresh;
    messages.add(fresh);
    _changed = true;
  }

  /// The run's FIRST `message_delta` lands: the live bubble stops thinking
  /// and the answer body begins. The cloud event stream has no separate
  /// reasoning phase (the worker emits answer deltas only), so any content
  /// the bubble already held is pre-answer noise, never the answer's first
  /// characters: it is kept as a settled `reasoning` row inserted ABOVE the
  /// bubble — the transcript model's reasoning carrier (`_ReasoningCard`
  /// renders a reasoning row's content as the collapsed "Thought for Ns"
  /// block; persisted rows carry their reasoning the same way) — and the
  /// answer streams into a fresh body. The built wire always arms the bubble
  /// EMPTY, so today the snapshot is a no-op; the fold stays correct for a
  /// future emitter that streams a reasoning phase into the same bubble.
  ///
  /// The thinking flip is a STRUCTURAL change — the render gate switches from
  /// the reasoning card to the answer path — so it records `_changed` and
  /// the apply-level [_flushNotify] republishes the transcript once, exactly
  /// like `message_completed`'s replace. The per-token tick alone repaints
  /// only the tail row and would leave window caches keyed on `thinking`
  /// stale. No-op once the bubble is already answering (idempotent on the
  /// second-and-later deltas).
  ///
  /// HAZARD for a future reasoning-phase emitter: the UI's think-clock
  /// (`_ThinkClock`, chat_screen.dart) snapshots whatever a frame showed on
  /// the thinking bubble, so a bubble that streamed reasoning into `content`
  /// across frames would render its snapshot BESIDE this row while live
  /// (the clock dies with the bubble at `message_completed`; the reasoning
  /// row is the durable carrier). Such an emitter should fold reasoning as
  /// its own rows instead of into the live bubble's content.
  void _beginLiveAnswer(Message live, DateTime now) {
    if (!live.thinking) return;
    final noise = live.content;
    if (noise.isNotEmpty) {
      final startedAt = _runStartedAt;
      int? elapsedMs =
          startedAt == null ? null : now.difference(startedAt).inMilliseconds;
      if (elapsedMs != null && elapsedMs < 0) elapsedMs = 0;
      final thought = Message(
        role: 'assistant',
        kind: MsgKind.reasoning,
        content: noise,
        // The pre-answer phase's length: drives the row's "Thought for Ns"
        // label (`_ReasoningCard._doneDuration`).
        elapsedMs: elapsedMs,
        time: now,
      );
      // Directly above the bubble so the thought block precedes the answer
      // it produced; appended defensively when the bubble is not tracked in
      // `messages` yet (the wire always pairs them — `_replaceLiveBubble`
      // parity).
      final idx = messages.indexOf(live);
      if (idx >= 0) {
        messages.insert(idx, thought);
      } else {
        messages.add(thought);
      }
      live.content = '';
    }
    live.thinking = false;
    _changed = true;
  }

  /// One notification per mutating `apply` (the projector calls this at the
  /// end of every fold; no-op folds notify nothing).
  void _flushNotify() {
    if (!_changed) return;
    _changed = false;
    notifyListeners();
  }
}

/// Folds cloud session events into a [TranscriptProjection] target. Applies
/// only events the multiplexer has already seq-deduped; re-checks anyway
/// (monotonic seq guard) so the same event re-fed after later ones — same
/// object or a stale replay — mutates once.
class EventTranscriptProjector {
  /// [clock] is injectable so tests can pin `elapsedMs` deterministically;
  /// production uses the system clock.
  EventTranscriptProjector(this.target, {DateTime Function()? clock})
      : _clock = clock ?? _systemClock;

  final TranscriptProjection target;
  final DateTime Function() _clock;

  static DateTime _systemClock() => DateTime.now();

  /// Max seq (numeric compare) already folded — the exactly-once guard at
  /// O(1) memory. The multiplexer dedupes per-seq upstream; this catches
  /// consumer re-feeds (A, B, A) and same-object double-applies alike.
  String? _lastSeq;

  /// Seeds (or clears, with null) the exactly-once cursor. P8 Task 9 calls
  /// this with the offline cache's high-water mark BEFORE folding replayed
  /// events: the seeded transcript already reflects every event at or below
  /// the mark, so re-feeding one must be a no-op. Without this API the
  /// private `_lastSeq` survives [TranscriptProjection.seedFromHistory] and
  /// would either drop uncovered events or duplicate covered ones.
  void seedCursor(String? seq) => _lastSeq = seq;

  /// The current high-water mark (test/observability seam).
  String? get cursor => _lastSeq;

  /// Folds ONE event. Unknown/fold-table-absent types are ignored (never
  /// throw — forward compatibility for P2/P3 event types). Payload fields
  /// are parsed defensively: a known type with an off-contract payload folds
  /// with nulls rather than throwing (the server's zod + typed emitters
  /// make that a belt-and-suspenders path).
  void apply(CloudSessionEvent event) {
    final last = _lastSeq;
    if (last != null && _seqCompare(event.seq, last) <= 0) return;
    _lastSeq = event.seq;
    switch (event.type) {
      case 'run_started':
        _onRunStarted(event.payload);
        break;
      case 'message_delta':
        _onMessageDelta(event.payload);
        break;
      case 'message_completed':
        _onMessageCompleted(event.payload);
        break;
      case 'run_started_retry':
        _onRunStartedRetry(event.payload);
        break;
      case 'run_failed':
        _onRunFailed(event.payload);
        break;
      case 'run_cancelled':
        _onRunCancelled(event.payload);
        break;
      case 'run_completed':
        _onRunCompleted();
        break;
      case 'system_note':
        _onSystemNote(event.payload);
        break;
      case 'approval_requested':
        _onApprovalRequested(event.payload);
        break;
      case 'approval_resolved':
        _onApprovalResolved(event.payload);
        break;
      default:
        // Fold-table-absent type: no-op. Covers the LANDED @ovid/shared
        // union members listed in the library doc and any future type.
        //
        // HAZARD for future emitters (P3 carry, review ruling 2): before
        // the full processor landed, run_cancelled was union-only — no
        // emitter — and sat in this branch, which left the projection stuck
        // busy=true with a shimmering live bubble (the reason this switch
        // now folds it like run_failed). Any future terminal-ish event type
        // must update this switch in the same change as its emitter — fold
        // it like run_failed (terminal-settle + busy=false) — or land its
        // own client folding task.
        return;
    }
    target._flushNotify();
  }

  // -------------------------------------------------------------------------
  // Fold-table rows
  // -------------------------------------------------------------------------

  void _onRunStarted(Map<String, dynamic> payload) {
    final runId = _str(payload, 'runId');
    // Double-apply guard: a run_started for the run already active appends
    // exactly one bubble.
    if (runId != null && runId == target._activeRunId) return;
    final now = _clock();
    target._setBusy(true);
    target._setActiveRunId(runId);
    target._setStatusLine(null);
    target._runStartedAt = now;
    target._appendLiveBubble(Message(
      role: 'assistant',
      kind: MsgKind.streaming,
      thinking: true,
      content: '',
      time: now,
    ));
  }

  void _onMessageDelta(Map<String, dynamic> payload) {
    final runId = _str(payload, 'runId');
    final text = _str(payload, 'text');
    if (text == null || text.isEmpty) return;
    // Epoch gate: deltas for any run other than the active one are DROPPED
    // (a stale or post-terminal delta must never land).
    if (runId == null || runId != target._activeRunId) return;
    final live = target._liveBubble;
    if (live == null) return; // no bubble (missed run_started): nowhere to fold
    // First delta of the run: end the thinking phase so the streamed text
    // renders through the answer path, not inside the "Thinking…" card
    // (the flip also snapshots any pre-delta content — `_beginLiveAnswer`).
    target._beginLiveAnswer(live, _clock());
    live.content = live.content + text;
    // Per-token publication: the tick repaints ONLY the live tail row
    // (live-bubble-tick parity) — the one-time thinking flip above is the
    // structural exception, republished through the apply-level flush.
    target.liveBubbleTicks.value++;
  }

  void _onMessageCompleted(Map<String, dynamic> payload) {
    // Double-apply guard (Review Focus #2): message_completed clears
    // activeRunId, so a second application is a no-op.
    if (target._activeRunId == null) return;
    final now = _clock();
    final startedAt = target._runStartedAt;
    int? elapsedMs = startedAt == null
        ? null
        : now.difference(startedAt).inMilliseconds;
    if (elapsedMs != null && elapsedMs < 0) elapsedMs = 0;
    final messageId = _str(payload, 'messageId');
    final finalized = Message(
      role: 'assistant',
      kind: MsgKind.text,
      // Server content/id authoritative (null messageId falls back to the
      // Message ctor's production id).
      content: _str(payload, 'content') ?? '',
      privateSyncId: messageId,
      thinking: false,
      elapsedMs: elapsedMs,
      time: now,
    );
    if (messageId != null &&
        target.messages.any((m) => m.privateSyncId == messageId)) {
      // Task 9 replay overlap: the seeded cache already holds this message.
      target._replaceExistingMessage(messageId, finalized);
    } else {
      target._replaceLiveBubble(finalized);
    }
    target._setActiveRunId(null);
  }

  void _onRunStartedRetry(Map<String, dynamic> payload) {
    final attempt = _int(payload, 'attempt');
    final nextBackoffMs = _int(payload, 'nextBackoffMs');
    if (attempt == null || nextBackoffMs == null) return;
    // Ruling 1 (controller-adopted, fix round 1): the failed attempt's
    // partial is discarded and a FRESH empty bubble re-armed, so the retry
    // streams fresh text (never attempt-N-partial + attempt-N+1 text). On
    // the model_transient_exhausted path NO message_completed ever replaces
    // the bubble, so without this reset the terminal-settle would bake the
    // concatenated partials into a permanent settled row.
    target._resetLiveBubble(Message(
      role: 'assistant',
      kind: MsgKind.streaming,
      thinking: true,
      content: '',
      time: _clock(),
    ));
    target._setStatusLine(
        'Retrying in ${nextBackoffMs ~/ 1000}s… (attempt $attempt)');
    // Stays busy: the run is still in flight (attempt is the one ABOUT to
    // start — runProcessor.ts event contract).
  }

  void _onRunFailed(Map<String, dynamic> payload) {
    final code = _str(payload, 'code');
    final message = _str(payload, 'message');
    target._setBusy(false);
    target._setLastError(code, message);
    // Terminal: the composer must not keep a retry line up for a dead run,
    // and the run is no longer active (a late delta has nowhere to land).
    target._setStatusLine(null);
    target._setActiveRunId(null);
    // A prompt cannot outlive its run — the bridge settles before any
    // terminal, so this only fires on a wire that skipped the resolved
    // event (the defensive belt; run_cancelled shares it through here).
    target._setPendingApproval(null);
    target._settleLiveBubble();
    target._appendMessage(Message(
      role: 'assistant',
      kind: MsgKind.turnTail,
      // Verbatim server string when present; humanText for the pinned codes.
      content: message ?? (code == null ? '' : humanText(code)),
      time: _clock(),
    ));
  }

  /// The full processor's terminal for a user-initiated cancel (loop.ts
  /// `cancelled()`): payload `{runId, reason?}` — no code/message. Folds as
  /// the compat spelling the P2 sink renders for the same cancel,
  /// `run_failed{code:'cancelled', message:CANCELLED_MESSAGE}`: the server's
  /// `reason` verbatim when present, else the pinned copy (the server's
  /// CANCELLED_MESSAGE and [humanText]'s 'cancelled' text are the same
  /// string, 'Stopped by user.'). Delegates to [_onRunFailed] so the two
  /// terminals can never drift apart.
  void _onRunCancelled(Map<String, dynamic> payload) {
    final reason = _str(payload, 'reason');
    _onRunFailed(<String, dynamic>{
      'code': 'cancelled',
      'message': reason ?? humanText('cancelled'),
    });
  }

  void _onRunCompleted() {
    target._setBusy(false);
    target._setStatusLine(null);
    // Terminal (same reasoning as run_failed). Normally a no-op pair: the
    // wire always lands message_completed before run_completed.
    target._setActiveRunId(null);
    // Same prompt-outlives-run belt as _onRunFailed (a resolved question
    // precedes run_completed on the built wire).
    target._setPendingApproval(null);
    target._settleLiveBubble();
  }

  void _onSystemNote(Map<String, dynamic> payload) {
    target._appendMessage(Message(
      role: 'assistant',
      kind: MsgKind.turnTail,
      content: _str(payload, 'text') ?? _str(payload, 'message') ?? '',
      time: _clock(),
    ));
  }

  /// `approval_requested{approvalId,tool,kind,summary,detail,allowAlways,
  /// expiresAt?}` (agent-core approvals.ts — the sink emits BEFORE the bridge
  /// starts its timeout clock, so the card always beats the auto-deny).
  /// Replaces any standing prompt: the gate answers one request at a time,
  /// so a second requested event means the first was settled off-wire (a
  /// replay gap) and the live one is the truth.
  void _onApprovalRequested(Map<String, dynamic> payload) {
    final approvalId = _str(payload, 'approvalId');
    final tool = _str(payload, 'tool');
    // Defensive: a prompt with no answer key could never be cleared.
    if (approvalId == null || approvalId.isEmpty || tool == null) return;
    final rawExpiresAt = payload['expiresAt'];
    target._setPendingApproval(CloudApprovalPrompt(
      approvalId: approvalId,
      tool: tool,
      kind: _str(payload, 'kind') ?? 'tool',
      summary: _str(payload, 'summary') ?? '',
      detail: _str(payload, 'detail') ?? '',
      allowAlways: payload['allowAlways'] == true,
      expiresAt: rawExpiresAt is String ? DateTime.tryParse(rawExpiresAt) : null,
    ));
  }

  /// `approval_resolved{approvalId,decision,reason?}` — exactly one per
  /// prompt (the bridge settles once, first answer wins). Id-matched only:
  /// a resolved for a superseded prompt never clears the live one.
  void _onApprovalResolved(Map<String, dynamic> payload) {
    final live = target._pendingApproval;
    if (live == null) return; // nothing pending (a late/duplicate resolved)
    final approvalId = _str(payload, 'approvalId');
    if (approvalId == null || approvalId != live.approvalId) return;
    target._setPendingApproval(null);
  }

  /// Human text for the run_failed codes whose server payloads carry no
  /// message. Unmapped codes render the code verbatim — never a blank row,
  /// never invented prose.
  @visibleForTesting
  static String humanText(String code) {
    switch (code) {
      case 'cancelled':
        return 'Stopped by user.';
      case 'key_not_minted':
        return 'No model API key is provisioned for this account.';
      default:
        return code;
    }
  }

  // -------------------------------------------------------------------------
  // Defensive payload access
  // -------------------------------------------------------------------------

  static String? _str(Map<String, dynamic> payload, String key) =>
      payload[key] is String ? payload[key] as String : null;

  static int? _int(Map<String, dynamic> payload, String key) =>
      payload[key] is num ? (payload[key] as num).toInt() : null;

  /// Redis stream ids `"<ms>-<idx>"`, compared NUMERICALLY on both parts —
  /// mirrors `WsMultiplexer.compareSeq` (and the gateway's `compareSeq`)
  /// so the projector's exactly-once guard can never diverge from the
  /// multiplexer's dedupe semantics. Duplicated here because that static is
  /// `@visibleForTesting` (production code may not call it). A lexicographic
  /// compare breaks the moment the millisecond part changes width.
  static int _seqCompare(String a, String b) {
    final ap = _seqParts(a);
    final bp = _seqParts(b);
    if (ap.$1 != bp.$1) return ap.$1 < bp.$1 ? -1 : 1;
    if (ap.$2 != bp.$2) return ap.$2 < bp.$2 ? -1 : 1;
    return 0;
  }

  static (int, int) _seqParts(String seq) {
    final dash = seq.indexOf('-');
    final ms = int.tryParse(dash == -1 ? seq : seq.substring(0, dash)) ?? 0;
    final idx =
        int.tryParse(dash == -1 ? '0' : seq.substring(dash + 1)) ?? 0;
    return (ms, idx);
  }
}
