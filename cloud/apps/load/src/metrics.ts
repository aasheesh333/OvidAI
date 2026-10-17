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
