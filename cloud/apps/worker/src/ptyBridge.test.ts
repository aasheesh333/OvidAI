import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import Redis from "ioredis";
import {
  parsePtyOutMsg,
  parsePtyReplyMsg,
  ptyCtlChannel,
  ptyOutChannel,
  ptyRegistryKey,
  type PtyOutMsg,
  type PtyReplyMsg,
  type RingChunkWire,
} from "@ovid/shared";
import {
  PTY_SCROLLBACK_BYTES,
  SandboxAdmissionError,
  SandboxCapacityError,
  createChunkRing,
  type PtyHandlers,
  type PtyRequest,
  type PtySession,
  type SandboxHandle,
  type SandboxManager,
} from "@ovid/sandbox";
import { startWorkerPtyBridge } from "./ptyBridge.js";

/**
 * Worker pty bridge (Task 13), TEST_REDIS_URL-gated: the real PSUBSCRIBE
 * dispatch over real Redis against a stub SandboxManager whose handle creates
 * ring-backed fake PtySessions. TTL/heartbeat are injected short (300/100 ms)
 * per the brief so the PEXPIRE refresh is observable without wall-clock waits.
 *
 * Scoped cleanup only (shared dev redis — no FLUSHDB): this suite DELetes
 * exactly the pty:reg:* keys it created; channels are ephemeral pub/sub.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const TTL_MS = 300;
const HEARTBEAT_MS = 100;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForAsync(
  cond: () => Promise<boolean>,
  what: string,
  timeoutMs = 10_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await cond())) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(25);
  }
}

const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64");

// ---------------------------------------------------------------------------
// Ring-backed fake PtySessions + stub SandboxManager
// ---------------------------------------------------------------------------

interface FakePty {
  session: PtySession;
  writes: Buffer[];
  resizes: Array<{ cols: number; rows: number }>;
  /** Pushes text into the ring and fires the bridge's onData handler. */
  emit(text: string): void;
}

function fakePty(sessionId: string): FakePty & { bind(handlers: PtyHandlers): void } {
  const ring = createChunkRing(PTY_SCROLLBACK_BYTES);
  const writes: Buffer[] = [];
  const resizes: Array<{ cols: number; rows: number }> = [];
  let handlers: PtyHandlers | undefined;
  let alive = true;
  let resolveExit!: (code: number | null) => void;
  const exit = new Promise<number | null>((resolve) => {
    resolveExit = resolve;
  });
  const session: PtySession = {
    id: randomUUID().slice(0, 12),
    sessionId,
    ring,
    write: (data: Buffer) => {
      writes.push(data);
    },
    resize: (cols: number, rows: number) => {
      resizes.push({ cols, rows });
    },
    kill: async () => {
      if (alive) {
        alive = false;
        resolveExit(0);
        handlers?.onExit(0);
      }
    },
    exit,
    get alive(): boolean {
      return alive;
    },
  };
  return {
    session,
    writes,
    resizes,
    emit: (text: string) => {
      if (!alive) return;
      handlers?.onData(ring.push(Buffer.from(text, "utf8")));
    },
    bind: (h: PtyHandlers) => {
      handlers = h;
    },
  };
}

function stubSandbox(opts: { attachError?: Error } = {}): {
  manager: SandboxManager;
  ptys: FakePty[];
  attachCalls: string[];
} {
  const ptys: FakePty[] = [];
  const attachCalls: string[] = [];
  const handle = {
    createPty: async (req: PtyRequest, handlers: PtyHandlers) => {
      const fp = fakePty(req.sessionId);
      fp.bind(handlers);
      ptys.push(fp);
      return fp.session;
    },
  } as unknown as SandboxHandle;
  const manager = {
    attach: async (userId: string) => {
      attachCalls.push(userId);
      if (opts.attachError !== undefined) throw opts.attachError;
      return handle;
    },
  } as unknown as SandboxManager;
  return { manager, ptys, attachCalls };
}

// ---------------------------------------------------------------------------
// Harness: this suite plays the GATEWAY — publishes ctl frames, collects on
// dedicated reply/out channels.
// ---------------------------------------------------------------------------

interface Tap {
  /** The reply channel to hand the bridge in a ctl frame. */
  channel: string;
  next(): Promise<PtyOutMsg | PtyReplyMsg>;
}

// `pnpm -r test` runs independent workspace packages (worker, gateway)
// CONCURRENTLY, and Redis pub/sub is NOT db-scoped: this suite's live bridges
// (PSUBSCRIBE pty:ctl:*) answer ANY pty ctl frame on the shared test instance
// — including the gateway wsPty suite's harness frames, corrupting its
// reply-channel assertions. Both pty pub/sub suites (this one and the
// gateway's wsPty.test.ts) take this cross-suite lock so only ONE runs at a
// time. Crash-safe: the lock carries a TTL, a crashed holder frees it.
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

