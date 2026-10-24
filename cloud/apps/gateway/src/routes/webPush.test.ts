import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { pushSubscriptionsRepo, users, type Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubSystemBus, stubTickets, stubVerifier } from "../test/stubs.js";

const ENDPOINT = "https://fcm.googleapis.com/subscription/one";

describe.skipIf(!TEST_DATABASE_URL)("web push subscriptions (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;

  beforeAll(async () => {
    db = await openTestDb();
    app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      webPushPublicKey: "test-public-vapid-key",
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  it("returns only the public VAPID key, or an honest unconfigured error", async () => {
    const configured = await app.inject({ method: "GET", url: "/cloud/v1/push/config", headers: authHeaders("u1") });
    expect(configured.statusCode).toBe(200);
    expect(configured.json()).toEqual({ vapidPublicKey: "test-public-vapid-key" });
    expect(configured.body).not.toContain("private");

    const bare = buildGateway({
      system: stubSystemBus(), db, queues: stubQueues().queues,
      verifier: stubVerifier(), tickets: stubTickets(), keys: stubKeys(),
      mint: stubMint(), events: noopEvents,
    });
    const missing = await bare.inject({ method: "GET", url: "/cloud/v1/push/config", headers: authHeaders("u1") });
    expect(missing.statusCode).toBe(503);
    expect(missing.json().error.code).toBe("web_push_unconfigured");
    await bare.close();
  });

  it("stores a browser subscription with its two keys and deletes it owner-scoped", async () => {
    const uid = testUid("web-push");
    await users.ensure(db, uid, null);
    const created = await app.inject({
      method: "POST", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid),
      payload: { endpoint: ENDPOINT, p256dh: "public-client-key", auth: "subscription-auth" },
    });
    expect(created.statusCode).toBe(201);
    const stored = await pushSubscriptionsRepo.listForUser(db, uid);
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ endpoint: ENDPOINT, p256dh: "public-client-key", auth: "subscription-auth" });

    const confirmed = await app.inject({
      method: "GET", url: `/cloud/v1/push/subscription?endpoint=${encodeURIComponent(ENDPOINT)}`,
      headers: authHeaders(uid),
    });
    expect(confirmed.statusCode).toBe(200);
    expect(confirmed.json()).toEqual({ registered: true });

    const other = testUid("web-push-other");
    await users.ensure(db, other, null);
    const wrongOwner = await app.inject({
      method: "DELETE", url: "/cloud/v1/push/subscriptions", headers: authHeaders(other),
      payload: { endpoint: ENDPOINT },
    });
    expect(wrongOwner.statusCode).toBe(204);
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(1);
    const notRegistered = await app.inject({
      method: "GET", url: `/cloud/v1/push/subscription?endpoint=${encodeURIComponent(ENDPOINT)}`,
      headers: authHeaders(other),
    });
    expect(notRegistered.json()).toEqual({ registered: false });

    const removed = await app.inject({
      method: "DELETE", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid),
      payload: { endpoint: ENDPOINT },
    });
    expect(removed.statusCode).toBe(204);
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(0);
  });

  it("caps browser subscriptions per account without accepting a flood", async () => {
    const uid = testUid("web-push-cap");
    await users.ensure(db, uid, null);
    for (let index = 0; index < 10; index += 1) {
      await pushSubscriptionsRepo.upsert(db, {
        userId: uid, endpoint: `https://fcm.googleapis.com/subscription/${index}`, p256dh: "key", auth: "auth",
      });
    }
    const response = await app.inject({
      method: "POST", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid),
      payload: { endpoint: "https://fcm.googleapis.com/subscription/eleventh", p256dh: "key", auth: "auth" },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("push_subscription_limit");
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(10);

    const refresh = await app.inject({
      method: "POST", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid),
      payload: { endpoint: "https://fcm.googleapis.com/subscription/0", p256dh: "new-key", auth: "new-auth" },
    });
    expect(refresh.statusCode).toBe(201);
    const concurrent = await Promise.all(
      Array.from({ length: 4 }, (_, index) => app.inject({
        method: "POST", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid),
        payload: { endpoint: `https://fcm.googleapis.com/subscription/concurrent-${index}`, p256dh: "key", auth: "auth" },
      })),
    );
    expect(concurrent.every((res) => res.statusCode === 409)).toBe(true);
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(10);
  });

  it("rejects insecure or extra-field subscriptions before writing", async () => {
    const uid = testUid("web-push-invalid");
    for (const payload of [
      { endpoint: "http://push.example.test/subscription", p256dh: "key", auth: "auth" },
      { endpoint: "https://169.254.169.254/latest/meta-data", p256dh: "key", auth: "auth" },
      { endpoint: "https://user:secret@fcm.googleapis.com/one", p256dh: "key", auth: "auth" },
      { endpoint: "https://push.example.test/not-allowlisted", p256dh: "key", auth: "auth" },
      { endpoint: ENDPOINT, p256dh: "key", auth: "auth", uid: "victim" },
    ]) {
      const response = await app.inject({
        method: "POST", url: "/cloud/v1/push/subscriptions", headers: authHeaders(uid), payload,
      });
      expect(response.statusCode).toBe(400);
    }
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(0);
  });
});
