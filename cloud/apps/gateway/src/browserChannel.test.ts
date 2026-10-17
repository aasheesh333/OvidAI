import { randomUUID } from "node:crypto";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import type { FastifyInstance } from "fastify";
import IORedis, { type Redis } from "ioredis";
import WebSocket, { type RawData, type WebSocket as WsSocket } from "ws";
import { sessions, users, type Db } from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import {
  BROWSER_FRAME_FORMAT,
  browserCtlChannel,
  browserFramesChannel,
  browserInputChannel,
  browserStateChannel,
  wsServerMsg,
  type BrowserStateDto,
  type WsServerMsg,
} from "@ovid/shared";
import { buildGateway } from "./app.js";
import { createTicketStore, type TicketStore } from "./tickets.js";
import type { PtyBridge } from "./wsPty.js";
import { handleWsConnection, type WsConnectionOptions, type WsDeps } from "./ws.js";
import { BROWSER_FRAME_HIGH_WATER, BROWSER_VIEWER_HEARTBEAT_MS } from "./browserChannel.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "./test/db.js";
import { stubSystemBus, stubKeys, stubMint, stubQueues, stubTickets, stubVerifier } from "./test/stubs.js";

/**
 * Task 9 tests — the gateway `browser` WS channel, against real Redis + real
 * Postgres. The harness plays the worker (T8's bridge peer) with SEPARATE
 * connections, matching the real topology and redis's hard rule that a
 * connection in subscriber mode may not publish (binding T8-review carry):
 * one command-mode peer connection PUBLISHes state/frames, and every ctl/
 * input observation tap is its own dedicated subscriber connection.
 *
 * Cross-suite lock (binding T8 carry): this suite EMITS on browser:* pub/sub
 * channels and redis pub/sub is not db-scoped — `pnpm -r test` may run the
 * @ovid/browser bridge suite concurrently — so every test takes
 * `browser:test:suite-lock` (SET NX PX + token-guarded Lua release) for the
 * duration of its publishes. Taken per TEST (not per suite): each test holds
 * it for only a few seconds, comfortably inside the TTL a crashed holder needs
 * to be freed.
 *
 * The slow-client and heartbeat pins drive handleWsConnection directly with
 * a stub-send socket (the brief's test-only seam): bufferedAmount is a plain
 * property the test sets, so the high-water drop is deterministic without
 * timing a real TCP backpressure window, and the heartbeat interval is
 * injected through WsConnectionOptions.browserHeartbeatMs.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const WS_PATH = "/cloud/ws"; // contract path, hardcoded on purpose
const SUITE_LOCK_KEY = "browser:test:suite-lock";
const SUITE_LOCK_TTL_MS = 10_000;

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

// ---------------------------------------------------------------------------
// Harness pieces shared by both real-redis describes.
// ---------------------------------------------------------------------------

function parseJson(buf: Buffer): Record<string, unknown> {
  return JSON.parse(buf.toString("utf8")) as Record<string, unknown>;
}

/** A valid BrowserStateDto for `sid` (schema-exact). */
function mkState(sid: string): BrowserStateDto {
  return {
    sessionId: sid,
    live: true,
    url: "https://example.com/",
    title: "Example",
    takeover: false,
    screencast: true,
    frameFormat: "jpeg",
    viewport: { width: 1280, height: 720 },
  };
}

const JPEG = Buffer.from([
  0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0xff, 0xd9,
]);

/** The worker's wire format: 1-byte BROWSER_FRAME_FORMAT prefix + image bytes. */
function framePayload(image: Buffer): Buffer {
  return Buffer.concat([Buffer.from([BROWSER_FRAME_FORMAT.jpeg]), image]);
}

/** Every tap connection ever opened (quit in afterAll; double-quit is caught). */
const tapConns: Redis[] = [];

/**
 * Dedicated subscriber connection on `channel` (text payloads: the JSON ctl/
 * input/state channels). Awaited BEFORE the subscriber is registered, so a
 * publish triggered right after openTap() cannot be missed.
 */
