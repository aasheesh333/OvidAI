/**
 * Task 8 tests — the worker-side Redis browser bridge, against a REAL redis
 * (TEST_REDIS_URL). The harness plays the gateway with SEPARATE connections,
 * matching the real topology and redis's hard rule that a connection in
 * subscriber mode may not publish: `gw` only PUBLISHes ctl/input, and every
 * frames/state tap is its own subscriber connection. `mkBridge` tracks every
 * connection the factory created so `close()` can be proven to quit them all
 * (Review Focus #2). The malformed-input pins (`not-json`, `{type:"tap"}`)
 * prove the connection survives bad payloads (Review Focus #4).
 *
 * Cross-suite lock (T13 precedent, binding P6 ruling): `pnpm -r test` runs
 * the gateway and worker suites concurrently and redis pub/sub is not
 * db-scoped — this suite and any other suite that emits on browser channels
 * take `browser:test:suite-lock` so only one runs at a time (TTL-guarded, so
 * a crashed holder frees it).
 */

import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import IORedis, { type Redis } from "ioredis";

import {
  BROWSER_FRAME_FORMAT,
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  browserCtlMsgSchema,
  browserInputEventSchema,
  browserStateDtoSchema,
  type BrowserCtlMsg,
  type BrowserInputEvent,
  type BrowserStateDto,
} from "@ovid/shared";

