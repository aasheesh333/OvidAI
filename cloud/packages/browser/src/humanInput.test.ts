import { describe, expect, it } from "vitest";

import {
  createHumanizer,
  createSeededRng,
  planPointerPath,
  planTyping,
  typingDelays,
  type HumanPage,
  type PointerStep,
} from "./humanInput.js";

/**
 * Product spec §8: "The agent drives like a human: scroll, hover, type with
 * delays". The plans must be deterministic under a seeded RNG so tests pin
 * exact paths/delays rather than tolerating flaky timing.
 */

interface StubPage extends HumanPage {
  events: string[];
  moves: Array<{ x: number; y: number }>;
  typed: string[];
}

function stubPage(): StubPage {
  const events: string[] = [];
  const moves: Array<{ x: number; y: number }> = [];
  const typed: string[] = [];
  return {
    events,
    moves,
    typed,
    mouse: {
      async move(x, y) {
        moves.push({ x, y });
        events.push(`move:${x},${y}`);
      },
      async down() {
        events.push("down");
      },
      async up() {
        events.push("up");
      },
      async click() {
        events.push("click");
      },
    },
    keyboard: {
      async type(text) {
        typed.push(text);
        events.push(`type:${text}`);
      },
      async press(key) {
        events.push(`press:${key}`);
      },
    },
  };
}

function noSleep(): { sleep: (ms: number) => Promise<void>; sleeps: number[] } {
  const sleeps: number[] = [];
  return {
    sleeps,
    sleep: async (ms: number) => {
      sleeps.push(ms);
    },
  };
}

describe("seeded RNG", () => {
  it("is deterministic for a seed and differs across seeds", () => {
    const a = createSeededRng(42);
    const b = createSeededRng(42);
    const c = createSeededRng(43);
    const seqA = Array.from({ length: 8 }, () => a());
    const seqB = Array.from({ length: 8 }, () => b());
    const seqC = Array.from({ length: 8 }, () => c());
    expect(seqA).toEqual(seqB);
    expect(seqA).not.toEqual(seqC);
    for (const n of seqA) {
      expect(n).toBeGreaterThanOrEqual(0);
      expect(n).toBeLessThan(1);
    }
  });
});

describe("pointer path planning", () => {
  const from = { x: 10, y: 20 };
  const to = { x: 410, y: 260 };

  it("is identical for the same seed and different for another seed", () => {
    const a = planPointerPath(from, to, createSeededRng(7));
    const b = planPointerPath(from, to, createSeededRng(7));
    const c = planPointerPath(from, to, createSeededRng(8));
    expect(a).toEqual(b);
    expect(a).not.toEqual(c);
  });

  it("starts near the origin, lands exactly on the target, and is interpolated + jittered", () => {
    const path: PointerStep[] = planPointerPath(from, to, createSeededRng(11), { steps: 12, jitter: 3 });
    expect(path).toHaveLength(12);
    expect(path[path.length - 1]).toEqual({ x: to.x, y: to.y, delayMs: expect.any(Number) });
    expect(path[0]!.x).toBeGreaterThan(from.x);
    expect(path[0]!.x).toBeLessThan(to.x);

    // Not a straight line: at least one point sits off the from→to chord.
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const offChord = path.some((p) => Math.abs((p.x - from.x) * dy - (p.y - from.y) * dx) > 0.5);
    expect(offChord).toBe(true);

    // Realistic timing: every step pauses, within the configured band.
    for (const step of path) {
      expect(step.delayMs).toBeGreaterThanOrEqual(8);
      expect(step.delayMs).toBeLessThanOrEqual(24);
    }
  });
});

describe("typing plan", () => {
  it("is identical for the same seed and different for another seed", () => {
    const a = planTyping("hello, world!", createSeededRng(3));
    const b = planTyping("hello, world!", createSeededRng(3));
    const c = planTyping("hello, world!", createSeededRng(4));
    expect(a).toEqual(b);
    expect(a).not.toEqual(c);
    expect(a.map((s) => s.char).join("")).toBe("hello, world!");
  });

  it("has a positive per-key delay for every character", () => {
    const delays = typingDelays("abc 123.", createSeededRng(5));
    expect(delays).toHaveLength("abc 123.".length);
    for (const d of delays) expect(d).toBeGreaterThan(0);
  });
});

describe("humanizer playback", () => {
  it("click: interpolated moves → pause → down → up, identical across runs with one seed", async () => {
    async function run(seed: number) {
      const page = stubPage();
      const { sleep, sleeps } = noSleep();
      const human = createHumanizer({ seed, sleep });
      await human.click(page, { x: 300, y: 200 });
      return { page, sleeps, pointer: human.pointer() };
    }

    const a = await run(21);
    const b = await run(21);
    expect(a.page.moves).toEqual(b.page.moves);
    expect(a.sleeps).toEqual(b.sleeps);
    expect(a.pointer).toEqual({ x: 300, y: 200 });

    // A human path is several small moves, not one teleport.
    expect(a.page.moves.length).toBeGreaterThan(3);
    expect(a.page.moves[a.page.moves.length - 1]).toEqual({ x: 300, y: 200 });
    expect(a.page.events).toContain("down");
    expect(a.page.events).toContain("up");
    expect(a.page.events.lastIndexOf("down")).toBeLessThan(a.page.events.lastIndexOf("up"));
  });

  it("type: one keyboard event per character with a delay after each key", async () => {
    async function run(seed: number) {
      const page = stubPage();
      const { sleep, sleeps } = noSleep();
      const human = createHumanizer({ seed, sleep });
      await human.type(page, "Hi there!");
      return { page, sleeps };
    }

    const a = await run(9);
    const b = await run(9);
    expect(a.page.typed).toEqual([...`Hi there!`]);
    expect(a.page.typed).toEqual(b.page.typed);
    expect(a.sleeps).toEqual(b.sleeps);
    expect(a.sleeps).toHaveLength("Hi there!".length);
    for (const d of a.sleeps) expect(d).toBeGreaterThan(0);

    // Different seed ⇒ different cadence (the jitter is real).
    const c = await run(10);
    expect(c.sleeps).not.toEqual(a.sleeps);
  });

  it("drag: press, interpolated path, release; long-press holds the button", async () => {
    const page = stubPage();
    const { sleep, sleeps } = noSleep();
    const human = createHumanizer({ seed: 2, sleep });

    await human.drag(page, { x: 20, y: 20 }, { x: 200, y: 120 });
    expect(page.events).toContain("down");
    expect(page.events[page.events.lastIndexOf("down") + 1]).toMatch(/^move:/);
    expect(page.events[page.events.length - 1]).toBe("up");

    const before = page.events.length;
    await human.longPress(page, { x: 50, y: 50 }, 700);
    expect(page.events.slice(before)).toContain("down");
    expect(page.events[page.events.length - 1]).toBe("up");
    expect(sleeps).toContain(700);
  });
});
