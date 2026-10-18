/**
 * P10 Task 9 — auth surface + single-use ticket races.
 *
 * In-process gateway (`buildGateway` + `inject()` for REST, a real `ws` client
 * against `app.listen(0)` for the handshake). Real Postgres for ownership
 * rows; real Redis for the ticket store (dev services only — never FLUSHDB;
 * every key this file creates is single-use or expired by the test itself).
 *
 * Pinned behavior (one `it` each):
 *   - one ticket, 20 concurrent handshakes → exactly one subscribes, 19 are
 *     rejected with the `unauthenticated` error frame + close 4401, and a
 *     21st use after the winner is rejected (P1's atomic Lua GET+DEL).
 *   - an expired ticket is rejected with the SAME shape as an invalid one.
 *   - a ticket bound to uid A cannot subscribe to uid B's session
 *     (`forbidden`, never a subscription) — fail closed, no cross-tenant read.
 *   - a ticket replayed after a clean disconnect is rejected.
 *   - every absurd `Authorization` value on POST /sessions → 401
 *     `unauthenticated`, zero 500s.
 *   - the REAL firebase verifier (firebase-admin, emulator signature mode so
 *     no network I/O) rejects a locally-forged EXPIRED token with the same
 *     401 envelope, and the swallowed verification error reaches the
 *     injected request logger (Task 2 seam) — diagnosable server-side,
 *     invisible to the client.
 *
 * Loud failure: without TEST_DATABASE_URL/TEST_REDIS_URL the ticket-race
 * group FAILS in beforeAll with the missing env vars (never a silent green —
 * Review Focus #4 / Finding 7).
 */

import { createRequire } from "node:module";
import { randomBytes } from "node:crypto";
import WebSocket from "ws";
import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, sessions, users, type Db } from "@ovid/db";
import {
  createRedisSystemBus,
  type EventLog,
  type SystemBus,
} from "@ovid/events";
import type { QueueServices } from "@ovid/queue";
import {
  buildGateway,
  createFirebaseVerifier,
  createTestVerifier,
  createTicketStore,
  TICKET_TTL_SECONDS,
  type TicketStore,
} from "@ovid/gateway";

/** Contract pin: the gateway's failed-ticket WS close code (ws.ts). */
const WS_CLOSE_UNAUTHENTICATED = 4401;

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

if (!TEST_DATABASE_URL || !TEST_REDIS_URL) {
  console.error(
    "[security] auth-surface requires TEST_DATABASE_URL and TEST_REDIS_URL — " +
      "refusing to skip green.",
  );
}

/** Ticket key shape, pinned from createTicketStore (tickets.ts). */
const TICKET_KEY = (ticket: string): string => `ws:ticket:${ticket}`;

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

function authHeaders(uid: string): Record<string, string> {
  return { authorization: `Bearer test:${uid}` };
}

/** Minimal non-touching stubs — REST/WS auth paths never reach these. */
const stubQueues = { agentRuns: { remove: async () => {} } } as unknown as QueueServices;
const stubEvents: EventLog = {
  async append() {
    throw new Error("events.append not expected in auth-surface tests");
  },
  async readSince() {
    return [];
  },
  async subscribe() {
    return async () => {};
  },
};
const stubKeys = { getKeyForUser: async () => "sk-test" };
const stubMint = { ensureKeyForUid: async () => ({ key: "sk-test", tier: "free", baseUrl: "" }) };
const stubTickets: TicketStore = {
  async mint() {
    return "unused";
  },
  async verify() {
    return null;
  },
};
const stubSystemBus: SystemBus = {
  async publish() {},
  async subscribe() {
    return async () => {};
  },
};

interface WsOutcome {
  subscribed: boolean;
  errorCode: string | null;
  closeCode: number | null;
}

/**
 * One handshake attempt: connect, immediately pipeline a subscribe frame
 * (buffered pre-auth by the gateway), and resolve when the connection either
 * acknowledges the subscription, is closed, or answers a non-auth error.
 */
