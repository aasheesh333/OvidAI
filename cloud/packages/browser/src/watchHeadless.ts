/**
 * Watch-inactivity → headless (product spec §8: "Closing the viewer for 45
 * seconds puts the browser in headless mode; the run continues and the user is
 * notified").
 *
 * The engine already has a detach grace window for the case where the LAST
 * viewer leaves (`detachGrace.ts`). This module covers the other half of the
 * contract: a viewer is still attached ("watching") but has sent no human
 * input for the idle window. At expiry the page goes HEADLESS — frame
 * streaming stops, the session/context stays alive — and the next
 * human activity ("Take control" or any viewer input) resumes streaming and
 * re-arms the window.
 *
 * Pure scheduling: no Playwright, no Redis, so the 45 s boundary is testable
 * with a fake clock. The engine supplies `onHeadless` (stop the cast, publish
 * state) and `onResume` (start the cast, publish state).
 */

/** Spec §8 default: 45 s of no human input while watched → headless. */
export const WATCH_IDLE_HEADLESS_MS = 45_000;

export interface WatchHeadlessController {
  /** A viewer attached (or re-attached). Resumes from headless and arms the window. */
  viewerJoined(sessionId: string): void;
  /** The last viewer left. Cancels the inactivity timer (detach grace owns that path). */
  viewerLeft(sessionId: string): void;
  /** Any human input (pointer/key/tab switch) — re-arms while watching. */
  humanActivity(sessionId: string): void;
  /** "Take control": leave headless immediately, resume streaming, arm the window. */
  takeControl(sessionId: string): void;
  /** Takeover released: the page is agent-owned again but still watched; re-arm. */
  releaseControl(sessionId: string): void;
  /** True while the page is headless (streaming stopped, session alive). */
  isHeadless(sessionId: string): boolean;
  /** True while an inactivity timer is pending (diagnostics + tests). */
  pending(sessionId: string): boolean;
  /** Every session currently headless (diagnostics + tests). */
  headlessSessions(): string[];
  /** Drop one session's state/timer (release/eviction). */
  forget(sessionId: string): void;
  /** Cancel every timer and forget all state (engine close). */
  clear(): void;
}

export interface WatchHeadlessOptions {
  /** Idle window in milliseconds. <= 0 disables the conversion (tests/tight boxes). */
  idleMs?: number;
  /** Called exactly once per idle expiry, while the viewer is still watching. */
  onHeadless(sessionId: string): void;
  /** Called when a headless session becomes watched/controlled again. */
  onResume?(sessionId: string): void;
  /** Test seams; production uses the global timer functions. */
  setTimeout?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimeout?: (handle: ReturnType<typeof setTimeout>) => void;
}

interface WatchState {
  watching: boolean;
  headless: boolean;
  timer: ReturnType<typeof setTimeout> | null;
}

export function createWatchHeadless(opts: WatchHeadlessOptions): WatchHeadlessController {
  const idleMs = opts.idleMs ?? WATCH_IDLE_HEADLESS_MS;
  const setTimer = opts.setTimeout ?? setTimeout;
  const clearTimer = opts.clearTimeout ?? clearTimeout;
  const states = new Map<string, WatchState>();

  function stateOf(sessionId: string): WatchState {
    let state = states.get(sessionId);
    if (state === undefined) {
      state = { watching: false, headless: false, timer: null };
      states.set(sessionId, state);
    }
    return state;
  }

  function cancelTimer(state: WatchState): void {
    if (state.timer === null) return;
    clearTimer(state.timer);
    state.timer = null;
  }

  /** Arm (or re-arm) the idle window. No-op when unwatched or disabled. */
  function arm(sessionId: string, state: WatchState): void {
    cancelTimer(state);
    if (!state.watching || state.headless || idleMs <= 0) return;
    const timer = setTimer(() => {
      // Delete BEFORE the callback so a re-entrant resume/activity sees a
      // clean slot (the callback publishes state, which can re-enter).
      if (state.timer === timer) state.timer = null;
      if (!state.watching || state.headless) return;
      state.headless = true;
      opts.onHeadless(sessionId);
    }, idleMs);
    // Never keep a worker process alive for an inactivity window.
    (timer as { unref?: () => void }).unref?.();
    state.timer = timer;
  }

  function resume(sessionId: string, state: WatchState): void {
    if (!state.headless) return;
    state.headless = false;
    opts.onResume?.(sessionId);
  }

  return {
    viewerJoined(sessionId: string): void {
      const state = stateOf(sessionId);
      state.watching = true;
      // A re-opened viewer on a headless page gets the stream back at once.
      resume(sessionId, state);
      arm(sessionId, state);
    },

    viewerLeft(sessionId: string): void {
      const state = stateOf(sessionId);
      state.watching = false;
      cancelTimer(state);
    },

    humanActivity(sessionId: string): void {
      const state = stateOf(sessionId);
      if (!state.watching) return;
      // Input implies the human is back: leave headless and resume streaming.
      resume(sessionId, state);
      arm(sessionId, state);
    },

    takeControl(sessionId: string): void {
      const state = stateOf(sessionId);
      // Take-control implies watching even if a join was missed.
      state.watching = true;
      resume(sessionId, state);
      arm(sessionId, state);
    },

    releaseControl(sessionId: string): void {
      const state = stateOf(sessionId);
      if (!state.watching) return;
      arm(sessionId, state);
    },

    isHeadless: (sessionId: string) => states.get(sessionId)?.headless === true,
    pending: (sessionId: string) => states.get(sessionId)?.timer !== null && states.get(sessionId)?.timer !== undefined,
    headlessSessions: () => [...states.entries()].filter(([, state]) => state.headless).map(([sessionId]) => sessionId),
    forget(sessionId: string): void {
      const state = states.get(sessionId);
      if (state === undefined) return;
      cancelTimer(state);
      states.delete(sessionId);
    },
    clear(): void {
      for (const state of states.values()) cancelTimer(state);
      states.clear();
    },
  };
}
