/**
 * LightpandaPool pins (P6 browser engine, Task 11) — HOST-GATED.
 *
 * The Lightpanda binary is provisioned by the host operator per the
 * research (§1.4: linux-x64 nightly from GitHub releases) and pointed at
 * via OVID_LIGHTPANDA_BIN — same gating pattern as the sandbox package's
 * bwrap host tests and pool.test.ts's chromiumExecutableExists gate.
 * Without the binary the whole suite skips cleanly; with it, every test
 * runs against a REAL lightpanda serve/fetch process over CDP and the
 * local fixture server only.
 *
 * Review Focus #1 (isolation): every lease is killed on release — cookie
 * state cannot leak between leases because no process ever survives one.
 */

import { execSync } from "node:child_process";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";

import type { BrowserEngineConfig } from "./config.js";
import {
  createLightpandaPool,
  LIGHTPANDA_PORT_BASE,
  lightpandaAvailable,
  type LightpandaPool,
} from "./lightpanda.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";

const BIN = process.env.OVID_LIGHTPANDA_BIN ?? null;

describe.skipIf(!lightpandaAvailable(BIN))("LightpandaPool (real lightpanda, host-gated)", () => {
  let server: TestPageServer;
  const pools: LightpandaPool[] = [];

  beforeAll(async () => {
    server = await startTestPageServer();
  });

  afterAll(async () => {
    await server.close();
  });

  function makeCfg(overrides: Partial<BrowserEngineConfig> = {}): BrowserEngineConfig {
    return {
      maxLiveBrowsers: 2,
      tier1FallbackContexts: 1,
      idleEvictMs: 500,
      maxTier1Processes: 2,
      tier1TimeoutMs: 20_000,
      maxActiveScreencasts: 3,
      screencastLoadMax: 6.0,
      screencast: { width: 400, height: 300, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
      stateDir: null,
      lightpandaBin: BIN,
      allowHosts: ["127.0.0.1", "localhost"],
      ownPublicIp: null,
      chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
      ...overrides,
    };
  }

  function makePool(cfg: BrowserEngineConfig): LightpandaPool {
    const pool = createLightpandaPool(BIN!, cfg);
    pools.push(pool);
    return pool;
  }

  afterEach(async () => {
    for (const pool of pools) await pool.close();
    pools.length = 0;
  });

  function lightpandaPids(): number[] {
    try {
      return execSync("pgrep -x lightpanda || true", { encoding: "utf8" })
        .split("\n")
        .filter(Boolean)
        .map(Number);
    } catch {
      return [];
    }
  }

  /** Poll process.kill(pid, 0) until it throws (ESRCH = reaped). */
  async function untilReaped(pid: number, deadlineMs = 3_000): Promise<boolean> {
    const deadline = Date.now() + deadlineMs;
    while (Date.now() < deadline) {
      try {
        process.kill(pid, 0);
      } catch {
        return true;
      }
      await new Promise((r) => setTimeout(r, 100));
    }
    try {
      process.kill(pid, 0);
      return false;
    } catch {
      return true;
    }
  }

  it("lightpandaAvailable gates on binPath presence + X_OK", () => {
    expect(lightpandaAvailable(null)).toBe(false);
    expect(lightpandaAvailable("/nonexistent/lightpanda")).toBe(false);
    expect(lightpandaAvailable(BIN)).toBe(true);
  });

  it(
    "acquire spawns a live serve proc on the slot port; release kills and reaps it",
    async () => {
      const pool = makePool(makeCfg({ maxTier1Processes: 1 }));
      const lease = await pool.acquire(10_000);
      expect(lease.slot).toBe(0);
      expect(lease.cdpUrl).toBe(`http://127.0.0.1:${LIGHTPANDA_PORT_BASE}`);
      expect(lease.pid).toBeGreaterThan(1);
      // The process is alive right now...
      expect(() => process.kill(lease.pid, 0)).not.toThrow();
      expect(pool.running()).toBe(1);

      await pool.release(lease);
      expect(pool.running()).toBe(0);
      // ...and dead (ESRCH) within the reap bound.
      expect(await untilReaped(lease.pid)).toBe(true);
    },
    30_000,
  );

  it(
    "two concurrent leases get different slots and therefore different ports",
    async () => {
      const pool = makePool(makeCfg({ maxTier1Processes: 2 }));
      const a = await pool.acquire(10_000);
      const b = await pool.acquire(10_000);
      expect(a.slot).not.toBe(b.slot);
      expect(a.cdpUrl).not.toBe(b.cdpUrl);
      expect([a.slot, b.slot].sort()).toEqual([0, 1]);
      for (const lease of [a, b]) {
        expect(lease.cdpUrl).toBe(`http://127.0.0.1:${LIGHTPANDA_PORT_BASE + lease.slot}`);
      }
      expect(pool.running()).toBe(2);
      await pool.release(a);
      await pool.release(b);
      expect(pool.running()).toBe(0);
    },
    30_000,
  );

  it(
    "readPage returns the fixture article html with finalUrl === the requested url",
    async () => {
      const pool = makePool(makeCfg());
      const out = await pool.readPage(server.url("/"), 20_000);
      expect(out.html).toContain("A plain article");
      expect(out.finalUrl).toBe(server.url("/"));
      expect(out.title).toBe("Static article");
      // readPage is self-contained: the lease is released by the time it returns.
      expect(pool.running()).toBe(0);
    },
    30_000,
  );

  it(
    "isolation: login_tok set inside lease A's process NEVER reaches lease B",
    async () => {
      const pool = makePool(makeCfg());
      // Lease A's process receives Set-Cookie: login_tok=abc123 from /setcookie.
      const a = await pool.readPage(server.url("/setcookie"), 20_000);
      expect(a.finalUrl).toBe(server.url("/setcookie"));

      // Lease B is a fresh process by construction (release kills A's proc).
      // /echo-cookies returns the Cookie header the server actually received.
      const b = await pool.readPage(server.url("/echo-cookies"), 20_000);
      expect(b.html).not.toContain("login_tok");
    },
    30_000,
  );

  it(
    "FIFO: at maxTier1Processes=1 a second acquire waits until the first release",
    async () => {
      const pool = makePool(makeCfg({ maxTier1Processes: 1 }));
      const first = await pool.acquire(10_000);
      let secondResolved = false;
      const second = pool.acquire(10_000).then((lease) => {
        secondResolved = true;
        return lease;
      });
      await new Promise((r) => setTimeout(r, 300));
      expect(secondResolved).toBe(false);
      expect(pool.running()).toBe(1);

      await pool.release(first);
      const lease2 = await second; // admitted FIFO after the release
      expect(lease2.slot).toBe(0);
      expect(pool.running()).toBe(1);
      await pool.release(lease2);
    },
    30_000,
  );

  it(
    "close() with a live lease kills everything and leaves no stray lightpanda pids",
    async () => {
      const before = lightpandaPids();
      const pool = makePool(makeCfg());
      const lease = await pool.acquire(10_000);
      expect(pool.running()).toBe(1);

      await pool.close();
      expect(pool.running()).toBe(0);
      expect(await untilReaped(lease.pid)).toBe(true);

      // pgrep audit: no lightpanda processes beyond whatever predated this test.
      const after = lightpandaPids();
      expect(after.filter((pid) => !before.includes(pid))).toEqual([]);
    },
    30_000,
  );

  it(
    "oneShotMarkdown dumps markdown containing the article heading",
    async () => {
      const pool = makePool(makeCfg());
      const out = await pool.oneShotMarkdown(server.url("/"), 30_000);
      expect(out.markdown).toContain("A plain article");
      expect(out.finalUrl).toBe(server.url("/"));
      expect(out.title).toBeNull();
    },
    60_000,
  );
});
