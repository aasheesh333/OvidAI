import { readFileSync } from "node:fs";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import {
  createDb,
  createSystemRequestStore,
  migrate,
  newId,
  schema,
  sessions,
  users,
  type Db,
  type SystemRequestStore,
} from "@ovid/db";
import {
  systemRequestDtoSchema,
  systemRequestsFixtureV1Schema,
  systemResponseDtoSchema,
  type SystemResponseAttempt,
  type SystemRequestsFixtureV1,
} from "@ovid/shared";
import { buildGateway, type GatewayDeps } from "../app.js";
import { closeDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../../packages/db/src/migrationTestKit.js";
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

const fixtureUrl = new URL(
  "../../../../packages/shared/contracts/fixtures/system-requests-v1.json",
  import.meta.url,
);
const FIXTURE: SystemRequestsFixtureV1 = systemRequestsFixtureV1Schema.parse(
  JSON.parse(readFileSync(fixtureUrl, "utf8")),
);
const OWNER = FIXTURE.requests.pendingApproval.userId;
const SESSION_ID = FIXTURE.requests.pendingApproval.sessionId;
const T0 = new Date("2026-10-24T12:00:00.000Z");
const RESPONSE_TIME = new Date(FIXTURE.responseReceipt.createdAt);

type FixtureRequestName = keyof SystemRequestsFixtureV1["requests"];

describe.skipIf(!TEST_DATABASE_URL).sequential("gateway durable system request routes (isolated real Postgres)", () => {
  let db: Db;
  let scratch: MigrationScratch;
  let store: SystemRequestStore;
  let now: Date;
  const built: FastifyInstance[] = [];

  beforeAll(async () => {
    // A private database prevents other gateway suites from projecting or
    // retaining references to the canonical fixture's stable IDs.
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_system_requests");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
  }, 180_000);

  beforeEach(async () => {
    now = new Date(T0);
    await db.$client`DELETE FROM system_request_responses WHERE user_id = ${OWNER}`;
    await db.$client`DELETE FROM system_requests WHERE user_id = ${OWNER}`;
    await db.$client`DELETE FROM runs WHERE session_id = ${SESSION_ID}`;
    await db.$client`DELETE FROM messages WHERE session_id = ${SESSION_ID}`;
    await db.$client`DELETE FROM sessions WHERE id = ${SESSION_ID}`;
    await db.$client`DELETE FROM users WHERE uid = ${OWNER}`;
    store = createSystemRequestStore(db, { clock: () => now });
  });

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
    await scratch?.close();
  }, 30_000);

  function makeApp(extra: Partial<GatewayDeps> = {}): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      clock: () => now,
      ...extra,
    });
    built.push(app);
    return app;
  }

  async function seedFixtureRequests(names: readonly FixtureRequestName[]): Promise<void> {
    await users.ensure(db, OWNER, null);
    await db.insert(schema.sessions).values({
      id: SESSION_ID,
      userId: OWNER,
      title: "Canonical system request fixture",
    });
    const approvalPrompt = newId();
    const sensitivePrompt = newId();
    await db.insert(schema.messages).values([
      { id: approvalPrompt, sessionId: SESSION_ID, role: "user", content: "approval fixture" },
      { id: sensitivePrompt, sessionId: SESSION_ID, role: "user", content: "sensitive fixture" },
    ]);
    await db.insert(schema.runs).values([
      {
        id: FIXTURE.requests.pendingApproval.runId,
        sessionId: SESSION_ID,
        promptMessageId: approvalPrompt,
        status: "running",
      },
      {
        id: FIXTURE.requests.sensitiveElicitation.runId,
        sessionId: SESSION_ID,
        promptMessageId: sensitivePrompt,
        status: "running",
      },
    ]);
    for (const name of names) {
      const request = FIXTURE.requests[name];
      await store.create({
        requestId: request.requestId,
        userId: request.userId,
        sessionId: request.sessionId,
        runId: request.runId,
        kind: request.kind,
        safePayload: request.safePayload,
        sensitive: request.sensitive,
        expiresAt: new Date(request.expiresAt),
      });
      if (request.version !== 1) {
        await db.$client`
          UPDATE system_requests SET version = ${request.version}
          WHERE request_id = ${request.requestId}`;
      }
    }
  }

  function respondBody(attempt: SystemResponseAttempt): Omit<SystemResponseAttempt, "requestId"> {
    return {
      version: attempt.version,
      response: attempt.response,
      clientResponseId: attempt.clientResponseId,
    };
  }

  async function postResponse(
    app: FastifyInstance,
    requestId: string,
    uid: string,
    body: unknown,
  ) {
    return app.inject({
      method: "POST",
      url: `/cloud/v1/system-requests/${encodeURIComponent(requestId)}/respond`,
      headers: authHeaders(uid),
      payload: body as Record<string, unknown>,
    });
  }

  it("GET returns canonical pending DTOs only for the verified owner's session", async () => {
    await seedFixtureRequests(["pendingApproval", "sensitiveElicitation"]);
    const app = makeApp();
    const res = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
      headers: authHeaders(OWNER),
    });

    expect(res.statusCode).toBe(200);
    const body = res.json() as unknown;
    expect(Array.isArray(body)).toBe(true);
    expect(systemRequestDtoSchema.array().parse(body)).toEqual([
      FIXTURE.requests.pendingApproval,
      FIXTURE.requests.sensitiveElicitation,
    ]);
  });

  it("POST returns the canonical non-secret receipt and structurally identical replay without claiming resolution", async () => {
    await seedFixtureRequests(["pendingApproval"]);
    now = new Date(RESPONSE_TIME);
    const app = makeApp();
    const request = FIXTURE.requests.pendingApproval;
    const receipt = FIXTURE.responseReceipt;

    const first = await postResponse(app, request.requestId, OWNER, {
      version: receipt.version,
      response: receipt.response,
      clientResponseId: receipt.clientResponseId,
    });
    expect(first.statusCode).toBe(200);
    expect(systemResponseDtoSchema.parse(first.json())).toEqual(receipt);
    expect(first.json()).not.toHaveProperty("status");

    const replay = await postResponse(
      app,
      request.requestId,
      OWNER,
      respondBody(FIXTURE.identicalReplay.attempt),
    );
    expect(replay.statusCode).toBe(200);
    expect(replay.json()).toEqual(first.json());

    // A receipt is only a receipt. Resolution is observed through a fresh DTO
    // read, never through a client-supplied status or an optimistic card state.
    expect(await store.get({ userId: OWNER, requestId: request.requestId })).toMatchObject({
      status: "resolved",
      version: request.version + 1,
      response: receipt.response,
    });
    const refreshed = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
      headers: authHeaders(OWNER),
    });
    expect(refreshed.statusCode).toBe(200);
    expect(refreshed.json()).toEqual([]);

    // A retry after the original expiry still replays its durable receipt; it
    // must not turn an already-accepted response into a late response.
    now = new Date("2026-10-24T13:01:00.000Z");
    const afterExpiry = await postResponse(
      app,
      request.requestId,
      OWNER,
      respondBody(FIXTURE.identicalReplay.attempt),
    );
    expect(afterExpiry.statusCode).toBe(200);
    expect(afterExpiry.json()).toEqual(receipt);
  });

  it("requires verified Firebase auth and makes wrong-owner and unknown IDs non-enumerating", async () => {
    await seedFixtureRequests(["pendingApproval"]);
    const app = makeApp();
    const request = FIXTURE.requests.pendingApproval;
    const other = testUid("system-request-other");
    await users.ensure(db, other, null);
    const foreignSession = await sessions.create(db, other, "Foreign session");
    const missingSession = newId();
    const sessionDenied = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
      headers: authHeaders(other),
    });
    const sessionMissing = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${missingSession}/system-requests`,
      headers: authHeaders(other),
    });
    const sessionForeign = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${foreignSession.id}/system-requests`,
      headers: authHeaders(OWNER),
    });
    const sessionMalformed = await app.inject({
      method: "GET",
      url: "/cloud/v1/sessions/not-a-uuid/system-requests",
      headers: authHeaders(other),
    });
    for (const res of [sessionDenied, sessionMissing, sessionForeign, sessionMalformed]) {
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: { code: "not_found", message: "Session not found." } });
    }

    const body = respondBody(FIXTURE.identicalReplay.attempt);
    const wrongOwner = await postResponse(app, request.requestId, other, body);
    const unknownRequest = await postResponse(app, newId(), other, body);
    for (const res of [wrongOwner, unknownRequest]) {
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({
        error: { code: "not_found", message: "System request not found." },
      });
    }
    expect(await store.get({ userId: OWNER, requestId: request.requestId })).toMatchObject({
      status: "pending",
      version: request.version,
      response: null,
    });

    for (const res of [
      await app.inject({ method: "GET", url: `/cloud/v1/sessions/${SESSION_ID}/system-requests` }),
      await app.inject({
        method: "POST",
        url: `/cloud/v1/system-requests/${request.requestId}/respond`,
        payload: body,
      }),
      await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
        headers: { authorization: "Bearer forged-token" },
      }),
    ]) {
      expect(res.statusCode).toBe(401);
      expect(res.json()).toEqual({
        error: { code: "unauthenticated", message: "Missing or invalid credentials." },
      });
    }
  });

  it("accepts only version,response,clientResponseId and never applies client-forged resolution fields", async () => {
    await seedFixtureRequests(["pendingApproval"]);
    const app = makeApp();
    const request = FIXTURE.requests.pendingApproval;
    const valid = respondBody(FIXTURE.identicalReplay.attempt);
    const invalidBodies: unknown[] = [
      {},
      { ...valid, version: 0 },
      { ...valid, version: 1.5 },
      { ...valid, version: "3" },
      { ...valid, response: null },
      { ...valid, response: [] },
      { ...valid, clientResponseId: "" },
      { ...valid, role: "assistant" },
      { ...valid, status: "resolved" },
      { ...valid, assistant: "forged answer" },
      { ...valid, requestId: newId() },
      { ...valid, userId: "client-forged-user" },
      { ...valid, unknownField: true },
    ];
    for (const body of invalidBodies) {
      const res = await postResponse(app, request.requestId, OWNER, body);
      expect(res.statusCode, JSON.stringify(body)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(await store.get({ userId: OWNER, requestId: request.requestId })).toEqual(request);
    expect(await db.$client`
      SELECT count(*)::int AS count FROM system_request_responses WHERE request_id = ${request.requestId}`
    ).toEqual([{ count: 0 }]);
  });

  it("maps stale versions and different responses to truthful conflicts without a forged receipt", async () => {
    await seedFixtureRequests(["pendingApproval"]);
    now = new Date(RESPONSE_TIME);
    const app = makeApp();
    const request = FIXTURE.requests.pendingApproval;

    const stale = await postResponse(
      app,
      request.requestId,
      OWNER,
      respondBody(FIXTURE.versionConflict.attempt),
    );
    expect(stale.statusCode).toBe(409);
    expect(stale.json()).toEqual({ error: FIXTURE.versionConflict.error });
    expect(stale.json()).not.toHaveProperty("receipt");

    const accepted = await postResponse(app, request.requestId, OWNER, {
      version: FIXTURE.responseReceipt.version,
      response: FIXTURE.responseReceipt.response,
      clientResponseId: FIXTURE.responseReceipt.clientResponseId,
    });
    expect(accepted.statusCode).toBe(200);
    const changed = await postResponse(app, request.requestId, OWNER, {
      version: request.version,
      response: { approve: false, allowDependencyScripts: false },
      clientResponseId: FIXTURE.responseReceipt.clientResponseId,
    });
    expect(changed.statusCode).toBe(409);
    expect(changed.json()).toEqual({
      error: {
        code: "response_conflict",
        message: "A different response was already recorded.",
      },
    });
    expect(await store.get({ userId: OWNER, requestId: request.requestId })).toMatchObject({
      status: "resolved",
      version: request.version + 1,
      response: FIXTURE.responseReceipt.response,
    });
  });

  it("expires a late response durably without storing a receipt", async () => {
    await seedFixtureRequests(["pendingApproval"]);
    now = new Date(FIXTURE.requests.pendingApproval.expiresAt);
    const app = makeApp();
    const request = FIXTURE.requests.pendingApproval;
    const late = await postResponse(
      app,
      request.requestId,
      OWNER,
      respondBody(FIXTURE.identicalReplay.attempt),
    );
    expect(late.statusCode).toBe(410);
    expect(late.json()).toEqual({
      error: { code: "request_expired", message: "The system request has expired." },
    });
    expect(await store.get({ userId: OWNER, requestId: request.requestId })).toMatchObject({
      status: "expired",
      version: request.version + 1,
      response: null,
    });
    expect(await db.$client`
      SELECT count(*)::int AS count FROM system_request_responses WHERE request_id = ${request.requestId}`
    ).toEqual([{ count: 0 }]);
    const refreshed = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
      headers: authHeaders(OWNER),
    });
    expect(refreshed.json()).toEqual([]);
  });

  it("keeps sensitive responses pending and plaintext-free across publish failure, no subscriber, and restart", async () => {
    await seedFixtureRequests(["sensitiveElicitation"]);
    now = new Date(RESPONSE_TIME);
    const request = FIXTURE.requests.sensitiveElicitation;
    const secrets = [
      "gateway-sensitive-canary-commit-before-publish",
      "gateway-sensitive-canary-no-subscriber",
      "gateway-sensitive-canary-after-restart",
    ];
    let publishAttempts = 0;
    const hub = (failure: string | null): NonNullable<GatewayDeps["systemHub"]> => ({
      attach: () => () => {},
      publishOut: async () => {},
      respond: async () => {
        publishAttempts += 1;
        if (failure !== null) throw new Error(failure);
      },
      close: async () => {},
    });

    const scenarios = [
      { failure: "commit_before_publish_failed", secret: secrets[0]! },
      { failure: null, secret: secrets[1]! },
      { failure: "restart_before_recovery", secret: secrets[2]! },
    ];
    for (const [index, scenario] of scenarios.entries()) {
      // Each new app is a fresh gateway composition over the same durable DB;
      // the last one models a process restart before any subscriber recovery.
      const app = makeApp({ systemHub: hub(scenario.failure) });
      const res = await postResponse(app, request.requestId, OWNER, {
        version: request.version,
        response: { action: "accept", content: { password: scenario.secret } },
        clientResponseId: `sensitive-attempt-${index}`,
      });
      expect(res.statusCode).toBe(503);
      expect(res.json()).toEqual({
        error: {
          code: "sensitive_delivery_unavailable",
          message: "Sensitive response delivery is unavailable; re-enter it after durable recovery is available.",
        },
      });
      expect(res.body).not.toContain(scenario.secret);
      expect(await store.get({ userId: OWNER, requestId: request.requestId })).toEqual(request);
    }
    expect(publishAttempts).toBe(0);

    const refreshed = await built[built.length - 1]!.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${SESSION_ID}/system-requests`,
      headers: authHeaders(OWNER),
    });
    expect(refreshed.statusCode).toBe(200);
    expect(refreshed.json()).toEqual([request]);
    const rows = await db.$client`
      SELECT
        (SELECT count(*)::int FROM system_request_responses WHERE request_id = ${request.requestId}) AS responses,
        (SELECT row_to_json(system_requests)::text FROM system_requests WHERE request_id = ${request.requestId}) AS request_raw,
        (SELECT coalesce(string_agg(row_to_json(system_request_responses)::text, ''), '')
           FROM system_request_responses WHERE request_id = ${request.requestId}) AS response_raw`;
    expect(rows[0]?.responses).toBe(0);
    for (const secret of secrets) {
      expect(rows[0]?.request_raw).not.toContain(secret);
      expect(rows[0]?.response_raw).not.toContain(secret);
    }
  });
});
