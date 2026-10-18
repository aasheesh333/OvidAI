import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import Redis from "ioredis";
import WebSocket from "ws";
import { sessions, users, type Db } from "@ovid/db";
import { createRedisEventLog, type EventLog, type SystemBus } from "@ovid/events";
import {
  wsServerMsg,
  type SessionEvent,
  type SystemEvent,
  type SystemEventEnvelope,
  type WsServerMsg,
} from "@ovid/shared";
import { registerWsRoute } from "./routes/wsRoute.js";
import { buildGateway, WS_MAX_PAYLOAD_BYTES } from "./app.js";
import { createTicketStore, type TicketStore } from "./tickets.js";
import {
  PTY_OPEN_TIMEOUT_MS,
  PTY_REPLY_TIMEOUT_MS,
  PtyBridgeError,
  type PtyBridge,
} from "./wsPty.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "./test/db.js";
import {
  stubKeys,
  stubMint,
  noopDb,
  stubQueues,
  stubTickets,
  stubVerifier,
  stubSystemBus as sharedSystemBus,
  type TicketStub,
} from "./test/stubs.js";
import { compareSeq, MAX_SUBSCRIPTIONS_PER_CONNECTION, PTY_DISABLED_MESSAGE } from "./ws.js";
import type { PtyOutMsg, RingChunkWire } from "@ovid/shared";
import type { SystemHub } from "./systemChannel.js";

