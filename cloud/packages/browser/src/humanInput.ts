/**
 * Human-like input for AGENT-driven browser actions (product spec §8: "The
 * agent drives like a human: scroll, hover, type with delays, no parallel
 * clicks").
 *
 * Two concerns live here:
 *
 *  1. Planning — pure functions turn a start/end point into an interpolated,
 *     jittered pointer path, and a string into per-key delays. A seeded RNG
 *     makes both plans byte-for-byte reproducible in tests.
 *  2. Playback — a `Humanizer` walks the plan against Playwright's mouse and
 *     keyboard, sleeping between steps. `sleep` is injectable so tests do not
 *     spend wall-clock time.
 *
 * Viewer input (`input.ts`) is deliberately NOT routed through this module:
 * a real finger/mouse event is already human. This is only for the agent.
 */

import type { Page } from "playwright-core";

export interface Point {
  x: number;
  y: number;
}

/** One interpolated pointer position plus the pause that precedes it. */
export interface PointerStep extends Point {
  delayMs: number;
}

export interface PointerPathOptions {
  /** Interpolation steps (default scales with distance, 6–24). */
  steps?: number;
  /** Maximum random offset in CSS pixels (default 2.5). */
  jitter?: number;
  /** Per-step pause bounds (default 8–24 ms). */
  minStepDelayMs?: number;
  maxStepDelayMs?: number;
}

export interface TypingPlanOptions {
  /** Per-key pause bounds for ordinary characters (default 35–110 ms). */
  minKeyDelayMs?: number;
  maxKeyDelayMs?: number;
}

export interface TypingStep {
  char: string;
  delayMs: number;
}

/** Structural subset of Playwright's Page used by the humanizer (easy to stub). */
export interface HumanPage {
  mouse: {
    move(x: number, y: number, options?: { steps?: number }): Promise<void>;
    down(options?: { button?: "left" | "right" | "middle" }): Promise<void>;
    up(options?: { button?: "left" | "right" | "middle" }): Promise<void>;
    click(
      x: number,
      y: number,
      options?: { button?: "left" | "right" | "middle"; clickCount?: number; delay?: number },
    ): Promise<void>;
  };
  keyboard: {
    type(text: string): Promise<void>;
    press(key: string): Promise<void>;
  };
}

/** Mulberry32 — tiny, fast, and stable across Node versions. */
export function createSeededRng(seed: number): () => number {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4_294_967_296;
  };
}

function randomBetween(rng: () => number, min: number, max: number): number {
  return min + rng() * (max - min);
}

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

/** Smoothstep: slow start, fast middle, slow landing — the human feel. */
function smoothstep(t: number): number {
  return t * t * (3 - 2 * t);
}

function defaultSteps(from: Point, to: Point): number {
  const distance = Math.hypot(to.x - from.x, to.y - from.y);
  return Math.max(6, Math.min(24, Math.round(distance / 40)));
}

/**
 * Interpolate a pointer path from `from` to `to` with a smoothstep curve and
 * small jitter. The first point is the exact start and the last point is the
 * exact target, so clicks land where they were aimed. Pure and deterministic
 * for a given RNG.
 */
export function planPointerPath(
  from: Point,
  to: Point,
  rng: () => number,
  opts: PointerPathOptions = {},
): PointerStep[] {
  const steps = opts.steps ?? defaultSteps(from, to);
  const jitter = opts.jitter ?? 2.5;
  const minDelay = opts.minStepDelayMs ?? 8;
  const maxDelay = opts.maxStepDelayMs ?? 24;
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const path: PointerStep[] = [];
  for (let i = 1; i <= steps; i++) {
    const t = smoothstep(i / steps);
    // Jitter fades toward the target so the final click is precise.
    const spread = jitter * (1 - t);
    const x = i === steps ? to.x : round2(from.x + dx * t + randomBetween(rng, -spread, spread));
    const y = i === steps ? to.y : round2(from.y + dy * t + randomBetween(rng, -spread, spread));
    path.push({ x, y, delayMs: Math.round(randomBetween(rng, minDelay, maxDelay)) });
  }
  return path;
}

/**
 * Per-character typing plan. Letters/digits use the ordinary delay band;
 * spaces and punctuation get the realistic short/long pauses. Deterministic
 * for a given RNG.
 */
