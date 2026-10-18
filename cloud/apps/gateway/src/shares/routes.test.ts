import { randomBytes } from "node:crypto";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { schema, sharesRepo, type Db } from "@ovid/db";
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
import { OPEN_APP_SCRIPT, pageCsp, SHARES_HEADERS } from "./headers.js";
import type { ShareAdmission } from "./routes.js";

// Port of server/shares/tests/test_shares.py + parallel_shares_invariants.py.
// Real Postgres, Fastify inject; the verifier is the gateway stub mapped onto
// the Python verify_uid contract. Clock is injected so receipts/expiry are
// deterministic.

const BASE_URL = "https://share.example.test";
const TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;
const BASE = new Date("2026-05-01T00:00:00.000Z");
const TTL_SECONDS = 30 * 86400;

const MESSAGES = [
  { role: "user", content: "Hello" },
  { role: "assistant", content: "<script>alert(1)</script> **hi**" },
];

function payload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    session_id: "session-1",
    request_id: "request-1",
    messages: MESSAGES,
    ...overrides,
  };
}

function seedToken(): string {
  return randomBytes(32).toString("base64url");
}

describe.skipIf(!TEST_DATABASE_URL)("gateway legacy shares routes (real postgres)", () => {
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

  interface AppOpts {
    now?: () => Date;
    admission?: ShareAdmission;
  }

  function makeApp(opts: AppOpts = {}): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      shares: {
        baseUrl: BASE_URL,
        clock: opts.now ?? (() => BASE),
        ...(opts.admission ? { admission: opts.admission } : {}),
      },
    });
    built.push(app);
    return app;
  }

  async function create(
    app: FastifyInstance,
    uid: string,
    overrides: Record<string, unknown> = {},
  ) {
    return app.inject({
      method: "POST",
      url: "/shares",
      headers: authHeaders(uid),
      payload: payload(overrides),
    });
  }

  it("create → receipt from the configured base only (Host spoof ignored)", async () => {
    const uid = testUid("share-create");
    const app = makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/shares",
      headers: { ...authHeaders(uid), host: "evil.test", "x-forwarded-host": "evil.test" },
      payload: payload(),
    });
    expect(res.statusCode).toBe(201);
    const receipt = res.json() as Record<string, unknown>;
    expect(Object.keys(receipt).sort()).toEqual(
      ["created_at", "expires_at", "id", "request_id", "session_id", "url"].sort(),
    );
    expect(receipt.id).toMatch(TOKEN_RE);
    expect(receipt.session_id).toBe("session-1");
    expect(receipt.request_id).toBe("request-1");
    expect(receipt.created_at).toBe(BASE.getTime() / 1000);
    expect(receipt.expires_at).toBe(BASE.getTime() / 1000 + TTL_SECONDS);
    expect(receipt.url).toBe(`${BASE_URL}/s/${receipt.id as string}`);
    expect(res.headers["cache-control"]).toContain("no-store");
    expect(res.headers["cache-control"]).toContain("private");
  });

  it("authentication failures use the legacy detail envelope and never cache", async () => {
    const app = makeApp();
    for (const headers of [{}, { authorization: "Bearer nope" }]) {
      const res = await app.inject({ method: "POST", url: "/shares", headers, payload: payload() });
      expect(res.statusCode).toBe(401);
      expect(res.json()).toEqual({
        detail: headers.authorization === undefined ? "authentication_required" : "invalid_authentication",
      });
      expect(res.headers["cache-control"]).toContain("private");
    }
    // Anonymous listing is rejected too.
    const list = await app.inject({ method: "GET", url: "/shares" });
    expect(list.statusCode).toBe(401);
    expect(list.json()).toEqual({ detail: "authentication_required" });
  });

  it("dedup identical retry → the same immutable receipt; changed content → 409", async () => {
    const uid = testUid("share-dedup");
    const app = makeApp();
    const first = await create(app, uid);
    expect(first.statusCode).toBe(201);
    const again = await create(app, uid);
    expect(again.statusCode).toBe(201);
    expect(again.json()).toEqual(first.json());

    const changed = await create(app, uid, {
      messages: [{ role: "user", content: "Different" }],
    });
    expect(changed.statusCode).toBe(409);
    expect(changed.json()).toEqual({ detail: "request_already_used" });

    const token = (first.json() as { id: string }).id;
    const publicSnap = await app.inject({ method: "GET", url: `/s/${token}.json` });
    expect(publicSnap.json()).toEqual({ messages: MESSAGES, session_id: "session-1" });
  });

  it("revoked receipt retry → 409 (never republishes)", async () => {
    const uid = testUid("share-revoked-retry");
    const app = makeApp();
    const first = await create(app, uid);
    const token = (first.json() as { id: string }).id;
    const del = await app.inject({
      method: "DELETE",
      url: `/shares/${token}`,
      headers: authHeaders(uid),
    });
    expect(del.statusCode).toBe(204);
    // Idempotent for the owner.
    const delAgain = await app.inject({
      method: "DELETE",
      url: `/shares/${token}`,
      headers: authHeaders(uid),
    });
    expect(delAgain.statusCode).toBe(204);

    const replay = await create(app, uid);
    expect(replay.statusCode).toBe(409);
    expect(replay.json()).toEqual({ detail: "request_already_used" });
  });

  it("101st active share → 429; GET and DELETE still work", async () => {
    const uid = testUid("share-active-quota");
    const app = makeApp();
    const rows = Array.from({ length: 100 }, (_, i) => ({
      token: seedToken(),
      ownerUid: uid,
      sessionId: "session-1",
      requestId: `seed-${i}`,
      content: { messages: [{ role: "user", content: "seed" }] },
      messageCount: 1,
      createdAt: BASE,
      expiresAt: new Date(BASE.getTime() + TTL_SECONDS * 1000),
    }));
    await db.insert(schema.shares).values(rows);

    const blocked = await create(app, uid, { request_id: "over-active" });
    expect(blocked.statusCode).toBe(429);
    expect(blocked.json()).toEqual({ detail: "share_limit_reached" });

    const list = await app.inject({ method: "GET", url: "/shares", headers: authHeaders(uid) });
    expect(list.statusCode).toBe(200);
    expect((list.json() as { shares: unknown[] }).shares).toHaveLength(100);

    const del = await app.inject({
      method: "DELETE",
      url: `/shares/${rows[0]!.token}`,
      headers: authHeaders(uid),
    });
    expect(del.statusCode).toBe(204);

    const after = await create(app, uid, { request_id: "after-delete" });
    expect(after.statusCode).toBe(201);
  });

  it("lifetime 1000 budget is not reset by revocation or expiry", async () => {
    const uid = testUid("share-lifetime-quota");
    const app = makeApp();
    const expiredAt = new Date(BASE.getTime() - 1000);
    const rows = Array.from({ length: 1000 }, (_, i) => ({
      token: seedToken(),
      ownerUid: uid,
      sessionId: "session-1",
      requestId: `seed-${i}`,
      content: null,
      messageCount: 0,
      createdAt: BASE,
      expiresAt: expiredAt,
      revokedAt: BASE,
    }));
    await db.insert(schema.shares).values(rows);

    const blocked = await create(app, uid, { request_id: "over-budget" });
    expect(blocked.statusCode).toBe(429);
    expect(blocked.json()).toEqual({ detail: "share_storage_limit_reached" });

    // A retry of an existing (revoked) receipt is still a conflict, never a
    // quota mask and never a republish.
    const replay = await create(app, uid, { request_id: "seed-5" });
    expect(replay.statusCode).toBe(409);
    expect(replay.json()).toEqual({ detail: "request_already_used" });

    // The budget is per-owner.
    const bob = await create(app, testUid("share-lifetime-bob"));
    expect(bob.statusCode).toBe(201);
  });

  it("owner lists only their own active receipts, filterable by session", async () => {
    const alice = testUid("share-list-alice");
    const bob = testUid("share-list-bob");
    const app = makeApp();
    const receipt = (await create(app, alice)).json() as { id: string };
    expect(
      (await app.inject({ method: "GET", url: "/shares", headers: authHeaders(bob) })).json(),
    ).toEqual({ shares: [] });

    const mine = await app.inject({ method: "GET", url: "/shares", headers: authHeaders(alice) });
    expect((mine.json() as { shares: Array<{ request_id: string }> }).shares[0]!.request_id).toBe(
      "request-1",
    );
    const filtered = await app.inject({
      method: "GET",
      url: "/shares?session_id=session-1",
      headers: authHeaders(alice),
    });
    expect((filtered.json() as { shares: unknown[] }).shares).toHaveLength(1);
    const other = await app.inject({
      method: "GET",
      url: "/shares?session_id=other",
      headers: authHeaders(alice),
    });
    expect(other.json()).toEqual({ shares: [] });

    // The viewer never carries owner metadata.
    const page = await app.inject({ method: "GET", url: `/s/${receipt.id}` });
    expect(page.body).not.toContain(alice);
    expect(page.body).not.toContain("request-1");
    expect(page.body).not.toContain("session-1");
  });

  it("owner updates a live link in place; token/expiry are immutable", async () => {
    const alice = testUid("share-update");
    const bob = testUid("share-update-bob");
    const app = makeApp();
    const share = (await create(app, alice)).json() as { id: string; expires_at: number };
    const updated = payload({
      request_id: "update-1",
      messages: [...MESSAGES, { role: "user", content: "More" }],
    });
    const res = await app.inject({
      method: "PUT",
      url: `/shares/${share.id}`,
      headers: authHeaders(alice),
      payload: updated,
    });
    expect(res.statusCode).toBe(200);
    expect((res.json() as { id: string }).id).toBe(share.id);
    expect((res.json() as { expires_at: number }).expires_at).toBe(share.expires_at);
    const snap = await app.inject({ method: "GET", url: `/s/${share.id}.json` });
    expect(
      (snap.json() as { messages: Array<{ content: string }> }).messages.at(-1)!.content,
    ).toBe("More");

    const wrongOwner = await app.inject({
      method: "PUT",
      url: `/shares/${share.id}`,
      headers: authHeaders(bob),
      payload: updated,
    });
    expect(wrongOwner.statusCode).toBe(404);
    expect(wrongOwner.json()).toEqual({ detail: "share_not_found" });

    const wrongSession = await app.inject({
      method: "PUT",
      url: `/shares/${share.id}`,
      headers: authHeaders(alice),
      payload: { ...updated, session_id: "session-2" },
    });
    expect(wrongSession.statusCode).toBe(404);

    const privateBody = await app.inject({
      method: "PUT",
      url: `/shares/${share.id}`,
      headers: authHeaders(alice),
      payload: payload({
        messages: [{ role: "user", content: "<think>x</think>" }],
      }),
    });
    expect(privateBody.statusCode).toBe(422);
    expect(privateBody.json()).toEqual({ detail: "invalid_snapshot" });

    await app.inject({ method: "DELETE", url: `/shares/${share.id}`, headers: authHeaders(alice) });
    const afterRevoke = await app.inject({
      method: "PUT",
      url: `/shares/${share.id}`,
      headers: authHeaders(alice),
      payload: updated,
    });
    expect(afterRevoke.statusCode).toBe(404);
  });

  it("viewer: escaped hostile content, exact headers and the CSP-hashed script", async () => {
    const uid = testUid("share-viewer");
    const app = makeApp();
    const share = (await create(app, uid)).json() as { id: string };
    const page = await app.inject({ method: "GET", url: `/s/${share.id}` });

    expect(page.statusCode).toBe(200);
    expect(page.headers["content-type"]).toContain("text/html");
    expect(page.headers["cache-control"]).toBe(SHARES_HEADERS["Cache-Control"]);
    expect(page.headers["pragma"]).toBe(SHARES_HEADERS["Pragma"]);
    expect(page.headers["x-robots-tag"]).toBe(SHARES_HEADERS["X-Robots-Tag"]);
    expect(page.headers["x-content-type-options"]).toBe(
      SHARES_HEADERS["X-Content-Type-Options"],
    );
    expect(page.headers["referrer-policy"]).toBe(SHARES_HEADERS["Referrer-Policy"]);
    expect(page.headers["content-security-policy"]).toBe(pageCsp());
    expect(page.headers["content-security-policy"]).toContain("script-src 'sha256-");
    expect(page.headers["content-security-policy"]).toContain("default-src 'none'");
    expect(page.headers["content-security-policy"]).toContain("frame-ancestors 'none'");
    // The base SHARES_HEADERS CSP has `sandbox`; the script-bearing PAGE_CSP
    // deliberately does not (Python PAGE_CSP parity).
    expect(SHARES_HEADERS["Content-Security-Policy"]).toContain("sandbox");
    expect(page.headers["content-security-policy"]).not.toContain("sandbox");
    expect(page.headers["etag"]).toBeUndefined();
    expect(page.headers["last-modified"]).toBeUndefined();

    // Exactly one script: the constant, CSP-hashed open-in-app redirect.
    expect(page.body.split("<script>").length - 1).toBe(1);
    expect(page.body).toContain(`<script>${OPEN_APP_SCRIPT}</script>`);
    // Hostile content is inert text.
    expect(page.body).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(page.body).not.toContain("<script>alert(1)");
    expect(page.body).toContain("Open in the Ovid app");
    expect(page.body).toContain(`referrer=share_token%3D${share.id}`);
    expect(page.body).toContain(
      `intent://share.example.test/s/${share.id}#Intent;scheme=https;package=com.dhanuk.ovidai;`,
    );
    expect(page.body).toContain("data-pkg=\"com.dhanuk.ovidai\"");
  });

  it("viewer 404 page is identical for unknown, revoked and expired links", async () => {
    let now = new Date(BASE);
    const uid = testUid("share-viewer-404");
    const app = makeApp({ now: () => now });
    const live = (await create(app, uid)).json() as { id: string };

    const unknown = await app.inject({ method: "GET", url: `/s/${"A".repeat(43)}` });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.headers["cache-control"]).toContain("no-store");
    const notFoundPage = unknown.body;
    expect(notFoundPage).toContain("Link unavailable");
    expect(notFoundPage).not.toContain("Hello");

    await app.inject({ method: "DELETE", url: `/shares/${live.id}`, headers: authHeaders(uid) });
    const revoked = await app.inject({
      method: "GET",
      url: `/s/${live.id}`,
      headers: { "if-none-match": "*", "if-modified-since": "Wed, 01 Jan 2099 00:00:00 GMT" },
    });
    expect(revoked.statusCode).toBe(404);
    expect(revoked.body).toBe(notFoundPage);
    expect(revoked.headers["etag"]).toBeUndefined();

    const expiring = (await create(app, uid, { request_id: "expiring" })).json() as { id: string };
    now = new Date(BASE.getTime() + (TTL_SECONDS + 1) * 1000);
    const expired = await app.inject({ method: "GET", url: `/s/${expiring.id}` });
    expect(expired.statusCode).toBe(404);
    expect(expired.body).toBe(notFoundPage);
    const expiredJson = await app.inject({ method: "GET", url: `/s/${expiring.id}.json` });
    expect(expiredJson.statusCode).toBe(404);
    expect(expiredJson.json()).toEqual({ detail: "share_not_found" });
  });

  it("collab invite landing: 43-char validation, no lookup, app/play fallbacks", async () => {
    const previous = process.env.OVID_ANDROID_PACKAGE_NAME;
    process.env.OVID_ANDROID_PACKAGE_NAME = "com.example.app";
    try {
      const app = makeApp();
      const token = "a".repeat(43);
      const invite = "b".repeat(43);
      const page = await app.inject({ method: "GET", url: `/s/${token}/${invite}` });
      expect(page.statusCode).toBe(200);
      expect(page.body).toContain("Join a live Ovid session");
      expect(page.body).toContain(
        `referrer=share_token%3D${token}%26invite%3D${invite}`,
      );
      expect(page.body).toContain(`intent://share.example.test/s/${token}/${invite}#Intent`);
      expect(page.body).toContain("id=com.example.app");
      expect(page.headers["cache-control"]).toContain("no-store");
      expect(page.headers["x-robots-tag"]).toContain("noindex");

      const short = await app.inject({ method: "GET", url: `/s/${token}/short` });
      expect(short.statusCode).toBe(404);
      // No lookup happened: the unknown token still renders the invite page.
      const unknown = await app.inject({ method: "GET", url: `/s/${"z".repeat(43)}/${invite}` });
      expect(unknown.statusCode).toBe(200);
    } finally {
      if (previous === undefined) delete process.env.OVID_ANDROID_PACKAGE_NAME;
      else process.env.OVID_ANDROID_PACKAGE_NAME = previous;
    }
  });

  it("assetlinks: 503 until configured, uppercased fingerprints, invalid → 503", async () => {
    const previous = process.env.OVID_ANDROID_RELEASE_CERT_SHA256;
    try {
      delete process.env.OVID_ANDROID_RELEASE_CERT_SHA256;
      const unconfigured = makeApp();
      const missing = await unconfigured.inject({
        method: "GET",
        url: "/.well-known/assetlinks.json",
      });
      expect(missing.statusCode).toBe(503);
      expect(missing.json()).toEqual({
        detail: "android_release_fingerprint_not_configured",
      });

      const first = "AB:".repeat(31) + "AB";
      const second = "cd:".repeat(31) + "cd";
      process.env.OVID_ANDROID_RELEASE_CERT_SHA256 = `${first}, ${second}`;
      const configured = makeApp();
      const ok = await configured.inject({ method: "GET", url: "/.well-known/assetlinks.json" });
      expect(ok.statusCode).toBe(200);
      expect(ok.json()).toEqual([
        {
          relation: ["delegate_permission/common.handle_all_urls"],
          target: {
            namespace: "android_app",
            package_name: "com.dhanuk.ovidai",
            sha256_cert_fingerprints: [first, second.toUpperCase()],
          },
        },
      ]);
      expect(ok.headers["cache-control"]).toBe("public, max-age=3600");

      process.env.OVID_ANDROID_RELEASE_CERT_SHA256 = `${first},nope`;
      const invalid = makeApp();
      const bad = await invalid.inject({ method: "GET", url: "/.well-known/assetlinks.json" });
      expect(bad.statusCode).toBe(503);
      expect(bad.json()).toEqual({
        detail: "android_release_fingerprint_not_configured",
      });
    } finally {
      if (previous === undefined) delete process.env.OVID_ANDROID_RELEASE_CERT_SHA256;
      else process.env.OVID_ANDROID_RELEASE_CERT_SHA256 = previous;
    }
  });

  it("raw body is bounded before JSON parse; oversized snapshots never echo content", async () => {
    const uid = testUid("share-limits");
    const app = makeApp();
    const tooBig = await app.inject({
      method: "POST",
      url: "/shares",
      headers: { ...authHeaders(uid), "content-type": "application/json" },
      payload: " ".repeat(1_500_001),
    });
    expect(tooBig.statusCode).toBe(413);
    expect(tooBig.json()).toEqual({ detail: "snapshot_too_large" });

    const tenChunks = Array.from({ length: 10 }, () => ({
      role: "user",
      content: "a".repeat(20_000),
    }));
    const overText = await create(app, uid, {
      messages: [...tenChunks, { role: "user", content: "a" }],
    });
    expect(overText.statusCode).toBe(422);
    expect(overText.json()).toEqual({ detail: "invalid_snapshot" });

    const secret = "sk-abcdefghijklmnop";
    const privateText = await create(app, uid, {
      request_id: "private",
      messages: [{ role: "user", content: secret }],
    });
    expect(privateText.statusCode).toBe(422);
    expect(privateText.json()).toEqual({ detail: "invalid_snapshot" });
    expect(privateText.body).not.toContain(secret);

    const extraField = await create(app, uid, { owner_uid: "bob" });
    expect(extraField.statusCode).toBe(422);
    expect(extraField.body).not.toContain("bob");
  });

  it("fork is idempotent per recipient, rejected after revoke, source unmutated", async () => {
    const alice = testUid("share-fork-alice");
    const bob = testUid("share-fork-bob");
    const app = makeApp();
    const share = (await create(app, alice)).json() as { id: string };

    const first = await app.inject({
      method: "POST",
      url: `/shares/${share.id}/fork`,
      headers: authHeaders(bob),
      payload: { request_id: "fork-1" },
    });
    expect(first.statusCode).toBe(201);
    expect(Object.keys(first.json() as object)).toEqual(["session_id"]);
    expect((first.json() as { session_id: string }).session_id).toMatch(/^[A-Za-z0-9_-]{22}$/);

    const replay = await app.inject({
      method: "POST",
      url: `/shares/${share.id}/fork`,
      headers: authHeaders(bob),
      payload: { request_id: "fork-1" },
    });
    expect(replay.statusCode).toBe(201);
    expect(replay.json()).toEqual(first.json());

    // A request id already bound to a different source is a conflict.
    const otherShare = (await create(app, alice, { request_id: "request-2" })).json() as {
      id: string;
    };
    const otherSource = await app.inject({
      method: "POST",
      url: `/shares/${otherShare.id}/fork`,
      headers: authHeaders(bob),
      payload: { request_id: "fork-1" },
    });
    expect(otherSource.statusCode).toBe(409);

    // Invalid fork bodies are rejected.
    const extra = await app.inject({
      method: "POST",
      url: `/shares/${share.id}/fork`,
      headers: authHeaders(bob),
      payload: { request_id: "fork-2", secret: "x" },
    });
    expect(extra.statusCode).toBe(422);

    // Source snapshot is unchanged by forking.
    const source = await app.inject({ method: "GET", url: `/s/${share.id}.json` });
    expect((source.json() as { messages: unknown[] }).messages).toEqual(MESSAGES);

    await app.inject({ method: "DELETE", url: `/shares/${share.id}`, headers: authHeaders(alice) });
    const revoked = await app.inject({
      method: "POST",
      url: `/shares/${share.id}/fork`,
      headers: authHeaders(bob),
      payload: { request_id: "fork-3" },
    });
    expect(revoked.statusCode).toBe(409);
    expect(revoked.json()).toEqual({ detail: "share_unavailable" });
  });

  it("admission fence blocks every owner operation with the lifecycle error", async () => {
    const uid = testUid("share-fenced");
    let calls = 0;
    const admission: ShareAdmission = async (principal, fn) => {
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

    const createRes = await create(app, uid);
    expect(createRes.statusCode).toBe(403);
    expect(createRes.json()).toEqual({ detail: "account_deletion_pending" });
    const listRes = await app.inject({ method: "GET", url: "/shares", headers: authHeaders(uid) });
    expect(listRes.statusCode).toBe(403);
    expect(calls).toBe(2);
    // No receipt was created.
    const rows = await db.$client`SELECT token FROM shares WHERE owner_uid = ${uid}`;
    expect(rows).toHaveLength(0);
  });

  it("deleteAccount erases content but keeps the receipt; purgeExpired keeps rows", async () => {
    let now = new Date(BASE);
    const uid = testUid("share-cleanup");
    const app = makeApp({ now: () => now });
    const share = (await create(app, uid)).json() as { id: string };

    await sharesRepo.deleteAccount(db, uid, { now });
    expect(await sharesRepo.publicSnapshot(db, share.id, { now })).toBeNull();
    const kept = await db.$client`SELECT token, content FROM shares WHERE token = ${share.id}`;
    expect(kept).toHaveLength(1);
    expect(kept[0]!.content).toBeNull();

    // A different owner: expiry purge clears content, row survives.
    const other = testUid("share-purge");
    const live = (await create(app, other)).json() as { id: string };
    now = new Date(BASE.getTime() + (TTL_SECONDS + 1) * 1000);
    const purged = await sharesRepo.purgeExpired(db, 10_000, { now });
    expect(purged).toBeGreaterThanOrEqual(1);
    const rows = await db.$client`SELECT content FROM shares WHERE owner_uid = ${other}`;
    expect(rows).toHaveLength(1);
    expect(rows[0]!.content).toBeNull();
    expect(await sharesRepo.publicSnapshot(db, live.id, { now })).toBeNull();
  });
});