describe.skipIf(!TEST_REDIS_URL)("startWorkerPtyBridge (real redis)", () => {
  let redis: Redis;
  let releaseSuiteLock: (() => Promise<void>) | null = null;
  const stops: Array<() => Promise<void>> = [];
  const registryKeys: string[] = [];
  const taps: Redis[] = [];

  beforeAll(async () => {
    redis = new Redis(TEST_REDIS_URL!);
    releaseSuiteLock = await acquireSuiteLock(redis);
  });

  afterEach(async () => {
    while (stops.length > 0) await stops.pop()!().catch(() => {});
  });

  afterAll(async () => {
    // Every bridge is stopped in afterEach; release the lock BEFORE quitting
    // the connection so a waiting suite can start immediately.
    await releaseSuiteLock?.();
    for (const t of taps) await t.quit().catch(() => t.disconnect());
    if (registryKeys.length > 0) await redis.del(...registryKeys).catch(() => {});
    await redis.quit().catch(() => redis.disconnect());
  });

  async function tap(channel: string): Promise<Tap> {
    const sub = redis.duplicate();
    taps.push(sub);
    sub.on("error", () => {});
    const seen: Array<PtyOutMsg | PtyReplyMsg> = [];
    let cursor = 0;
    const waiters: Array<(v: PtyOutMsg | PtyReplyMsg) => void> = [];
    sub.on("message", (_ch: string, raw: string) => {
      let m: PtyOutMsg | PtyReplyMsg;
      try {
        m = (channel.startsWith("pty:out:") ? parsePtyOutMsg : parsePtyReplyMsg)(JSON.parse(raw));
      } catch {
        return; // garbage on the channel: skip
      }
      seen.push(m);
      const waiter = waiters.shift();
      if (waiter === undefined) return;
      cursor += 1;
      waiter(m);
    });
    // Await the ack BEFORE the caller publishes: a worker reply can otherwise
    // beat a fresh connection's SUBSCRIBE roundtrip.
    await sub.subscribe(channel);
    return {
      channel,
      next: () =>
        new Promise((resolve) => {
          if (cursor < seen.length) resolve(seen[cursor++]!);
          else waiters.push(resolve);
        }),
    };
  }

  /** Starts a bridge over `stub`'s manager; stop() is auto-run in afterEach. */
  async function startBridge(stub: ReturnType<typeof stubSandbox>): Promise<void> {
    const stop = await startWorkerPtyBridge(
      { sandbox: stub.manager, redis },
      { ttlMs: TTL_MS, heartbeatMs: HEARTBEAT_MS },
    );
    stops.push(stop);
  }

  let seq = 0;
  function freshIds(): { ptyId: string; sessionId: string } {
    seq += 1;
    const ptyId = `t13-${seq}-${randomUUID().slice(0, 8)}`;
    registryKeys.push(ptyRegistryKey(ptyId));
    return { ptyId, sessionId: `sess-${seq}` };
  }

  async function publishCtl(msg: Record<string, unknown>): Promise<void> {
    await redis.publish(ptyCtlChannel(msg.ptyId as string), JSON.stringify(msg));
  }

  async function openPty(userId = "u-t13"): Promise<{
    ptyId: string;
    sessionId: string;
    reply: PtyReplyMsg;
  }> {
    const { ptyId, sessionId } = freshIds();
    const replies = await tap(`pty:reply:t13-open-${seq}-${randomUUID().slice(0, 8)}`);
    await publishCtl({
      type: "open",
      ptyId,
      userId,
      sessionId,
      cols: 120,
      rows: 30,
      replyChannel: replies.channel,
    });
    // The reply channel only carries reply frames (tap is channel-agnostic).
    const reply = (await replies.next()) as PtyReplyMsg;
    return { ptyId, sessionId, reply };
  }

  it("open → opened reply, exact registry hash fields, TTL > 0, attach(userId) called", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, sessionId, reply } = await openPty();
    expect(reply).toEqual({ type: "opened", ptyId, sessionId });
    expect(stub.attachCalls).toEqual(["u-t13"]);

    const reg = (await redis.hgetall(ptyRegistryKey(ptyId))) as Record<string, string>;
    expect(Object.keys(reg).sort()).toEqual(["cols", "createdAt", "rows", "sessionId", "userId"]);
    expect(reg.userId).toBe("u-t13");
    expect(reg.sessionId).toBe(sessionId);
    expect(reg.cols).toBe("120");
    expect(reg.rows).toBe("30");
    expect(Number.isNaN(Date.parse(reg.createdAt))).toBe(false);

    expect(await redis.pttl(ptyRegistryKey(ptyId))).toBeGreaterThan(0);
    expect(stub.ptys).toHaveLength(1);
  }, 15_000);

  it("pty data → pty:out output messages with monotonic offsets", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, sessionId, reply } = await openPty();
    expect(reply.type).toBe("opened");

    const out = await tap(ptyOutChannel(ptyId));
    stub.ptys[0]!.emit("hello ");
    stub.ptys[0]!.emit("world");
    const m1 = (await out.next()) as PtyOutMsg;
    const m2 = (await out.next()) as PtyOutMsg;
    expect(m1).toEqual({ type: "output", ptyId, offset: 0, data: b64("hello ") });
    expect(m2).toEqual({ type: "output", ptyId, offset: 6, data: b64("world") });
  }, 15_000);

  it("close ctl → session killed, exit published, registry key gone (poll)", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, sessionId, reply } = await openPty();
    expect(reply.type).toBe("opened");
    const out = await tap(ptyOutChannel(ptyId));

    await publishCtl({ type: "close", ptyId });
    const m = (await out.next()) as PtyOutMsg;
    expect(m).toEqual({ type: "exit", ptyId, exitCode: 0 });
    expect(stub.ptys[0]!.session.alive).toBe(false);
    await waitForAsync(
      async () => (await redis.exists(ptyRegistryKey(ptyId))) === 0,
      "registry key gone after exit",
    );
    void sessionId;
  }, 15_000);

  it("attach → attach_reply chunks equal ring.since(lastOffset); covered bytes never re-delivered", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, sessionId, reply } = await openPty();
    expect(reply.type).toBe("opened");
    stub.ptys[0]!.emit("hello world"); // 11 bytes → ring, before any subscriber

    const ask = async (lastOffset: number | null): Promise<RingChunkWire[]> => {
      const replies = await tap(`pty:reply:t13-att-${seq}-${randomUUID().slice(0, 8)}`);
      await publishCtl({ type: "attach", ptyId, lastOffset, replyChannel: replies.channel });
      const m = (await replies.next()) as PtyReplyMsg;
      if (m.type !== "attach_reply") throw new Error(`expected attach_reply, got ${m.type}`);
      // Ground truth: the ring itself.
      const since = stub.ptys[0]!.session.ring.since(lastOffset);
      expect(m.chunks).toEqual(since.chunks as RingChunkWire[]);
      expect(m.endOffset).toBe(since.endOffset);
      expect(m.truncated).toBe(since.truncated);
      return m.chunks;
    };

    expect(await ask(null)).toEqual([{ offset: 0, data: b64("hello world") }]);
    expect(await ask(5)).toEqual([{ offset: 5, data: b64(" world") }]);
    expect(await ask(11)).toEqual([]); // everything consumed — never re-delivered
  }, 15_000);

  it("attach unknown ptyId → attach_failed pty_gone", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId } = freshIds();
    const replies = await tap(`pty:reply:t13-gone-${randomUUID().slice(0, 8)}`);
    await publishCtl({
      type: "attach",
      ptyId,
      lastOffset: null,
      replyChannel: replies.channel,
    });
    const m = (await replies.next()) as PtyReplyMsg;
    expect(m).toMatchObject({ type: "attach_failed", ptyId, code: "pty_gone" });
  }, 15_000);

  it("input → the pty received the decoded buffer; resize → recorded", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, sessionId, reply } = await openPty();
    expect(reply.type).toBe("opened");

    await publishCtl({ type: "input", ptyId, data: b64("ls -la\n") });
    await waitForAsync(() => Promise.resolve(stub.ptys[0]!.writes.length === 1), "write arrived");
    expect(stub.ptys[0]!.writes[0]!.equals(Buffer.from("ls -la\n", "utf8"))).toBe(true);

    await publishCtl({ type: "resize", ptyId, cols: 200, rows: 50 });
    await waitForAsync(() => Promise.resolve(stub.ptys[0]!.resizes.length === 1), "resize arrived");
    expect(stub.ptys[0]!.resizes[0]).toEqual({ cols: 200, rows: 50 });
    void sessionId;
  }, 15_000);

  it("admission errors map: SandboxAdmissionError → sandbox_busy; SandboxCapacityError → sandbox_unavailable", async () => {
    for (const [error, code] of [
      [new SandboxAdmissionError("admission timed out"), "sandbox_busy"],
      [new SandboxCapacityError("disk_pressure"), "sandbox_unavailable"],
    ] as const) {
      const stub = stubSandbox({ attachError: error });
      await startBridge(stub);
      const { ptyId, sessionId } = freshIds();
      const replies = await tap(`pty:reply:t13-adm-${randomUUID().slice(0, 8)}`);
      await publishCtl({
        type: "open",
        ptyId,
        userId: "u-adm",
        sessionId,
        cols: 80,
        rows: 24,
        replyChannel: replies.channel,
      });
      const m = (await replies.next()) as PtyReplyMsg;
      // Stop THIS bridge before the next iteration: two subscribed bridges
      // would both answer the same ctl pattern.
      await stops.pop()!().catch(() => {});
      expect(m).toMatchObject({ type: "opened_failed", ptyId, code });
      expect(stub.ptys).toHaveLength(0); // no pty created on a failed admission
    }
  }, 15_000);

  it("heartbeat refreshes the registry TTL — the key outlives ttlMs", async () => {
    const stub = stubSandbox();
    await startBridge(stub);
    const { ptyId, reply } = await openPty();
    expect(reply.type).toBe("opened");

    // Without the heartbeat the PEXPIRE(300) would delete the key by now.
    await sleep(TTL_MS + 200);
    expect(await redis.exists(ptyRegistryKey(ptyId))).toBe(1);
    const pttl = await redis.pttl(ptyRegistryKey(ptyId));
    expect(pttl).toBeGreaterThan(0);
    expect(pttl).toBeLessThanOrEqual(TTL_MS);
  }, 15_000);
});
