/**
 * Task 14 tests — the BrowserEngine facade, end to end: real chromium, real
 * redis (TEST_REDIS_URL), and a test-side redis PEER that plays the gateway
 * (subscribing frames/state, publishing ctl/input — the Task-9 peer's exact
 * topology). Pins the brief's engine behaviors:
 *
 *   - openSession ⇒ the peer sees {live:true} once a viewer joins (the
 *     screencast-start publish),
 *   - viewer_join ⇒ ≥1 binary frame within 10 s on the animated fixture, with
 *     the 1-byte prefix matching BROWSER_FRAME_FORMAT of the published
 *     frameFormat, and the webp probe's navigation RESTORED (T6 carry: the
 *     probe navigates the page — the engine must not clobber user content),
 *   - viewer_leave ⇒ frames go quiet and screencastCount()===0,
 *   - input through the peer ⇒ the /click fixture flips to CLICKED (the full
 *     injection path, arrival-ordered) — under takeover, the only state in
 *     which the engine accepts viewer input,
 *   - input WITHOUT takeover ⇒ dropped server-side: #out never flips until
 *     the flag is set (exclusivity lives in the engine, not the client),
 *   - takeover ctl ⇒ registry flag + a tool call returns exactly
 *     TAKEOVER_REFUSAL,
 *   - takeover + last viewer leaving ⇒ the flag releases (a subsequent tool
 *     is NOT refused) and the release is published — the bridge's stale
 *     sweep funnels through the same onViewersChange(0),
 *   - state publish includes url/title after browser_open via engine.tools,
 *   - idle eviction (injected clock + idleEvictMs:200) ⇒ {live:false} to the
 *     peer AND the persistence stub received the login_tok cookie state
 *     (flush-before-close, the 3-min hibernation mirror),
 *   - close() with a live session ⇒ flush called, browser dead, every bridge
 *     connection quit, second close() is a no-throw no-op.
 *
 * The whole suite is chromium-gated AND redis-gated, and takes the
 * cross-suite browser lock (T13 precedent): every connection the engine's
 * redis factory creates is tracked so close() can be proven to quit them all.
 */

import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import IORedis, { type Redis } from "ioredis";

import {
  BROWSER_FRAME_FORMAT,
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  type BrowserCtlMsg,
  type BrowserStateDto,
} from "@ovid/shared";

import type { BrowserEngineConfig } from "./config.js";
import { createBrowserEngine, type BrowserEngine } from "./engine.js";
import { chromiumExecutableExists } from "./pool.js";
import { frameMagicFormat } from "./screencast.js";
import { TAKEOVER_REFUSAL } from "./sessions.js";
import { ensureSession } from "./sessionOps.js";
import type { StorageStatePersistence } from "./stateStore.js";
import { startTestPageServer, type TestPageServer } from "./test/testServer.js";
import { acquireBrowserSuiteLock, sleep } from "./test/suiteLock.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const GATED = Boolean(TEST_REDIS_URL) && chromiumExecutableExists();

async function waitFor(what: string, predicate: () => boolean | Promise<boolean>, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await predicate()) return;
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

// ---------------------------------------------------------------------------
// Gateway-peer taps (dedicated subscriber connections, like the real peer)
// ---------------------------------------------------------------------------

const tapConns: Redis[] = [];

interface StateTap {
  states: BrowserStateDto[];
  waitForState(pred: (s: BrowserStateDto) => boolean, timeoutMs?: number): Promise<BrowserStateDto>;
}

async function openStateTap(sessionId: string): Promise<StateTap> {
  const redis = new IORedis(TEST_REDIS_URL!);
  tapConns.push(redis);
  const states: BrowserStateDto[] = [];
  redis.on("message", (ch: Buffer, msg: string) => {
    if (ch.toString("utf8") !== browserStateChannel(sessionId)) return;
    try {
      states.push(JSON.parse(msg) as BrowserStateDto);
    } catch {
      /* not ours / not JSON */
    }
  });
  await redis.subscribe(browserStateChannel(sessionId));
  return {
    states,
    async waitForState(pred, timeoutMs = 5000) {
      await waitFor("a browser_state matching the predicate", () => states.some(pred), timeoutMs);
      return [...states].reverse().find(pred)!;
    },
  };
}

