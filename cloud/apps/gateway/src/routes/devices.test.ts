import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import type { Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
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

describe.skipIf(!TEST_DATABASE_URL)("gateway device routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;

  beforeAll(async () => {
    db = await openTestDb();
    const { queues } = stubQueues();
    app = buildGateway({
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function rowsFor(token: string): Promise<Array<{ user_id: string; platform: string }>> {
    return (await db.$client.unsafe(
      "SELECT user_id, platform FROM devices WHERE token = $1",
      [token],
    )) as Array<{ user_id: string; platform: string }>;
  }

  it("POST /devices → 200 DeviceDto and registers the token", async () => {
    const uid = testUid("dev-register");
    const token = `fcm-${testUid("tok")}`;
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/devices",
      headers: authHeaders(uid),
      payload: { token, platform: "android" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ token, platform: "android" });
    expect(await rowsFor(token)).toEqual([{ user_id: uid, platform: "android" }]);
  });

  it("re-POSTing the same token upserts — exactly one row", async () => {
    const uid = testUid("dev-upsert");
    const token = `fcm-${testUid("tok")}`;
    for (let i = 0; i < 3; i++) {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/devices",
        headers: authHeaders(uid),
        payload: { token, platform: "android" },
      });
      expect(res.statusCode).toBe(200);
    }
    expect(await rowsFor(token)).toHaveLength(1);
  });

  it("POST /devices rejects non-android platforms and malformed bodies → 400", async () => {
    const uid = testUid("dev-bad");
    const payloads = [
      { token: "t", platform: "ios" },
      { token: "", platform: "android" },
      { platform: "android" },
      { token: "t", platform: "android", extra: 1 },
      {},
    ];
    for (const payload of payloads) {
      const res = await app.inject({
        method: "POST",
        url: "/cloud/v1/devices",
        headers: authHeaders(uid),
        payload,
      });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
  });

  it("DELETE /devices removes the caller's token → 204; unknown token is a no-op 204", async () => {
    const uid = testUid("dev-delete");
    const token = `fcm-${testUid("tok")}`;
    await app.inject({
      method: "POST",
      url: "/cloud/v1/devices",
      headers: authHeaders(uid),
      payload: { token, platform: "android" },
    });

    const res = await app.inject({
      method: "DELETE",
      url: "/cloud/v1/devices",
      headers: authHeaders(uid),
      payload: { token },
    });
    expect(res.statusCode).toBe(204);
    expect(await rowsFor(token)).toEqual([]);

    const again = await app.inject({
      method: "DELETE",
      url: "/cloud/v1/devices",
      headers: authHeaders(uid),
      payload: { token },
    });
    expect(again.statusCode).toBe(204);
  });

  it("DELETE with someone else's token → 204 but the row SURVIVES (no existence leak)", async () => {
    const owner = testUid("dev-owner");
    const stranger = testUid("dev-stranger");
    const token = `fcm-${testUid("tok")}`;
    await app.inject({
      method: "POST",
      url: "/cloud/v1/devices",
      headers: authHeaders(owner),
      payload: { token, platform: "android" },
    });

    const res = await app.inject({
      method: "DELETE",
      url: "/cloud/v1/devices",
      headers: authHeaders(stranger),
      payload: { token },
    });
    expect(res.statusCode).toBe(204);
    expect(await rowsFor(token)).toEqual([{ user_id: owner, platform: "android" }]);
  });

  it("DELETE /devices requires a non-empty token in the body → 400", async () => {
    const uid = testUid("dev-delete-bad");
    for (const payload of [{}, { token: "" }, { token: 42 }, { token: "t", extra: 1 }]) {
      const res = await app.inject({
        method: "DELETE",
        url: "/cloud/v1/devices",
        headers: authHeaders(uid),
        payload,
      });
      expect(res.statusCode, JSON.stringify(payload)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
  });

  it("device routes answer 401 unauthenticated", async () => {
    for (const req of [
      { method: "POST" as const, url: "/cloud/v1/devices", payload: { token: "t", platform: "android" } },
      { method: "DELETE" as const, url: "/cloud/v1/devices", payload: { token: "t" } },
    ]) {
      const res = await app.inject({ ...req, headers: {} });
      expect(res.statusCode, req.url).toBe(401);
      expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    }
  });
});
