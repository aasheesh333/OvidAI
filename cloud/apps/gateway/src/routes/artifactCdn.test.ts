import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { signInternalRequest } from "@ovid/shared";
import { attachments, createDb, migrate, newId, sessions, users, workspaceObjects, type Db } from "@ovid/db";
import {
  createStorage,
  decodeOpaqueKey,
  verifyCdnToken,
  type CdnConfig,
  type StorageAdapter,
} from "@ovid/storage";
import { buildGateway } from "../app.js";
import { createMigrationScratch, type MigrationScratch } from "../../../../packages/db/src/migrationTestKit.js";
import { TEST_DATABASE_URL, testUid } from "../test/db.js";
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
import { CDN_GRANT_ASSERT_PATH, CDN_GRANT_CREATE_PATH } from "./artifactCdn.js";
import { StorageQuota } from "../storageQuota.js";

const SECRET = "w12-gateway-test-signing-secret-32-bytes!!";
const GRANT_SECRET = "gateway-cdn-grant-internal-secret-32-bytes";
const T0 = new Date("2023-11-14T22:13:20.000Z");
const TTL = 900;
const CDN: CdnConfig = {
  baseUrl: "https://cdn.ovidsi.test",
  secret: SECRET,
  ttlSeconds: TTL,
  grantInternalSecret: GRANT_SECRET,
};

interface CdnAnswer {
  url: string;
  expiresAt: string;
  cacheClass: string;
  grantId?: string;
  versionHash?: string;
  disposition?: string;
  contentType?: string;
}