interface FrameTap {
  received: number;
  next(timeoutMs: number): Promise<{ prefix: number; data: Buffer }>;
}

async function openFrameTap(sessionId: string): Promise<FrameTap> {
  const redis = new IORedis(TEST_REDIS_URL!);
  tapConns.push(redis);
  const queue: Array<{ prefix: number; data: Buffer }> = [];
  const waiters: Array<(f: { prefix: number; data: Buffer }) => void> = [];
  let received = 0;
  redis.on("messageBuffer", (ch: Buffer, msg: Buffer) => {
    if (ch.toString("utf8") !== browserFramesChannel(sessionId)) return;
    received++;
    const frame = { prefix: msg[0], data: msg.subarray(1) };
    queue.push(frame);
    for (const w of waiters.splice(0)) w(frame);
  });
  await redis.subscribe(browserFramesChannel(sessionId));
  return {
    get received() {
      return received;
    },
    next: (timeoutMs: number) =>
      new Promise((resolve, reject) => {
        const head = queue.shift();
        if (head) {
          resolve(head);
          return;
        }
        const timer = setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i !== -1) waiters.splice(i, 1);
          reject(new Error("no screencast frame arrived"));
        }, timeoutMs);
        const waiter = (f: { prefix: number; data: Buffer }) => {
          clearTimeout(timer);
          resolve(f);
        };
        waiters.push(waiter);
      }),
  };
}

// ---------------------------------------------------------------------------
// Engine rig
// ---------------------------------------------------------------------------

function makeCfg(overrides: Partial<BrowserEngineConfig> = {}): BrowserEngineConfig {
  return {
    maxLiveBrowsers: 2,
    tier1FallbackContexts: 1,
    idleEvictMs: 180_000,
    maxTier1Processes: 2,
    tier1TimeoutMs: 20_000,
    maxActiveScreencasts: 2,
    screencastLoadMax: 6.0,
    screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 2 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: ["127.0.0.1", "localhost"],
    ownPublicIp: null,
    blockHeavyResources: false,
    chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
    ...overrides,
  };
}

interface EngineRig {
  engine: BrowserEngine;
  /** Every connection the engine's redis factory created (bridge-owned). */
  conns: Redis[];
  flush: ReturnType<typeof vi.fn>;
  restore: ReturnType<typeof vi.fn>;
  /** The persistence stub handed to the engine (for direct sessionOps calls). */
  persistence: StorageStatePersistence;
  /** Mutable injected clock — frozen by default so nothing ages by accident. */
  clock: { t: number };
  wsRoot: string;
}

async function mkEngine(cfgOverrides: Partial<BrowserEngineConfig> = {}): Promise<EngineRig> {
  const conns: Redis[] = [];
  const flush = vi.fn(async () => {});
  const restore = vi.fn(async () => null);
  const persistence = { flush, restore } as unknown as StorageStatePersistence;
  const clock = { t: Date.now() };
  const wsRoot = await mkdtemp(join(tmpdir(), "ovid-browser-engine-"));
  const engine = await createBrowserEngine({
    cfg: makeCfg(cfgOverrides),
    redisFactory: () => {
      const r = new IORedis(TEST_REDIS_URL!);
      conns.push(r);
      return r;
    },
    persistence,
    workspaceDir: async () => wsRoot,
    now: () => clock.t,
    log: () => {},
  });
  return { engine, conns, flush, restore, persistence, clock, wsRoot };
}

function tool(engine: BrowserEngine, name: string) {
  const def = engine.tools.find((t) => t.name === name);
  if (!def) throw new Error(`missing tool ${name}`);
  return def;
}

const joinMsg = (viewerId: string): string =>
  JSON.stringify({ type: "viewer_join", viewerId } satisfies BrowserCtlMsg);
const leaveMsg = (viewerId: string): string =>
  JSON.stringify({ type: "viewer_leave", viewerId } satisfies BrowserCtlMsg);
const takeoverMsg = (enabled: boolean): string =>
  JSON.stringify({ type: "takeover", enabled } satisfies BrowserCtlMsg);

