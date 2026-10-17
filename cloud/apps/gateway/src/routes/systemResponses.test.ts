import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import { buildGateway, type GatewayDeps } from "../app.js";
import type { SystemHub } from "../systemChannel.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// POST /cloud/v1/system/responses (P5 Task 15) — the REST answer path for
// ANY pending system-channel request (the WS system_response twin). The
// gateway forwards {id, payload} opaquely to the worker on sys:{uid}:in;
// the caller's authenticated uid scopes it (never a body field).

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;

function stubSystemHub(): { hub: SystemHub; responds: Array<{ uid: string; id: string; payload: Record<string, unknown> }> } {
  const responds: Array<{ uid: string; id: string; payload: Record<string, unknown> }> = [];
  const hub: SystemHub = {
    attach: () => () => {},
    publishOut: async () => {},
    respond: async (uid, id, payload) => {
      responds.push({ uid, id, payload });
    },
    close: async () => {},
  };
  return { hub, responds };
}

describe.skipIf(!TEST_DATABASE_URL_)("gateway system responses route (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  let bare: FastifyInstance;
  let responds: Array<{ uid: string; id: string; payload: Record<string, unknown> }>;

  beforeAll(async () => {
    db = await openTestDb();
    const { hub, responds: captured } = stubSystemHub();
    responds = captured;
    const deps = (extra: Partial<GatewayDeps>): GatewayDeps => ({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      ...extra,
    });
    app = buildGateway(deps({ systemHub: hub }));
    bare = buildGateway(deps({}));
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await bare?.close();
    await closeDb(db);
  });

  it("POST {id,payload} → 204; systemHub.respond called with the CALLER's uid", async () => {
    const uid = testUid("sys-ok");
    const payload = { approve: true, allowDependencyScripts: false };
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/system/responses",
      headers: authHeaders(uid),
      payload: { id: "req-1", payload },
    });
    expect(res.statusCode).toBe(204);
    expect(responds).toEqual([{ uid, id: "req-1", payload }]);
  });

  it("malformed bodies → 400", async () => {
    const uid = testUid("sys-bad");
    for (const payload of [
      {},
      { id: "" },
      { id: "req-2" }, // missing payload
      { payload: { a: 1 } }, // missing id
      { id: "req-2", payload: "nope" },
      { id: "req-2", payload: {}, extra: true },
    ]) {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/system/responses",
        headers: authHeaders(uid),
        payload,
      });
      expect(res.statusCode).toBe(400);
    }
    expect(responds.length).toBe(1); // nothing forwarded from the refusals
  });

  it("a gateway composed without the system channel → 503 unavailable", async () => {
    const res = await bare.inject({
      method: "POST",
      url: "/cloud/v1/system/responses",
      headers: authHeaders(testUid("sys-bare")),
      payload: { id: "req-3", payload: { approve: false } },
    });
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({
      error: { code: "unavailable", message: "System channel is not configured." },
    });
  });
});
