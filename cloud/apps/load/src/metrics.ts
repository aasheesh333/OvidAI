import type { SessionEvent } from "@ovid/shared";

/**
 * Metrics primitives for the load harness.
 *
 * Everything here is pure and deterministic: no clocks, no I/O. The scenario
 * layer owns sampling; this layer owns the arithmetic, so the latency-floor
 * and integrity tests can pin exact values.
 */

/** One delivered event as observed by a load client. */
export interface ReceivedEvent {
  event: SessionEvent;
  /** Client wall clock (Date.now()) at the moment the frame was accepted. */
  receivedAtMs: number;
}

export interface EventDeliveryStats {
  p50Ms: number;
  p95Ms: number;
  p99Ms: number;
  samples: number;
}

export interface IntegrityDiff {
  /** Ground-truth seqs that never reached the client. */
  lostEvents: number;
  /** Extra deliveries beyond the first for the same seq. */
  duplicateEvents: number;
  /** Ground-truth seqs absent from the Postgres session_event_mirror. */
  gapsVsMirror: number;
}

/**
 * One run the gateway accepted (`202 {status:"queued"}`). `acceptedAtMs` is
 * the client's wall clock when the send response arrived — the start of the
 * "accepted but not started" window used for the admission backlog metric.
 */
export interface AcceptedRun {
  runId: string;
  sessionId: string;
  acceptedAtMs: number;
}

export interface AdmissionDerivation {
  /**
   * Peak concurrent `tool_started` events across ALL sessions (deduped by
   * seq), decremented by `tool_completed`. This is concurrent sandbox-backed
   * tool execution, not a worker-internal sandbox gauge.
   */
  maxObservedActiveSandboxes: number;
  /**
   * Peak accepted-but-not-started runs (gateway accepted, no `run_started`
   * and no terminal event yet). This is a real backlog measurement, but it
   * covers BOTH the per-session turn queue and the sandbox admission queue:
   * the SandboxManager's queue depth is not exposed over any wire surface.
   */
  queuedAtCap: number;
  /** `run_failed` events whose code is an admission rejection. */
  rejectedAtCap: number;
  /** Rejection counts by code (`sandbox_unavailable` / `sandbox_busy`). */
  rejectedCodes: Record<string, number>;
  /** Accepted runs that never produced a start or terminal event. */
  acceptedNotTerminal: number;
}

/** Run-level admission failure codes (the REAL surface; not PTY WS errors). */
const ADMISSION_FAILURE_CODES = new Set(["sandbox_unavailable", "sandbox_busy"]);

/**
 * Derive admission metrics from the event stream the clients already record.
 *
 * Rejections come from `run_failed` events (`payload.code`), never from
 * `clients[].errors` — those are WS `{op:"error"}` frames and the sandbox
 * codes there belong to the pty_open path. The queue metric is the peak
 * accepted-not-started window: a genuine observation of backlog, with the
 * documented limitation that the event stream cannot separate the session
 * turn queue from the sandbox admission queue.
 */