export function planTyping(text: string, rng: () => number, opts: TypingPlanOptions = {}): TypingStep[] {
  const minDelay = opts.minKeyDelayMs ?? 35;
  const maxDelay = opts.maxKeyDelayMs ?? 110;
  const plan: TypingStep[] = [];
  for (const char of text) {
    let delay: number;
    if (char === " ") delay = randomBetween(rng, Math.max(12, minDelay - 15), Math.max(30, maxDelay - 35));
    else if (char === "\n") delay = randomBetween(rng, maxDelay, maxDelay + 70);
    else if (/[.,!?;:'"()[\]{}@#$%^&*+=<>/\\|~`_-]/.test(char)) {
      delay = randomBetween(rng, maxDelay - 20, maxDelay + 50);
    } else delay = randomBetween(rng, minDelay, maxDelay);
    plan.push({ char, delayMs: Math.round(delay) });
  }
  return plan;
}

/** Convenience projection: just the per-key delays (tests + diagnostics). */
export function typingDelays(text: string, rng: () => number, opts: TypingPlanOptions = {}): number[] {
  return planTyping(text, rng, opts).map((step) => step.delayMs);
}

export interface HumanizerOptions extends PointerPathOptions, TypingPlanOptions {
  /** Deterministic mode: a fixed seed. Production omits it (Math.random). */
  seed?: number;
  /** Explicit RNG (wins over `seed`). */
  rng?: () => number;
  /** Test seam; production uses setTimeout. */
  sleep?: (ms: number) => Promise<void>;
  /** Where the pointer is assumed to start (default 0,0). */
  initialPointer?: Point;
}

export interface Humanizer {
  /** Last known pointer position. */
  pointer(): Point;
  /** Pure plan for the next move (deterministic under a seeded RNG). */
  planMove(to: Point, opts?: PointerPathOptions): PointerStep[];
  /** Pure plan for typing `text`. */
  planType(text: string, opts?: TypingPlanOptions): TypingStep[];
  /** Move the pointer along a jittered, interpolated path. */
  moveMouse(page: HumanPage, to: Point, opts?: PointerPathOptions): Promise<void>;
  /** Move to the target, pause, then press/release the left button. */
  click(page: HumanPage, to: Point, opts?: PointerPathOptions & { pressMs?: number }): Promise<void>;
  /** Two clicks with a human inter-click pause. */
  doubleClick(page: HumanPage, to: Point, opts?: PointerPathOptions & { pressMs?: number }): Promise<void>;
  /** Press, drag along an interpolated path, release. */
  drag(page: HumanPage, from: Point, to: Point, opts?: PointerPathOptions): Promise<void>;
  /** Move to the target, hold the left button for `durationMs`, release. */
  longPress(page: HumanPage, to: Point, durationMs?: number, opts?: PointerPathOptions): Promise<void>;
  /** Type one character at a time with per-key delays. */
  type(page: HumanPage, text: string, opts?: TypingPlanOptions): Promise<void>;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function createHumanizer(opts: HumanizerOptions = {}): Humanizer {
  const rng = opts.rng ?? (opts.seed !== undefined ? createSeededRng(opts.seed) : Math.random);
  const sleep = opts.sleep ?? defaultSleep;
  let current: Point = opts.initialPointer ?? { x: 0, y: 0 };

  function planMove(to: Point, moveOpts: PointerPathOptions = {}): PointerStep[] {
    return planPointerPath(current, to, rng, {
      ...(opts.steps !== undefined ? { steps: opts.steps } : {}),
      ...(opts.jitter !== undefined ? { jitter: opts.jitter } : {}),
      ...(opts.minStepDelayMs !== undefined ? { minStepDelayMs: opts.minStepDelayMs } : {}),
      ...(opts.maxStepDelayMs !== undefined ? { maxStepDelayMs: opts.maxStepDelayMs } : {}),
      ...moveOpts,
    });
  }

  function planType(text: string, typeOpts: TypingPlanOptions = {}): TypingStep[] {
    return planTyping(text, rng, {
      ...(opts.minKeyDelayMs !== undefined ? { minKeyDelayMs: opts.minKeyDelayMs } : {}),
      ...(opts.maxKeyDelayMs !== undefined ? { maxKeyDelayMs: opts.maxKeyDelayMs } : {}),
      ...typeOpts,
    });
  }

  async function moveMouse(page: HumanPage, to: Point, moveOpts: PointerPathOptions = {}): Promise<void> {
    for (const step of planMove(to, moveOpts)) {
      await sleep(step.delayMs);
      await page.mouse.move(step.x, step.y);
      current = { x: step.x, y: step.y };
    }
  }

  async function click(
    page: HumanPage,
    to: Point,
    clickOpts: PointerPathOptions & { pressMs?: number } = {},
  ): Promise<void> {
    await moveMouse(page, to, clickOpts);
    await sleep(Math.round(randomBetween(rng, 18, 55)));
    await page.mouse.down();
    await sleep(clickOpts.pressMs ?? Math.round(randomBetween(rng, 45, 95)));
    await page.mouse.up();
  }

  async function doubleClick(
    page: HumanPage,
    to: Point,
    clickOpts: PointerPathOptions & { pressMs?: number } = {},
  ): Promise<void> {
    await click(page, to, clickOpts);
    await sleep(Math.round(randomBetween(rng, 55, 130)));
    await page.mouse.down();
    await sleep(clickOpts.pressMs ?? Math.round(randomBetween(rng, 35, 70)));
    await page.mouse.up();
  }

  async function drag(page: HumanPage, from: Point, to: Point, dragOpts: PointerPathOptions = {}): Promise<void> {
    await moveMouse(page, from, dragOpts);
    await page.mouse.down();
    // Dragging is slower and less jittery than a free move.
    await moveMouse(page, to, { jitter: 1, ...dragOpts });
    await sleep(Math.round(randomBetween(rng, 30, 80)));
    await page.mouse.up();
  }

  async function longPress(
    page: HumanPage,
    to: Point,
    durationMs = 600,
    pressOpts: PointerPathOptions = {},
  ): Promise<void> {
    await moveMouse(page, to, pressOpts);
    await page.mouse.down();
    await sleep(durationMs);
    await page.mouse.up();
  }

  async function type(page: HumanPage, text: string, typeOpts: TypingPlanOptions = {}): Promise<void> {
    for (const step of planType(text, typeOpts)) {
      if (step.char === "\n") await page.keyboard.press("Enter");
      else await page.keyboard.type(step.char);
      await sleep(step.delayMs);
    }
  }

  return {
    pointer: () => ({ ...current }),
    planMove,
    planType,
    moveMouse,
    click,
    doubleClick,
    drag,
    longPress,
    type,
  };
}

/** A `Page` satisfies `HumanPage`; this keeps the dependency explicit at call sites. */
export function asHumanPage(page: Page): HumanPage {
  return page;
}
