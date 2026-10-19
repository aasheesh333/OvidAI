/**
 * message_delta coalescer (capacity wave 2026-10-19).
 *
 * Every `message_delta` costs an XADD + PUBLISH on redis-q, an INSERT into
 * `session_event_mirror`, and one WS frame per subscriber. Providers stream
 * roughly one token per SSE chunk, so at 30–80 tok/s × hundreds of
 * concurrent runs the per-token event — not the model — becomes the box's
 * hottest path (measured: ~13.5k events/s at 1800 active users).
 *
 * Contract (unchanged for clients): deltas are emitted strictly in arrival
 * order and their concatenation is byte-identical to the provider's text.
 * Only the chunking changes:
 *
 *   • the FIRST delta of a stream goes out immediately (time-to-first-token
 *     is never delayed);
 *   • later deltas are merged into one event at most every `windowMs`;
 *   • while an emit is in flight further text accumulates (natural
 *     backpressure — a slow redis/Postgres merges more instead of queueing
 *     one promise per token);
 *   • `drain()` flushes the remainder and resolves once every emit landed,
 *     rejecting with the first emit error (same surfacing point as the old
 *     per-delta promise chain's `await flushed`).
 *
 * `windowMs = 0` restores per-delta events, except that text arriving while
 * an emit is in flight is still merged (never reordered or dropped).
 */
export interface DeltaCoalescer {
  push(text: string): void;
  drain(): Promise<void>;
}

export interface DeltaCoalescerOptions {
  windowMs: number;
  /** Test seam. */
  setTimer?: (fn: () => void, ms: number) => unknown;
  clearTimer?: (handle: unknown) => void;
  now?: () => number;
}

export const DEFAULT_DELTA_COALESCE_MS = 50;

/** OVID_DELTA_COALESCE_MS (0–1000, default 50). Bad values throw at boot. */
export function deltaCoalesceMsFromEnv(env: NodeJS.ProcessEnv): number {
  const raw = env.OVID_DELTA_COALESCE_MS;
  if (raw === undefined || raw.trim() === "") return DEFAULT_DELTA_COALESCE_MS;
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 0 || n > 1000) {
    throw new Error(`OVID_DELTA_COALESCE_MS must be an integer 0..1000, got: ${raw}`);
  }
  return n;
}

export function createDeltaCoalescer(
  emitText: (text: string) => Promise<void>,
  opts: DeltaCoalescerOptions,
): DeltaCoalescer {
  const windowMs = Math.max(0, opts.windowMs);
  const setTimer = opts.setTimer ?? ((fn, ms) => setTimeout(fn, ms));
  const clearTimer = opts.clearTimer ?? ((h) => clearTimeout(h as ReturnType<typeof setTimeout>));
  const now = opts.now ?? Date.now;

  let buffer = "";
  let inFlight: Promise<void> | null = null;
  let timer: unknown = null;
  let lastEmitAt = Number.NEGATIVE_INFINITY;
  let failure: unknown = null;
  let failed = false;

  const flush = (): void => {
    timer = null;
    if (inFlight !== null || buffer === "") return;
    const text = buffer;
    buffer = "";
    lastEmitAt = now();
    // `new Promise(r => r(...))` runs emitText NOW (no extra tick before the
    // first token) and turns a synchronous throw into a rejection.
    inFlight = (failed ? Promise.resolve() : new Promise<void>((r) => r(emitText(text)))).then(
      () => undefined,
      (err: unknown) => {
        if (!failed) {
          failed = true;
          failure = err;
        }
      },
    );
    void inFlight.then(() => {
      inFlight = null;
      if (buffer !== "") schedule();
    });
  };

  const schedule = (): void => {
    if (timer !== null || inFlight !== null) return;
    const wait = Math.max(0, lastEmitAt + windowMs - now());
    if (wait === 0) flush();
    else timer = setTimer(flush, wait);
  };

  return {
    push(text) {
      if (text === "") return;
      buffer += text;
      schedule();
    },
    async drain() {
      // Flush whatever is buffered now, bypassing the window; loop until
      // nothing is buffered or in flight (an in-flight completion may have
      // armed a window timer for text that arrived meanwhile — cancel it).
      for (;;) {
        if (timer !== null) {
          clearTimer(timer);
          timer = null;
        }
        if (inFlight !== null) {
          await inFlight;
          continue;
        }
        if (buffer !== "") {
          flush();
          continue;
        }
        break;
      }
      if (failed) throw failure;
    },
  };
}
