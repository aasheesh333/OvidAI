import { afterEach, beforeAll, afterAll, describe, expect, it } from "vitest";
import type { AddressInfo } from "node:net";
import type { FastifyInstance } from "fastify";
import Redis from "ioredis";
import WebSocket from "ws";
import { sessions, users, type Db } from "@ovid/db";
import { APPROVAL_RESPONSES_CHANNEL, wsServerMsg, type WsServerMsg } from "@ovid/shared";
import { buildGateway } from "./app.js";
import type { EventLog } from "@ovid/events";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "./test/db.js";
import {
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  type TicketStub,
  stubSystemBus,
} from "./test/stubs.js";
import { createRedisApprovalPublisher } from "./ws.js";

/**
 * Gateway approval ops (P3 Task 12) — the `approval_response` client op over
 * the REAL redis + postgres stack (test-auth via stub tickets/verifier):
 * ownership like subscribe, publish to the approval-responses channel, and
 * the approval_ack echo. A dedicated subscriber observes what is (and is NOT)
 * published.
 */

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const WS_PATH = "/cloud/ws"; // contract path, hardcoded on purpose

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface TestClient {
  socket: WebSocket;
  /** Every server frame, parsed THROUGH the shared schema (off-contract frames throw here). */
  messages: WsServerMsg[];
  send(msg: unknown): void;
  waitFor(cond: () => boolean, what: string, timeoutMs?: number): Promise<void>;
  close(): Promise<void>;
}

async function connectClient(wsBase: string, ticket: string): Promise<TestClient> {
  const url = `${wsBase}?ticket=${encodeURIComponent(ticket)}`;
  const socket = new WebSocket(url);
  const messages: WsServerMsg[] = [];
  socket.on("message", (data) => {
    messages.push(wsServerMsg(JSON.parse(data.toString())));
  });
  await new Promise<void>((resolve, reject) => {
    socket.once("open", () => resolve());
    socket.once("error", reject);
  });
  return {
    socket,
    messages,
    send: (msg) => socket.send(JSON.stringify(msg)),
    waitFor: (cond, what, timeoutMs = 10_000) =>
      (async () => {
        const deadline = Date.now() + timeoutMs;
        while (!cond()) {
          if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
          await sleep(10);
        }
      })(),
    async close() {
      if (socket.readyState === WebSocket.OPEN) socket.close();
      await new Promise<void>((resolve) => {
        socket.once("close", () => resolve());
        setTimeout(resolve, 2_000).unref?.();
      });
    },
  };
}

