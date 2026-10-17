/**
 * Reconnect backoff for MCP transports: exponential 500ms → 30s with a hard
 * 10-attempt ceiling, pure timer logic behind an injectable `schedule` so
 * tests pin the sequence without real timers. The owner (router/session
 * manager, not the transport) drives it from onClose({expected: false}).
 */

export const RECONNECT_INITIAL_MS = 500;
export const RECONNECT_MAX_MS = 30_000;
export const RECONNECT_MAX_ATTEMPTS = 10;

export interface ReconnectorOptions {
  /** Attempt a reconnect. Resolves true on success, false/throw on failure. */
  connect: () => Promise<boolean>;
  initialMs?: number;
  maxMs?: number;
  maxAttempts?: number;
  /** Test seam; default is setTimeout + unref. Returns a cancel fn. */
  schedule?: (ms: number, fn: () => void) => () => void;
}

const defaultSchedule = (ms: number, fn: () => void): (() => void) => {
  const timer = setTimeout(fn, ms);
  // Keep the event loop free while a reconnect is pending.
  (timer as { unref?: () => void }).unref?.();
  return () => clearTimeout(timer);
};

export class McpReconnector {
  private readonly connect: () => Promise<boolean>;
  private readonly initialMs: number;
  private readonly maxMs: number;
  private readonly maxAttempts: number;
  private readonly schedule: (ms: number, fn: () => void) => () => void;
  private _attempts = 0;
  private cancelTimer: (() => void) | null = null;

  constructor(opts: ReconnectorOptions) {
    this.connect = opts.connect;
    this.initialMs = opts.initialMs ?? RECONNECT_INITIAL_MS;
    this.maxMs = opts.maxMs ?? RECONNECT_MAX_MS;
    this.maxAttempts = opts.maxAttempts ?? RECONNECT_MAX_ATTEMPTS;
    this.schedule = opts.schedule ?? defaultSchedule;
  }

  /** Attempts scheduled since the last reset (0 = healthy). */
  get attempts(): number {
    return this._attempts;
  }

  /**
   * An unexpected disconnect happened: schedule a connect attempt at
   * clamp(initial * 2^(attempt-1), initial, max). Past maxAttempts the call
   * gives up silently — no throw, no timer.
   */
  scheduleUnexpected(): void {
    if (this._attempts >= this.maxAttempts) return; // gave up silently
    this._attempts++;
    const delay = Math.max(
      this.initialMs,
      Math.min(this.initialMs * 2 ** (this._attempts - 1), this.maxMs),
    );
    // Only one pending reconnect at a time: a fresh unexpected disconnect
    // replaces the pending timer (the attempt counter keeps climbing).
    this.cancelTimer?.();
    this.cancelTimer = this.schedule(delay, () => {
      this.cancelTimer = null;
      this.connect()
        .then((ok) => {
          if (ok) {
            this.markConnected();
          } else {
            this.scheduleUnexpected();
          }
        })
        .catch(() => this.scheduleUnexpected());
    });
  }

  /** User-initiated disconnect: clear the pending timer AND the counter. */
  cancel(): void {
    this.cancelTimer?.();
    this.cancelTimer = null;
    this._attempts = 0;
  }

  /** A connect attempt (or any observed success) resets the counter. */
  markConnected(): void {
    this._attempts = 0;
  }
}
