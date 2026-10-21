/**
 * Input injection (P6 Task 7): translate `BrowserInputEvent`s from the
 * browser channel (wire contract from P6 Task 2, `@ovid/shared` browser.ts)
 * into Playwright mouse/keyboard calls on a live page.
 *
 * Per research §3.4, Playwright's mouse/keyboard wrappers are the verified
 * equivalent of raw CDP `Input.dispatch*` (and add actionability handling
 * where it matters), so this layer never talks raw CDP.
 *
 * Coordinate contract: client events arrive in page CSS pixels in the
 * viewport of the latest `browser_state` (see the shared wire contract), so
 * we round to integers and clamp into `[0, width-1] × [0, height-1]` from
 * `page.viewportSize()` (fallback 1280×800 — the headless-shell case where
 * the page reports no viewport).
 */

import type { Page } from "playwright-core";

import type { BrowserInputEvent } from "@ovid/shared";

/** A malformed input event — the caller (T8) drops it and logs, never crashes the page. */
export class BrowserInputError extends Error {
  constructor(reason: string) {
    super(`Invalid browser input: ${reason}`);
    this.name = "BrowserInputError";
  }
}

/** Viewport used when the page reports none (headless shell before first layout). */
const FALLBACK_VIEWPORT = { width: 1280, height: 800 } as const;

/** CDP rejects huge wheel deltas; clamp before dispatch. */
const MAX_WHEEL_DELTA = 10_000;

/** Default long-press hold, matching the Android view long-press timeout. */
const DEFAULT_LONG_PRESS_MS = 600;

/** Default swipe interpolation steps. */
const DEFAULT_SWIPE_STEPS = 8;

/** Validate one required finite number field, or throw BrowserInputError. */
function finiteNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new BrowserInputError(`${field} must be a finite number`);
  }
  return value;
}

/** Validate an optional finite number field (absent/undefined is fine). */
function optionalFiniteNumber(value: unknown, field: string): number | undefined {
  if (value === undefined) return undefined;
  return finiteNumber(value, field);
}

interface Point {
  x: number;
  y: number;
}

/** Round + clamp a CSS-pixel pair into the live viewport. */
async function clampPoint(page: Page, xRaw: unknown, yRaw: unknown, xField: string, yField: string): Promise<Point> {
  const x = finiteNumber(xRaw, xField);
  const y = finiteNumber(yRaw, yField);
  const viewport = page.viewportSize() ?? FALLBACK_VIEWPORT;
  const maxX = Math.max(viewport.width - 1, 0);
  const maxY = Math.max(viewport.height - 1, 0);
  return {
    x: Math.min(Math.max(Math.round(x), 0), maxX),
    y: Math.min(Math.max(Math.round(y), 0), maxY),
  };
}

/**
 * Public viewport clamp for the agent's human-like pointer path (the viewer
 * path already clamps inside `applyInputEvent`). Throws BrowserInputError for
 * non-finite coordinates, exactly like the event mapper.
 */
export async function clampToViewport(page: Page, x: unknown, y: unknown): Promise<Point> {
  return clampPoint(page, x, y, "x", "y");
}

/** Clamp a signed wheel delta to ±MAX_WHEEL_DELTA (finiteness already checked). */
function clampDelta(delta: number): number {
  return Math.min(Math.max(delta, -MAX_WHEEL_DELTA), MAX_WHEEL_DELTA);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Apply one viewer input event to the page. Throws `BrowserInputError` for
 * malformed events (non-finite numbers, unknown types, unsupported keys);
 * Playwright errors from other dispatches propagate unchanged.
 */
export async function applyInputEvent(page: Page, event: BrowserInputEvent): Promise<void> {
  if (event === null || typeof event !== "object" || typeof (event as { type?: unknown }).type !== "string") {
    throw new BrowserInputError("event must be an object with a string type");
  }

  switch ((event as { type: string }).type) {
    case "tap": {
      const e = event as { x?: unknown; y?: unknown };
      const { x, y } = await clampPoint(page, e.x, e.y, "x", "y");
      await page.mouse.click(x, y);
      return;
    }

    case "double_tap": {
      const e = event as { x?: unknown; y?: unknown };
      const { x, y } = await clampPoint(page, e.x, e.y, "x", "y");
      await page.mouse.dblclick(x, y);
      return;
    }

    case "long_press": {
      const e = event as { x?: unknown; y?: unknown; durationMs?: unknown };
      const { x, y } = await clampPoint(page, e.x, e.y, "x", "y");
      const duration = optionalFiniteNumber(e.durationMs, "durationMs");
      if (duration !== undefined && (duration <= 0 || !Number.isInteger(duration))) {
        throw new BrowserInputError("durationMs must be a positive integer");
      }
      const holdMs = duration ?? DEFAULT_LONG_PRESS_MS;
      await page.mouse.move(x, y);
      await page.mouse.down();
      await sleep(holdMs);
      await page.mouse.up();
      return;
    }

    case "scroll": {
      const e = event as { dx?: unknown; dy?: unknown; x?: unknown; y?: unknown };
      const dx = clampDelta(finiteNumber(e.dx, "dx"));
      const dy = clampDelta(finiteNumber(e.dy, "dy"));
      const x = optionalFiniteNumber(e.x, "x");
      const y = optionalFiniteNumber(e.y, "y");
      if (x !== undefined && y !== undefined) {
        const point = await clampPoint(page, x, y, "x", "y");
        await page.mouse.move(point.x, point.y);
      } else if ((x === undefined) !== (y === undefined)) {
        throw new BrowserInputError("x and y must be present together for scroll");
      }
      await page.mouse.wheel(dx, dy);
      return;
    }

    case "swipe": {
      const e = event as { fromX?: unknown; fromY?: unknown; toX?: unknown; toY?: unknown; steps?: unknown };
      const from = await clampPoint(page, e.fromX, e.fromY, "fromX", "fromY");
      const to = await clampPoint(page, e.toX, e.toY, "toX", "toY");
      const rawSteps = optionalFiniteNumber(e.steps, "steps");
      if (rawSteps !== undefined && (!Number.isInteger(rawSteps) || rawSteps < 1)) {
        throw new BrowserInputError("steps must be a positive integer");
      }
      const steps = rawSteps ?? DEFAULT_SWIPE_STEPS;
      await page.mouse.move(from.x, from.y);
      await page.mouse.down();
      for (let i = 1; i <= steps; i++) {
        const t = i / steps;
        await page.mouse.move(from.x + Math.round((to.x - from.x) * t), from.y + Math.round((to.y - from.y) * t));
      }
      await page.mouse.up();
      return;
    }

    case "key": {
      const e = event as { key?: unknown; text?: unknown };
      if (typeof e.key !== "string" || e.key.length === 0) {
        throw new BrowserInputError("key must be a non-empty string");
      }
      if (e.text !== undefined && typeof e.text !== "string") {
        throw new BrowserInputError("text must be a string");
      }
      if (e.text !== undefined) {
        await page.keyboard.insertText(e.text);
        return;
      }
      try {
        await page.keyboard.press(e.key);
      } catch (err) {
        // Unknown key strings pass through to Playwright; rewrap so callers
        // see a single error shape for malformed input.
        throw new BrowserInputError(`unsupported key "${e.key}": ${(err as Error).message}`);
      }
      return;
    }

    default:
      throw new BrowserInputError(`unknown event type ${(event as { type: string }).type}`);
  }
}
