import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, newId, schema, sessions, users, workspaceObjects, type Db } from "@ovid/db";
import { createStorage, type StorageAdapter } from "@ovid/storage";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubTickets, stubVerifier, stubSystemBus } from "../test/stubs.js";

type Item = { id: string; origin: string; category: string; name: string; sessionId: string; availability: string };
type Page = { items: Item[]; nextCursor: string | null };

describe.skipIf(!TEST_DATABASE_URL)("account Artifact Vault (real postgres + storage)", () => {
  let db: Db;
  let root: string;
  let storage: StorageAdapter;
  const apps: FastifyInstance[] = [];
  beforeAll(async () => {
    db = await openTestDb();
    root = await mkdtemp(join(tmpdir(), "ovid-vault-"));
    storage = createStorage({ backend: "fs", fsRoot: root });
  }, 60_000);
  afterEach(async () => { while (apps.length) await apps.pop()!.close(); });
  afterAll(async () => { await closeDb(db); await rm(root, { recursive: true, force: true }); });
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
  async function generated(uid: string, sid: string, name: string, id = newId()) {
    const key = `users/${uid}/artifacts/${sid}/${id}-${name}`;
    await storage.put(key, Buffer.from("data"));
    return workspaceObjects.registerArtifact(db, { id, userId: uid, sessionId: sid, r2Key: key, bytes: 4, sha256: "a".repeat(64), contentType: "application/octet-stream", meta: { name } });
  }
  async function uploaded(uid: string, sid: string, name: string, id = newId(), put = true) {
    const key = `users/${uid}/sessions/${sid}/uploads/${id}`;
    if (put) await storage.put(key, Buffer.from("data"));
    return attachments.create(db, { id, userId: uid, sessionId: sid, name, size: 4, r2Key: key });
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
