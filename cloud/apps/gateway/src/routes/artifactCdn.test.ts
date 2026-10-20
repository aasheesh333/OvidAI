import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, newId, sessions, users, workspaceObjects, type Db } from "@ovid/db";
import {
  createStorage,
  decodeOpaqueKey,
  verifyCdnToken,
  type CdnConfig,
  type StorageAdapter,
} from "@ovid/storage";
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

const SECRET = "w12-gateway-test-signing-secret-32-bytes!!";
const T0 = new Date("2023-11-14T22:13:20.000Z");
const TTL = 900;
const CDN: CdnConfig = { baseUrl: "https://cdn.ovidsi.test", secret: SECRET, ttlSeconds: TTL };

interface CdnAnswer {
  url: string;
  expiresAt: string;
  cacheClass: string;
}

describe.skipIf(!TEST_DATABASE_URL)("W12 CDN mint routes (real postgres + fs storage)", () => {
  let db: Db;
  let root: string;
  let storage: StorageAdapter;
  const apps: FastifyInstance[] = [];

  beforeAll(async () => {
    db = await openTestDb();
    root = await mkdtemp(join(tmpdir(), "ovid-cdn-"));
    storage = createStorage({ backend: "fs", fsRoot: root });
  }, 60_000);

  afterEach(async () => {
    while (apps.length > 0) await apps.pop()!.close();
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await closeDb(db);
    await rm(root, { recursive: true, force: true });
  });

  function app(
    overrides: { storage?: StorageAdapter; cdn?: CdnConfig } = {},
  ): FastifyInstance {
    const a = buildGateway({
      db,
      system: stubSystemBus(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      storage: overrides.storage ?? storage,
      cdn: overrides.cdn ?? CDN,
      clock: () => T0,
    });
    apps.push(a);
    return a;
  }

  async function fixture() {
    const uid = testUid("cdn-owner");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const first = await sessions.create(db, uid, "First chat");
    const second = await sessions.create(db, uid, "Second chat");
    return { uid, first: first.id, second: second.id };
  }

  async function generated(
    uid: string,
    sid: string,
    name: string,
    content = "artifact-data",
    id = newId(),
  ) {
    const sha = createHash("sha256").update(content).digest("hex");
    const key = `users/${uid}/artifacts/${sid}/${id}-${sha.slice(0, 16)}-${name}`;
    await storage.put(key, Buffer.from(content), { contentType: "application/octet-stream" });
    const row = await workspaceObjects.registerArtifact(db, {
      id,
      userId: uid,
      sessionId: sid,
      r2Key: key,
      bytes: Buffer.byteLength(content),
      sha256: sha,
      contentType: "application/octet-stream",
      meta: { name },
    });
    return { id, key, row, content };
  }

  async function uploaded(
    uid: string,
    sid: string,
    name: string,
    content = "upload-data",
    id = newId(),
    put = true,
  ) {
    const key = `users/${uid}/sessions/${sid}/uploads/${id}`;
    if (put) await storage.put(key, Buffer.from(content));
    const row = await attachments.create(db, {
      id,
      userId: uid,
      sessionId: sid,
      name,
      size: Buffer.byteLength(content),
      r2Key: key,
    });
    return { id, key, row };
  }

  async function mint(
    a: FastifyInstance,
    uid: string,
    id: string,
    source: string,
    query = "",
  ) {
    return a.inject({
      method: "GET",
      url: `/cloud/v1/artifacts/${id}/cdn-url?source=${source}${query}`,
      headers: authHeaders(uid),
    });
  }

  function claimsFrom(url: string) {
    const u = new URL(url);
    return {
      opaque: u.pathname.slice("/o/".length),
      token: u.searchParams.get("t")!,
      claims: {
        key: decodeOpaqueKey(u.pathname.slice("/o/".length))!,
        expiresAtEpochSeconds: Number(u.searchParams.get("e")),
        disposition: (u.searchParams.get("d") ?? "inline") as "inline" | "attachment",
        filename: u.searchParams.get("fn") ?? undefined,
        contentType: u.searchParams.get("ct") ?? undefined,
        cacheClass: (u.searchParams.get("c") ?? "short") as "immutable" | "short",
      },
    };
  }

  it("mints an immutable signed URL for a generated artifact, with one HEAD", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const head = vi.spyOn(storage, "head");
    const res = await mint(app(), uid, g.id, "generated");
    expect(res.statusCode).toBe(200);
    expect(head).toHaveBeenCalledTimes(1);
    expect(res.headers["cache-control"]).toBe("private, no-store");
    expect(res.headers["pragma"]).toBe("no-cache");

    const body = res.json<CdnAnswer>();
    expect(body.cacheClass).toBe("immutable");
    expect(body.expiresAt).toBe(new Date(T0.getTime() + TTL * 1000).toISOString());
    const { opaque, token, claims } = claimsFrom(body.url);
    expect(body.url.startsWith(`${CDN.baseUrl}/o/`)).toBe(true);
    expect(opaque).not.toContain("/");
    expect(claims.key).toBe(g.key);
    expect(claims.expiresAtEpochSeconds).toBe(Math.floor(T0.getTime() / 1000) + TTL);
    expect(claims.contentType).toBe("application/octet-stream");
    expect(claims.filename).toBe("report.pdf");
    expect(
      verifyCdnToken(token, claims, SECRET, {
        nowSeconds: Math.floor(T0.getTime() / 1000),
        maxTtlSeconds: TTL,
      }),
    ).toBe(true);
  });

  it("mints a short-TTL URL for an uploaded artifact and signs its content type", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "photo.png");
    const res = await mint(app(), uid, u.id, "uploaded");
    expect(res.statusCode).toBe(200);
    const body = res.json<CdnAnswer>();
    expect(body.cacheClass).toBe("short");
    const { claims, token } = claimsFrom(body.url);
    expect(claims.key).toBe(u.key);
    expect(claims.cacheClass).toBe("short");
    expect(claims.contentType).toBe("image/png");
    expect(
      verifyCdnToken(token, claims, SECRET, {
        nowSeconds: Math.floor(T0.getTime() / 1000),
      }),
    ).toBe(true);
  });

  it("signs download disposition and filename when download=1", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "my report.pdf");
    const res = await mint(app(), uid, g.id, "generated", "&download=1");
    const body = res.json<CdnAnswer>();
    const { claims } = claimsFrom(body.url);
    expect(claims.disposition).toBe("attachment");
    expect(claims.filename).toBe("my report.pdf");
  });

  it("is owner/source scoped: foreign owner, wrong source and malformed ids are the same 404", async () => {
    const { uid, first } = await fixture();
    const foreign = await fixture();
    const g = await generated(uid, first, "secret.txt");
    const u = await uploaded(uid, first, "photo.png");
    const a = app();

    expect((await mint(a, foreign.uid, g.id, "generated")).statusCode).toBe(404);
    expect((await mint(a, uid, g.id, "uploaded")).statusCode).toBe(404);
    expect((await mint(a, uid, u.id, "generated")).statusCode).toBe(404);
    expect((await mint(a, uid, "not-a-uuid", "generated")).statusCode).toBe(404);
    expect((await mint(a, uid, newId(), "generated")).statusCode).toBe(404);
    expect((await mint(a, uid, g.id, "bogus")).statusCode).toBe(400);
  });

  it("verifies presence with the canonical typed codes (404 / 409 / 503)", async () => {
    const { uid, first } = await fixture();
    const missing = await generated(uid, first, "gone.txt");
    await storage.delete(missing.key);
    const missingRes = await mint(app(), uid, missing.id, "generated");
    expect(missingRes.statusCode).toBe(404);
    expect(missingRes.json().error.code).toBe("artifact_unavailable");

    // Row says 13 bytes, object has fewer → incomplete upload.
    const short = await generated(uid, first, "short.txt");
    await storage.put(short.key, Buffer.from("x"));
    const shortRes = await mint(app(), uid, short.id, "generated");
    expect(shortRes.statusCode).toBe(409);
    expect(shortRes.json().error.code).toBe("artifact_incomplete");

    const throwing: StorageAdapter = {
      ...storage,
      head: async () => {
        throw new Error("storage down");
      },
    };
    const failed = await mint(app({ storage: throwing }), uid, short.id, "generated");
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error.code).toBe("artifact_storage_unavailable");
  });

  it("answers a typed 503 cdn_not_configured without breaking the canonical mint", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const noCdn = buildGateway({
      db,
      system: stubSystemBus(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      storage,
    });
    apps.push(noCdn);

    const cdnRes = await mint(noCdn, uid, g.id, "generated");
    expect(cdnRes.statusCode).toBe(503);
    expect(cdnRes.json().error.code).toBe("cdn_not_configured");

    // The existing canonical mint still works on the same composition.
    const canonical = await noCdn.inject({
      method: "GET",
      url: `/cloud/v1/artifacts/${g.id}/url?source=generated`,
      headers: authHeaders(uid),
    });
    expect(canonical.statusCode).toBe(200);
    expect(typeof canonical.json().url).toBe("string");
  });

  it("mints an attachment CDN URL only for its owning session", async () => {
    const { uid, first, second } = await fixture();
    const foreign = await fixture();
    const u = await uploaded(uid, first, "photo.png");
    const a = app();

    const ok = await a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${u.id}/cdn-url`,
      headers: authHeaders(uid),
    });
    expect(ok.statusCode).toBe(200);
    const body = ok.json<CdnAnswer>();
    expect(body.cacheClass).toBe("short");
    expect(claimsFrom(body.url).claims.key).toBe(u.key);
    expect(claimsFrom(body.url).claims.contentType).toBe("image/png");

    const wrongSession = await a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${second}/attachments/${u.id}/cdn-url`,
      headers: authHeaders(uid),
    });
    expect(wrongSession.statusCode).toBe(404);

    const foreignOwner = await a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${u.id}/cdn-url`,
      headers: authHeaders(foreign.uid),
    });
    expect(foreignOwner.statusCode).toBe(404);

    const unknown = await a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${newId()}/cdn-url`,
      headers: authHeaders(uid),
    });
    expect(unknown.statusCode).toBe(404);
  });

  it("applies the same missing/size checks to attachments", async () => {
    const { uid, first } = await fixture();
    const missing = await uploaded(uid, first, "gone.png", "x", newId(), false);
    const res = await app().inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${missing.id}/cdn-url`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("artifact_unavailable");

    const short = await uploaded(uid, first, "short.png", "0123456789");
    await storage.put(short.key, Buffer.from("x"));
    const shortRes = await app().inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${short.id}/cdn-url`,
      headers: authHeaders(uid),
    });
    expect(shortRes.statusCode).toBe(409);
    expect(shortRes.json().error.code).toBe("artifact_incomplete");
  });

  it("never emits a CDN URL when storage itself is not configured", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const noStorage = buildGateway({
      db,
      system: stubSystemBus(),
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      cdn: CDN,
    });
    apps.push(noStorage);
    const res = await mint(noStorage, uid, g.id, "generated");
    expect(res.statusCode).toBe(503);
    expect(res.json().error.code).toBe("storage_not_configured");
  });
});
