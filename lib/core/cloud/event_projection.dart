/// Client-side transcript projection for Ovid Cloud session events (P8 Task 7).
///
/// Folds the multiplexer's (already seq-deduped) [CloudSessionEvent] stream
/// for ONE session into the existing KEPT transcript model (`Message` /
/// `MsgKind`, lib/core/state.dart) — the thin client's replacement for
/// AgentService's in-process streaming pipeline. Task 8's `CloudAgentFacade`
/// creates one [TranscriptProjection] + [EventTranscriptProjector] per
/// session and feeds it from `WsMultiplexer.subscribe(sessionId)`; the
/// projector itself does no routing and no I/O.
///
/// The fold table is the binding contract (plan Task 7):
///
/// | Event | Projection |
/// |---|---|
/// | `run_started{runId}` | busy=true, activeRunId, live `streaming` bubble, statusLine cleared |
/// | `message_delta{runId,text}` | epoch-gated append into the bubble's content + [TranscriptProjection.liveBubbleTicks] tick |
/// | `message_completed{messageId,content}` | bubble REPLACED by the server-authoritative text Message; activeRunId cleared (the double-apply guard) |
/// | `run_started_retry{attempt,nextBackoffMs}` | the composer status line; stays busy |
/// | `run_failed{code,message?}` | busy=false, error fields, turn-tail row |
/// | `run_completed{runId}` | busy=false, statusLine cleared |
/// | `system_note` | turn-tail row |
///
/// Every OTHER event type is a NO-OP (forward compatibility): the LANDED
/// @ovid/shared union members the table does not cover yet (tool_started,
/// tool_completed, artifact_created, workspace_hibernated, workspace_hydrated,
/// approval_requested, approval_resolved, todo_updated, goal_updated,
/// plan_mode_changed, run_cancelled, subagent_started, subagent_completed,
/// compaction_completed) and any future type — later P8+ tasks fold them.
///
/// Payload field names mirror the BUILT emitters exactly (camelCase):
/// cloud/apps/worker/src/runProcessor.ts (event-contract block). The server
/// is the contract; when this file and the server disagree, fix this file.
library;

import 'package:flutter/foundation.dart';

import '../state.dart';
import 'cloud_ws.dart';

/// The transcript + run-status state for ONE cloud session, folded from
/// session events. Structural transcript changes (append / replace / settle /
/// seed) notify listeners; per-delta content growth does NOT — it publishes
/// through [liveBubbleTicks] instead, exactly like AgentService's live-bubble
/// tick, so a streaming token repaints only the tail row, never every widget
/// listening to this notifier.
class TranscriptProjection extends ChangeNotifier {
  /// The transcript for this session, oldest-first.
  final List<Message> messages = <Message>[];

  /// Ticks once per accepted `message_delta` so only the live tail bubble
  /// repaints. Replaces AgentService.liveBubbleTicksFor (Task 8).
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

  void _appendMessage(Message m) {
    messages.add(m);
    _changed = true;
  }

  /// Settles the live streaming bubble: one with partial content is promoted
  /// to a settled text row (the partial output stays visible — AgentService
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
      case 'run_completed':
        _onRunCompleted();
        break;
      case 'system_note':
        _onSystemNote(event.payload);
        break;
      default:
        // Fold-table-absent type: no-op. Covers the LANDED @ovid/shared
        // union members listed in the library doc and any future type.
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
    live.content = live.content + text;
    // Per-token publication: the tick repaints ONLY the live tail row
    // (AgentService liveBubbleTicks parity) — no notifyListeners here.
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
    target._replaceLiveBubble(Message(
      role: 'assistant',
      kind: MsgKind.text,
      // Server content/id authoritative (null messageId falls back to the
      // Message ctor's production id).
      content: _str(payload, 'content') ?? '',
      privateSyncId: _str(payload, 'messageId'),
      thinking: false,
      elapsedMs: elapsedMs,
      time: now,
    ));
    target._setActiveRunId(null);
  }

  void _onRunStartedRetry(Map<String, dynamic> payload) {
    final attempt = _int(payload, 'attempt');
    final nextBackoffMs = _int(payload, 'nextBackoffMs');
    if (attempt == null || nextBackoffMs == null) return;
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
    target._settleLiveBubble();
    target._appendMessage(Message(
      role: 'assistant',
      kind: MsgKind.turnTail,
      // Verbatim server string when present; humanText for the pinned codes.
      content: message ?? (code == null ? '' : humanText(code)),
      time: _clock(),
    ));
  }

  void _onRunCompleted() {
    target._setBusy(false);
    target._setStatusLine(null);
    // Terminal (same reasoning as run_failed). Normally a no-op pair: the
    // wire always lands message_completed before run_completed.
    target._setActiveRunId(null);
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
