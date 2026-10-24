import type {
  CollabEventPage,
  CollabPageInput,
  CollabProjectionReader,
} from "./projection.js";

export interface CollabLongPollInput extends CollabPageInput {
  waitSeconds: number;
  signal: AbortSignal;
}

export interface CollabLongPollOptions {
  now?: () => number;
  pollIntervalMs?: number;
  /** Bounded test/transport seam; production uses an abortable timer. */
  sleep?: (milliseconds: number, signal: AbortSignal) => Promise<void>;
  /** A notification is only a wake hint; it never supplies event authority. */
  wake?: (roomId: string, signal: AbortSignal) => Promise<void>;
}

function abortReason(signal: AbortSignal): Error {
  return signal.reason instanceof Error
    ? signal.reason
    : new DOMException("The operation was aborted.", "AbortError");
}

function throwIfAborted(signal: AbortSignal): void {
  if (signal.aborted) throw abortReason(signal);
}

function delay(milliseconds: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const onAbort = () => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      reject(abortReason(signal));
    };
    const timer = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, milliseconds);
    signal.addEventListener("abort", onAbort, { once: true });
  });
}

function clampLimit(value: number): number {
  if (value === Number.POSITIVE_INFINITY) return 100;
  const integer = Math.trunc(value);
  if (!Number.isFinite(integer)) return 1;
  return Math.min(100, Math.max(1, integer));
}

function clampWaitMilliseconds(value: number): number {
  if (Number.isNaN(value) || value <= 0) return 0;
  if (value === Number.POSITIVE_INFINITY) return 25_000;
  return Math.trunc(Math.min(25, value) * 1000);
}

async function waitForHint(
  roomId: string,
  milliseconds: number,
  signal: AbortSignal,
  options: CollabLongPollOptions,
): Promise<void> {
  const linked = new AbortController();
  let rejectAborted!: (reason: Error) => void;
  const aborted = new Promise<never>((_resolve, reject) => {
    rejectAborted = reject;
  });
  const onAbort = () => {
    const reason = abortReason(signal);
    linked.abort(reason);
    rejectAborted(reason);
  };
  signal.addEventListener("abort", onAbort, { once: true });
  try {
    const sleeping = (options.sleep ?? delay)(milliseconds, linked.signal);
    const waking = options.wake?.(roomId, linked.signal);
    if (waking === undefined) await Promise.race([sleeping, aborted]);
    else await Promise.race([sleeping, waking, aborted]);
    throwIfAborted(signal);
  } finally {
    signal.removeEventListener("abort", onAbort);
    // Also releases a notification listener when the bounded timer wins.
    linked.abort();
  }
}

function unchangedIfEmpty(page: CollabEventPage, cursor: string | null): CollabEventPage {
  if (page.events.length > 0 || page.hasMore) return page;
  return { ...page, nextCursor: cursor ?? "v1:0" };
}

/**
 * Bounded authoritative long poll. Every sleep and every final empty answer is
 * bracketed by fresh projection reads, whose own authorization is rechecked.
 */
export async function longPoll(
  projection: CollabProjectionReader,
  input: CollabLongPollInput,
  options: CollabLongPollOptions = {},
): Promise<CollabEventPage> {
  const { waitSeconds, signal, ...rest } = input;
  const pageInput: CollabPageInput = { ...rest, limit: clampLimit(rest.limit) };
  const now = options.now ?? Date.now;
  const interval = Math.max(1, options.pollIntervalMs ?? 1000);
  const waitMilliseconds = clampWaitMilliseconds(waitSeconds);

  throwIfAborted(signal);
  let page = await projection.page(pageInput);
  throwIfAborted(signal);
  if (page.events.length > 0 || page.hasMore || waitMilliseconds === 0) {
    return unchangedIfEmpty(page, pageInput.cursor);
  }

  const deadline = now() + waitMilliseconds;
  while (true) {
    throwIfAborted(signal);
    // Required immediately before sleeping, and again before an empty answer.
    page = await projection.page(pageInput);
    throwIfAborted(signal);
    if (page.events.length > 0 || page.hasMore) return page;

    const remaining = deadline - now();
    if (remaining <= 0) return unchangedIfEmpty(page, pageInput.cursor);
    await waitForHint(
      pageInput.roomId,
      Math.min(remaining, interval),
      signal,
      options,
    );
  }
}