/**
 * Gateway WS channel (Task 8). Review Focus #1 — the reconnect replay/live
 * race — is pinned twice: end-to-end against real Redis (reconnect with a
 * stale lastEventId), and deterministically against a stub EventLog whose
 * readSince is gated open only AFTER a live event lands mid-replay.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const WS_PATH = "/cloud/ws"; // contract path, hardcoded on purpose

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

interface TestClient {
  socket: WebSocket;
  /** Every server frame, parsed THROUGH the shared schema (off-contract frames throw here). */
  messages: WsServerMsg[];
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
  socket.on("message", (data) => {
    messages.push(wsServerMsg(JSON.parse(data.toString())));
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

function eventOps(client: TestClient): SessionEvent[] {
  return client.messages.flatMap((m) => (m.op === "event" ? [m.event] : []));
}

// ---------------------------------------------------------------------------
// Real services: real gateway on port 0, real Redis event log + ticket store,
// real Postgres ownership rows.
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_REDIS_URL || !TEST_DATABASE_URL)(
  "gateway /cloud/ws (real redis + postgres)",
  () => {
    let db: Db;
    let redis: Redis;
    let events: EventLog;
    let tickets: TicketStore;
    const apps: FastifyInstance[] = [];
    const clients: TestClient[] = [];
    const createdSids: string[] = [];

    beforeAll(async () => {
      db = await openTestDb();
      redis = new Redis(TEST_REDIS_URL!);
      events = createRedisEventLog(redis);
      tickets = createTicketStore(redis);
    }, 60_000);

    afterEach(async () => {
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      while (apps.length > 0) await apps.pop()!.close();
    });

    afterAll(async () => {
      // Clean up only the keys this suite created (streams; ticket keys have a
      // TTL and are consumed by verify anyway). No FLUSHDB — shared dev redis.
      if (createdSids.length > 0) {
        await redis.del(createdSids.map((s) => `sess:${s}:events`)).catch(() => {});
      }
      await redis.quit().catch(() => redis.disconnect());
      await closeDb(db);
    });

    async function makeApp(): Promise<{ app: FastifyInstance; wsBase: string }> {
      const app = buildGateway({
        system: sharedSystemBus(),
        db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets,
        keys: stubKeys(),
        mint: stubMint(),
        events,
      });
      apps.push(app);
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      return { app, wsBase: `ws://127.0.0.1:${port}${WS_PATH}` };
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

    it("valid ticket → subscribed ack first, then replay of 3 pre-existing events in seq order", async () => {
      const uid = testUid("ws8a");
      const sid = await createOwnedSession(uid);
      const e1 = await events.append(sid, "run_started", { runId: "r1" });
      const e2 = await events.append(sid, "message_delta", { text: "hello" });
      const e3 = await events.append(sid, "message_completed", { messageId: "m1", role: "assistant" });

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "subscribe", sessionId: sid });

      await client.waitFor(() => client.messages.length >= 4, "subscribed + 3 replayed events");
      // subscribed ack arrives BEFORE any replayed event (contract for the thin client).
      expect(client.messages[0]).toEqual({ op: "subscribed", sessionId: sid });
      expect(eventOps(client)).toEqual([e1, e2, e3]);
      const seqs = eventOps(client).map((e) => e.seq);
      expect(seqs).toEqual([...seqs].sort(compareSeq)); // monotonic by stream id
    }, 20_000);

    it("reconnect with lastEventId=e2 → replay only e3, then live e4 exactly once (Review Focus #1)", async () => {
      const uid = testUid("ws8b");
      const sid = await createOwnedSession(uid);
      await events.append(sid, "run_started", { runId: "r1" }); // e1, already seen by "previous life"
      const e2 = await events.append(sid, "message_delta", { text: "one" });
      const e3 = await events.append(sid, "message_delta", { text: "two" });

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "subscribe", sessionId: sid, lastEventId: e2.seq });

      await client.waitFor(() => client.messages.length >= 2, "subscribed + e3 only");
      expect(client.messages[0]).toEqual({ op: "subscribed", sessionId: sid });
      expect(eventOps(client)).toEqual([e3]); // e1/e2 never re-sent

      // Live tail continues on the same subscription — appended AFTER the replay read.
      const e4 = await events.append(sid, "run_completed", { runId: "r1" });
      await client.waitFor(() => eventOps(client).length >= 2, "live e4");
      await sleep(150); // give any duplicate copy a chance to (wrongly) arrive
      expect(eventOps(client)).toEqual([e3, e4]); // exactly once, in order
      expect(compareSeq(e4.seq, e3.seq)).toBe(1);
    }, 20_000);

    it("ticket is single-use: reuse → unauthenticated error frame + close code 4401", async () => {
      const uid = testUid("ws8c");
      const { wsBase } = await makeApp();
      const ticket = await tickets.mint(uid);

      const first = await newClient(wsBase, ticket);
      first.send({ op: "ping" });
      await first.waitFor(() => first.messages.some((m) => m.op === "pong"), "pong proves verify ran");
      await first.close();

      const second = await newClient(wsBase, ticket);
      await second.waitFor(() => second.messages.length >= 1, "unauthenticated error frame");
      expect(second.messages[0]).toMatchObject({ op: "error", code: "unauthenticated" });
      expect(await second.closeCode).toBe(4401);
    }, 20_000);

    it("missing ticket → unauthenticated error frame + close code 4401", async () => {
      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, null);
      await client.waitFor(() => client.messages.length >= 1, "unauthenticated error frame");
      expect(client.messages[0]).toMatchObject({ op: "error", code: "unauthenticated" });
      expect(await client.closeCode).toBe(4401);
    }, 20_000);

    it("wrong owner → forbidden (with sessionId), socket stays open for other subscriptions", async () => {
      const uidOwner = testUid("ws8d-owner");
      const uidOther = testUid("ws8d-other");
      const sidOwner = await createOwnedSession(uidOwner);
      const sidOther = await createOwnedSession(uidOther);

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uidOther));

      client.send({ op: "subscribe", sessionId: sidOwner });
      await client.waitFor(() => client.messages.some((m) => m.op === "error"), "forbidden");
      expect(client.messages[0]).toEqual({
        op: "error",
        code: "forbidden",
        message: expect.any(String),
        sessionId: sidOwner,
      });

      // The connection survived the rejection: a subsequent subscribe on the
      // SAME socket succeeds (multiplexing is not poisoned by one bad session).
      client.send({ op: "subscribe", sessionId: sidOther });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "subscribed"),
        "subscribed on same socket",
      );
      expect(client.messages[1]).toEqual({ op: "subscribed", sessionId: sidOther });
    }, 20_000);

    it("malformed frame → bad_message; connection survives (ping → pong after)", async () => {
      const uid = testUid("ws8e");
      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      client.sendRaw("{not json at all");
      await client.waitFor(() => client.messages.length >= 1, "bad_message (garbage)");
      expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_message" });

      client.sendRaw(JSON.stringify({ op: "bogus_op" })); // valid JSON, off-contract shape
      await client.waitFor(() => client.messages.length >= 2, "bad_message (unknown op)");
      expect(client.messages[1]).toMatchObject({ op: "error", code: "bad_message" });

      client.send({ op: "ping" });
      await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong");
    }, 20_000);

    it("unsubscribe tears down that subscription only; the sibling keeps streaming", async () => {
      const uid = testUid("ws8f");
      const sidA = await createOwnedSession(uid);
      const sidB = await createOwnedSession(uid);

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "subscribe", sessionId: sidA });
      client.send({ op: "subscribe", sessionId: sidB });
      await client.waitFor(
        () => client.messages.filter((m) => m.op === "subscribed").length === 2,
        "both subscribed",
      );

      client.send({ op: "unsubscribe", sessionId: sidA });
      // Give the teardown a moment, then append to BOTH sessions.
      await sleep(150);
      const b1 = await events.append(sidB, "message_delta", { text: "b-live" });
      await events.append(sidA, "message_delta", { text: "a-after-unsub" });

      await client.waitFor(() => eventOps(client).length >= 1, "sibling live event");
      await sleep(150); // chance for the unsubscribed session's event to (wrongly) arrive
      expect(eventOps(client)).toEqual([b1]); // only B's event; A is silent
    }, 20_000);

    it("socket close tears down every subscription (live channel back to baseline)", async () => {
      const uid = testUid("ws8g");
      const sid = await createOwnedSession(uid);
      const liveChannel = `sess:${sid}:live`;
      const channelCount = async (): Promise<number> =>
        ((await redis.pubsub("CHANNELS", liveChannel)) as unknown as string[]).length;

      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));
      client.send({ op: "subscribe", sessionId: sid });
      await client.waitFor(() => client.messages.some((m) => m.op === "subscribed"), "subscribed");
      await waitForAsync(async () => (await channelCount()) === 1, "redis subscriber registered");

      await client.close();
      // The Task 4 unsubscribe quits the duplicated pub/sub connection, so the
      // channel must disappear — no leaked subscriber connections.
      await waitForAsync(async () => (await channelCount()) === 0, "redis subscriber torn down");
    }, 20_000);

    it("I2 — oversized frame (> 262144 bytes) kills the socket with 1009; normal-size frames keep working", async () => {
      expect(WS_MAX_PAYLOAD_BYTES).toBe(262_144); // the pinned cap, not the 100 MiB ws default

      const uid = testUid("ws8h");
      const { wsBase } = await makeApp();
      const client = await newClient(wsBase, await tickets.mint(uid));

      // Control: a normal frame on THIS connection works.
      client.send({ op: "ping" });
      await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong before oversize");

      // One 300 KiB single text frame — past maxPayload: the server must
      // abort the connection instead of buffering it.
      client.sendRaw("x".repeat(300_000));
      await client.waitFor(
        () => client.socket.readyState === WebSocket.CLOSED,
        "socket closed after oversized frame",
        10_000,
      );
      expect(await client.closeCode).toBe(1009); // ws "message too big"

      // The kill is per-frame, not server-wide: a fresh connection works.
      const sid = await createOwnedSession(uid);
      const fresh = await newClient(wsBase, await tickets.mint(uid));
      fresh.send({ op: "subscribe", sessionId: sid });
      await fresh.waitFor(
        () => fresh.messages.some((m) => m.op === "subscribed"),
        "normal frames still work on a fresh connection",
      );
    }, 20_000);
  },
);

