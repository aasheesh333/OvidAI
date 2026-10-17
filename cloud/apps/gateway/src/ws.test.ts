import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { randomUUID } from "node:crypto";
import type { AddressInfo } from "node:net";
import type { FastifyInstance } from "fastify";
import Redis from "ioredis";
import WebSocket from "ws";
import { sessions, users, type Db } from "@ovid/db";
import { createRedisEventLog, type EventLog } from "@ovid/events";
import { wsServerMsg, type SessionEvent, type WsServerMsg } from "@ovid/shared";
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
  stubQueues,
  stubTickets,
  stubVerifier,
  type TicketStub,
} from "./test/stubs.js";
import { compareSeq, MAX_SUBSCRIPTIONS_PER_CONNECTION } from "./ws.js";
import type { PtyOutMsg, RingChunkWire } from "@ovid/shared";

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

  it("pty_open happy → pty_opened, then snapshot + live pty_output frames in order", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-happy"));
    clients.push(client);

    client.send({ op: "pty_open", sessionId: PTY_SID, cols: 120, rows: 40 });
    await client.waitFor(() => client.messages.some((m) => m.op === "pty_opened"), "pty_opened");

    const ptyId = stub.opens[0]!.ptyId;
    expect(client.messages[0]).toEqual({ op: "pty_opened", ptyId, sessionId: PTY_SID });
    // Snapshot chunks arrive as pty_output frames, in snapshot order, right
    // after the ack.
    expect(client.messages[1]).toEqual({ op: "pty_output", ptyId, data: b64("hi"), offset: 0 });
    expect(client.messages[2]).toEqual({ op: "pty_output", ptyId, data: b64("!"), offset: 2 });
    expect(stub.opens).toEqual([
      {
        ptyId: expect.any(String),
        meta: { userId: "pty-happy", sessionId: PTY_SID, cols: 120, rows: 40 },
        timeoutMs: PTY_OPEN_TIMEOUT_MS,
      },
    ]);
    expect(stub.attaches[0]).toMatchObject({ ptyId, lastOffset: null, timeoutMs: PTY_REPLY_TIMEOUT_MS });

    // Live tail after the snapshot.
    stub.deliver({ type: "output", ptyId, offset: 3, data: b64("?") });
    await client.waitFor(
      () => client.messages.some((m) => m.op === "pty_output" && m.offset === 3),
      "live pty_output",
    );
  }, 15_000);

  it("pty_exit → pty_exit frame, sub dropped (no further output)", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-exit"));
    clients.push(client);

    client.send({ op: "pty_open", sessionId: PTY_SID, cols: 80, rows: 24 });
    await client.waitFor(() => client.messages.some((m) => m.op === "pty_opened"), "pty_opened");
    const ptyId = stub.opens[0]!.ptyId;

    stub.deliver({ type: "exit", ptyId, exitCode: 0 });
    await client.waitFor(() => client.messages.some((m) => m.op === "pty_exit"), "pty_exit frame");
    expect(client.messages.find((m) => m.op === "pty_exit")).toEqual({
      op: "pty_exit",
      ptyId,
      exitCode: 0,
    });
    // Sub dropped: a later live output is NOT forwarded.
    stub.deliver({ type: "output", ptyId, offset: 9, data: b64("x") });
    await sleep(150);
    expect(client.messages.some((m) => m.op === "pty_output" && m.offset === 9)).toBe(false);
    expect(stub.detached).toContain(ptyId);
  }, 15_000);

  it("pty_open on another user's session → forbidden, bridge never called; PtyBridgeError passes through and the connection survives", async () => {
    // Ownership check fails (sessions.get → null): forbidden, no bridge call.
    const forbidden = stubPtyBridge();
    const ticketsF = stubTickets();
    const wsBaseF = await makePtyApp(forbidden, ptyDb(() => false), ticketsF);
    const clientF = await connectClient(wsBaseF, await ticketsF.mint("pty-other"));
    clients.push(clientF);
    clientF.send({ op: "pty_open", sessionId: PTY_SID, cols: 80, rows: 24 });
    await clientF.waitFor(() => clientF.messages.some((m) => m.op === "error"), "forbidden");
    expect(clientF.messages[0]).toEqual({
      op: "error",
      code: "forbidden",
      message: expect.any(String),
      sessionId: PTY_SID,
    });
    expect(forbidden.opens).toHaveLength(0);

    // PtyBridgeError from open → {op:"error", code, ptyId}; connection survives.
    const failing = stubPtyBridge({ openError: new PtyBridgeError("sandbox_busy", "admission queue full") });
    const ticketsE = stubTickets();
    const wsBaseE = await makePtyApp(failing, ptyDb(() => true), ticketsE);
    const clientE = await connectClient(wsBaseE, await ticketsE.mint("pty-busy"));
    clients.push(clientE);
    clientE.send({ op: "pty_open", sessionId: PTY_SID, cols: 80, rows: 24 });
    await clientE.waitFor(() => clientE.messages.some((m) => m.op === "error"), "sandbox_busy error frame");
    expect(clientE.messages[0]).toEqual({
      op: "error",
      code: "sandbox_busy",
      message: "admission queue full",
      ptyId: expect.any(String),
    });
    clientE.send({ op: "ping" });
    await clientE.waitFor(() => clientE.messages.some((m) => m.op === "pong"), "pong (connection survived)");
  }, 15_000);

  it("pty_attach owned → pty_attached + snapshot frames; pty_input on the attached pty is allowed with no extra lookup", async () => {
    const ptyId = "att-1";
    const stub = stubPtyBridge({
      lookup: new Map([[ptyId, { userId: "pty-attach", sessionId: PTY_SID }]]),
    });
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-attach"));
    clients.push(client);

    client.send({ op: "pty_attach", ptyId, lastOffset: 0 });
    await client.waitFor(() => client.messages.some((m) => m.op === "pty_attached"), "pty_attached");
    expect(client.messages[0]).toEqual({ op: "pty_attached", ptyId, truncated: false });
    expect(client.messages[1]).toEqual({ op: "pty_output", ptyId, data: b64("hi"), offset: 0 });
    expect(client.messages[2]).toEqual({ op: "pty_output", ptyId, data: b64("!"), offset: 2 });
    expect(stub.attaches[0]).toMatchObject({ ptyId, lastOffset: 0 });

    // This connection attached the pty: input is allowed without a lookup.
    client.send({ op: "pty_input", ptyId, data: b64("ls\n") });
    await client.waitFor(() => stub.sends.length === 1, "bridge.send(input)");
    expect(stub.sends[0]).toEqual({ ptyId, msg: { type: "input", data: b64("ls\n") } });
    expect(stub.lookups).toEqual([ptyId]); // exactly the attach lookup
  }, 15_000);

  it("pty_attach on a registry owned by another uid → {op:error, forbidden, ptyId}; nothing attached", async () => {
    const ptyId = "att-other";
    const stub = stubPtyBridge({
      lookup: new Map([[ptyId, { userId: "someone-else", sessionId: PTY_SID }]]),
    });
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-victim"));
    clients.push(client);

    client.send({ op: "pty_attach", ptyId });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "forbidden");
    expect(client.messages[0]).toEqual({
      op: "error",
      code: "forbidden",
      message: expect.any(String),
      ptyId,
    });
    expect(stub.attaches).toHaveLength(0);
  }, 15_000);

  it("pty_input on a pty never opened/attached here and unknown to lookup → forbidden, nothing sent", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-ghost"));
    clients.push(client);

    client.send({ op: "pty_input", ptyId: "ghost-pty", data: b64("x") });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "forbidden");
    expect(client.messages[0]).toEqual({
      op: "error",
      code: "forbidden",
      message: expect.any(String),
      ptyId: "ghost-pty",
    });
    expect(stub.lookups).toEqual(["ghost-pty"]);
    expect(stub.sends).toHaveLength(0);
  }, 15_000);

  it("malformed pty_resize (cols:\"x\") → bad_message; the connection survives", async () => {
    const stub = stubPtyBridge();
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-malformed"));
    clients.push(client);

    client.send({ op: "pty_resize", ptyId: "p", cols: "x", rows: 24 });
    await client.waitFor(() => client.messages.some((m) => m.op === "error"), "bad_message");
    expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_message" });
    expect(stub.sends).toHaveLength(0);

    client.send({ op: "ping" });
    await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (connection survived)");
  }, 15_000);

  it("socket close → detach for every opened/attached pty; send close NOT called (ptys survive)", async () => {
    const p1 = "survive-1";
    const p2 = "survive-2";
    const stub = stubPtyBridge({
      lookup: new Map([
        [p1, { userId: "pty-survive", sessionId: PTY_SID }],
        [p2, { userId: "pty-survive", sessionId: PTY_SID }],
      ]),
    });
    const tickets = stubTickets();
    const wsBase = await makePtyApp(stub, ptyDb(() => true), tickets);
    const client = await connectClient(wsBase, await tickets.mint("pty-survive"));
    clients.push(client);

    client.send({ op: "pty_attach", ptyId: p1 });
    client.send({ op: "pty_attach", ptyId: p2 });
    client.send({ op: "pty_open", sessionId: PTY_SID, cols: 80, rows: 24 });
    await client.waitFor(
      () =>
        client.messages.filter((m) => m.op === "pty_attached").length === 2 &&
        client.messages.some((m) => m.op === "pty_opened"),
      "two attached + one opened",
    );
    const p3 = stub.opens[0]!.ptyId;

    await client.close();
    // Detach (not kill): every sub torn down…
    await waitFor(() => stub.detached.includes(p1), "p1 detached");
    await waitFor(() => stub.detached.includes(p2), "p2 detached");
    await waitFor(() => stub.detached.includes(p3), "p3 detached");
    // …and no pty_close was ever SENT — the ptys survive for re-attach.
    expect(stub.sends.filter((s) => s.msg.type === "close")).toHaveLength(0);
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