async function openTap(channel: string): Promise<{
  received: Array<{ channel: string; message: Buffer }>;
  next(what: string, timeoutMs?: number): Promise<{ channel: string; message: Buffer }>;
}> {
  const redis = new IORedis(TEST_REDIS_URL!);
  tapConns.push(redis);
  const received: Array<{ channel: string; message: Buffer }> = [];
  redis.on("message", (ch: Buffer, msg: string) => {
    if (ch.toString("utf8") !== channel) return;
    received.push({ channel, message: Buffer.from(msg, "utf8") });
  });
  await redis.subscribe(channel);
  return {
    received,
    async next(what, timeoutMs = 10_000) {
      const deadline = Date.now() + timeoutMs;
      while (received.length === 0) {
        if (Date.now() >= deadline) throw new Error(`tap timed out: ${what}`);
        await sleep(10);
      }
      return received.shift()!;
    },
  };
}

async function quitTaps(): Promise<void> {
  for (const t of tapConns.splice(0)) await t.quit().catch(() => {});
}

/**
 * The T8 suite-lock pattern, verbatim: SET NX PX with a random token, and a
 * token-checked Lua DEL on release so a TTL expiry between GET and DEL can
 * never delete the NEXT holder's key.
 */
async function acquireSuiteLock(redis: Redis): Promise<() => Promise<void>> {
  const token = randomUUID();
  const deadline = Date.now() + 30_000;
  for (;;) {
    const ok = await redis.set(SUITE_LOCK_KEY, token, "PX", SUITE_LOCK_TTL_MS, "NX");
    if (ok === "OK") break;
    if (Date.now() > deadline) throw new Error("browser suite lock not free within 30s");
    await sleep(50);
  }
  let released = false;
  return async () => {
    if (released) return;
    released = true;
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

function rawToBuffer(data: RawData): Buffer {
  if (Array.isArray(data)) return Buffer.concat(data);
  if (data instanceof ArrayBuffer) return Buffer.from(data);
  return data;
}

// ---------------------------------------------------------------------------
// Real gateway: buildGateway + real ticket store + real db ownership rows +
// a real ws client that records BOTH text and binary frames.
// ---------------------------------------------------------------------------

interface TestClient {
  socket: WebSocket;
  /** Text frames, parsed THROUGH the shared schema (off-contract frames throw). */
  messages: WsServerMsg[];
  /** Binary frames (screencast image bytes) in arrival order. */
  binary: Buffer[];
  closeCode: Promise<number>;
  send(msg: unknown): void;
  sendRaw(raw: string): void;
  waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
  close(): Promise<number>;
}

async function connectClient(wsBase: string, ticket: string | null): Promise<TestClient> {
  const url = ticket === null ? wsBase : `${wsBase}?ticket=${encodeURIComponent(ticket)}`;
  const socket = new WebSocket(url);
  const messages: WsServerMsg[] = [];
  const binary: Buffer[] = [];
  socket.on("message", (data: RawData, isBinary: boolean) => {
    if (isBinary) binary.push(rawToBuffer(data));
    else messages.push(wsServerMsg(JSON.parse(data.toString())));
  });
  let resolveClose!: (code: number) => void;
  const closeCode = new Promise<number>((resolve) => {
    resolveClose = resolve;
  });
  socket.on("close", (code) => resolveClose(code));
  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
  return {
    socket,
    messages,
    binary,
    closeCode,
    send: (msg) => socket.send(JSON.stringify(msg)),
    sendRaw: (raw) => socket.send(raw),
    waitFor: (cond, what, timeoutMs) => waitFor(cond, what, timeoutMs),
    async close() {
      if (socket.readyState === WebSocket.OPEN || socket.readyState === WebSocket.CONNECTING) {
        socket.close();
      }
      return closeCode;
    },
  };
}

describe.skipIf(!TEST_REDIS_URL || !TEST_DATABASE_URL)(
  "gateway /cloud/ws browser_* ops (real redis + postgres)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let tickets: TicketStore;
    const apps: FastifyInstance[] = [];
    const clients: TestClient[] = [];
    const createdSids: string[] = [];
    let releaseSuiteLock: (() => Promise<void>) | null = null;

    beforeAll(async () => {
      db = await openTestDb();
      redis = new IORedis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);
    }, 60_000);

    beforeEach(async () => {
      releaseSuiteLock = await acquireSuiteLock(redis);
    });

    afterEach(async () => {
      // Clients first (their teardown publishes viewer_leave — still inside
      // the lock), then apps, then release the lock for the next holder.
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      while (apps.length > 0) await apps.pop()!.close();
      await releaseSuiteLock?.();
      releaseSuiteLock = null;
    });

    afterAll(async () => {
      // Clean up only the keys this suite created (streams; ticket keys have a
      // TTL and are consumed by verify anyway; browser:* pub/sub keys none).
      if (createdSids.length > 0) {
        await redis.del(createdSids.map((s) => `sess:${s}:events`)).catch(() => {});
      }
      await quitTaps();
      await redis.quit().catch(() => redis.disconnect());
      await closeDb(db);
    });

    /**
     * Builds a listening gateway. With `withBrowser` (default) the browser
     * channel is wired with a tracking redisFactory — every connection it
     * created is recorded so tests can prove teardown quits them all.
     */
    async function makeApp(withBrowser = true): Promise<{ wsBase: string; created: Redis[] }> {
      const created: Redis[] = [];
      const app = buildGateway({
        system: stubSystemBus(),
        db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets,
        keys: stubKeys(),
        mint: stubMint(),
        events,
        ...(withBrowser
          ? {
              browser: {
                redisFactory: () => {
                  const r = new IORedis(TEST_REDIS_URL!);
                  created.push(r);
                  return r;
                },
              },
            }
          : {}),
      });
      apps.push(app);
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      return { wsBase: `ws://127.0.0.1:${port}${WS_PATH}`, created };
    }

    async function newClient(wsBase: string, ticket: string | null): Promise<TestClient> {
      const client = await connectClient(wsBase, ticket);
      clients.push(client);
      return client;
    }

    async function createOwnedSession(uid: string): Promise<string> {
      await users.ensure(db, uid, null);
      const row = await sessions.create(db, uid, null);
      createdSids.push(row.id);
      return row.id;
    }

    const channelCount = async (channel: string): Promise<number> =>
      ((await redis.pubsub("CHANNELS", channel)) as unknown as string[]).length;

    it("browser_attach: viewer_join on ctl; nothing until the worker publishes; invalid state dropped; state + binary frame relayed (prefix stripped)", async () => {
      const uid = testUid("ws9a");
      const sid = await createOwnedSession(uid);
      const ctlTap = await openTap(browserCtlChannel(sid));

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "browser_attach", sessionId: sid });

      // The worker-side peer observes the join; the message is schema-shaped.
      const join = parseJson((await ctlTap.next("viewer_join")).message);
      expect(join).toEqual({ type: "viewer_join", viewerId: expect.any(String) });

      // NO ack frame exists for browser_attach: the client receives nothing
      // until the worker publishes state/frames.
      await sleep(200);
      expect(client.messages).toEqual([]);
      expect(client.binary).toEqual([]);

      // Schema-invalid state → logged and DROPPED; the connection survives.
      await redis.publish(browserStateChannel(sid), JSON.stringify({ nope: true }));
      await sleep(200);
      expect(client.messages).toEqual([]);

      // Valid state → forwarded verbatim as a browser_state op.
      await redis.publish(browserStateChannel(sid), JSON.stringify(mkState(sid)));
      await client.waitFor(
        () => client.messages.some((m) => m.op === "browser_state"),
        "browser_state frame",
      );
      expect(client.messages).toEqual([{ op: "browser_state", sessionId: sid, state: mkState(sid) }]);

      // Binary frame: the redis format-prefix byte is STRIPPED; the client
      // receives the bare image bytes as a BINARY ws message.
      await redis.publish(browserFramesChannel(sid), framePayload(JPEG));
      await client.waitFor(() => client.binary.length === 1, "binary frame");
      expect(client.binary[0]).toEqual(JPEG);
    }, 20_000);

    it("browser_input → exact event JSON on the input channel; browser_takeover → ctl takeover", async () => {
      const uid = testUid("ws9b");
      const sid = await createOwnedSession(uid);
      const ctlTap = await openTap(browserCtlChannel(sid));
      const inputTap = await openTap(browserInputChannel(sid));

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "browser_attach", sessionId: sid });
      await ctlTap.next("viewer_join before input");

      client.send({ op: "browser_input", sessionId: sid, input: { type: "tap", x: 12.5, y: 30 } });
      const input = parseJson((await inputTap.next("input event on the input channel")).message);
      expect(input).toEqual({ type: "tap", x: 12.5, y: 30 });

      client.send({ op: "browser_takeover", sessionId: sid, enabled: true });
      const on = parseJson((await ctlTap.next("takeover on")).message);
      expect(on).toEqual({ type: "takeover", enabled: true });
      client.send({ op: "browser_takeover", sessionId: sid, enabled: false });
      const off = parseJson((await ctlTap.next("takeover off")).message);
      expect(off).toEqual({ type: "takeover", enabled: false });
    }, 20_000);

    it("attach to another user's session → forbidden (no join published); the socket still serves a normal subscribe", async () => {
      const uidOwner = testUid("ws9c-owner");
      const uidOther = testUid("ws9c-other");
      const sidOwner = await createOwnedSession(uidOwner);
      const sidOwn = await createOwnedSession(uidOther);
      const ctlTap = await openTap(browserCtlChannel(sidOwner));

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uidOther));

      client.send({ op: "browser_attach", sessionId: sidOwner });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "forbidden error frame",
      );
      expect(client.messages[0]).toEqual({
        op: "error",
        code: "forbidden",
        message: expect.any(String),
        sessionId: sidOwner,
      });
      await sleep(150);
      expect(ctlTap.received).toEqual([]); // ownership was refused BEFORE any redis work

      // Channel independence regression: the same socket keeps working.
      client.send({ op: "subscribe", sessionId: sidOwn });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "subscribed"),
        "subscribed on the same socket",
      );
    }, 20_000);

    it("gateway composed without browser deps → unavailable; the connection survives", async () => {
      const uid = testUid("ws9d");
      const sid = await createOwnedSession(uid);

      const { wsBase } = await makeApp(false);
      const client = await newClient(wsBase, await tickets.mint(uid));

      client.send({ op: "browser_attach", sessionId: sid });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "unavailable error frame",
      );
      expect(client.messages[0]).toMatchObject({
        op: "error",
        code: "unavailable",
        message: "Browser channel not configured.",
      });

      client.send({ op: "ping" });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "pong"),
        "pong (connection survived)",
      );
    }, 20_000);

    it("browser_input / browser_takeover without an attach for that session → not_attached", async () => {
      const uid = testUid("ws9e");
      const sidA = await createOwnedSession(uid);
      const sidB = await createOwnedSession(uid);
      const ctlTapA = await openTap(browserCtlChannel(sidA));

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      // No attach at all.
      client.send({ op: "browser_input", sessionId: sidA, input: { type: "key", key: "Enter" } });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "not_attached (input, no attach)",
      );
      expect(client.messages[0]).toEqual({
        op: "error",
        code: "not_attached",
        message: expect.any(String),
        sessionId: sidA,
      });

      client.send({ op: "browser_takeover", sessionId: sidA, enabled: true });
      await client.waitFor(
        () => client.messages.filter((m) => m.op === "error").length === 2,
        "not_attached (takeover, no attach)",
      );
      expect(client.messages[1]).toMatchObject({ op: "error", code: "not_attached", sessionId: sidA });

      // Attached to A: ops naming a DIFFERENT session are still not_attached.
      client.send({ op: "browser_attach", sessionId: sidA });
      await ctlTapA.next("join A");
      client.send({ op: "browser_input", sessionId: sidB, input: { type: "key", key: "Enter" } });
      await client.waitFor(
        () => client.messages.filter((m) => m.op === "error").length === 3,
        "not_attached (input for sidB)",
      );
      expect(client.messages[2]).toMatchObject({ op: "error", code: "not_attached", sessionId: sidB });
    }, 20_000);

    it("malformed input payload → bad_message; the connection survives", async () => {
      const uid = testUid("ws9f");
      const sid = await createOwnedSession(uid);

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      // Valid JSON, off-schema input event (tap without x/y) — refused at the
      // shared wsClientMsg parse, never published.
      client.sendRaw(JSON.stringify({ op: "browser_input", sessionId: sid, input: { type: "tap" } }));
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "bad_message error frame",
      );
      expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_message" });

      client.send({ op: "ping" });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "pong"),
        "pong (connection survived)",
      );
    }, 20_000);

    it("re-attach replaces: peer sees leave(v1) then join(v2); frames flow exactly once to the new viewer", async () => {
      const uid = testUid("ws9g");
      const sid = await createOwnedSession(uid);
      const ctlTap = await openTap(browserCtlChannel(sid));

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      client.send({ op: "browser_attach", sessionId: sid });
      const join1 = parseJson((await ctlTap.next("join v1")).message);

      client.send({ op: "browser_attach", sessionId: sid });
      const leave1 = parseJson((await ctlTap.next("leave v1")).message);
      const join2 = parseJson((await ctlTap.next("join v2")).message);

      expect(join1).toEqual({ type: "viewer_join", viewerId: expect.any(String) });
      expect(leave1).toEqual({ type: "viewer_leave", viewerId: join1.viewerId });
      expect(join2).toEqual({ type: "viewer_join", viewerId: expect.any(String) });
      expect(join2.viewerId).not.toBe(join1.viewerId); // each attach mints a fresh viewerId

      // The replacement viewer's subscriber is live and the old one is gone:
      // exactly ONE copy of the frame reaches the socket.
      await redis.publish(browserFramesChannel(sid), framePayload(JPEG));
      await client.waitFor(() => client.binary.length === 1, "frame after re-attach");
      await sleep(250); // a second copy from a leaked old subscriber would land here
      expect(client.binary).toHaveLength(1);
      expect(client.binary[0]).toEqual(JPEG);
    }, 20_000);

    it("socket close → viewer_leave published, both attach connections quit, channel count back to baseline", async () => {
      const uid = testUid("ws9h");
      const sid = await createOwnedSession(uid);
      const ctlTap = await openTap(browserCtlChannel(sid));

      const { wsBase, created } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      client.send({ op: "browser_attach", sessionId: sid });
      const join = parseJson((await ctlTap.next("join")).message);
      // TWO connections per attach (binding T8 carry): a SEPARATE ctl/input
      // publisher and a frames/state subscriber — a subscriber-mode
      // connection cannot publish, and the join above proves the publisher
      // was never in subscriber mode.
      expect(created).toHaveLength(2);

      // Socket close (no explicit browser_detach): the teardown path must
      // publish the leave and quit both connections.
      await client.close();
      const leave = parseJson((await ctlTap.next("leave on socket close")).message);
      expect(leave).toEqual({ type: "viewer_leave", viewerId: join.viewerId });

      await waitForAsync(
        () => created.every((c) => c.status === "end"),
        "both attach connections quit",
      );
      await waitForAsync(
        async () => (await channelCount(browserStateChannel(sid))) === 0,
        "state channel back to baseline",
      );
      await waitForAsync(
        async () => (await channelCount(browserFramesChannel(sid))) === 0,
        "frames channel back to baseline",
      );
    }, 20_000);

    it("browser_detach → viewer_leave + connections quit; a later socket close publishes NO second leave", async () => {
      const uid = testUid("ws9i");
      const sid = await createOwnedSession(uid);
      const ctlTap = await openTap(browserCtlChannel(sid));

      const { wsBase, created } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      client.send({ op: "browser_attach", sessionId: sid });
      const join = parseJson((await ctlTap.next("join")).message);

      client.send({ op: "browser_detach", sessionId: sid });
      const leave = parseJson((await ctlTap.next("leave on detach")).message);
      expect(leave).toEqual({ type: "viewer_leave", viewerId: join.viewerId });
      await waitForAsync(
        () => created.every((c) => c.status === "end"),
        "both attach connections quit on detach",
      );

      // Frames published after the detach never reach the client.
      await redis.publish(browserFramesChannel(sid), framePayload(JPEG));
      await sleep(250);
      expect(client.binary).toEqual([]);

      // Socket close after an explicit detach: teardown is a no-op — exactly
      // one viewer_leave was ever published for this viewer.
      await client.close();
      await sleep(300);
      expect(ctlTap.received).toEqual([]);
    }, 20_000);
  },
);