// ---------------------------------------------------------------------------
// Deterministic race harness: stub EventLog whose readSince awaits a deferred,
// so a live event provably lands DURING the replay read. No services needed.
// ---------------------------------------------------------------------------

describe("gateway /cloud/ws (stub EventLog — deterministic replay/live race)", () => {
  const apps: FastifyInstance[] = [];
  const clients: TestClient[] = [];

  afterEach(async () => {
    while (clients.length > 0) await clients.pop()!.close().catch(() => {});
    while (apps.length > 0) await apps.pop()!.close();
  });

  // UUID-shaped so the ownership guard's isUuid check passes.
  const RACE_SID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";

  /**
   * sessions.get runs db.select().from(…).where(…).limit(1) → rows; this fake
   * "owns" every session, so a forbidden answer can only come from the guard.
   * `onQuery` (optional) counts ownership queries so tests can prove the db
   * was never touched.
   */
  function fakeDb(onQuery?: () => void): Db {
    return {
      select: () => ({
        from: () => ({
          where: () => ({
            limit: () => {
              onQuery?.();
              return Promise.resolve([{ id: RACE_SID }]);
            },
          }),
        }),
      }),
    } as unknown as Db;
  }

  interface RaceStub {
    events: EventLog;
    calls: string[];
    deliver(e: SessionEvent): void;
    resolveReplay(events: SessionEvent[]): void;
    unsubscribeCalls(): number;
  }

  function raceStubEventLog(): RaceStub {
    const calls: string[] = [];
    let deliverLive: ((e: SessionEvent) => void) | null = null;
    let resolveReplay!: (events: SessionEvent[]) => void;
    const replayGate = new Promise<SessionEvent[]>((resolve) => {
      resolveReplay = resolve;
    });
    let unsubscribeCalls = 0;
    const events: EventLog = {
      append: async () => {
        throw new Error("append is unused in the race test");
      },
      readSince: async () => {
        calls.push("readSince");
        return replayGate; // resolves ONLY when the test says so
      },
      subscribe: async (_sessionId, onEvent) => {
        calls.push("subscribe");
        deliverLive = onEvent;
        return async () => {
          unsubscribeCalls += 1;
        };
      },
    };
    return {
      events,
      calls,
      deliver: (e) => {
        if (deliverLive === null) throw new Error("deliver() before subscribe() ran");
        deliverLive(e);
      },
      resolveReplay: (evts) => resolveReplay(evts),
      unsubscribeCalls: () => unsubscribeCalls,
    };
  }

  function ev(seq: string, text: string): SessionEvent {
    return {
      sessionId: RACE_SID,
      seq,
      type: "message_delta",
      payload: { text },
      ts: "2026-10-16T00:00:00.000Z",
    };
  }

  async function makeStubApp(
    stubEvents: EventLog,
    tickets: TicketStub,
    db: Db = fakeDb(),
    ticketStoreOverride?: TicketStore,
  ): Promise<string> {
    const app = buildGateway({
      system: sharedSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: ticketStoreOverride ?? tickets,
      keys: stubKeys(),
      mint: stubMint(),
      events: stubEvents,
    });
    apps.push(app);
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    return `ws://127.0.0.1:${port}${WS_PATH}`;
  }

  it("live event during replay arrives exactly once, order monotonic; close → unsubscribe (Review Focus #1)", async () => {
    const stub = raceStubEventLog();
    const tickets = stubTickets();
    const wsBase = await makeStubApp(stub.events, tickets);
    const client = await connectClient(wsBase, await tickets.mint("racer"));
    clients.push(client);

    const e1 = ev("100-0", "one");
    const e2 = ev("101-0", "two");
    const e3 = ev("102-0", "three");

    client.send({ op: "subscribe", sessionId: RACE_SID });
    await waitFor(
      () => stub.calls.includes("subscribe") && stub.calls.includes("readSince"),
      "server started subscribe + replay",
    );
    // subscribe() ran BEFORE readSince() — the ordering that closes the race.
    expect(stub.calls).toEqual(["subscribe", "readSince"]);

    // The race, deterministically: a live event lands while replay is in flight…
    stub.deliver(e2);
    // …and the replay window then returns an OVERLAP containing the same event.
    stub.resolveReplay([e1, e2]);

    await client.waitFor(() => client.messages.length >= 3, "subscribed + e1 + e2");
    await sleep(150); // let any duplicate copy a chance to (wrongly) arrive
    expect(client.messages[0]).toEqual({ op: "subscribed", sessionId: RACE_SID });
    const seen = eventOps(client);
    expect(seen).toEqual([e1, e2]); // e2 EXACTLY ONCE despite the overlap
    expect(seen.filter((e) => e.seq === e2.seq)).toHaveLength(1);

    // After the flush the subscription is live: e3 passes through.
    stub.deliver(e3);
    await client.waitFor(() => eventOps(client).length >= 3, "live e3");
    const all = eventOps(client);
    expect(all).toEqual([e1, e2, e3]);
    for (let i = 1; i < all.length; i++) {
      expect(compareSeq(all[i]!.seq, all[i - 1]!.seq)).toBe(1); // strictly monotonic
    }

    // Socket close tears the subscription down (stub spy on the unsubscribe fn).
    await client.close();
    await waitFor(() => stub.unsubscribeCalls() === 1, "unsubscribe called on socket close");
  }, 20_000);

  it("non-uuid sessionId → forbidden without touching db or event log", async () => {
    const stub = raceStubEventLog();
    const tickets = stubTickets();
    const wsBase = await makeStubApp(stub.events, tickets);
    const client = await connectClient(wsBase, await tickets.mint("racer2"));
    clients.push(client);

    // fakeDb "owns" everything — a forbidden answer proves the shape guard
    // short-circuited before the ownership query.
    client.send({ op: "subscribe", sessionId: "not-a-uuid" });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "forbidden");
    expect(client.messages[0]).toEqual({
      op: "error",
      code: "forbidden",
      message: expect.any(String),
      sessionId: "not-a-uuid",
    });
    expect(stub.calls).toEqual([]); // event log never touched
  }, 15_000);

  it("client dropping during the ticket verify never creates a subscription (no leaked redis subscriber)", async () => {
    // Deterministic race (review Important #1): verify is gated; a subscribe
    // frame is queued pre-auth; the client is TERMINATED; only then does
    // verify resolve. A buggy handler drains the queue for a socket whose
    // 'close' already fired (unheard — no listener was registered yet) and
    // builds a subscription holding a real redis pub/sub connection forever.
    let resolveVerify!: (result: { uid: string } | null) => void;
    const verifyGate = new Promise<{ uid: string } | null>((resolve) => {
      resolveVerify = resolve;
    });
    let verifyCalls = 0;
    const gatedTickets: TicketStore = {
      mint: async () => "unused-in-this-test",
      verify: async () => {
        verifyCalls += 1;
        return verifyGate;
      },
    };

    const stub = raceStubEventLog(); // subscribe/readSince spies (its replay gate stays shut)
    let dbQueries = 0;
    const wsBase = await makeStubApp(stub.events, stubTickets(), fakeDb(() => dbQueries++), gatedTickets);

    const client = await connectClient(wsBase, "gated-ticket");
    clients.push(client);
    await waitFor(() => verifyCalls === 1, "server started ticket verify");

    // The subscribe frame lands in the server's pre-auth queue…
    client.send({ op: "subscribe", sessionId: RACE_SID });
    await sleep(100); // loopback: make sure the frame reached the server
    // …then the peer drops abruptly, and only AFTER that does verify resolve.
    client.socket.terminate();
    await sleep(50); // let the server observe the TCP reset and emit 'close'
    resolveVerify({ uid: "racer" });

    await sleep(300); // give a buggy drain every chance to build the subscription
    expect(stub.calls).toEqual([]); // events.subscribe never ran → nothing to leak
    expect(dbQueries).toBe(0); // ownership query never ran either
  }, 20_000);

  it("I3 — subscription cap 64: 65th distinct session refused (too_many_subscriptions), re-subscribe replaces, unsubscribe frees a slot", async () => {
    expect(MAX_SUBSCRIPTIONS_PER_CONNECTION).toBe(64); // the pinned cap

    // Cheap stub: every subscribe succeeds immediately, replay is empty —
    // the cap is the only thing that can refuse here (fakeDb owns everything).
    const stub: EventLog = {
      append: async () => {
        throw new Error("append is unused in the cap test");
      },
      readSince: async () => [],
      subscribe: async () => async () => {},
    };
    const tickets = stubTickets();
    const wsBase = await makeStubApp(stub, tickets);
    const client = await connectClient(wsBase, await tickets.mint("capper"));
    clients.push(client);

    // 64 distinct owned sessions: all subscribe (the cap allows exactly 64).
    const sids = Array.from({ length: 65 }, () => randomUUID());
    for (let i = 0; i < 64; i += 1) client.send({ op: "subscribe", sessionId: sids[i] });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "subscribed").length === 64,
      "64 subscribed",
      20_000,
    );

    // The 65th DISTINCT session: refused with the cap error frame; no
    // subscribed ack follows and the connection survives.
    client.send({ op: "subscribe", sessionId: sids[64] });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "cap error frame");
    const err = client.messages.find((m) => m.op === "error");
    expect(err).toEqual({
      op: "error",
      code: "too_many_subscriptions",
      message: expect.any(String),
      sessionId: sids[64],
    });
    await sleep(150); // settle: no (wrongly granted) ack may follow
    expect(client.messages.filter((m) => m.op === "subscribed")).toHaveLength(64);
    expect(client.socket.readyState).toBe(WebSocket.OPEN);

    // Re-subscribe to an EXISTING session at the cap: a replacement, not a
    // net-new subscription — must be allowed (fresh ack for the same session).
    client.send({ op: "subscribe", sessionId: sids[0] });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "subscribed").length === 65,
      "re-subscribe at cap replaces",
    );

    // Unsubscribe frees a slot: a previously refused distinct session fits.
    client.send({ op: "unsubscribe", sessionId: sids[0] });
    await sleep(150); // let the teardown settle
    client.send({ op: "subscribe", sessionId: sids[64] });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "subscribed").length === 66,
      "freed slot accepts a new session",
    );
  }, 20_000);
});