function connectAndSubscribe(
  port: number,
  ticket: string,
  sessionId: string,
  timeoutMs = 8_000,
): Promise<WsOutcome> {
  return new Promise((resolve) => {
    const ws = new WebSocket(
      `ws://127.0.0.1:${port}/cloud/ws?ticket=${encodeURIComponent(ticket)}`,
    );
    const outcome: WsOutcome = { subscribed: false, errorCode: null, closeCode: null };
    let settled = false;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        ws.close();
      } catch {
        /* already closed */
      }
      resolve(outcome);
    };
    const timer = setTimeout(() => {
      try {
        ws.terminate();
      } catch {
        /* ignore */
      }
      finish();
    }, timeoutMs);
    timer.unref?.();

    ws.on("open", () => {
      ws.send(JSON.stringify({ op: "subscribe", sessionId }));
    });
    ws.on("message", (data) => {
      let msg: { op?: string; code?: string };
      try {
        msg = JSON.parse(data.toString()) as { op?: string; code?: string };
      } catch {
        return;
      }
      if (msg.op === "subscribed") {
        outcome.subscribed = true;
        finish();
        return;
      }
      if (msg.op === "error") {
        outcome.errorCode = msg.code ?? null;
        // The auth rejection is followed by close 4401 — wait for it so the
        // close code is asserted. Every other error leaves the socket open.
        if (msg.code !== "unauthenticated") finish();
      }
    });
    ws.on("close", (code) => {
      outcome.closeCode = code;
      finish();
    });
    ws.on("error", () => finish());
  });
}

describe(
  "auth surface — single-use WS tickets (real Postgres + Redis)",
  () => {
    let db: Db;
    let redis: Redis;
    let tickets: TicketStore;
    let app: ReturnType<typeof buildGateway>;
    let port: number;
    let uidA: string;
    let uidB: string;
    let sessionA: string;
    let sessionB: string;

    beforeAll(async () => {
      if (!TEST_DATABASE_URL || !TEST_REDIS_URL) {
        throw new Error(
          "[security] auth-surface: TEST_DATABASE_URL and TEST_REDIS_URL " +
            "must both be set — refusing to skip green.",
        );
      }
      await migrate(TEST_DATABASE_URL);
      db = createDb(TEST_DATABASE_URL);
      redis = new Redis(TEST_REDIS_URL);
      tickets = createTicketStore(redis);

      const stamp = `${Date.now().toString(36)}-${randomBytes(4).toString("hex")}`;
      uidA = `auth-a-${stamp}`;
      uidB = `auth-b-${stamp}`;
      await users.ensure(db, uidA, null);
      await users.ensure(db, uidB, null);
      sessionA = (await sessions.create(db, uidA, "A session")).id;
      sessionB = (await sessions.create(db, uidB, "B session")).id;

      app = buildGateway({
        system: createRedisSystemBus(redis),
        db,
        queues: stubQueues,
        verifier: createTestVerifier(),
        tickets,
        keys: stubKeys,
        mint: stubMint,
        events: stubEvents,
      });
      await app.listen({ host: "127.0.0.1", port: 0 });
      const address = app.server.address();
      if (address === null || typeof address === "string") {
        throw new Error("gateway did not bind a TCP port");
      }
      port = address.port;
    });

    afterAll(async () => {
      await app?.close();
      redis?.disconnect();
      await db?.$client.end({ timeout: 5 });
    });

    /** Mint through the real REST route (also pins the route contract). */
    async function mintTicket(uid: string): Promise<string> {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/auth/ticket",
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      const ticket = (res.json() as { ticket: string }).ticket;
      expect(typeof ticket).toBe("string");
      return ticket;
    }

    it("a ticket mints a working handshake (control for the race below)", async () => {
      const ticket = await mintTicket(uidA);
      const outcome = await connectAndSubscribe(port, ticket, sessionA);
      expect(outcome.subscribed).toBe(true);
      expect(outcome.errorCode).toBeNull();
    });

    it("20-way concurrent use of one ticket → exactly one subscribes; 21st rejected", async () => {
      const ticket = await mintTicket(uidA);

      const outcomes = await Promise.all(
        Array.from({ length: 20 }, () => connectAndSubscribe(port, ticket, sessionA)),
      );

      const winners = outcomes.filter((o) => o.subscribed);
      const rejected = outcomes.filter(
        (o) => !o.subscribed && o.errorCode === "unauthenticated",
      );
      expect(winners).toHaveLength(1);
      expect(rejected).toHaveLength(19);
      for (const loser of rejected) {
        expect(loser.closeCode).toBe(WS_CLOSE_UNAUTHENTICATED);
      }

      // Replay after the winner consumed it — the same failure shape.
      const replay = await connectAndSubscribe(port, ticket, sessionA);
      expect(replay.subscribed).toBe(false);
      expect(replay.errorCode).toBe("unauthenticated");
      expect(replay.closeCode).toBe(WS_CLOSE_UNAUTHENTICATED);
    });

    it("an expired ticket is rejected with the invalid-ticket shape", async () => {
      const ticket = await mintTicket(uidA);
      // The test owns this key: expire it via its own connection (never FLUSHDB).
      await redis.pexpire(TICKET_KEY(ticket), 1);
      expect(await redis.pttl(TICKET_KEY(ticket))).toBeLessThanOrEqual(1);
      await sleep(25);

      const outcome = await connectAndSubscribe(port, ticket, sessionA);
      expect(outcome.subscribed).toBe(false);
      expect(outcome.errorCode).toBe("unauthenticated");
      expect(outcome.closeCode).toBe(WS_CLOSE_UNAUTHENTICATED);
    });

    it("a ticket bound to uid A cannot subscribe to uid B's session", async () => {
      const ticket = await mintTicket(uidA);
      const outcome = await connectAndSubscribe(port, ticket, sessionB);
      expect(outcome.subscribed).toBe(false);
      expect(outcome.errorCode).toBe("forbidden");
    });

    it("a ticket replayed after a clean disconnect is rejected", async () => {
      const ticket = await mintTicket(uidA);
      const first = await connectAndSubscribe(port, ticket, sessionA);
      expect(first.subscribed).toBe(true);
      // connectAndSubscribe closed the client cleanly; give the server's
      // close handler a tick to run, then replay the same ticket.
      await sleep(50);
      const second = await connectAndSubscribe(port, ticket, sessionA);
      expect(second.subscribed).toBe(false);
      expect(second.errorCode).toBe("unauthenticated");
      expect(second.closeCode).toBe(WS_CLOSE_UNAUTHENTICATED);
    });

    it("tickets carry the P1 TTL (no accidental long-lived credentials)", async () => {
      const ticket = await mintTicket(uidA);
      const ttl = await redis.ttl(TICKET_KEY(ticket));
      expect(ttl).toBeGreaterThan(0);
      expect(ttl).toBeLessThanOrEqual(TICKET_TTL_SECONDS);
    });
  },
);

