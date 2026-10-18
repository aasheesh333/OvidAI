import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { type Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
  stubSystemBus,
} from "../test/stubs.js";
import type { ReportsAdmission } from "./reports.js";

// Port of server/reports/tests/test_reports.py. Real Postgres, Fastify inject.

const REPORT_HEADERS = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
};

function body(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    request_id: "r".repeat(32),
    kind: "ai_output",
    reason: "hate",
    details: "offensive",
    excerpt: "bad reply",
    model: "m1",
    ...overrides,
  };
}

describe.skipIf(!TEST_DATABASE_URL)("gateway legacy /v1/reports route (real postgres)", () => {
  let db: Db;
  const built: FastifyInstance[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp(opts: { admission?: ReportsAdmission; dailyLimit?: number } = {}): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      reports: {
        ...(opts.admission ? { admission: opts.admission } : {}),
        ...(opts.dailyLimit !== undefined ? { dailyLimit: opts.dailyLimit } : {}),
      },
    });
    built.push(app);
    return app;
  }

  async function post(
    app: FastifyInstance,
    uid: string,
    overrides: Record<string, unknown> = {},
    headers: Record<string, string> = authHeaders(uid),
  ) {
    return app.inject({
      method: "POST",
      url: "/v1/reports",
      headers,
      payload: body(overrides),
    });
  }

  it("requires a verified identity (token only, never the body)", async () => {
    const app = makeApp();
    const anonymous = await app.inject({
      method: "POST",
      url: "/v1/reports",
      payload: body(),
    });
    expect(anonymous.statusCode).toBe(401);
    expect(anonymous.json()).toEqual({ detail: "authentication_required" });

    const invalid = await post(app, "x", {}, { authorization: "Bearer nope" });
    expect(invalid.statusCode).toBe(401);
    expect(invalid.json()).toEqual({ detail: "invalid_authentication" });
  });

  it("creates 201, replays 200 with the same id, and stores the token uid", async () => {
    const uid = testUid("report-create");
    const app = makeApp();
    const first = await post(app, uid);
    expect(first.statusCode).toBe(201);
    const firstBody = first.json() as { id: string };
    expect(Object.keys(firstBody)).toEqual(["id"]);
    expect(first.headers["cache-control"]).toBe(REPORT_HEADERS["cache-control"]);
    expect(first.headers["x-content-type-options"]).toBe(
      REPORT_HEADERS["x-content-type-options"],
    );

    const again = await post(app, uid);
    expect(again.statusCode).toBe(200);
    expect(again.json()).toEqual(firstBody);

    const rows = await db.$client`
      SELECT * FROM reports WHERE reporter_uid = ${uid} AND request_id = ${"r".repeat(32)}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.kind).toBe("ai_output");
    expect(rows[0]!.reason).toBe("hate");
    expect(rows[0]!.details).toBe("offensive");
    expect(rows[0]!.excerpt).toBe("bad reply");
    expect(rows[0]!.model).toBe("m1");
    expect(rows[0]!.status).toBe("open");
  });

  it("rejects unknown/extra fields and out-of-range values", async () => {
    const uid = testUid("report-validation");
    const app = makeApp();
    const cases: Array<Record<string, unknown>> = [
      { reporter_uid: "bob" },
      { uid: "bob" },
      { kind: "payment" },
      { reason: "nope" },
      { excerpt: "x".repeat(4001) },
      { details: "x".repeat(1001) },
      { request_id: "short" },
      { target_id: "t".repeat(129) },
      { model: "m".repeat(129) },
      { details: null },
      { excerpt: null },
    ];
    for (const overrides of cases) {
      const res = await post(app, uid, overrides);
      expect(res.statusCode, JSON.stringify(overrides).slice(0, 60)).toBe(422);
      expect(res.json()).toEqual({ detail: "invalid_report" });
    }
    const rows = await db.$client`SELECT id FROM reports WHERE reporter_uid = ${uid}`;
    expect(rows).toHaveLength(0);
  });

  it("accepts the full kind/reason enums and optional target_id", async () => {
    const uid = testUid("report-enums");
    const app = makeApp();
    const kinds = ["ai_output", "shared_conversation", "collab_message", "collab_participant"];
    const reasons = [
      "sexual",
      "child_safety",
      "hate",
      "violence",
      "self_harm",
      "illegal",
      "misleading",
      "privacy",
      "spam",
      "other",
    ];
    let index = 0;
    for (const kind of kinds) {
      for (const reason of reasons) {
        const res = await post(app, uid, {
          request_id: `${kind}-${reason}`.replace(/[^A-Za-z0-9_-]/g, "-").padEnd(16, "x"),
          kind,
          reason,
          target_id: "session-1",
          details: "",
          excerpt: "",
        });
        expect(res.statusCode, `${kind}/${reason}`).toBe(201);
        index += 1;
      }
    }
    expect(index).toBe(40);
  });

  it("enforces the per-reporter daily limit after dedup", async () => {
    const uid = testUid("report-limit");
    const bob = testUid("report-limit-bob");
    const app = makeApp({ dailyLimit: 2 });
    expect((await post(app, uid, { request_id: "a".repeat(20) })).statusCode).toBe(201);
    expect((await post(app, uid, { request_id: "b".repeat(20) })).statusCode).toBe(201);

    // A replay of an existing report still returns 200 at the limit.
    expect((await post(app, uid, { request_id: "a".repeat(20) })).statusCode).toBe(200);

    const limited = await post(app, uid, { request_id: "c".repeat(20) });
    expect(limited.statusCode).toBe(429);
    expect(limited.json()).toEqual({ detail: "report_limit_reached" });
    expect(limited.headers["cache-control"]).toBe("no-store");

    // The limit is per reporter.
    expect((await post(app, bob, { request_id: "c".repeat(20) })).statusCode).toBe(201);
  });

  it("admission fence → 403 with the lifecycle detail", async () => {
    const uid = testUid("report-fenced");
    let calls = 0;
    const admission: ReportsAdmission = async (principal, fn) => {
      if (principal.uid === uid) {
        calls += 1;
        throw Object.assign(new Error("pending"), {
          status: 403,
          code: "account_deletion_pending",
        });
      }
      return fn(principal.uid);
    };
    const app = makeApp({ admission });
    const res = await post(app, uid);
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ detail: "account_deletion_pending" });
    expect(calls).toBe(1);
    const rows = await db.$client`SELECT id FROM reports WHERE reporter_uid = ${uid}`;
    expect(rows).toHaveLength(0);
  });

  it("malformed JSON is a 422 invalid_report (never a gateway envelope)", async () => {
    const uid = testUid("report-json");
    const app = makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/v1/reports",
      headers: { ...authHeaders(uid), "content-type": "application/json" },
      payload: "{not json",
    });
    expect(res.statusCode).toBe(422);
    expect(res.json()).toEqual({ detail: "invalid_report" });
  });
});