describe.skipIf(!GATED)("BrowserEngine facade (real redis + chromium, harness plays the gateway)", () => {
  let gw: Redis;
  let server: TestPageServer;
  let releaseSuiteLock: (() => Promise<void>) | null = null;
  let rig: EngineRig | null = null;

  beforeAll(async () => {
    gw = new IORedis(TEST_REDIS_URL!);
    server = await startTestPageServer();
    releaseSuiteLock = await acquireBrowserSuiteLock(gw);
  });

  afterAll(async () => {
    await releaseSuiteLock?.();
    for (const r of tapConns) await r.quit().catch(() => {});
    await server.close();
    await gw.quit().catch(() => {});
  });

  afterEach(async () => {
    // Every test closes its own engine; this is the safety net for the one
    // that fails mid-flight (close() is idempotent, so double-close is fine).
    await rig?.engine.close();
    if (rig) await rm(rig.wsRoot, { recursive: true, force: true }).catch(() => {});
    rig = null;
  });

  it("openSession: the peer sees {live:true} once a viewer joins (the screencast-start publish)", async () => {
    const sid = randomUUID();
    const tap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));

    const st = await tap.waitForState((s) => s.live && s.screencast);
    expect(st.sessionId).toBe(sid);
    expect(st.takeover).toBe(false);
  });

  it("viewer_join starts the screencast: ≥1 frame within 10 s, prefix byte matches the published frameFormat, and the probe restored the user's page", async () => {
    const sid = randomUUID();
    const stateTap = await openStateTap(sid);
    const frameTap = await openFrameTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/animated") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));

    // The screencast-start state lands first (frameFormat is on it), then
    // frames flow — both well inside 10 s even with the one-per-engine probe.
    const st = await stateTap.waitForState((s) => s.live && s.screencast, 10_000);
    const frame = await frameTap.next(10_000);
    expect(frame.prefix).toBe(BROWSER_FRAME_FORMAT[st.frameFormat]);
    // The prefix must tell the truth about the image bytes behind it.
    expect(frameMagicFormat(frame.data)).toBe(st.frameFormat);

    // T6 carry: probeWebpSupport NAVIGATES the page to its inline fixture.
    // The engine probed on this first cast start (after the user navigation)
    // and must have restored the user's page afterwards.
    const page = rig.engine.registry.activePage(sid);
    expect(page).not.toBeNull();
    expect(page!.url()).toBe(server.url("/animated"));
  });

  it("viewer_leave stops the cast: frames go quiet (500 ms) and screencastCount()===0", async () => {
    const sid = randomUUID();
    const frameTap = await openFrameTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/animated") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));
    await frameTap.next(10_000); // the cast is provably live

    await gw.publish(browserCtlChannel(sid), leaveMsg("v1"));
    const engine = rig.engine;
    await waitFor("screencastCount()===0 after leave", () => engine.screencastCount() === 0);
    expect(engine.registry.get(sid)).not.toBeNull(); // the SESSION stays; only the cast stops

    const atStop = frameTap.received;
    await sleep(500); // the animated fixture cycles every 100 ms — 500 ms quiet proves the cast is dead
    expect(frameTap.received).toBe(atStop);
  });

  it("input under takeover flips the /click fixture to CLICKED (end-to-end injection, arrival-ordered)", async () => {
    const sid = randomUUID();
    const stateTap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/click") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));
    // Wait for the cast to be live BEFORE sending input: the first cast start
    // runs the webp probe, which navigates the page to its inline fixture and
    // back — the real client likewise waits for browser_state before input.
    await stateTap.waitForState((s) => s.screencast === true, 10_000);
    // The engine only accepts viewer input under takeover — the client
    // contract (input gates on the flag) pinned end to end.
    await gw.publish(browserCtlChannel(sid), takeoverMsg(true));
    await waitFor("registry takeover flag", () => rig!.engine.registry.get(sid)?.takeover === true);

    // #btn sits at left:20 top:20, 100x40 — (60, 40) is inside it.
    await gw.publish(browserInputChannel(sid), JSON.stringify({ type: "tap", x: 60, y: 40 }));
    const page = rig.engine.registry.activePage(sid)!;
    await waitFor(
      "#out === CLICKED",
      async () => (await page.evaluate(() => document.getElementById("out")?.textContent)) === "CLICKED",
    );
  });

  it("input without takeover is dropped server-side: #out never flips until the flag is set", async () => {
    const sid = randomUUID();
    const stateTap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/click") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));
    await stateTap.waitForState((s) => s.screencast === true, 10_000);

    // A buggy or older client injects mid-automation (no takeover flag): the
    // agent owns the page, so the engine must drop the event — the fixture
    // flips synchronously on a real tap, so a quiet page proves the drop.
    await gw.publish(browserInputChannel(sid), JSON.stringify({ type: "tap", x: 60, y: 40 }));
    const page = rig.engine.registry.activePage(sid)!;
    await sleep(600);
    expect(await page.evaluate(() => document.getElementById("out")?.textContent)).not.toBe("CLICKED");

    // The SAME event under takeover lands — the earlier silence was the
    // flag, not a broken injection path.
    await gw.publish(browserCtlChannel(sid), takeoverMsg(true));
    await waitFor("registry takeover flag", () => rig!.engine.registry.get(sid)?.takeover === true);
    await gw.publish(browserInputChannel(sid), JSON.stringify({ type: "tap", x: 60, y: 40 }));
    await waitFor(
      "#out === CLICKED after takeover",
      async () => (await page.evaluate(() => document.getElementById("out")?.textContent)) === "CLICKED",
    );
  });

  it("takeover ctl flags the registry, publishes takeover state, and a tool call returns exactly TAKEOVER_REFUSAL", async () => {
    const sid = randomUUID();
    const tap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), takeoverMsg(true));
    await waitFor("registry takeover flag", () => rig!.engine.registry.get(sid)?.takeover === true);

    const st = await tap.waitForState((s) => s.takeover === true);
    expect(st.sessionId).toBe(sid);

    const result = await tool(rig.engine, "browser_read").execute({}, { sessionId: sid, userId: "u1" });
    expect(result.content).toBe(TAKEOVER_REFUSAL);
  });

  it("the last viewer leaving releases takeover: flag false, release published, a subsequent tool is NOT refused", async () => {
    const sid = randomUUID();
    const tap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/") },
      { sessionId: sid, userId: "u1" },
    );
    await gw.publish(browserCtlChannel(sid), joinMsg("v1"));
    await gw.publish(browserCtlChannel(sid), takeoverMsg(true));
    await tap.waitForState((s) => s.takeover === true);
    const flagAt = tap.states.findIndex((s) => s.takeover === true);

    // A mid-takeover disconnect (no takeover:false ctl ever arrives): the
    // viewer just leaves. The flag must release on its own — otherwise every
    // browser_* tool stays refused until idle eviction destroys the session.
    await gw.publish(browserCtlChannel(sid), leaveMsg("v1"));
    await waitFor(
      "registry takeover flag released",
      () => rig!.engine.registry.get(sid)?.takeover === false,
    );
    // The release is published too — a state AFTER the takeover:true one
    // carries takeover:false, mirroring onTakeover's own publish.
    await waitFor(
      "a post-takeover state with takeover:false",
      () => tap.states.slice(flagAt + 1).some((s) => s.takeover === false),
    );

    const result = await tool(rig.engine, "browser_read").execute({}, { sessionId: sid, userId: "u1" });
    expect(result.content).not.toBe(TAKEOVER_REFUSAL);
    expect(result.content.length).toBeGreaterThan(0);
  });

  it("state publish includes url/title after browser_open via engine.tools", async () => {
    const sid = randomUUID();
    const tap = await openStateTap(sid);
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/") },
      { sessionId: sid, userId: "u1" },
    );

    const st = await tap.waitForState((s) => s.live && s.url === server.url("/") && s.title === "Static article");
    expect(st.viewport).toEqual({ width: 1280, height: 800 });
  });

  it("idle eviction: injected clock + idleEvictMs:200 ⇒ the peer sees {live:false} and persistence received the login_tok cookie state", async () => {
    const sid = randomUUID();
    const tap = await openStateTap(sid);
    rig = await mkEngine({ idleEvictMs: 200 });

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/setcookie") },
      { sessionId: sid, userId: "u1" },
    );

    rig.clock.t += 1000; // cross the idle threshold on the injected clock
    await rig.engine.pool.evictIdle();

    await tap.waitForState((s) => s.live === false);
    expect(rig.engine.registry.get(sid)).toBeNull();
    expect(rig.engine.screencastCount()).toBe(0);

    // flush-before-close: the capture ran BEFORE the context died, so the
    // fixture's login_tok cookie (set via Set-Cookie header) survived.
    expect(rig.flush).toHaveBeenCalledTimes(1);
    const [flushedUser, captured] = rig.flush.mock.calls[0] as [string, { cookies: Array<{ name: string }> }];
    expect(flushedUser).toBe("u1");
    expect(captured.cookies.some((c) => c.name === "login_tok")).toBe(true);
  });

  it("close() flushes a session that was never published: goto timeout AFTER Set-Cookie still persists the cookie (I1)", async () => {
    const sid = randomUUID();
    rig = await mkEngine();

    // Reproduce browser_open's creation path exactly: the tools pass a
    // notify-SUPPRESSED deps clone into ensureSession (they publish only after
    // a successful goto), so a goto that times out leaves the session in the
    // REGISTRY but never in the engine's published-live set.
    const session = await ensureSession(
      {
        pool: rig.engine.pool,
        registry: rig.engine.registry,
        persistence: rig.persistence,
        cfg: makeCfg(),
        notifyState: undefined,
        log: () => {},
      },
      { sessionId: sid, userId: "u1" },
    );
    // The response's Set-Cookie header reaches the context immediately; the
    // body never arrives, so domcontentloaded never fires and goto times out.
    await expect(
      session.handle.page.goto(server.url("/setcookie-hang"), {
        waitUntil: "domcontentloaded",
        timeout: 1500,
      }),
    ).rejects.toThrow();

    await rig.engine.close();

    // The cookie landed in the context before the timeout; close() must have
    // enumerated the REGISTRY (the "context alive" set) and flushed it.
    expect(rig.flush).toHaveBeenCalledTimes(1);
    const [flushedUser, captured] = rig.flush.mock.calls[0] as [string, { cookies: Array<{ name: string }> }];
    expect(flushedUser).toBe("u1");
    expect(captured.cookies.some((c) => c.name === "hang_tok")).toBe(true);
  });

  it("close(): state flushed, browser dead, every bridge connection quit, second close() no-throw", async () => {
    const sid = randomUUID();
    rig = await mkEngine();

    await rig.engine.openSession(sid, "u1");
    await tool(rig.engine, "browser_open").execute(
      { url: server.url("/setcookie") },
      { sessionId: sid, userId: "u1" },
    );

    await rig.engine.close();

    expect(rig.flush).toHaveBeenCalledTimes(1);
    const [, captured] = rig.flush.mock.calls[0] as [string, { cookies: Array<{ name: string }> }];
    expect(captured.cookies.some((c) => c.name === "login_tok")).toBe(true);
    expect(rig.engine.registry.get(sid)).toBeNull();
    expect(rig.engine.pool.stats().browserAlive).toBe(false);
    await waitFor("every engine-created redis connection quit", () =>
      rig!.conns.every((r) => r.status === "end"),
    );

    // Idempotent: a second close() must neither throw nor re-flush.
    await expect(rig.engine.close()).resolves.toBeUndefined();
    expect(rig.flush).toHaveBeenCalledTimes(1);
  });
});

