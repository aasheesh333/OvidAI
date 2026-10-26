import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import {
  createDb,
  eventMirror,
  sessions,
  SubagentRosterCursorError,
  SubagentRosterTooLargeError,
  type Db,
} from "@ovid/db";
import type { SessionEvent } from "@ovid/shared";
import { authHook } from "../auth.js";
import { buildGateway } from "../app.js";
import { rateLimitClassFor } from "../rateLimits.js";
import { closeDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";
import { parseSubagentLimit } from "./subagents.js";

const rosterRead = vi.hoisted(() => ({ mock: vi.fn() }));
vi.mock("@ovid/db", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/db")>();
  rosterRead.mock.mockImplementation(actual.readSubagentRosterSession);
  return { ...actual, readSubagentRosterSession: rosterRead.mock };
});

const BASE = 1_700_000_000_000;
const CHILD_A = "22222222-2222-4222-8222-222222222222";
const CHILD_B = "33333333-3333-4333-8333-333333333333";
const CHILD_RUN_A = "44444444-4444-4444-8444-444444444444";
const CHILD_RUN_B = "55555555-5555-4555-8555-555555555555";
const ROOT_RUN = "66666666-6666-4666-8666-666666666666";

describe("subagent roster route contract", () => {
  it("classifies the route as poll and parses the clients' limit=200", () => {
    expect(rateLimitClassFor("GET", "/cloud/v1/sessions/abc/subagents")).toBe("poll");
    expect(parseSubagentLimit("200")).toBe(200);
    expect(parseSubagentLimit("999")).toBe(200);
    expect(parseSubagentLimit(undefined)).toBe(50);
  });

  it("authenticates before ownership or cursor parsing", async () => {
    const app = Fastify();
    app.register(async (scope) => {
      scope.addHook("onRequest", authHook(stubVerifier()));
      const { registerSubagentRoutes } = await import("./subagents.js");
      registerSubagentRoutes(scope, { db: {} as Db } as never);
    }, { prefix: "/cloud/v1" });
    try {
      const unauthenticated = await app.inject({
        method: "GET",
        url: "/cloud/v1/sessions/not-a-uuid/subagents?after=not-a-cursor",
      });
      expect(unauthenticated.statusCode).toBe(401);

      const malformed = await app.inject({
        method: "GET",
        url: "/cloud/v1/sessions/not-a-uuid/subagents?after=not-a-cursor",
        headers: authHeaders("route-only"),
      });
      expect(malformed.statusCode).toBe(404);
      expect(malformed.json()).toEqual({ error: { code: "not_found", message: "Session not found." } });
    } finally {
      await app.close();
    }
  });

  it("maps only the typed cursor and scan-bound errors", async () => {
    const sessionId = "11111111-1111-4111-8111-111111111111";
    const ownership = vi.spyOn(sessions, "get").mockResolvedValue({ id: sessionId } as never);
    const app = Fastify({ logger: false });
    app.register(async (scope) => {
      scope.addHook("onRequest", authHook(stubVerifier()));
      const { registerSubagentRoutes } = await import("./subagents.js");
      registerSubagentRoutes(scope, { db: {} as Db } as never);
    }, { prefix: "/cloud/v1" });
    try {
      rosterRead.mock.mockRejectedValueOnce(new SubagentRosterCursorError("invalid cursor"));
      const cursor = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sessionId}/subagents`,
        headers: authHeaders("route-only"),
      });
      expect(cursor.statusCode).toBe(400);
      expect(cursor.json()).toEqual({
        error: { code: "bad_request", message: "after is not a valid worker cursor." },
      });

      rosterRead.mock.mockRejectedValueOnce(new SubagentRosterTooLargeError("too large"));
      const tooLarge = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sessionId}/subagents`,
        headers: authHeaders("route-only"),
      });
      expect(tooLarge.statusCode).toBe(503);
      expect(tooLarge.json()).toEqual({
        error: {
          code: "temporarily_unavailable",
          message: "The subagent roster is too large to read safely. Try again after older work settles.",
        },
      });

      rosterRead.mock.mockRejectedValueOnce(new RangeError("unrelated range failure"));
      const unrelated = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sessionId}/subagents`,
        headers: authHeaders("route-only"),
      });
      expect(unrelated.statusCode).toBe(500);
      expect(unrelated.json()).not.toMatchObject({
        error: { code: "temporarily_unavailable" },
      });
    } finally {
      ownership.mockRestore();
      await app.close();
    }
  });
});

describe.skipIf(!TEST_DATABASE_URL)("subagent roster route (real postgres)", () => {
  let db: Db;
  const built: FastifyInstance[] = [];

  beforeAll(() => {
    db = createDb(TEST_DATABASE_URL!);
  });

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp(): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    built.push(app);
    return app;
  }

  async function createSession(app: FastifyInstance, uid: string): Promise<string> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  async function seed(sessionId: string, seq: string, type: SessionEvent["type"], payload: Record<string, unknown>): Promise<void> {
    await eventMirror.put(db, {
      sessionId,
      seq,
      type,
      payload,
      ts: new Date(BASE + Number(seq.replace(/\D/g, ""))).toISOString(),
    });
  }

  function get(app: FastifyInstance, uid: string, sessionId: string, query = "") {
    return app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sessionId}/subagents${query}`,
      headers: authHeaders(uid),
    });
  }

  function started(child: string, run: string, at: number): Record<string, unknown> {
    return {
      sessionId: "ignored-by-mirror-route",
      runId: ROOT_RUN,
      childSessionId: child,
      childRunId: run,
      requestId: `request-${child}`,
      batchId: "batch-1",
      agentType: "worker",
      prompt: "work",
      startedAt: new Date(at).toISOString(),
      status: "running",
    };
  }

  it("returns the exact Web/Flutter projection, supports limit=200 and after continuation", async () => {
    const app = makeApp();
    const uid = testUid("roster-contract");
    const sessionId = await createSession(app, uid);
    await seed(sessionId, "1000-0", "subagent_started", started(CHILD_A, CHILD_RUN_A, BASE));
    await seed(sessionId, "1001-0", "subagent_started", started(CHILD_B, CHILD_RUN_B, BASE + 1000));

    const first = await get(app, uid, sessionId, "?limit=200");
    expect(first.statusCode).toBe(200);
    expect(first.headers["cache-control"]).toBe("private, no-store");
    const body = first.json();
    expect(body.counts).toEqual({
      total: 2, running: 2, awaiting_next_user_task: 0,
      completed: 0, failed: 0, cancelled: 0, timeout: 0,
    });
    expect(body.items).toHaveLength(2);
    expect(body.items[0]).toMatchObject({
      requestId: expect.any(String),
      childSessionId: expect.any(String),
      childRunId: expect.any(String),
      attemptId: null,
      startKnown: true,
      lastCursor: null,
      structuredReport: null,
      steps: [],
    });
    expect(Object.keys(body.items[0]).sort()).toEqual([
      "admittedAt", "agentType", "attemptId", "attemptNumber", "batchId",
      "childRunId", "childSessionId", "compaction", "deferredAt", "deferredRequestId",
      "endedAt", "error", "lastActivity", "lastActivityAt", "lastCursor",
      "launchReason", "logAvailable", "logicalWorkerId", "parentRunId", "prompt",
      "promptTruncated", "requestId", "requestedAt", "rootTaskRunId",
      "schedulingReason", "startKnown", "startedAt", "status", "steps",
      "structuredReport", "summary",
    ]);

    const page1 = await get(app, uid, sessionId, "?limit=1");
    expect(page1.statusCode).toBe(200);
    const cursor = page1.json().nextCursor as string;
    expect(cursor).toEqual(expect.any(String));
    const page2 = await get(app, uid, sessionId, `?limit=200&after=${encodeURIComponent(cursor)}`);
    expect(page2.statusCode).toBe(200);
    expect(page2.json().items).toHaveLength(1);
    expect(page2.json().counts.total).toBe(2);
    expect(page2.json().nextCursor).toBeNull();
  });

  it("keeps live control timestamps open, bounds the prompt, and returns an empty roster", async () => {
    const app = makeApp();
    const uid = testUid("roster-controls");
    const sessionId = await createSession(app, uid);
    await seed(sessionId, "2000-0", "subagent_started", {
      ...started(CHILD_A, CHILD_RUN_A, BASE), prompt: "p".repeat(500),
    });
    await seed(sessionId, "2001-0", "subagent_controlled", {
      sessionId, runId: ROOT_RUN, childSessionId: CHILD_A, childRunId: CHILD_RUN_A,
      logicalWorkerId: "worker-a", attemptId: "attempt-a", action: "continue",
      status: "running", controlledAt: new Date(BASE + 1000).toISOString(),
    });
    const live = await get(app, uid, sessionId);
    expect(live.statusCode).toBe(200);
    expect(live.json().items[0]).toMatchObject({
      status: "running", endedAt: null, prompt: "p".repeat(200), promptTruncated: true,
    });

    const emptySession = await createSession(app, uid);
    expect((await get(app, uid, emptySession)).json()).toEqual({
      counts: { total: 0, running: 0, awaiting_next_user_task: 0, completed: 0, failed: 0, cancelled: 0, timeout: 0 },
      items: [],
      nextCursor: null,
    });
  });

  it("returns the same 404 for foreign, unknown, malformed, and deleted sessions", async () => {
    const app = makeApp();
    const owner = testUid("roster-owner");
    const other = testUid("roster-other");
    const sessionId = await createSession(app, owner);
    for (const [uid, id] of [
      [other, sessionId],
      [owner, "00000000-0000-4000-8000-000000000000"],
      [owner, "not-a-uuid"],
    ] as const) {
      const res = await get(app, uid, id, "?after=not-a-cursor");
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: { code: "not_found", message: "Session not found." } });
    }
    await sessions.softDelete(db, sessionId, owner);
    const deleted = await get(app, owner, sessionId);
    expect(deleted.statusCode).toBe(404);
    expect(deleted.json()).toEqual({ error: { code: "not_found", message: "Session not found." } });
  });

  it("rejects a malformed after only after ownership succeeds", async () => {
    const app = makeApp();
    const uid = testUid("roster-cursor");
    const sessionId = await createSession(app, uid);
    const bad = await get(app, uid, sessionId, "?after=not-a-cursor");
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toEqual({ error: { code: "bad_request", message: "after is not a valid worker cursor." } });
  });
});