describe("auth surface — malformed credentials never 500", () => {
  it("every absurd Authorization value on POST /sessions → 401 unauthenticated", async () => {
    const app = buildGateway({
      system: stubSystemBus,
      db: {} as unknown as Db,
      queues: stubQueues,
      verifier: createTestVerifier(),
      tickets: stubTickets,
      keys: stubKeys,
      mint: stubMint,
      events: stubEvents,
    });
    try {
      const jwtLike = [
        Buffer.from(JSON.stringify({ alg: "RS256", kid: "bogus" })).toString("base64url"),
        Buffer.from(
          JSON.stringify({
            aud: "ovid-test",
            iss: "https://securetoken.google.com/ovid-test",
            sub: "u1",
            exp: Math.floor(Date.now() / 1000) + 3600,
          }),
        ).toString("base64url"),
        "not-a-real-signature",
      ].join(".");

      const headers: Array<Record<string, string> | undefined> = [
        undefined, // no Authorization at all
        { authorization: "" },
        { authorization: "Bearer" },
        { authorization: "Bearer " },
        { authorization: "Bearer x" },
        { authorization: `Bearer ${"x".repeat(10_000)}` },
        { authorization: `Bearer ${jwtLike}` },
        { authorization: `Basic ${Buffer.from("user:pass").toString("base64")}` },
      ];

      for (const header of headers) {
        const res = await app.inject({
          method: "POST",
          url: "/cloud/v1/sessions",
          headers: header,
          payload: {},
        });
        expect(res.statusCode, `headers=${JSON.stringify(header)}`).toBe(401);
        expect(res.statusCode).not.toBe(500);
        expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
      }
    } finally {
      await app.close();
    }
  });
});