// ---------------------------------------------------------------------------
// Dedicated-uid boot contract (ungated — no redis/chromium needed)
// ---------------------------------------------------------------------------

describe("BrowserEngine uid-drop boot contract", () => {
  const uidCfg = () => makeCfg({ egressUid: 230_000, sandboxUidRange: [200_000, 209_999] });

  it("rejects construction when uid-drop preparation fails (fail loudly at boot)", async () => {
    await expect(
      createBrowserEngine({
        cfg: uidCfg(),
        redisFactory: () => {
          throw new Error("redis must not be touched during boot");
        },
        persistence: null,
        prepareUidDrop: async () => {
          throw new Error("uid drop unavailable");
        },
      }),
    ).rejects.toThrow("uid drop unavailable");
  });

  it("cleans up the prepared uid-drop runtime on close()", async () => {
    const cleanup = vi.fn(async () => {});
    const engine = await createBrowserEngine({
      cfg: uidCfg(),
      redisFactory: () => {
        throw new Error("redis must not be touched");
      },
      persistence: null,
      prepareUidDrop: async () => ({
        uid: 230_000,
        gid: 230_000,
        wrapperPath: "/tmp/ovid-test-shim.sh",
        downloadsDir: "/tmp/ovid-test-downloads",
        env: { ...process.env },
        cleanup,
      }),
    });
    await engine.close();
    expect(cleanup).toHaveBeenCalledTimes(1);
  });
});