export function deriveAdmissionMetrics(
  received: ReceivedEvent[],
  acceptedRuns: AcceptedRun[],
  endedAtMs: number,
): AdmissionDerivation {
  // A reconnect replay can redeliver a seq; the first receipt is the truth.
  const bySeq = new Map<string, ReceivedEvent>();
  for (const item of received) {
    if (!bySeq.has(item.event.seq)) bySeq.set(item.event.seq, item);
  }
  const events = [...bySeq.values()].sort((a, b) => a.receivedAtMs - b.receivedAtMs);

  const firstStart = new Map<string, number>();
  const firstTerminal = new Map<string, number>();
  const rejectedCodes: Record<string, number> = {};
  let rejectedAtCap = 0;
  let active = 0;
  let maxActive = 0;

  // Pending accepted runs per session, oldest first. Used to attribute a
  // terminal `run_failed` that carries no runId (the worker's admission path
  // emits `{code:"sandbox_unavailable"}` without one) to the run it can only
  // have been for. Attribution is a heuristic, but it is strictly better than
  // letting the run look permanently queued.
  const pendingBySession = new Map<string, AcceptedRun[]>();
  for (const run of [...acceptedRuns].sort((a, b) => a.acceptedAtMs - b.acceptedAtMs)) {
    const list = pendingBySession.get(run.sessionId) ?? [];
    list.push(run);
    pendingBySession.set(run.sessionId, list);
  }
  const removePending = (sessionId: string, runId: string): void => {
    const list = pendingBySession.get(sessionId);
    if (list === undefined) return;
    const index = list.findIndex((run) => run.runId === runId);
    if (index >= 0) list.splice(index, 1);
  };

  for (const item of events) {
    const event = item.event;
    if (event.type === "tool_started") {
      active += 1;
      maxActive = Math.max(maxActive, active);
    } else if (event.type === "tool_completed") {
      active = Math.max(0, active - 1);
    }

    const payloadRunId = event.payload.runId;
    const runId = typeof payloadRunId === "string" && payloadRunId !== "" ? payloadRunId : null;

    if (event.type === "run_started") {
      if (runId !== null) {
        if (!firstStart.has(runId)) firstStart.set(runId, item.receivedAtMs);
        removePending(event.sessionId, runId);
      }
      continue;
    }

    if (event.type === "run_completed" || event.type === "run_failed") {
      if (event.type === "run_failed") {
        const code = event.payload.code;
        if (typeof code === "string" && ADMISSION_FAILURE_CODES.has(code)) {
          rejectedAtCap += 1;
          rejectedCodes[code] = (rejectedCodes[code] ?? 0) + 1;
        }
      }

      if (runId !== null) {
        if (!firstTerminal.has(runId)) firstTerminal.set(runId, item.receivedAtMs);
        removePending(event.sessionId, runId);
      } else if (event.type === "run_failed") {
        // Unattributed terminal failure: attribute it to the oldest accepted
        // run on this session that had already been accepted when it arrived.
        const list = pendingBySession.get(event.sessionId);
        const pending = list?.find((run) => run.acceptedAtMs <= item.receivedAtMs);
        if (pending !== undefined && list !== undefined) {
          list.splice(list.indexOf(pending), 1);
          if (!firstTerminal.has(pending.runId)) {
            firstTerminal.set(pending.runId, item.receivedAtMs);
          }
        }
      }
    }
  }

  // Peak accepted-not-started: +1 at acceptance, -1 at first start/terminal
  // (or at the end of the run for a run that never produced either).
  const deltas: Array<{ at: number; delta: number }> = [];
  let acceptedNotTerminal = 0;
  for (const run of acceptedRuns) {
    const start = firstStart.get(run.runId);
    const terminal = firstTerminal.get(run.runId);
    if (start === undefined && terminal === undefined) acceptedNotTerminal += 1;
    const stop = start ?? terminal ?? endedAtMs;
    const begin = Math.min(run.acceptedAtMs, stop);
    deltas.push({ at: begin, delta: 1 });
    deltas.push({ at: stop, delta: -1 });
  }
  // At the same millisecond, apply the end before the start so a run that
  // starts exactly when another is accepted does not inflate the peak.
  deltas.sort((a, b) => a.at - b.at || a.delta - b.delta);
  let queued = 0;
  let maxQueued = 0;
  for (const entry of deltas) {
    queued += entry.delta;
    maxQueued = Math.max(maxQueued, queued);
  }

  return {
    maxObservedActiveSandboxes: maxActive,
    queuedAtCap: maxQueued,
    rejectedAtCap,
    rejectedCodes,
    acceptedNotTerminal,
  };
}

/**
 * Nearest-rank percentile (the plan pins `percentile([1..100], 95) === 95`).
 * Sorts a copy — the caller's array is never mutated. An empty sample is a
 * bug in the caller (a "0ms p95" would silently pass a threshold), so it
 * throws rather than lying.
 */
