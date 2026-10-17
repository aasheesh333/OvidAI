import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import Redis from "ioredis";
import {
  parsePtyCtlMsg,
  ptyCtlChannel,
  ptyOutChannel,
  ptyRegistryKey,
  type PtyCtlMsg,
  type PtyOutMsg,
} from "@ovid/shared";
import {
  PTY_OPEN_TIMEOUT_MS,
  PTY_REPLY_TIMEOUT_MS,
  PtyBridgeError,
  createRedisPtyBridge,
  type PtyBridge,
} from "./wsPty.js";

/**
 * The gateway-side pty bridge (Task 13) against REAL Redis, with a test
 * harness that plays the worker protocol (subscribe the ctl channel, reply on
 * the request's replyChannel, publish to pty:out).
 *
 * Review Focus #3 — the ordering/dedupe contract — is pinned here: the bridge
 * SUBSCRIBEs pty:out BEFORE publishing the attach request, so a live chunk
 * that lands between that SUBSCRIBE and the attach_reply is seen by the
 * bridge; the offset dedupe then guarantees exactly-once (snapshot wins).
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64");

interface Tap {
  /** Raw pub/sub items in arrival order (channel + JSON text). */
  next(): Promise<{ channel: string; message: string }>;
}

// `pnpm -r test` runs independent workspace packages (worker, gateway)
// CONCURRENTLY, and Redis pub/sub is NOT db-scoped: while the worker
// ptyBridge suite's bridges (PSUBSCRIBE pty:ctl:*) are live they answer THIS
// suite's harness ctl frames — e.g. a foreign "opened" makes the timeout test
// resolve. Both pty pub/sub suites (this one and the worker's
// ptyBridge.test.ts) take this cross-suite lock so only ONE runs at a time.
// Crash-safe: the lock carries a TTL, a crashed holder frees it.
const SUITE_LOCK_KEY = "pty:test:suite-lock";
const SUITE_LOCK_TTL_MS = 10_000;

async function acquireSuiteLock(redis: Redis): Promise<() => Promise<void>> {
  const token = randomUUID();
  const deadline = Date.now() + 8_000;
  for (;;) {
    const ok = await redis.set(SUITE_LOCK_KEY, token, "PX", SUITE_LOCK_TTL_MS, "NX");
    if (ok === "OK") break;
    if (Date.now() > deadline) throw new Error("pty suite lock not free within 8s");
    await sleep(50);
  }
  let released = false;
  return async () => {
    if (released) return;
    released = true;
    // Release only OUR lock, atomically (a TTL expiry between GET and DEL
    // could otherwise delete the next holder's key).
    await redis
      .eval(
        "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
        1,
        SUITE_LOCK_KEY,
        token,
      )
      .catch(() => {});
  };
}