describe("auth surface — real firebase verifier", () => {
  it("expired forged token → 401, and the swallowed error reaches the injected logger", async () => {
    // Load firebase-admin from the GATEWAY's dependency tree (e2e does not
    // depend on it directly; the gateway composition is the code under test).
    const gatewayRequire = createRequire(
      new URL("../../../gateway/package.json", import.meta.url),
    );
    const { initializeApp, deleteApp } = gatewayRequire("firebase-admin/app") as {
      initializeApp: (options: { projectId: string }, name?: string) => unknown;
      deleteApp: (app: unknown) => Promise<void>;
    };

    const projectId = "ovid-p10-task9";
    const appName = `p10-t9-${randomBytes(4).toString("hex")}`;
    // Emulator signature mode: the token is locally forged (wrong key) and
    // expired; verification fails on `exp` with ZERO network I/O. The
    // production path (fetching Google certs) is exactly the same verifier
    // code — only the signature backend differs.
    const previousEmulator = process.env.FIREBASE_AUTH_EMULATOR_HOST;
    process.env.FIREBASE_AUTH_EMULATOR_HOST = "127.0.0.1:9";
    const firebaseApp = initializeApp({ projectId }, appName);

    const logLines: string[] = [];
    const app = buildGateway(
      {
        db: {} as unknown as Db,
        queues: stubQueues,
        verifier: createFirebaseVerifier(firebaseApp as never),
        tickets: stubTickets,
        keys: stubKeys,
        mint: stubMint,
        events: stubEvents,
        system: stubSystemBus,
      },
      {
        logger: {
          level: "warn",
          stream: {
            write(line: string): void {
              logLines.push(line);
            },
          },
        },
      },
    );

    try {
      const b64 = (value: unknown): string =>
        Buffer.from(JSON.stringify(value)).toString("base64url");
      const now = Math.floor(Date.now() / 1000);
      const expired = [
        b64({ alg: "none", typ: "JWT" }),
        b64({
          aud: projectId,
          iss: `https://securetoken.google.com/${projectId}`,
          sub: "forged-user",
          iat: now - 7200,
          exp: now - 3600,
        }),
        "forged-signature",
      ].join(".");

      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/sessions",
        headers: {
          authorization: `Bearer ${expired}`,
          "x-firebase-appcheck": "app-check-present",
        },
        payload: {},
      });

      expect(res.statusCode).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
      // The client body must not leak verification details.
      expect(res.body).not.toContain("expired");
      expect(res.body).not.toContain("auth/id-token");

      // Task 2 seam: the swallowed error is visible to the injected logger.
      // The verifier now names WHICH half failed (id token vs App Check) so an
      // operator can diagnose a real client; the client body above stays
      // generic, which is the property this case exists to pin.
      const joined = logLines.join("\n");
      expect(joined).toContain("auth verification failed");
      expect(joined).toContain("id token rejected");
    } finally {
      await app.close();
      await deleteApp(firebaseApp);
      if (previousEmulator === undefined) {
        delete process.env.FIREBASE_AUTH_EMULATOR_HOST;
      } else {
        process.env.FIREBASE_AUTH_EMULATOR_HOST = previousEmulator;
      }
    }
  });

  it("a missing App Check token is rejected before any token verification", async () => {
    const gatewayRequire = createRequire(
      new URL("../../../gateway/package.json", import.meta.url),
    );
    const { initializeApp, deleteApp } = gatewayRequire("firebase-admin/app") as {
      initializeApp: (options: { projectId: string }, name?: string) => unknown;
      deleteApp: (app: unknown) => Promise<void>;
    };
    const firebaseApp = initializeApp(
      { projectId: "ovid-p10-task9" },
      `p10-t9-nocheck-${randomBytes(4).toString("hex")}`,
    );
    const app = buildGateway({
      system: stubSystemBus,
      db: {} as unknown as Db,
      queues: stubQueues,
      verifier: createFirebaseVerifier(firebaseApp as never),
      tickets: stubTickets,
      keys: stubKeys,
      mint: stubMint,
      events: stubEvents,
    });
    try {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/sessions",
        headers: { authorization: "Bearer any-structurally-plausible-token" },
        payload: {},
      });
      expect(res.statusCode).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    } finally {
      await app.close();
      await deleteApp(firebaseApp);
    }
  });
});