import { createRedisBrowserBridge, type BrowserBridge } from "./bridge.js";
import { acquireBrowserSuiteLock } from "./test/suiteLock.js";

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const SUITE_LOCK_TTL_MS = 10_000;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function waitFor(what: string, predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

interface Tap {
  /** Raw pub/sub items in arrival order (channel + payload). */
  next(): Promise<{ channel: string; message: Buffer }>;
}

/**
 * Open a dedicated subscriber connection for `channel` and tap arrivals.
 * `binary` picks the ioredis event: `messageBuffer` delivers the payload as
 * a Buffer (frames are raw image bytes — the string-coerced `message` event
 * is lossy for non-UTF-8 payloads), `message` delivers UTF-8 text (JSON).
 * Both events deliver the CHANNEL as a Buffer, so compare stringified.
 */
async function openTap(channel: string, binary: boolean): Promise<Tap> {
  const redis = new IORedis(TEST_REDIS_URL!);
  tapConns.push(redis);
  const queue: Array<{ channel: string; message: Buffer }> = [];
  const waiters: Array<() => void> = [];
  redis.on(binary ? "messageBuffer" : "message", (ch: Buffer, msg: Buffer | string) => {
    if (ch.toString("utf8") !== channel) return;
    queue.push({ channel: channel, message: Buffer.isBuffer(msg) ? msg : Buffer.from(String(msg), "utf8") });
    for (const w of waiters.splice(0)) w();
  });
  await redis.subscribe(channel);
  // Every received message lands in the queue; `next()` resolves in arrival
  // order, so `await tap.next()` is also a synchronization point.
  return {
    next: () =>
      new Promise((resolve) => {
        const head = queue.shift();
        if (head) resolve(head);
        else waiters.push(() => resolve(queue.shift()!));
      }),
  };
}

/** The bridge under test + the connections its factory created (all tracked). */
function mkBridge(
  handlers: Parameters<typeof createRedisBrowserBridge>[0]["handlers"],
  opts?: { viewerStaleMs?: number; sweepIntervalMs?: number; now?: () => number },
): { bridge: BrowserBridge; created: IORedis[] } {
  const created: IORedis[] = [];
  const bridge = createRedisBrowserBridge({
    redisFactory: () => {
      const r = new IORedis(TEST_REDIS_URL!);
      created.push(r);
      return r;
    },
    handlers,
    ...opts,
  });
  return { bridge, created };
}

const join = (viewerId: string): string => JSON.stringify({ type: "viewer_join", viewerId } satisfies BrowserCtlMsg);
const leave = (viewerId: string): string => JSON.stringify({ type: "viewer_leave", viewerId } satisfies BrowserCtlMsg);
const takeover = (enabled: boolean): string => JSON.stringify({ type: "takeover", enabled } satisfies BrowserCtlMsg);
const noop = () => {};

const tapConns: Redis[] = [];describe.skipIf(!TEST_REDIS_URL)("createRedisBrowserBridge (real redis, harness plays the gateway)", () => {
  let gw: Redis; // the harness "gateway" publisher connection (command mode)
  let releaseSuiteLock: (() => Promise<void>) | null = null;

  beforeAll(async () => {
    gw = new IORedis(TEST_REDIS_URL!);
    releaseSuiteLock = await acquireBrowserSuiteLock(gw, { ttlMs: SUITE_LOCK_TTL_MS });
  });

  afterAll(async () => {
    await releaseSuiteLock?.();
    for (const r of tapConns) await r.quit().catch(() => {});
    await gw.quit().catch(() => {});
  });

  it("join/leave transitions fire onViewersChange on every size change", async () => {
    const sid = randomUUID();
    const events: Array<[string, number]> = [];
    const { bridge } = mkBridge({ onViewersChange: (s, v) => events.push([s, v]), onInput: noop, onTakeover: noop, onSwitchTab: noop });
    await bridge.watch(sid);

    await gw.publish(browserCtlChannel(sid), join("v1"));
    await waitFor("join v1 => 1", () => events.length >= 1);
    expect(events[0]).toEqual([sid, 1]);

    await gw.publish(browserCtlChannel(sid), join("v2"));
    await waitFor("join v2 => 2", () => events.length >= 2);
    expect(events[1]).toEqual([sid, 2]);

    await gw.publish(browserCtlChannel(sid), join("v1")); // duplicate join: size unchanged, NO event
    await sleep(80);
    expect(events.length).toBe(2);

    await gw.publish(browserCtlChannel(sid), leave("v1"));
    await waitFor("leave v1 => 1", () => events.length >= 3);
    expect(events[2]).toEqual([sid, 1]);
    expect(bridge.viewerCount(sid)).toBe(1);

    await bridge.close();
  });

  it("a stale viewer is swept to zero without any leave (gateway crash ⇒ screencast stops)", async () => {
    const sid = randomUUID();
    const events: Array<[string, number]> = [];
    let t = 10_000; // injected clock
    const { bridge } = mkBridge(
      { onViewersChange: (s, v) => events.push([s, v]), onInput: noop, onTakeover: noop, onSwitchTab: noop },
      { viewerStaleMs: 1000, sweepIntervalMs: 50, now: () => t },
    );
    await bridge.watch(sid);

    await gw.publish(browserCtlChannel(sid), join("v1"));
    await waitFor("join v1 => 1", () => events.length >= 1);

    t += 1500; // cross the stale threshold — no leave is ever published
    await waitFor("sweep to 0", () => events.length >= 2, 2000);
    expect(events[1]).toEqual([sid, 0]);
    expect(bridge.viewerCount(sid)).toBe(0);

    await bridge.close();
  });

  it("delivers only schema-valid input events, in arrival order, surviving bad payloads", async () => {
    const sid = randomUUID();
    const got: BrowserInputEvent[] = [];
    const { bridge } = mkBridge({ onViewersChange: noop, onInput: (_s, e) => got.push(e), onTakeover: noop, onSwitchTab: noop });
    await bridge.watch(sid);

    const tap: BrowserInputEvent = { type: "tap", x: 10, y: 20 };
    await gw.publish(browserInputChannel(sid), JSON.stringify(tap));
    await waitFor("valid tap", () => got.length >= 1);
    expect(got[0]).toEqual(tap);

    await gw.publish(browserInputChannel(sid), JSON.stringify({ type: "tap" })); // schema-invalid: missing x/y
    await gw.publish(browserInputChannel(sid), "not-json"); // unparseable
    await sleep(80);
    expect(got.length).toBe(1); // neither bad payload delivered

    const swipe: BrowserInputEvent = { type: "swipe", fromX: 0, fromY: 0, toX: 5, toY: 5, steps: 2 };
    await gw.publish(browserInputChannel(sid), JSON.stringify(swipe));
    await waitFor("post-garbage valid swipe still delivered", () => got.length >= 2);
    expect(got[1]).toEqual(swipe);

    await bridge.close();
  });

  it("surfaces the takeover toggle", async () => {
    const sid = randomUUID();
    const events: Array<[string, boolean]> = [];
    const { bridge } = mkBridge({ onViewersChange: noop, onInput: noop, onTakeover: (s, b) => events.push([s, b]), onSwitchTab: noop });
    await bridge.watch(sid);

    await gw.publish(browserCtlChannel(sid), takeover(true));
    await waitFor("takeover on", () => events.length >= 1);
    expect(events[0]).toEqual([sid, true]);

    await bridge.close();
  });

  it("publishFrame sends [format byte, image bytes] on the frames channel", async () => {
    const sid = randomUUID();
    const tap = await openTap(browserFramesChannel(sid), true);
    const { bridge } = mkBridge({ onViewersChange: noop, onInput: noop, onTakeover: noop, onSwitchTab: noop });

    bridge.publishFrame(sid, { format: "webp", data: Buffer.from("RIFFxxxxWEBP") });
    const got = await tap.next();
    expect(got.message[0]).toBe(BROWSER_FRAME_FORMAT.webp); // 2
    expect(got.message.subarray(1).toString("utf8")).toBe("RIFFxxxxWEBP");

    await bridge.close();
  });

  it("publishState sends a DTO that parses via browserStateDtoSchema", async () => {
    const sid = randomUUID();
    const state: BrowserStateDto = {
      sessionId: sid,
      live: true,
      url: "https://example.com/",
      title: "Example",
      takeover: false,
      screencast: true,
      frameFormat: "jpeg",
      viewport: { width: 1280, height: 720 },
    };
    const tap = await openTap(browserStateChannel(sid), false);
    const { bridge } = mkBridge({ onViewersChange: noop, onInput: noop, onTakeover: noop, onSwitchTab: noop });

    bridge.publishState(sid, state);
    const got = await tap.next();
    expect(browserStateDtoSchema.parse(JSON.parse(got.message.toString("utf8")))).toEqual(state);

    await bridge.close();
  });

  it("unwatch unsubscribes + quits the session connection; late ctl is ignored; close() quits every connection", async () => {
    const sid = randomUUID();
    const events: Array<[string, number]> = [];
    const { bridge, created } = mkBridge({ onViewersChange: (s, v) => events.push([s, v]), onInput: noop, onTakeover: noop, onSwitchTab: noop });
    await bridge.watch(sid);
    expect(created.length).toBe(1); // exactly one connection so far: the subscriber
    const sub = created[0];
    expect(sub.status).not.toBe("end");

    await bridge.unwatch(sid);
    await waitFor("subscriber quit after unwatch", () => sub.status === "end");

    await gw.publish(browserCtlChannel(sid), join("v9"));
    await sleep(80);
    expect(events.length).toBe(0); // no join observed after unwatch

    bridge.publishFrame(sid, { format: "jpeg", data: Buffer.from([0xff, 0xd8]) }); // lazily creates the publisher
    expect(created.length).toBe(2); // factory tracked the new connection
    await bridge.close();
    await waitFor("all factory connections quit on close()", () => created.every((r) => r.status === "end"));
  });

  it("watch twice for one session is idempotent (single connection)", async () => {
    const sid = randomUUID();
    const { bridge, created } = mkBridge({ onViewersChange: noop, onInput: noop, onTakeover: noop, onSwitchTab: noop });
    await bridge.watch(sid);
    await bridge.watch(sid);
    expect(created.filter((r) => r.status !== "end").length).toBe(1);
    await bridge.close();
  });

  it("the sweep interval is unref'd and cleared on close (never keeps the process alive)", async () => {
    const { bridge } = mkBridge({ onViewersChange: noop, onInput: noop, onTakeover: noop, onSwitchTab: noop }, { sweepIntervalMs: 1000 });
    // `_sweepTimer` is a test seam (documented in bridge.ts): the raw Node
    // Timeout handle, exposed so the unref can be asserted without timing a
    // whole process exit.
    const timer = (bridge as unknown as { _sweepTimer?: NodeJS.Timeout })._sweepTimer;
    expect(timer).toBeTruthy();
    expect((timer as unknown as { hasRef: () => boolean }).hasRef()).toBe(false); // unref'd

    await bridge.close();
    expect((bridge as unknown as { _sweepTimer?: NodeJS.Timeout | null })._sweepTimer).toBeNull();
  });

  it("schema sanity: the harness ctl/input messages parse against the shared schemas", () => {
    expect(browserCtlMsgSchema.parse(JSON.parse(join("v1")))).toEqual({ type: "viewer_join", viewerId: "v1" });
    expect(browserCtlMsgSchema.parse(JSON.parse(leave("v1")))).toEqual({ type: "viewer_leave", viewerId: "v1" });
    expect(browserCtlMsgSchema.parse(JSON.parse(takeover(true)))).toEqual({ type: "takeover", enabled: true });
    expect(browserInputEventSchema.parse({ type: "tap", x: 1, y: 2 })).toEqual({ type: "tap", x: 1, y: 2 });
  });

  it("publishFrame logs instead of throwing on a publisher error", async () => {
    const logs: Array<[string, unknown?]> = [];
    const log = (msg: string, err?: unknown) => logs.push([msg, err]);
    const bad = { publish: () => Promise.reject(new Error("redis down")) } as unknown as IORedis;
    const bridge = createRedisBrowserBridge({
      redisFactory: () => bad,
      handlers: { onViewersChange: noop, onInput: noop, onTakeover: noop, onSwitchTab: noop },
      log,
    });
    expect(() => bridge.publishFrame("s", { format: "jpeg", data: Buffer.from("x") })).not.toThrow();
    await waitFor("error logged", () => logs.length >= 1);
    expect(logs[0][0]).toContain("publishFrame");
    await bridge.close();
  });
});