describe.skipIf(!TEST_DATABASE_URL)("revocable CDN mint and internal grant routes (isolated Postgres + fs)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let root: string;
  let storage: StorageAdapter;
  const apps: FastifyInstance[] = [];

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_artifact_cdn");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
    root = await mkdtemp(join(tmpdir(), "ovid-cdn-"));
    storage = createStorage({ backend: "fs", fsRoot: root });
  }, 180_000);

  afterEach(async () => {
    while (apps.length > 0) await apps.pop()!.close();
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
    if (root !== undefined) await rm(root, { recursive: true, force: true });
  }, 30_000);

  function app(overrides: { storage?: StorageAdapter; cdn?: CdnConfig } = {}): FastifyInstance {
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
    contentType = "application/octet-stream",
  ) {
    const sha = createHash("sha256").update(content).digest("hex");
    const key = `users/${uid}/artifacts/${sid}/${id}-${sha.slice(0, 16)}-${name}`;
    await storage.put(key, Buffer.from(content), { contentType, sha256Hex: sha });
    const row = await workspaceObjects.registerArtifact(db, {
      id,
      userId: uid,
      sessionId: sid,
      r2Key: key,
      bytes: Buffer.byteLength(content),
      sha256: sha,
      contentType,
      meta: { name },
    });
    return { id, key, row, content, sha };
  }

  async function uploaded(
    uid: string,
    sid: string,
    name: string,
    content = "upload-data",
    id = newId(),
    put = true,
    ready = true,
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
    if (ready) {
      const quota = new StorageQuota({ db, storage });
      const reserved = await quota.reserveUpload({
        actorUserId: uid,
        ownerUserId: uid,
        sessionId: sid,
        attachmentId: id,
        declaredBytes: Buffer.byteLength(content),
      });
      if (!reserved.ok) throw new Error("unexpected test quota exhaustion");
      await quota.finalizeUpload({
        reservationId: id,
        actualBytes: Buffer.byteLength(content),
        actualContentType: null,
        etag: null,
      });
      await attachments.finalizeUpload(db, {
        id,
        sessionId: sid,
        userId: uid,
        actualBytes: Buffer.byteLength(content),
        actualContentType: null,
      });
    }
    return { id, key, row };
  }

  async function mint(a: FastifyInstance, uid: string, id: string, source: string, query = "") {
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
        grantId: u.searchParams.get("g") ?? undefined,
        versionHash: u.searchParams.get("v") ?? undefined,
      },
    };
  }

  it("mints an immutable v2 grant for a frozen generated-artifact copy, with one source HEAD", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const head = vi.spyOn(storage, "head");
    const res = await mint(app(), uid, g.id, "generated");
    expect(res.statusCode).toBe(200);
    expect(head.mock.calls.filter(([key]) => key === g.key)).toHaveLength(1);
    expect(res.headers["cache-control"]).toBe("private, no-store");

    const body = res.json<CdnAnswer>();
    expect(body.cacheClass).toBe("immutable");
    expect(body.grantId).toMatch(/^[0-9a-f-]{36}$/);
    expect(body.versionHash).toBe(g.sha);
    expect(body.expiresAt).toBe(new Date(T0.getTime() + TTL * 1000).toISOString());
    const { opaque, token, claims } = claimsFrom(body.url);
    expect(body.url.startsWith(`${CDN.baseUrl}/o/`)).toBe(true);
    expect(opaque).not.toContain("/");
    expect(claims.key).toContain(`/artifact-shares/${g.id}/sha256-${g.sha}/`);
    expect(claims.key).not.toBe(g.key);
    expect(claims.contentType).toBe("application/octet-stream");
    expect(claims.filename).toBe("report.pdf");
    expect(claims.grantId).toBe(body.grantId);
    expect(claims.versionHash).toBe(g.sha);
    expect(verifyCdnToken(token, claims, SECRET, {
      nowSeconds: Math.floor(T0.getTime() / 1000),
      maxTtlSeconds: TTL,
    })).toBe(true);
    expect(await storage.getBuffer(claims.key)).toEqual(Buffer.from(g.content));
  });

  it("keeps mutable uploaded artifacts on short presigned URLs with no grant/cache upgrade", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "photo.png");
    const res = await mint(app(), uid, u.id, "uploaded");
    expect(res.statusCode).toBe(200);
    const body = res.json<CdnAnswer>();
    expect(body.cacheClass).toBe("short");
    expect(body.url).toMatch(/^file:/);
    expect(body.grantId).toBeUndefined();
    expect(body.versionHash).toBeUndefined();
    expect(body.contentType).toBe("image/png");
  });

  it.each(["text/html", "image/svg+xml", "application/xml", "text/xml"])(
    "forces active %s shares to attachment-only",
    async (contentType) => {
      const { uid, first } = await fixture();
      const g = await generated(uid, first, "active.html", `<root>${contentType}</root>`, newId(), contentType);
      const res = await mint(app(), uid, g.id, "generated");
      expect(res.statusCode).toBe(200);
      const body = res.json<CdnAnswer>();
      expect(body.disposition).toBe("attachment");
      expect(body.contentType).toBe(contentType);
      expect(claimsFrom(body.url).claims.disposition).toBe("attachment");
    },
  );

  it("forces active mutable downloads to attachment on the short R2 URL", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "active.svg");
    const presign = vi.spyOn(storage, "presignGet");
    const res = await mint(app(), uid, u.id, "uploaded");
    expect(res.statusCode).toBe(200);
    expect(res.json<CdnAnswer>().disposition).toBe("attachment");
    expect(presign).toHaveBeenCalledWith(u.key, 3600, {
      disposition: "attachment",
      filename: "active.svg",
      contentType: "image/svg+xml",
    });
  });

  // UNEXECUTED round-1 regressions for response metadata and HEAD-vs-name.
  it("reports the same attachment disposition in the body and signed claims for download=1", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const res = await mint(app(), uid, g.id, "generated", "&download=1");
    expect(res.statusCode).toBe(200);
    const body = res.json<CdnAnswer>();
    expect(body.disposition).toBe("attachment");
    expect(claimsFrom(body.url).claims.disposition).toBe("attachment");
  });

  it("uses actual active HEAD type, not an innocuous filename, for mutable short URLs", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "innocent.txt");
    await storage.put(u.key, Buffer.from("upload-data"), { contentType: "text/html" });
    const presign = vi.spyOn(storage, "presignGet");
    const res = await mint(app(), uid, u.id, "uploaded");
    expect(res.statusCode).toBe(200);
    expect(res.json<CdnAnswer>().disposition).toBe("attachment");
    expect(presign).toHaveBeenCalledWith(u.key, 3600, {
      disposition: "attachment",
      filename: "innocent.txt",
      contentType: "text/html",
    });
  });

  it("is owner/source scoped and never emits a foreign grant", async () => {
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

  it("verifies presence with canonical typed codes (404 / 409 / 503)", async () => {
    const { uid, first } = await fixture();
    const missing = await generated(uid, first, "gone.txt");
    await storage.delete(missing.key);
    const missingRes = await mint(app(), uid, missing.id, "generated");
    expect(missingRes.statusCode).toBe(404);
    expect(missingRes.json().error.code).toBe("artifact_unavailable");

    const short = await generated(uid, first, "short.txt");
    await storage.put(short.key, Buffer.from("x"));
    const shortRes = await mint(app(), uid, short.id, "generated");
    expect(shortRes.statusCode).toBe(409);
    expect(shortRes.json().error.code).toBe("artifact_incomplete");

    const throwing: StorageAdapter = {
      ...storage,
      head: async () => { throw new Error("storage down"); },
    };
    const failed = await mint(app({ storage: throwing }), uid, short.id, "generated");
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error.code).toBe("artifact_storage_unavailable");
  });

  it("fails over to the canonical short mint when CDN or grant service is absent", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    for (const cdn of [undefined, { ...CDN, grantInternalSecret: undefined }]) {
      const noService = buildGateway({
        db,
        system: stubSystemBus(),
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
        storage,
        ...(cdn === undefined ? {} : { cdn }),
      });
      apps.push(noService);
      const cdnRes = await mint(noService, uid, g.id, "generated");
      expect(cdnRes.statusCode).toBe(503);
      expect(cdnRes.json().error.code).toBe(cdn === undefined ? "cdn_not_configured" : "cdn_grant_not_configured");
      const canonical = await noService.inject({
        method: "GET",
        url: `/cloud/v1/artifacts/${g.id}/url?source=generated`,
        headers: authHeaders(uid),
      });
      expect(canonical.statusCode).toBe(200);
      expect(canonical.json().url).toMatch(/^file:/);
    }
  });

  it("mints short attachment URLs only for the owning session", async () => {
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
    expect(ok.json<CdnAnswer>().url).toMatch(/^file:/);
    expect(ok.json<CdnAnswer>().cacheClass).toBe("short");
    for (const url of [
      `/cloud/v1/sessions/${second}/attachments/${u.id}/cdn-url`,
      `/cloud/v1/sessions/${first}/attachments/${newId()}/cdn-url`,
    ]) {
      expect((await a.inject({ method: "GET", url, headers: authHeaders(uid) })).statusCode).toBe(404);
    }
    expect((await a.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/attachments/${u.id}/cdn-url`,
      headers: authHeaders(foreign.uid),
    })).statusCode).toBe(404);
  });

  it("checks signed internal grants and synchronously revokes the old URL's grant", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "revocable.txt");
    const gateway = app();
    const minted = (await mint(gateway, uid, g.id, "generated")).json<CdnAnswer>();
    // UNEXECUTED root-composition regression: the production buildGateway,
    // not a test-only Fastify fixture, must expose the signed service route
    // outside Firebase auth. A grantless public v2 route is not a substitute.
    const timestamp = Math.floor(T0.getTime() / 1000);
    // UNEXECUTED round-1 root grant-create composition regression.
    const created = await gateway.inject({
      method: "POST",
      url: CDN_GRANT_CREATE_PATH,
      headers: {
        "content-type": "application/json",
        "X-Ovid-Timestamp": Buffer.from(String(timestamp)).toString("base64"),
        "X-Ovid-Signature": signInternalRequest(
          GRANT_SECRET,
          "POST",
          CDN_GRANT_CREATE_PATH,
          `${uid}:${g.id}`,
          timestamp,
        ),
      },
      payload: { actorUserId: uid, artifactId: g.id, displayName: "worker.txt" },
    });
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject({
      versionHash: g.sha,
      cacheClass: "immutable",
      contentType: "application/octet-stream",
    });
    expect(created.json().key).toContain(`/artifact-shares/${g.id}/sha256-${g.sha}/`);

    const check = (versionHash = g.sha, secret = GRANT_SECRET) => gateway.inject({
      method: "POST",
      url: CDN_GRANT_ASSERT_PATH,
      headers: {
        "content-type": "application/json",
        "X-Ovid-Timestamp": Buffer.from(String(timestamp)).toString("base64"),
        "X-Ovid-Signature": signInternalRequest(
          secret,
          "POST",
          CDN_GRANT_ASSERT_PATH,
          `${minted.grantId!}:${versionHash}`,
          timestamp,
        ),
      },
      payload: { grantId: minted.grantId, versionHash },
    });
    expect((await check()).statusCode).toBe(200);
    expect((await check()).json()).toEqual({ active: true });
    expect((await check("0".repeat(64))).json()).toEqual({ active: false });
    expect((await check(g.sha, "wrong-secret")).statusCode).toBe(403);

    const revoked = await gateway.inject({
      method: "DELETE",
      url: `/cloud/v1/artifact-shares/${minted.grantId}`,
      headers: authHeaders(uid),
    });
    expect(revoked.statusCode).toBe(200);
    expect((await check()).json()).toEqual({ active: false });
  });
});