export function percentile(values: number[], p: number): number {
  if (values.length === 0) {
    throw new Error("percentile: empty sample");
  }
  if (!Number.isFinite(p) || p < 0 || p > 100) {
    throw new Error(`percentile: p must be within [0, 100] (got ${p})`);
  }
  const sorted = [...values].sort((a, b) => a - b);
  // Nearest-rank: ceil(p/100 * N), clamped to the sample bounds.
  const rank = Math.ceil((p / 100) * sorted.length);
  const index = Math.min(sorted.length - 1, Math.max(0, rank - 1));
  return sorted[index]!;
}

/**
 * End-to-end delivery latency: server append timestamp (`event.ts`) to the
 * client's acceptance time. Negative deltas can only come from clock skew
 * between generator and server; clamping to 0 keeps the percentile honest
 * without hiding the sample count.
 */
export function deliveryLatencies(received: ReceivedEvent[]): number[] {
  const out: number[] = [];
  for (const item of received) {
    const ts = Date.parse(item.event.ts);
    if (!Number.isFinite(ts)) continue; // malformed ts is not a latency sample
    out.push(Math.max(0, item.receivedAtMs - ts));
  }
  return out;
}

export function eventDeliveryStats(received: ReceivedEvent[]): EventDeliveryStats {
  const latencies = deliveryLatencies(received);
  if (latencies.length === 0) {
    return { p50Ms: 0, p95Ms: 0, p99Ms: 0, samples: 0 };
  }
  return {
    p50Ms: percentile(latencies, 50),
    p95Ms: percentile(latencies, 95),
    p99Ms: percentile(latencies, 99),
    samples: latencies.length,
  };
}

/**
 * Compare what a client actually received with the event-log ground truth
 * (`EventLog.readSince`) and, when available, the Postgres mirror.
 *
 * - `lostEvents`: ground-truth seqs the client never saw.
 * - `duplicateEvents`: deliveries beyond the first for a seq (a replay that
 *   overlapped live delivery).
 * - `gapsVsMirror`: ground-truth seqs the mirror never recorded (a torn
 *   append+mirror pair). Defaults to comparing against the ground truth
 *   itself, i.e. "no mirror supplied ⇒ no gap observable".
 *
 * Duplicates are counted per repeated delivery, so a triple delivery counts
 * as two duplicates — the client's buffer must be exactly lossless.
 */
export function diffIntegrity(
  deliveredSeqs: string[],
  groundTruthSeqs: string[],
  mirrorSeqs: string[] = groundTruthSeqs,
): IntegrityDiff {
  const deliveredCounts = new Map<string, number>();
  for (const seq of deliveredSeqs) {
    deliveredCounts.set(seq, (deliveredCounts.get(seq) ?? 0) + 1);
  }

  const truth = new Set(groundTruthSeqs);
  let lostEvents = 0;
  for (const seq of truth) {
    if (!deliveredCounts.has(seq)) lostEvents += 1;
  }

  let duplicateEvents = 0;
  for (const count of deliveredCounts.values()) {
    if (count > 1) duplicateEvents += count - 1;
  }

  const mirror = new Set(mirrorSeqs);
  let gapsVsMirror = 0;
  for (const seq of truth) {
    if (!mirror.has(seq)) gapsVsMirror += 1;
  }

  return { lostEvents, duplicateEvents, gapsVsMirror };
}

/** Numeric comparison for Redis stream ids ("ms-idx"); exported for scenario use. */
export function compareSeq(a: string, b: string): number {
  const [aMs = 0, aIdx = 0] = a.split("-").map(Number);
  const [bMs = 0, bIdx = 0] = b.split("-").map(Number);
  if (aMs !== bMs) return aMs < bMs ? -1 : 1;
  if (aIdx !== bIdx) return aIdx < bIdx ? -1 : 1;
  return 0;
}
