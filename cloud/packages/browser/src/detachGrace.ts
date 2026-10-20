/**
 * Wave 6 W4 — the detach grace window.
 *
 * Owner rule R3 used to mean "the last viewer leaving stops the screencast
 * immediately". The master spec (§3 Screen 3) asks for 45 s of continued
 * rendering: closing the Browser screen (or backgrounding the app) must not
 * flash a dead canvas when the user re-opens a second later. So the engine
 * keeps the cast running for `graceMs` after the viewer count reaches zero,
 * then converts the browser to headless (frames stop; the context itself
 * stays alive under the pool's normal idle lease).
 *
 * This module is pure scheduling — no Playwright, no Redis — so the timing
 * contract is testable with a fake clock. The engine supplies the expiry
 * action (stop the cast + publish state).
 */

export interface DetachGraceController {
  /**
   * Arm the window for `sessionId`. Re-arming replaces the pending timer
   * (the latest leave restarts the full window). `graceMs <= 0` expires
   * immediately, preserving the pre-W4 behaviour for tests/tight boxes.
   */
  schedule(sessionId: string, onExpire: () => void): void;
  /** A viewer came back: keep the cast, drop the pending conversion. */
  cancel(sessionId: string): void;
  /** True while a conversion is pending (the pool must not idle-evict). */
  pending(sessionId: string): boolean;
  /** Cancel every pending timer (engine close / session teardown). */
  clear(): void;
  /** Number of pending timers (diagnostics + tests). */
  size(): number;
}

export interface DetachGraceOptions {
  /** Window length in milliseconds. */
  graceMs: number;
  /** Test seams; production uses the global timer functions. */
  setTimeout?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimeout?: (handle: ReturnType<typeof setTimeout>) => void;
}

export function createDetachGrace(opts: DetachGraceOptions): DetachGraceController {
  const graceMs = opts.graceMs;
  const setTimer = opts.setTimeout ?? setTimeout;
  const clearTimer = opts.clearTimeout ?? clearTimeout;
  const timers = new Map<string, ReturnType<typeof setTimeout>>();

  function cancel(sessionId: string): void {
    const timer = timers.get(sessionId);
    if (timer === undefined) return;
    timers.delete(sessionId);
    clearTimer(timer);
  }

  return {
    schedule(sessionId: string, onExpire: () => void): void {
      cancel(sessionId);
      if (graceMs <= 0) {
        // Still record the intent for one tick? No: an immediate conversion
        // is synchronous, exactly like the pre-W4 detach path.
        onExpire();
        return;
      }
      const timer = setTimer(() => {
        // Delete BEFORE running the action so a re-entrant schedule from the
        // action (unlikely, but stopScreencast publishes state) sees a clean
        // slot.
        if (timers.get(sessionId) === timer) timers.delete(sessionId);
        onExpire();
      }, graceMs);
      // Never keep a worker process alive for a grace window.
      (timer as { unref?: () => void }).unref?.();
      timers.set(sessionId, timer);
    },
    cancel,
    pending: (sessionId: string) => timers.has(sessionId),
    clear(): void {
      for (const timer of timers.values()) clearTimer(timer);
      timers.clear();
    },
    size: () => timers.size,
  };
}
