import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, createDb, migrate, newId, schema, sessions, users, workspaceObjects, type Db } from "@ovid/db";
import { createStorage, type StorageAdapter } from "@ovid/storage";
import { buildGateway } from "../app.js";
import { StorageQuota } from "../storageQuota.js";
import { createMigrationScratch, type MigrationScratch } from "../../../../packages/db/src/migrationTestKit.js";
import { TEST_DATABASE_URL, testUid } from "../test/db.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubTickets, stubVerifier, stubSystemBus } from "../test/stubs.js";

type Item = { id: string; origin: string; category: string; name: string; sessionId: string; availability: string };
type Page = { items: Item[]; nextCursor: string | null };

describe.skipIf(!TEST_DATABASE_URL)("account Artifact Vault (real postgres + storage)", () => {
  let scratch: MigrationScratch;
  let db: Db;
  let root: string;
  let storage: StorageAdapter;
  const apps: FastifyInstance[] = [];
  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_artifact_vault");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 8 });
    root = await mkdtemp(join(tmpdir(), "ovid-vault-"));
    storage = createStorage({ backend: "fs", fsRoot: root });
  }, 180_000);
  afterEach(async () => { while (apps.length) await apps.pop()!.close(); });
  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await scratch?.close();
    if (root !== undefined) await rm(root, { recursive: true, force: true });
  }, 30_000);
  function app(adapter: StorageAdapter = storage) {
    const a = buildGateway({ db, system: stubSystemBus(), queues: stubQueues().queues, verifier: stubVerifier(), tickets: stubTickets(), keys: stubKeys(), mint: stubMint(), events: noopEvents, storage: adapter });
    apps.push(a);
    return a;
  }
  async function fixture() {
    const uid = testUid("vault-owner");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const first = await sessions.create(db, uid, "First chat");
    const second = await sessions.create(db, uid, "Second chat");
    return { uid, first: first.id, second: second.id };
  }
  async function generated(uid: string, sid: string, name: string, id = newId(), contentType = "application/octet-stream") {
    const key = `users/${uid}/artifacts/${sid}/${id}-${name}`;
    await storage.put(key, Buffer.from("data"), { contentType });
    const sha256 = createHash("sha256").update("data").digest("hex");
    return workspaceObjects.registerArtifact(db, { id, userId: uid, sessionId: sid, r2Key: key, bytes: 4, sha256, contentType, meta: { name } });
  }
  async function uploaded(uid: string, sid: string, name: string, id = newId(), put = true, ready = true) {
    const key = `users/${uid}/sessions/${sid}/uploads/${id}`;
    if (put) await storage.put(key, Buffer.from("data"));
    const row = await attachments.create(db, { id, userId: uid, sessionId: sid, name, size: 4, r2Key: key });
    if (ready) {
      const quota = new StorageQuota({ db, storage });
      const reserved = await quota.reserveUpload({
        actorUserId: uid, ownerUserId: uid, sessionId: sid,
        attachmentId: id, declaredBytes: 4,
      });
      if (!reserved.ok) throw new Error("unexpected test quota exhaustion");
      await quota.finalizeUpload({
        reservationId: id, actualBytes: 4, actualContentType: null, etag: null,
      });
      await attachments.finalizeUpload(db, {
        id, sessionId: sid, userId: uid, actualBytes: 4, actualContentType: null,
      });
    }
    return row;
  }
  async function list(a: FastifyInstance, uid: string, query = "") {
    const res = await a.inject({ method: "GET", url: `/cloud/v1/artifacts${query}`, headers: authHeaders(uid) });
    expect(res.statusCode).toBe(200);
    return res.json<Page>();
  }
  it("lists both canonical sources across owned chats, not foreign rows, URLs, keys, or workspace archives; list never HEADs", async () => {
    const { uid, first, second } = await fixture();
    const g = await generated(uid, first, "report.pdf");
    const u = await uploaded(uid, second, "photo.png", newId(), false);
    const foreign = await fixture();
    await generated(foreign.uid, foreign.first, "secret.txt");
    await uploaded(foreign.uid, foreign.first, "private.txt");
    // Deliberately inconsistent ownership must not bypass the session join.
    await generated(uid, foreign.first, "bad-association.txt");
    await db.insert(schema.workspaceObjects).values({ id: newId(), userId: uid, sessionId: first, kind: "workspace_archive", r2Key: `archive/${newId()}`, bytes: 0, sha256: "b".repeat(64) });
    const head = vi.spyOn(storage, "head");
    const page = await list(app(), uid);
    expect(page.items.map(i => i.id)).toEqual([u.id, g.id]);
    expect(page.items.map(i => [i.origin, i.category, i.availability])).toEqual([["uploaded", "image", "unverified"], ["generated", "document", "unverified"]]);
    expect(JSON.stringify(page)).not.toMatch(/r2Key|r2_key|https?:|file:\/\//);
    expect(head).not.toHaveBeenCalled();
    head.mockRestore();
    expect((await list(app(), foreign.uid)).items.map(i => i.name)).toEqual(["private.txt", "secret.txt"]);
  });
  it("filters source, category, literal case-insensitive name search and session in SQL", async () => {
    const { uid, first, second } = await fixture();
    await generated(uid, first, "Report_100%.PDF");
    await generated(uid, first, "report-anything.pdf");
    await uploaded(uid, first, "Report_100%.PDF");
    await generated(uid, second, "Report_100%.PDF");
    const page = await list(app(), uid, `?source=generated&type=document&sessionId=${first}&q=${encodeURIComponent("REPORT_100%")}`);
    expect(page.items.map(i => i.name)).toEqual(["Report_100%.PDF"]);
    expect(page.items[0]!.sessionId).toBe(first);
    expect((await list(app(), uid, "?q=does-not-exist")).items).toEqual([]);
  });
  it("uses a stable compound cursor, even when canonical source tables have the same id", async () => {
    const { uid, first, second } = await fixture();
    const sharedId = newId();
    await generated(uid, first, "same-generated.txt", sharedId);
    await uploaded(uid, second, "same-uploaded.txt", sharedId);
    await generated(uid, first, "newest.txt");
    const a = app();
    const one = await list(a, uid, "?limit=1");
    expect(one.items.map(i => i.name)).toEqual(["newest.txt"]);
    const two = await list(a, uid, `?limit=1&cursor=${one.nextCursor}`);
    expect(two.items.map(i => i.name)).toEqual(["same-uploaded.txt"]);
    const three = await list(a, uid, `?limit=1&cursor=${two.nextCursor}`);
    expect(three.items.map(i => i.name)).toEqual(["same-generated.txt"]);
    expect(three.nextCursor).toBeNull();
  });
  it("retains files in the account Vault after soft chat deletion but not in the legacy session list", async () => {
    const { uid, first } = await fixture();
    await generated(uid, first, "retained.txt");
    await uploaded(uid, first, "retained-upload.txt");
    // Raw soft delete through the db handle's own client (drizzle-orm is not
    // a direct dependency of @ovid/gateway — the repos' soft-delete shape).
    await db.$client`update sessions set deleted_at = now() where id = ${first}`;
    const a = app();
    expect((await list(a, uid)).items).toHaveLength(2);
    expect((await a.inject({ method: "GET", url: `/cloud/v1/sessions/${first}/artifacts`, headers: authHeaders(uid) })).statusCode).toBe(404);
  });
  it("rejects malformed bounded query filters and foreign optional session scope", async () => {
    const { uid } = await fixture();
    const foreign = await fixture();
    const a = app();
    for (const query of ["source=oops", "type=oops", "cursor=not-a-cursor", `q=${"a".repeat(129)}`, "sessionId=garbage"]) {
      expect((await a.inject({ method: "GET", url: `/cloud/v1/artifacts?${query}`, headers: authHeaders(uid) })).statusCode).toBe(400);
    }
    expect((await a.inject({ method: "GET", url: `/cloud/v1/artifacts?sessionId=${foreign.first}`, headers: authHeaders(uid) })).statusCode).toBe(404);
  });
  it("mint is source/owner scoped, private no-store, verifies presence, and mints a fresh URL on every action", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "ok.txt");
    const u = await uploaded(uid, first, "pending.txt", newId(), false);
    const foreign = await fixture();
    const presign = vi.spyOn(storage, "presignGet");
    const a = app();
    const mint = (id: string, source: string, owner = uid) => a.inject({ method: "GET", url: `/cloud/v1/artifacts/${id}/url?source=${source}`, headers: authHeaders(owner) });
    const good = await mint(g.id, "generated");
    expect(good.statusCode).toBe(200);
    expect(good.headers["cache-control"]).toContain("no-store");
    expect(good.json().url).toMatch(/^file:/);
    expect(Date.parse(good.json().expiresAt)).toBeGreaterThan(Date.now());
    await mint(g.id, "generated");
    expect(presign).toHaveBeenCalledTimes(2);
    for (const response of [await mint(g.id, "generated", foreign.uid), await mint(g.id, "uploaded")]) {
      expect(response.statusCode).toBe(404);
      expect(response.json().error.code).toBe("not_found");
    }
    const missing = await mint(u.id, "uploaded");
    expect(missing.statusCode).toBe(404);
    expect(missing.json().error.code).toBe("artifact_unavailable");
    expect(presign).toHaveBeenCalledTimes(2);
    presign.mockRestore();
  });
  it("does not mint incomplete uploaded bytes or mask storage outage as a missing object", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "incomplete.txt");
    await storage.put(u.r2Key, Buffer.from("x"));
    const a = app();
    const incomplete = await a.inject({ method: "GET", url: `/cloud/v1/artifacts/${u.id}/url?source=uploaded`, headers: authHeaders(uid) });
    expect(incomplete.statusCode).toBe(409);
    expect(incomplete.json().error.code).toBe("artifact_incomplete");
    const broken = app({ ...storage, head: async () => { throw new Error("storage unavailable"); } });
    const failed = await broken.inject({ method: "GET", url: `/cloud/v1/artifacts/${u.id}/url?source=uploaded`, headers: authHeaders(uid) });
    expect(failed.statusCode).toBe(503);
    expect(failed.json().error.code).toBe("artifact_storage_unavailable");
  });
  it("never serves active content inline through the canonical Ovid/R2 mint", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "active.html", newId(), "text/html");
    const presign = vi.spyOn(storage, "presignGet");
    const res = await app().inject({
      method: "GET",
      url: `/cloud/v1/artifacts/${g.id}/url?source=generated`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(presign).toHaveBeenCalledWith(g.r2Key, 3600, {
      disposition: "attachment",
      filename: "active.html",
      contentType: "text/html",
    });
  });

  // UNEXECUTED N3: non-active canonical downloads preserve attachment intent.
  it("forces attachment disposition for a non-active canonical download=1", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "report.pdf", newId(), "application/pdf");
    const presign = vi.spyOn(storage, "presignGet");
    const res = await app().inject({
      method: "GET",
      url: `/cloud/v1/artifacts/${g.id}/url?source=generated&download=1`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(presign).toHaveBeenCalledWith(g.r2Key, 3600, {
      disposition: "attachment",
      filename: "report.pdf",
      contentType: "application/pdf",
    });
  });

  // UNEXECUTED round-1 regression for the legacy session mint.
  it("forces actual active content to attachment on the legacy session URL", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "innocent.txt", newId(), "text/html");
    const presign = vi.spyOn(storage, "presignGet");
    const res = await app().inject({
      method: "GET",
      url: `/cloud/v1/sessions/${first}/artifacts/${g.id}/url`,
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    expect(presign).toHaveBeenCalledWith(g.r2Key, 3600, {
      disposition: "attachment",
      filename: "innocent.txt",
      contentType: "text/html",
    });
  });

  it("deletion revokes dependent grants, frees the copy once, and removes bytes only after transition", async () => {
    const { uid, first } = await fixture();
    const g = await generated(uid, first, "shared.txt");
    const quota = new StorageQuota({ db, storage });
    const reserved = await quota.reserveArtifact({
      actorUserId: uid,
      ownerUserId: uid,
      sessionId: first,
      artifactId: g.id,
      declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    await quota.finalizeUpload({
      reservationId: g.id,
      actualBytes: 4,
      actualContentType: "application/octet-stream",
      etag: "source-etag",
    });
    const share = await quota.createImmutableShare({
      actorUserId: uid,
      artifactId: g.id,
      displayName: "shared.txt",
    });
    expect(await quota.assertActive(share.grantId, share.versionHash)).toBe(true);
    expect(await quota.storageUsage(uid)).toEqual({ usedBytes: 8, reservedBytes: 0 });
    const remove = vi.spyOn(storage, "delete");
    const a = app();
    const deleted = await a.inject({
      method: "DELETE",
      url: `/cloud/v1/artifacts/${g.id}?source=generated`,
      headers: authHeaders(uid),
    });
    expect(deleted.statusCode).toBe(200);
    expect(deleted.json()).toMatchObject({ id: g.id, freedBytes: 4 });
    expect(await quota.assertActive(share.grantId, share.versionHash)).toBe(false);
    expect(await quota.storageUsage(uid)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    expect(await storage.head(share.key)).toBeNull();
    expect(await storage.head(g.r2Key)).toBeNull();
    expect(remove).toHaveBeenCalledTimes(2);
    expect((await a.inject({
      method: "DELETE",
      url: `/cloud/v1/artifacts/${g.id}?source=generated`,
      headers: authHeaders(uid),
    })).statusCode).toBe(404);
    // A repeat delete re-runs dependent-grant cleanup (the retry path for
    // orphaned share bytes), but the source artifact bytes are removed once.
    expect(remove.mock.calls.filter(([key]) => key === g.r2Key)).toHaveLength(1);
    expect(await quota.storageUsage(uid)).toEqual({ usedBytes: 0, reservedBytes: 0 });
  });

  it("deleting a pending upload releases its reservation without inventing used bytes", async () => {
    const { uid, first } = await fixture();
    const u = await uploaded(uid, first, "pending-delete.txt", newId(), false, false);
    const quota = new StorageQuota({ db, storage });
    const reserved = await quota.reserveUpload({
      actorUserId: uid,
      ownerUserId: uid,
      sessionId: first,
      attachmentId: u.id,
      declaredBytes: 4,
    });
    if (!reserved.ok) throw new Error("unexpected quota exhaustion");
    const deleted = await app().inject({
      method: "DELETE",
      url: `/cloud/v1/artifacts/${u.id}?source=uploaded`,
      headers: authHeaders(uid),
    });
    expect(deleted.statusCode).toBe(200);
    expect(await quota.storageUsage(uid)).toEqual({ usedBytes: 0, reservedBytes: 0 });
    expect(await db.$client`SELECT state FROM storage_reservations WHERE id = ${u.id}`)
      .toEqual([{ state: "released" }]);
  });

  it("legacy URL route rejects a different owned session, deleted objects and non-artifact kinds", async () => {
    const { uid, first, second } = await fixture();
    const g = await generated(uid, first, "safe.txt");
    const a = app();
    const mint = (sid: string) => a.inject({ method: "GET", url: `/cloud/v1/sessions/${sid}/artifacts/${g.id}/url`, headers: authHeaders(uid) });
    expect((await mint(second)).statusCode).toBe(404);
    await db.$client`update workspace_objects set status = 'deleted' where id = ${g.id}`;
    expect((await mint(first)).statusCode).toBe(404);
    await db.$client`update workspace_objects set status = 'active', kind = 'workspace_archive' where id = ${g.id}`;
    expect((await mint(first)).statusCode).toBe(404);
  });
});