// ---------------------------------------------------------------------------
// Terminal-over-WS dispatch (Task 13): stub PtyBridge, no services needed.
// ---------------------------------------------------------------------------

describe("gateway /cloud/ws pty ops (stub PtyBridge)", () => {
  const apps: FastifyInstance[] = [];
  const clients: TestClient[] = [];

  afterEach(async () => {
    while (clients.length > 0) await clients.pop()!.close().catch(() => {});
    while (apps.length > 0) await apps.pop()!.close();
  });

  /** UUID-shaped so the ownership guard's isUuid check passes. */
  const PTY_SID = "1a1a1a1a-2b2b-4c3c-8d4d-5e5e5e5e5e5e";
  const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64");

  /**
   * Fake db whose ownership check owns the pinned PTY_SID only while
   * `owned()` says so — sessions.get returning null is the same code path as
   * "another user's session" (ownership-scoped lookup).
   */
  function ptyDb(owned: () => boolean): Db {
    return {
      select: () => ({
        from: () => ({
          where: () => ({
            limit: async () => (owned() ? [{ id: PTY_SID }] : []),
          }),
        }),
      }),
    } as unknown as Db;
  }

  interface PtyStub extends PtyBridge {
    opens: Array<{ ptyId: string; meta: { userId: string; sessionId: string; cols: number; rows: number }; timeoutMs: number }>;
    attaches: Array<{ ptyId: string; lastOffset: number | null; timeoutMs: number }>;
    sends: Array<{ ptyId: string; msg: { type: "input"; data: string } | { type: "resize"; cols: number; rows: number } | { type: "close" } }>;
    lookups: string[];
    detached: string[];
    /** Plays a live pty:out message to the most recent attach's onOut. */
    deliver(m: PtyOutMsg): void;
  }

  function stubPtyBridge(
    behavior: {
      openError?: Error;
      attachResult?: { truncated: boolean; chunks: RingChunkWire[]; endOffset: number };
      lookup?: Map<string, { userId: string; sessionId: string }>;
    } = {},
  ): PtyStub {
    const opens: PtyStub["opens"] = [];
    const attaches: PtyStub["attaches"] = [];
    const sends: PtyStub["sends"] = [];
    const lookups: string[] = [];
    const detached: string[] = [];
    let onOut: ((m: PtyOutMsg) => void) | null = null;
    return {
      opens,
      attaches,
      sends,
      lookups,
      detached,
      deliver: (m) => onOut?.(m),
      open: async (ptyId, meta, timeoutMs) => {
        opens.push({ ptyId, meta: { ...meta }, timeoutMs });
        if (behavior.openError !== undefined) throw behavior.openError;
      },
      attach: async (ptyId, lastOffset, cb, timeoutMs) => {
        attaches.push({ ptyId, lastOffset, timeoutMs });
        onOut = cb;
        const r =
          behavior.attachResult ?? {
            truncated: false,
            chunks: [
              { offset: 0, data: b64("hi") },
              { offset: 2, data: b64("!") },
            ],
            endOffset: 3,
          };
        return { ...r, detach: async () => { detached.push(ptyId); } };
      },
      send: async (ptyId, msg) => {
        sends.push({ ptyId, msg });
      },
      lookup: async (ptyId) => {
        lookups.push(ptyId);
        return behavior.lookup?.get(ptyId) ?? null;
      },
    };
  }

  async function makePtyApp(pty: PtyBridge, db: Db, tickets: TicketStub): Promise<string> {
    const events: EventLog = {
      append: async () => {
        throw new Error("append is unused in the pty tests");
      },
      readSince: async () => [],
      subscribe: async () => async () => {},
    };
    const app = buildGateway({
      system: sharedSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets,
      keys: stubKeys(),
      mint: stubMint(),
      events,
      pty,
    });
    apps.push(app);
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    return `ws://127.0.0.1:${port}${WS_PATH}`;
  }

  // ── Agent-only execution (owner directive 2026-10-18) ──────────────────
  // The user has no interactive terminal. The model runs commands in the
  // user's sandbox; the user follows the read-only run log. Every client pty
  // frame is refused at the dispatch boundary, BEFORE any ownership lookup or
  // bridge work — so the refusal cannot be used to probe which session ids
  // exist, and the bridge is never touched.

  it("pty_open → forbidden with the pinned copy; the bridge is never opened", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-refused"));
    clients.push(client);

    client.send({ op: "pty_open", sessionId: PTY_SID, cols: 120, rows: 40 });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "error"),
      "pty_open refusal",
    );

    const err = client.messages.find((m) => m.op === "error");
    expect(err).toMatchObject({
      op: "error",
      code: "forbidden",
      message: PTY_DISABLED_MESSAGE,
      sessionId: PTY_SID,
    });
    // No bridge work at all: no open, no attach, no lookup.
    expect(stub.opens).toHaveLength(0);
    expect(stub.attaches).toHaveLength(0);
    expect(stub.lookups).toHaveLength(0);
  });

  it("pty_input / pty_resize / pty_attach / pty_close are all refused", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-ctl-refused"));
    clients.push(client);

    const frames = [
      { op: "pty_input", ptyId: "p1", data: b64("rm -rf /") },
      { op: "pty_resize", ptyId: "p1", cols: 200, rows: 50 },
      { op: "pty_attach", ptyId: "p1", lastOffset: null },
      { op: "pty_close", ptyId: "p1" },
    ];
    for (const frame of frames) {
      const before = client.messages.length;
      client.send(frame);
      await client.waitFor(
        () =>
          client.messages.length > before &&
          client.messages[client.messages.length - 1]!.op === "error",
        `${frame.op} refusal`,
      );
      expect(client.messages[client.messages.length - 1]).toMatchObject({
        op: "error",
        code: "forbidden",
        message: PTY_DISABLED_MESSAGE,
        ptyId: "p1",
      });
    }
    // Nothing reached the bridge: no send, no attach, no lookup.
    expect(stub.sends).toHaveLength(0);
    expect(stub.attaches).toHaveLength(0);
    expect(stub.lookups).toHaveLength(0);
  });

  it("the connection survives a refused pty frame and still serves normal ops", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-survives"));
    clients.push(client);

    client.send({ op: "pty_open", sessionId: PTY_SID, cols: 80, rows: 24 });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "refusal");
    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong after refusal");
  });
});