// ---------------------------------------------------------------------------
// Deterministic pins via handleWsConnection + a stub-send socket: the
// slow-client high-water drop and the join heartbeat. Real redis for the
// browser channel; stubs for everything the browser ops never touch.
// ---------------------------------------------------------------------------

/** Minimal socket surface handleWsConnection uses; bufferedAmount is settable. */
function mkStubSocket(): {
  socket: WsSocket;
  sent: Array<{ kind: "text"; data: string } | { kind: "binary"; data: Buffer }>;
  state: { readyState: number; bufferedAmount: number };
  emitMessage(raw: string): void;
  emitClose(): void;
} {
  const listeners = new Map<string, Array<(...args: unknown[]) => void>>();
  const sent: Array<{ kind: "text"; data: string } | { kind: "binary"; data: Buffer }> = [];
  const state = { readyState: 1, bufferedAmount: 0 }; // 1 === OPEN
  const socket = {
    OPEN: 1,
    get readyState() {
      return state.readyState;
    },
    get bufferedAmount() {
      return state.bufferedAmount;
    },
    on(event: string, cb: (...args: unknown[]) => void) {
      const arr = listeners.get(event) ?? [];
      arr.push(cb);
      listeners.set(event, arr);
    },
    send(data: unknown) {
      if (typeof data === "string") sent.push({ kind: "text", data });
      else sent.push({ kind: "binary", data: Buffer.from(data as Buffer) });
    },
    close() {
      state.readyState = 3; // CLOSED
      for (const cb of listeners.get("close") ?? []) cb();
    },
    ping() {},
    terminate() {
      state.readyState = 3;
      for (const cb of listeners.get("close") ?? []) cb();
    },
  };
  return {
    socket: socket as unknown as WsSocket,
    sent,
    state,
    emitMessage: (raw: string) => {
      for (const cb of listeners.get("message") ?? []) cb(Buffer.from(raw));
    },
    emitClose: () => {
      for (const cb of listeners.get("close") ?? []) cb();
    },
  };
}