describe.skipIf(!TEST_REDIS_URL || !TEST_DATABASE_URL)(
  "gateway /cloud/ws approval ops (real redis + postgres, test-auth)",
  () => {
    let db: Db;
    let redis: Redis;
    /** Dedicated subscriber observing APPROVAL_RESPONSES_CHANNEL. */
    let observer: Redis;
    const observed: Array<{ approvalId: string; userId: string; decision: string }> = [];
    const apps: FastifyInstance[] = [];
    const clients: TestClient[] = [];
    const createdSids: string[] = [];
    let tickets: TicketStub;

    beforeAll(async () => {
      db = await openTestDb();
      redis = new Redis(TEST_REDIS_URL!);
      tickets = stubTickets();
      observer = redis.duplicate();
      observer.on("error", () => {});
      observer.on("message", (_ch: string, message: string) => {
        try {
          const parsed = JSON.parse(message) as {
            approvalId: string;
            userId: string;
            decision: string;
          };
          observed.push(parsed);
        } catch {
          // garbage on the channel: skip
        }
      });
      await observer.subscribe(APPROVAL_RESPONSES_CHANNEL);
    }, 60_000);

    afterEach(async () => {
      while (clients.length > 0) await clients.pop()!.close().catch(() => {});
      while (apps.length > 0) await apps.pop()!.close();
    });

    afterAll(async () => {
      await observer?.quit().catch(() => observer?.disconnect());
      await redis?.quit().catch(() => redis?.disconnect());
      await closeDb(db);
    });

    async function makeApp(withApprovals = true): Promise<string> {
      const events: EventLog = {
        append: async () => {
          throw new Error("append is unused in the approval tests");
        },
        readSince: async () => [],
        subscribe: async () => async () => {},
      };
      const app = buildGateway({
        system: stubSystemBus(),
        db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets,
        keys: stubKeys(),
        mint: stubMint(),
        events,
        ...(withApprovals ? { approvals: createRedisApprovalPublisher(redis) } : {}),
      });
      apps.push(app);
      await app.listen({ host: "127.0.0.1", port: 0 });
      const port = (app.server.address() as AddressInfo).port;
      return `ws://127.0.0.1:${port}${WS_PATH}`;
    }

    async function newClient(wsBase: string, uid: string): Promise<TestClient> {
      const client = await connectClient(wsBase, await tickets.mint(uid));
      clients.push(client);
      return client;
    }

    async function createOwnedSession(uid: string): Promise<string> {
      await users.ensure(db, uid, null);
      const row = await sessions.create(db, uid, null);
      createdSids.push(row.id);
      return row.id;
    }

    it("valid approval_response → approval_ack + the payload published (observer sees it)", async () => {
      const uid = testUid("wsap1");
      const sid = await createOwnedSession(uid);
      const before = observed.length;

      const wsBase = await makeApp();
      const client = await newClient(wsBase, uid);
      client.send({ op: "approval_response", sessionId: sid, approvalId: "ap-1", decision: "always" });

      await client.waitFor(
        () => client.messages.some((m) => m.op === "approval_ack"),
        "approval_ack frame",
      );
      expect(client.messages[0]).toEqual({
        op: "approval_ack",
        approvalId: "ap-1",
        decision: "always",
      });
      // The worker-bound payload lands on the channel: same approvalId, the
      // OWNER's uid, the decision verbatim.
      await (async () => {
        const deadline = Date.now() + 10_000;
        while (observed.length <= before) {
          if (Date.now() >= deadline) throw new Error("waitFor timed out: published payload");
          await sleep(10);
        }
      })();
      expect(observed[observed.length - 1]).toEqual({
        approvalId: "ap-1",
        userId: uid,
        decision: "always",
      });
    }, 20_000);

    it("approval_response for a FOREIGN session → forbidden, nothing published", async () => {
      const uidOwner = testUid("wsap2-owner");
      const uidOther = testUid("wsap2-other");
      const sidOwner = await createOwnedSession(uidOwner);
      const before = observed.length;

      const wsBase = await makeApp();
      const client = await newClient(wsBase, uidOther);
      client.send({ op: "approval_response", sessionId: sidOwner, approvalId: "ap-2", decision: "allow" });

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
      // Nothing was published — and the connection SURVIVES (multiplex not poisoned).
      await sleep(250);
      expect(observed.length).toBe(before);
      client.send({ op: "ping" });
      await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (survived)");
    }, 20_000);

    it("approval_response for an UNKNOWN session → forbidden, nothing published", async () => {
      const uid = testUid("wsap3");
      const before = observed.length;
      const wsBase = await makeApp();
      const client = await newClient(wsBase, uid);
      const unknown = "dddddddd-eeee-4f4f-8a8a-999999999999";

      client.send({ op: "approval_response", sessionId: unknown, approvalId: "ap-3", decision: "allow" });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "forbidden error frame (unknown session)",
      );
      expect(client.messages[0]).toMatchObject({ op: "error", code: "forbidden" });
      await sleep(250);
      expect(observed.length).toBe(before);
    }, 20_000);

    it("malformed decision → bad_request, nothing published, connection survives", async () => {
      const uid = testUid("wsap4");
      const sid = await createOwnedSession(uid);
      const before = observed.length;

      const wsBase = await makeApp();
      const client = await newClient(wsBase, uid);
      // The shared schema keeps `decision` an open string precisely so this
      // frame reaches the handler and gets the SPECIFIC refusal.
      client.send({ op: "approval_response", sessionId: sid, approvalId: "ap-4", decision: "maybe" });

      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "bad_request error frame",
      );
      expect(client.messages[0]).toMatchObject({ op: "error", code: "bad_request" });
      await sleep(250);
      expect(observed.length).toBe(before);
      client.send({ op: "ping" });
      await client.waitFor(() => client.messages.some((m) => m.op === "pong"), "pong (survived)");
    }, 20_000);

    it("pre-P3 composition (no publisher wired) → loud `unavailable` fallback", async () => {
      const uid = testUid("wsap5");
      const sid = await createOwnedSession(uid);
      const wsBase = await makeApp(false);
      const client = await newClient(wsBase, uid);
      client.send({ op: "approval_response", sessionId: sid, approvalId: "ap-5", decision: "allow" });
      await client.waitFor(
        () => client.messages.some((m) => m.op === "error"),
        "unavailable error frame",
      );
      expect(client.messages[0]).toMatchObject({ op: "error", code: "unavailable" });
    }, 20_000);
  },
);