// ---------------------------------------------------------------------------
// System channel ops (P5 Task 10): stub SystemHub, no services needed. All
// cases here are ADDITIVE — nothing above this block changed with Task 10.
// ---------------------------------------------------------------------------

describe("gateway /cloud/ws system channel ops (stub SystemHub)", () => {
  const apps: FastifyInstance[] = [];
  const clients: TestClient[] = [];

  afterEach(async () => {
    while (clients.length > 0) await clients.pop()!.close().catch(() => {});
    while (apps.length > 0) await apps.pop()!.close();
  });

  const SYSTEM_UID = "syschan-user";

  const SYSTEM_EVENT: SystemEventEnvelope = {
    id: "018f1e2a-7b1c-7abc-8def-0123456789ab",
    kind: "mcp_sampling_approval",
    requiresResponse: true,
    payload: { tool: "read_file", serverId: "srv-1" },
    ts: "2026-10-17T00:00:00.000Z",
  };

  interface SystemHubStub {
    hub: SystemHub;
    attaches: Array<{ uid: string; send: (e: SystemEventEnvelope) => void }>;
    detaches: string[];
    responses: Array<{ uid: string; id: string; payload: Record<string, unknown> }>;
    published: Array<{ uid: string; event: SystemEventEnvelope }>;
    /** Delivers an envelope to every attached send for that uid. */
    push(uid: string, event: SystemEventEnvelope): void;
  }

  function stubSystemHub(): SystemHubStub {
    const attaches: SystemHubStub["attaches"] = [];
    const detaches: string[] = [];
    const responses: SystemHubStub["responses"] = [];
    const published: SystemHubStub["published"] = [];
    const hub: SystemHub = {
      attach: (uid, send) => {
        attaches.push({ uid, send });
        return () => {
          detaches.push(uid);
        };
      },
      publishOut: async (uid, event) => {
        published.push({ uid, event });
      },
      respond: async (uid, id, payload) => {
        responses.push({ uid, id, payload });
      },
      close: async () => {},
    };
    return {
      hub,
      attaches,
      detaches,
      responses,
      published,
      push: (uid, event) => {
        for (const a of attaches) if (a.uid === uid) a.send(event);
      },
    };
  }

  async function makeSystemApp(
    systemHub: SystemHub | undefined,
    tickets: TicketStub,
  ): Promise<string> {
    const events: EventLog = {
      append: async () => {
        throw new Error("append is unused in the system channel tests");
      },
      readSince: async () => [],
      subscribe: async () => async () => {},
    };
    const app = buildGateway({
      system: sharedSystemBus(),
      db: noopDb,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets,
      keys: stubKeys(),
      mint: stubMint(),
      events,
      ...(systemHub !== undefined ? { systemHub } : {}),
    });
    apps.push(app);
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    return `ws://127.0.0.1:${port}${WS_PATH}`;
  }

  async function newSystemClient(wsBase: string, hubTickets: TicketStub): Promise<TestClient> {
    const client = await connectClient(wsBase, await hubTickets.mint(SYSTEM_UID));
    clients.push(client);
    return client;
  }

  it("authenticated socket receives system_event frames pushed via systemHub", async () => {
    const stub = stubSystemHub();
    const hubTickets = stubTickets();
    const wsBase = await makeSystemApp(stub.hub, hubTickets);
    const client = await newSystemClient(wsBase, hubTickets);

    await waitFor(() => stub.attaches.some((a) => a.uid === SYSTEM_UID), "systemHub attach");

    stub.push(SYSTEM_UID, SYSTEM_EVENT);
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_event"),
      "system_event frame",
    );
    expect(client.messages[0]).toEqual({ op: "system_event", event: SYSTEM_EVENT });
  }, 15_000);

  it("system_response frame from client reaches systemHub.respond with the ticket's uid", async () => {
    const stub = stubSystemHub();
    const hubTickets = stubTickets();
    const wsBase = await makeSystemApp(stub.hub, hubTickets);
    const client = await newSystemClient(wsBase, hubTickets);
    await waitFor(() => stub.attaches.some((a) => a.uid === SYSTEM_UID), "systemHub attach");

    client.send({ op: "system_response", id: SYSTEM_EVENT.id, payload: { decision: "allow" } });
    await waitFor(() => stub.responses.length === 1, "hub.respond called");
    expect(stub.responses[0]).toEqual({
      uid: SYSTEM_UID,
      id: SYSTEM_EVENT.id,
      payload: { decision: "allow" },
    });
  }, 15_000);

  it("unparseable system_response → bad_message error frame; the connection survives", async () => {
    const stub = stubSystemHub();
    const hubTickets = stubTickets();
    const wsBase = await makeSystemApp(stub.hub, hubTickets);
    const client = await newSystemClient(wsBase, hubTickets);

    // Empty id fails the shared schema; a string payload fails it too. Both
    // must answer bad_message (the generic off-contract refusal) WITHOUT
    // closing the socket.
    client.send({ op: "system_response", id: "", payload: {} });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "bad_message (empty id)");
    expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_message" });

    client.send({ op: "system_response", id: "evt-9", payload: "not-an-object" });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "error").length === 2,
      "bad_message (payload not a record)",
    );
    expect(client.messages[1]).toMatchObject({ op: "error", code: "bad_message" });

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (connection survived)");
    expect(stub.responses).toEqual([]); // nothing was published for either bad frame
  }, 15_000);

  it("pre-P5 composition (no systemHub wired) → system_response answers bad_message; connection survives", async () => {
    const hubTickets = stubTickets();
    const wsBase = await makeSystemApp(undefined, hubTickets); // NO systemHub in the composition
    const client = await newSystemClient(wsBase, hubTickets);

    client.send({ op: "system_response", id: "evt-1", payload: { decision: "allow" } });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "bad_message fallback");
    expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_message" });

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (connection survived)");
  }, 15_000);

  it("socket close detaches the system channel (same teardown bookkeeping as session subs)", async () => {
    const stub = stubSystemHub();
    const hubTickets = stubTickets();
    const wsBase = await makeSystemApp(stub.hub, hubTickets);
    const client = await newSystemClient(wsBase, hubTickets);
    await waitFor(() => stub.attaches.some((a) => a.uid === SYSTEM_UID), "systemHub attach");

    await client.close();
    await waitFor(() => stub.detaches.includes(SYSTEM_UID), "systemHub detach on socket close");
  }, 15_000);
});