const PTY_STUB = {} as unknown as PtyBridge;
const EVENTS_STUB: EventLog = {
  append: async () => {
    throw new Error("append is unused in the browser tests");
  },
  readSince: async () => [],
  subscribe: async () => async () => {},
};
/** Fake db whose ownership check owns every uuid session. */
function ownsAllDb(): Db {
  return {
    select: () => ({
      from: () => ({
        where: () => ({
          limit: async () => [{ id: "owned" }],
        }),
      }),
    }),
  } as unknown as Db;
}

describe.skipIf(!TEST_REDIS_URL)(
  "handleWsConnection browser channel (stub socket, real redis)",
  () => {
    let redis: Redis;
    let releaseSuiteLock: (() => Promise<void>) | null = null;

    beforeAll(async () => {
      redis = new IORedis(TEST_REDIS_URL!);
    });

    beforeEach(async () => {
      releaseSuiteLock = await acquireSuiteLock(redis);
    });

    afterEach(async () => {
      await releaseSuiteLock?.();
      releaseSuiteLock = null;
    });

    afterAll(async () => {
      await quitTaps();
      await redis.quit().catch(() => redis.disconnect());
    });

    /**
     * Drives handleWsConnection directly: stub ticket store (its ticket IS
     * the auth), fake db that owns every session, real redisFactory for the
     * browser channel. Returns the stub socket + a send() for client frames.
     */
    async function connectStub(opts: WsConnectionOptions = {}): Promise<{
      s: ReturnType<typeof mkStubSocket>;
      sid: string;
      send(msg: unknown): void;
      created: Redis[];
    }> {
      const tickets = stubTickets();
      const sid = randomUUID();
      const s = mkStubSocket();
      const created: Redis[] = [];
      const deps: WsDeps = {
        tickets,
        events: EVENTS_STUB,
        db: ownsAllDb(),
        pty: PTY_STUB,
        browser: {
          redisFactory: () => {
            const r = new IORedis(TEST_REDIS_URL!);
            created.push(r);
            return r;
          },
        },
      };
      const url = new URL("ws://127.0.0.1/cloud/ws");
      url.searchParams.set("ticket", await tickets.mint("stub-viewer"));
      await handleWsConnection(s.socket, url, deps, opts);
      return { s, sid, send: (msg: unknown) => s.emitMessage(JSON.stringify(msg)), created };
    }

    it("slow client: a frame buffered above the high-water is DROPPED; the connection stays open and later frames flow", async () => {
      const { s, sid, send, created } = await connectStub();
      const ctlTap = await openTap(browserCtlChannel(sid));

      send({ op: "browser_attach", sessionId: sid });
      await ctlTap.next("join");

      // Under the high-water: relayed as a binary message (prefix stripped).
      const small = Buffer.from([0x01, 0x02, 0x03, 0x04]);
      await redis.publish(browserFramesChannel(sid), framePayload(small));
      await waitFor(() => s.sent.filter((f) => f.kind === "binary").length === 1, "small frame relayed");
      expect(s.sent.filter((f) => f.kind === "binary")[0]).toEqual({ kind: "binary", data: small });

      // Above the high-water: DROPPED — never queued behind the stuck client.
      s.state.bufferedAmount = BROWSER_FRAME_HIGH_WATER + 1;
      const big = Buffer.alloc(64 * 1024, 0xab);
      await redis.publish(browserFramesChannel(sid), framePayload(big));
      await sleep(300);
      expect(s.sent.filter((f) => f.kind === "binary")).toHaveLength(1); // the big frame was dropped
      expect(s.state.readyState).toBe(1); // still OPEN

      // Back under the high-water: frames flow again.
      s.state.bufferedAmount = 0;
      await redis.publish(browserFramesChannel(sid), framePayload(small));
      await waitFor(
        () => s.sent.filter((f) => f.kind === "binary").length === 2,
        "frames flow again after the drain",
      );
      expect(s.sent.filter((f) => f.kind === "binary")[1]).toEqual({ kind: "binary", data: small });

      // Teardown quits both attach connections.
      s.emitClose();
      await waitForAsync(() => created.every((c) => c.status === "end"), "connections quit");
    }, 15_000);

    it("heartbeat: re-publishes viewer_join with the SAME viewerId at the injected interval; close publishes the leave", async () => {
      const { s, sid, send } = await connectStub({ browserHeartbeatMs: 80 });
      const ctlTap = await openTap(browserCtlChannel(sid));

      send({ op: "browser_attach", sessionId: sid });
      const join1 = parseJson((await ctlTap.next("initial join")).message);
      const join2 = parseJson((await ctlTap.next("heartbeat join", 5_000)).message);
      expect(join1).toEqual({ type: "viewer_join", viewerId: expect.any(String) });
      expect(join2).toEqual({ type: "viewer_join", viewerId: join1.viewerId }); // SAME viewerId

      s.emitClose();
      const leave = parseJson((await ctlTap.next("leave on close")).message);
      expect(leave).toEqual({ type: "viewer_leave", viewerId: join1.viewerId });
    }, 15_000);
  },
);

describe("browser channel constants (Task 9 pins)", () => {
  it("BROWSER_VIEWER_HEARTBEAT_MS is 30 s; the frame high-water is 4 MiB", () => {
    expect(BROWSER_VIEWER_HEARTBEAT_MS).toBe(30_000);
    expect(BROWSER_FRAME_HIGH_WATER).toBe(4 * 1024 * 1024);
  });
});