describe.skipIf(!TEST_REDIS_URL)("createRedisPtyBridge (real redis, harness plays the worker)", () => {
  let redis: Redis;
  let releaseSuiteLock: (() => Promise<void>) | null = null;
  const taps: Redis[] = [];
  const registryKeys: string[] = [];

  beforeAll(async () => {
    redis = new Redis(TEST_REDIS_URL!);
    releaseSuiteLock = await acquireSuiteLock(redis);
  });

  afterAll(async () => {
    await releaseSuiteLock?.();
    for (const t of taps) await t.quit().catch(() => t.disconnect());
    if (registryKeys.length > 0) await redis.del(...registryKeys).catch(() => {});
    await redis.quit().catch(() => redis.disconnect());
  });

  async function tap(channels: string[]): Promise<Tap> {
    const sub = redis.duplicate();
    taps.push(sub);
    sub.on("error", () => {});
    const seen: Array<{ channel: string; message: string }> = [];
    let cursor = 0;
    const waiters: Array<(v: { channel: string; message: string }) => void> = [];
    sub.on("message", (channel: string, message: string) => {
      const item = { channel, message };
      seen.push(item);
      const waiter = waiters.shift();
      if (waiter === undefined) return;
      cursor += 1;
      waiter(item);
    });
    await sub.subscribe(...channels);
    return {
      next: () =>
        new Promise((resolve) => {
          if (cursor < seen.length) resolve(seen[cursor++]!);
          else waiters.push(resolve);
        }),
    };
  }

  it("open publishes the ctl frame verbatim and resolves on the opened ack", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);

    const opened = bridge.open(
      ptyId,
      { userId: "u-wspty", sessionId: "sess-1", cols: 100, rows: 30 },
      PTY_OPEN_TIMEOUT_MS,
    );
    const ctlMsg = parsePtyCtlMsg(JSON.parse((await ctl.next()).message));
    expect(ctlMsg).toEqual({
      type: "open",
      ptyId,
      userId: "u-wspty",
      sessionId: "sess-1",
      cols: 100,
      rows: 30,
      replyChannel: expect.any(String),
    });
    expect((ctlMsg as { replyChannel: string }).replyChannel).toMatch(/^pty:reply:/);

    await redis.publish(
      (ctlMsg as { replyChannel: string }).replyChannel,
      JSON.stringify({ type: "opened", ptyId, sessionId: "sess-1" }),
    );
    await expect(opened).resolves.toBeUndefined();
  }, 15_000);

  it("opened_failed → rejects with PtyBridgeError carrying the code through", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);

    const p = bridge.open(ptyId, { userId: "u", sessionId: "s", cols: 80, rows: 24 }, PTY_OPEN_TIMEOUT_MS);
    const ctlMsg = parsePtyCtlMsg(JSON.parse((await ctl.next()).message)) as {
      replyChannel: string;
    };
    await redis.publish(
      ctlMsg.replyChannel,
      JSON.stringify({
        type: "opened_failed",
        ptyId,
        code: "sandbox_busy",
        message: "admission queue full",
      }),
    );
    const err = await p.then(
      () => {
        throw new Error("expected a rejection");
      },
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(PtyBridgeError);
    expect((err as PtyBridgeError).code).toBe("sandbox_busy");
    expect((err as PtyBridgeError).message).toBe("admission queue full");
  }, 15_000);

  it("no ack within replyTimeoutMs (override 200 ms) → rejects; the override beats the per-call timeout", async () => {
    const bridge = createRedisPtyBridge(redis, { replyTimeoutMs: 200 });
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);

    const started = Date.now();
    const p = bridge.open(ptyId, { userId: "u", sessionId: "s", cols: 80, rows: 24 }, PTY_OPEN_TIMEOUT_MS);
    await ctl.next(); // the ctl went out; nobody will answer it
    const err = await p.then(
      () => {
        throw new Error("expected a rejection");
      },
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(PtyBridgeError);
    expect((err as PtyBridgeError).code).toBe("timeout");
    expect(Date.now() - started).toBeLessThan(2_000); // 200 ms override, not the 30 s default
  }, 15_000);

  it("attach — Review Focus #3: pty:out subscribed BEFORE the ctl publish; a live chunk covered by the snapshot is dropped (snapshot wins), a chunk beyond endOffset arrives", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);
    const outSeen: PtyOutMsg[] = [];

    const attached = bridge.attach(ptyId, null, (m) => outSeen.push(m), PTY_REPLY_TIMEOUT_MS);
    const ctlMsg = parsePtyCtlMsg(JSON.parse((await ctl.next()).message));
    expect(ctlMsg).toEqual({
      type: "attach",
      ptyId,
      lastOffset: null,
      replyChannel: expect.any(String),
    });
    // The attach request is only published AFTER the pty:out SUBSCRIBE, so a
    // chunk published any time from here on is seen by the bridge.
    const channels = (await redis.pubsub("CHANNELS", ptyOutChannel(ptyId))) as unknown as string[];
    expect(channels).toContain(ptyOutChannel(ptyId));

    // Live chunk fully covered by the snapshot that follows — it must be
    // delivered ONLY via the snapshot chunks, never through onOut.
    await redis.publish(
      ptyOutChannel(ptyId),
      JSON.stringify({ type: "output", ptyId, offset: 0, data: b64("covered") }),
    );
    await redis.publish(
      (ctlMsg as { replyChannel: string }).replyChannel,
      JSON.stringify({
        type: "attach_reply",
        ptyId,
        truncated: false,
        chunks: [{ offset: 0, data: b64("covered") }],
        endOffset: 7,
      }),
    );
    const res = await attached;
    expect(res.truncated).toBe(false);
    expect(res.chunks).toEqual([{ offset: 0, data: b64("covered") }]);
    expect(res.endOffset).toBe(7);

    // A live chunk BEYOND endOffset arrives through onOut — the subscription
    // is live (proves nothing was lost in the pre-snapshot window).
    await redis.publish(
      ptyOutChannel(ptyId),
      JSON.stringify({ type: "output", ptyId, offset: 7, data: b64("live") }),
    );
    await waitFor(() => outSeen.length === 1, "beyond-endOffset chunk via onOut");
    await sleep(150); // any duplicate of the covered chunk would land here
    expect(outSeen).toEqual([{ type: "output", ptyId, offset: 7, data: b64("live") }]);
    expect(outSeen.filter((m) => m.type === "output" && m.offset === 0)).toHaveLength(0);

    await res.detach();
    // After detach nothing is delivered anymore.
    await redis.publish(
      ptyOutChannel(ptyId),
      JSON.stringify({ type: "output", ptyId, offset: 11, data: b64("ignored") }),
    );
    await sleep(150);
    expect(outSeen).toHaveLength(1);
  }, 15_000);

  it("frame order (review round-1 Important 1): buffered beyond-endOffset live tail arrives AFTER ack + snapshot — ACK → SNAPSHOT → LIVE, each offset exactly once", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);
    const order: string[] = [];

    // The `order` log proxies the socket: "ACK" + "SNAP:n" are pushed in the
    // continuation that runs when the bridge resolves — the exact point where
    // the ws dispatch sends pty_opened/pty_attached and the snapshot frames —
    // and "LIVE:n" is onOut (a live pty_output frame on the socket).
    const attached = (async () => {
      const res = await bridge.attach(
        ptyId,
        null,
        (m) => {
          if (m.type === "output") order.push(`LIVE:${m.offset}`);
        },
        PTY_REPLY_TIMEOUT_MS,
      );
      order.push("ACK");
      for (const c of res.chunks) order.push(`SNAP:${c.offset}`);
      return res;
    })();

    const ctlMsg = parsePtyCtlMsg(JSON.parse((await ctl.next()).message));
    const channels = (await redis.pubsub("CHANNELS", ptyOutChannel(ptyId))) as unknown as string[];
    expect(channels).toContain(ptyOutChannel(ptyId)); // pty:out subscribed before the ctl went out

    // The race window: BEFORE the attach_reply lands, TWO live chunks are
    // published — one fully covered by the upcoming snapshot (dropped), one
    // BEYOND its endOffset (buffered inside the bridge). Redis delivers
    // publishes in order, so both are in the pre-snapshot buffer when the
    // reply arrives — the buffered-beyond-end path.
    await redis.publish(
      ptyOutChannel(ptyId),
      JSON.stringify({ type: "output", ptyId, offset: 0, data: b64("covered") }),
    );
    await redis.publish(
      ptyOutChannel(ptyId),
      JSON.stringify({ type: "output", ptyId, offset: 7, data: b64("beyond") }),
    );
    await redis.publish(
      (ctlMsg as { replyChannel: string }).replyChannel,
      JSON.stringify({
        type: "attach_reply",
        ptyId,
        truncated: false,
        chunks: [{ offset: 0, data: b64("covered") }],
        endOffset: 7,
      }),
    );

    const res = await attached;
    expect(res.chunks).toEqual([{ offset: 0, data: b64("covered") }]);
    expect(res.endOffset).toBe(7);

    // The buffered tail is flushed from a macrotask; let it fire.
    await sleep(100);

    // Pinned frame order: ack first, snapshot second, buffered live tail
    // last. A pre-ack flush (the bug) would show LIVE:7 before ACK.
    expect(order).toEqual(["ACK", "SNAP:0", "LIVE:7"]);
    // Exactly once: offset 7 arrives exactly once, offset 0 only via the
    // snapshot (never LIVE — the covered chunk is dropped, snapshot wins).
    expect(order.filter((o) => o === "LIVE:7")).toHaveLength(1);
    expect(order.includes("LIVE:0")).toBe(false);
  }, 15_000);

  it("attach_failed → rejects with the pty_gone code through", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);

    const p = bridge.attach(
      ptyId,
      5,
      () => {},
      PTY_REPLY_TIMEOUT_MS,
    );
    const ctlMsg = parsePtyCtlMsg(JSON.parse((await ctl.next()).message)) as { replyChannel: string };
    expect(ctlMsg).toMatchObject({ type: "attach", ptyId, lastOffset: 5 });
    await redis.publish(
      ctlMsg.replyChannel,
      JSON.stringify({ type: "attach_failed", ptyId, code: "pty_gone", message: "terminal no longer exists" }),
    );
    const err = await p.then(
      () => {
        throw new Error("expected a rejection");
      },
      (e: unknown) => e,
    );
    expect(err).toBeInstanceOf(PtyBridgeError);
    expect((err as PtyBridgeError).code).toBe("pty_gone");
  }, 15_000);

  it("lookup returns the registry fields; null when missing or expired", async () => {
    const bridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    registryKeys.push(ptyRegistryKey(ptyId));

    expect(await bridge.lookup(ptyId)).toBeNull();

    await redis.hset(ptyRegistryKey(ptyId), {
      userId: "u-lookup",
      sessionId: "sess-lookup",
      cols: "80",
      rows: "24",
      createdAt: new Date().toISOString(),
    });
    expect(await bridge.lookup(ptyId)).toEqual({ userId: "u-lookup", sessionId: "sess-lookup" });

    // Expired registry (TTL lapsed): lookup must see it as gone.
    const ptyId2 = randomUUID();
    registryKeys.push(ptyRegistryKey(ptyId2));
    await redis.hset(ptyRegistryKey(ptyId2), {
      userId: "u-lookup",
      sessionId: "sess-lookup",
      cols: "80",
      rows: "24",
      createdAt: new Date().toISOString(),
    });
    await redis.pexpire(ptyRegistryKey(ptyId2), 1);
    await sleep(50);
    expect(await bridge.lookup(ptyId2)).toBeNull();
  }, 15_000);

  it("send publishes input/resize/close ctl verbatim (ptyId merged into each variant)", async () => {
    const bridge: PtyBridge = createRedisPtyBridge(redis);
    const ptyId = randomUUID();
    const ctl = await tap([ptyCtlChannel(ptyId)]);

    await bridge.send(ptyId, { type: "input", data: b64("hi\n") });
    expect(parsePtyCtlMsg(JSON.parse((await ctl.next()).message))).toEqual({
      type: "input",
      ptyId,
      data: b64("hi\n"),
    } satisfies PtyCtlMsg);

    await bridge.send(ptyId, { type: "resize", cols: 100, rows: 40 });
    expect(parsePtyCtlMsg(JSON.parse((await ctl.next()).message))).toEqual({
      type: "resize",
      ptyId,
      cols: 100,
      rows: 40,
    } satisfies PtyCtlMsg);

    await bridge.send(ptyId, { type: "close" });
    expect(parsePtyCtlMsg(JSON.parse((await ctl.next()).message))).toEqual({
      type: "close",
      ptyId,
    } satisfies PtyCtlMsg);
  }, 15_000);
});