// ---------------------------------------------------------------------------
// P4 Task 12: scheduler system channel (stub SystemBus), no services needed.
//
// These cases register the WS route DIRECTLY (registerWsRoute) rather than
// through buildGateway: GatewayDeps does not carry the P4 `system` bus yet
// (Task 11 wires it), and Task 12 is scoped to ws.ts/ws.test.ts. The direct
// composition is the same handler with the same frame chain; only the deps
// object is assembled here so the bus can be stubbed.
// ---------------------------------------------------------------------------

describe("gateway /cloud/ws P4 system channel (stub SystemBus)", () => {
  const apps: FastifyInstance[] = [];
  const clients: TestClient[] = [];

  afterEach(async () => {
    while (clients.length > 0) await clients.pop()!.close().catch(() => {});
    while (apps.length > 0) await apps.pop()!.close();
  });

  const SYS_UID = "p4sys-user";
  const OTHER_UID = "p4sys-other";
  const SESSION_ID = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff";

  const SYS_EVENT: SystemEvent = {
    type: "schedule_run_started",
    scheduleId: "11111111-2222-3333-4444-555555555555",
    ts: "2026-10-17T00:00:00.000Z",
    payload: { runId: "run-1" },
  };

  const OTHER_EVENT: SystemEvent = {
    type: "schedule_run_succeeded",
    scheduleId: "99999999-8888-7777-6666-555555555555",
    ts: "2026-10-17T00:00:01.000Z",
    payload: { runId: "run-other" },
  };

  interface BusEntry {
    uid: string;
    onEvent: (e: SystemEvent) => void;
    active: boolean;
  }

  interface SystemBusStub extends SystemBus {
    subscribes: BusEntry[];
    /** Every invocation of an unsubscribe function (idempotence is NOT hidden). */
    unsubscribeCalls: number;
    /** When set, the NEXT subscribe() rejects with it, then clears. */
    failNext: Error | null;
    /** Delivers an event to every ACTIVE subscription for that uid. */
    push(uid: string, event: SystemEvent): void;
  }

  function stubSystemBus(): SystemBusStub {
    const subscribes: BusEntry[] = [];
    let unsubscribeCalls = 0;
    const stub: SystemBusStub = {
      subscribes,
      get unsubscribeCalls(): number {
        return unsubscribeCalls;
      },
      failNext: null,
      publish: async () => {},
      subscribe: async (uid, onEvent) => {
        if (stub.failNext !== null) {
          const err = stub.failNext;
          stub.failNext = null;
          throw err;
        }
        const entry: BusEntry = { uid, onEvent, active: true };
        subscribes.push(entry);
        return async () => {
          unsubscribeCalls += 1;
          entry.active = false;
        };
      },
      push: (uid, event) => {
        for (const entry of subscribes) {
          if (entry.uid === uid && entry.active) entry.onEvent(event);
        }
      },
    };
    return stub;
  }

  /** sessions.get owns SESSION_ID; nothing else is touched. */
  function fakeOwnedDb(): Db {
    return {
      select: () => ({
        from: () => ({
          where: () => ({
            limit: async () => [{ id: SESSION_ID }],
          }),
        }),
      }),
    } as unknown as Db;
  }

  interface LiveEventStub {
    events: EventLog;
    deliver(e: SessionEvent): void;
    unsubscribeCalls(): number;
  }

  function liveEventStub(): LiveEventStub {
    let live: ((e: SessionEvent) => void) | null = null;
    let unsubscribeCalls = 0;
    return {
      events: {
        append: async () => {
          throw new Error("append is unused in the P4 system channel tests");
        },
        readSince: async () => [],
        subscribe: async (_sessionId, onEvent) => {
          live = onEvent;
          return async () => {
            unsubscribeCalls += 1;
          };
        },
      },
      deliver: (e) => {
        if (live === null) throw new Error("deliver() before subscribe() ran");
        live(e);
      },
      unsubscribeCalls: () => unsubscribeCalls,
    };
  }

  const noopPty: PtyBridge = {
    open: async () => {},
    attach: async () => ({
      truncated: false,
      chunks: [],
      endOffset: 0,
      detach: async () => {},
    }),
    send: async () => {},
    lookup: async () => null,
  };

  async function makeSystemBusApp(
    system: SystemBus | undefined,
    tickets: TicketStub,
    events: EventLog = liveEventStub().events,
  ): Promise<string> {
    const app = Fastify();
    await app.register(websocket, { options: { maxPayload: WS_MAX_PAYLOAD_BYTES } });
    registerWsRoute(app, {
      db: fakeOwnedDb(),
      tickets,
      events,
      pty: noopPty,
      ...(system !== undefined ? { system } : {}),
    });
    apps.push(app);
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    return `ws://127.0.0.1:${port}${WS_PATH}`;
  }

  async function newSystemBusClient(
    wsBase: string,
    busTickets: TicketStub,
    uid = SYS_UID,
  ): Promise<TestClient> {
    const client = await connectClient(wsBase, await busTickets.mint(uid));
    clients.push(client);
    return client;
  }

  function systemOps(client: TestClient): SystemEvent[] {
    return client.messages.flatMap((m) => (m.op === "system" ? [m.event] : []));
  }

  it("(a/b) subscribe_system → system_subscribed; bus events for the TICKET's uid arrive as system frames, other uids never do", async () => {
    const bus = stubSystemBus();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "system_subscribed ack",
    );
    expect(client.messages[0]).toEqual({ op: "system_subscribed" });
    // The bus is subscribed for the authenticated principal, never a client field.
    expect(bus.subscribes).toHaveLength(1);
    expect(bus.subscribes[0]!.uid).toBe(SYS_UID);

    bus.push(SYS_UID, SYS_EVENT);
    await client.waitFor(() => systemOps(client).length >= 1, "system event frame");
    expect(systemOps(client)[0]).toEqual(SYS_EVENT); // deep-equal, frame shape {op:"system", event}

    // Another uid's events are not on this socket's channel (the stub is
    // uid-keyed, exactly like the redis bus).
    bus.push(OTHER_UID, OTHER_EVENT);
    await sleep(150);
    expect(systemOps(client)).toEqual([SYS_EVENT]);
  }, 15_000);

  it("(c) unsubscribe_system → bus unsubscribe called; later publishes are not forwarded; connection survives", async () => {
    const bus = stubSystemBus();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "system_subscribed ack",
    );
    client.send({ op: "unsubscribe_system" });
    await waitFor(() => bus.unsubscribeCalls === 1, "bus unsubscribe called");

    bus.push(SYS_UID, SYS_EVENT);
    await sleep(150);
    expect(systemOps(client)).toEqual([]); // no forward after unsubscribe

    // The connection survives and can re-subscribe.
    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong");
    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "system_subscribed").length === 2,
      "re-subscribed after unsubscribe",
    );
  }, 15_000);

  it("(d) re-subscribe REPLACES: previous bus subscription torn down exactly once; frames not duplicated", async () => {
    const bus = stubSystemBus();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "first ack",
    );
    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.filter((m) => m.op === "system_subscribed").length === 2,
      "second ack",
    );

    expect(bus.subscribes).toHaveLength(2);
    expect(bus.unsubscribeCalls).toBe(1); // old subscription torn down once
    expect(bus.subscribes[0]!.active).toBe(false);
    expect(bus.subscribes[1]!.active).toBe(true);

    bus.push(SYS_UID, SYS_EVENT);
    await client.waitFor(() => systemOps(client).length >= 1, "event on the new subscription");
    await sleep(150);
    expect(systemOps(client)).toEqual([SYS_EVENT]); // exactly once, no duplicate from the old one
  }, 15_000);

  it("(e) socket close tears the bus subscription down (no leaked connection)", async () => {
    const bus = stubSystemBus();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "system_subscribed ack",
    );
    expect(bus.unsubscribeCalls).toBe(0);

    await client.close();
    await waitFor(() => bus.unsubscribeCalls === 1, "bus unsubscribe on socket close");
    expect(bus.subscribes[0]!.active).toBe(false);
  }, 15_000);

  it("(f) regression — session subscribe/event/pong flows are untouched by the system channel", async () => {
    const bus = stubSystemBus();
    const live = liveEventStub();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets, live.events);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe", sessionId: SESSION_ID });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "subscribed"),
      "session subscribed ack",
    );
    expect(client.messages[0]).toEqual({ op: "subscribed", sessionId: SESSION_ID });

    const event: SessionEvent = {
      sessionId: SESSION_ID,
      seq: "100-0",
      type: "message_delta",
      payload: { text: "hi" },
      ts: "2026-10-17T00:00:00.000Z",
    };
    live.deliver(event);
    await client.waitFor(() => eventOps(client).length >= 1, "live session event");
    expect(eventOps(client)).toEqual([event]);

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong");
  }, 15_000);

  it("(g) unknown keys on subscribe_system are stripped (existing zod behavior); the ack still arrives", async () => {
    const bus = stubSystemBus();
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system", extra: 1 });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "system_subscribed ack despite unknown key",
    );
    expect(client.messages[0]).toEqual({ op: "system_subscribed" });
    expect(bus.subscribes[0]!.uid).toBe(SYS_UID);
  }, 15_000);

  it("bus subscribe failure → internal error frame; the connection survives (never fatal)", async () => {
    const bus = stubSystemBus();
    bus.failNext = new Error("redis down");
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(bus, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "internal error frame");
    expect(client.messages[0]).toMatchObject({ op: "error", code: "internal" });
    expect(systemOps(client)).toEqual([]);

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (connection survived)");

    // A later subscribe (bus healthy again) works: the failure left no state.
    client.send({ op: "subscribe_system" });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "system_subscribed"),
      "recovered subscribe",
    );
    expect(bus.subscribes).toHaveLength(1);
  }, 15_000);

  it("pre-P4 composition (no system bus) → subscribe_system answers unavailable; connection survives", async () => {
    const busTickets = stubTickets();
    const wsBase = await makeSystemBusApp(undefined, busTickets);
    const client = await newSystemBusClient(wsBase, busTickets);

    client.send({ op: "subscribe_system" });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "unavailable fallback");
    expect(client.messages[0]).toMatchObject({ op: "error", code: "unavailable" });

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (connection survived)");
  }, 15_000);
});

describe("compareSeq", () => {
  it("compares Redis stream ids numerically on BOTH parts (not lexicographically)", () => {
    expect(compareSeq("100-0", "99-99")).toBe(1); // lexicographic "100" < "99" would say -1
    expect(compareSeq("99-99", "100-0")).toBe(-1);
    expect(compareSeq("5-10", "5-9")).toBe(1); // second part numeric too
    expect(compareSeq("5-9", "5-10")).toBe(-1);
    expect(compareSeq("5-5", "5-5")).toBe(0);
    expect(compareSeq("1700000000000-0", "1700000000000-0")).toBe(0);
    expect(compareSeq("1700000000001-0", "1700000000000-99")).toBe(1);
  });
});
