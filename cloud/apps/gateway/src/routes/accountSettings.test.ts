import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { accountSettings, byokKeysRepo, sessionState, users, type Db } from "@ovid/db";
import type { UiManifest } from "@ovid/shared";
import { buildGateway, type GatewayDeps } from "../app.js";
import type { WorkerClient, WorkerResult } from "../workerClient.js";
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

// Wave 4 — /settings, /presets, /sessions/:id/preset and /memory against
// real Postgres; the worker file service is an in-memory fake.

function fakeWorker(): WorkerClient & { files: Map<string, string> } {
  const files = new Map<string, string>();
  const ok = <T>(value: T): WorkerResult<T> => ({ ok: true, value }) as WorkerResult<T>;
  const fail = <T>(status: number, code: string): WorkerResult<T> =>
    ({ ok: false, status, error: { error: { code, message: code } } }) as WorkerResult<T>;
  const sha = async (s: string) =>
    (await import("node:crypto")).createHash("sha256").update(s, "utf8").digest("hex");
  return {
    files,
    async getTree(_u, _s, sub) {
      const prefix = `${sub}/`;
      const names = [...files.keys()].filter((k) => k.startsWith(prefix));
      if (names.length === 0) return fail(404, "not_found");
      const tree: UiManifest = {
        version: 1,
        generatedAt: new Date().toISOString(),
        truncated: false,
        totals: { files: names.length, dirs: 0, bytes: 0 },
        roots: names.map((p) => ({
          name: p.slice(prefix.length),
          path: p,
          type: "file" as const,
          sizeBytes: files.get(p)!.length,
        })),
      };
      return ok({ tree });
    },
    async getFile(_u, _s, path) {
      const c = files.get(path);
      if (c === undefined) return fail(404, "not_found");
      return ok({
        kind: "content" as const,
        path,
        sizeBytes: c.length,
        sha256Hex: await sha(c),
        contentType: "text/markdown",
        contentBase64: Buffer.from(c, "utf8").toString("base64"),
      });
    },
    async putFile(_u, _s, path, b64, pre) {
      const content = Buffer.from(b64, "base64").toString("utf8");
      const current = files.get(path);
      if (pre?.ifMatchSha256 !== undefined && (current === undefined || (await sha(current)) !== pre.ifMatchSha256)) {
        return fail(409, "baseline_mismatch");
      }
      files.set(path, content);
      return ok({ path, sizeBytes: content.length, sha256: await sha(content) });
    },
    async deleteFile(_u, _s, path) {
      if (!files.delete(path)) return fail(404, "not_found");
      return ok({ path, type: "file" as const });
    },
    async movePath() {
      return fail(400, "bad_request");
    },
    async makeDir() {
      return fail(400, "bad_request");
    },
  };
}

describe.skipIf(!TEST_DATABASE_URL)("Wave 4 account settings routes (real postgres)", () => {
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
      ...extra,
    });
    built.push(app);
    return app;
  }

  async function seedKey(uid: string): Promise<string> {
    await users.ensure(db, uid, null);
    const row = await byokKeysRepo.create(db, {
      userId: uid,
      providerId: "openai",
      endpoint: "https://api.openai.com/v1",
      label: null,
      wrappedDek: Buffer.from("d"),
      iv: Buffer.from("i"),
      ciphertext: Buffer.from("c"),
      tag: Buffer.from("t"),
      status: "untested",
    } as Parameters<typeof byokKeysRepo.create>[1]);
    return row.id;
  }

  async function createSession(app: FastifyInstance, uid: string): Promise<string> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: {},
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  // -- /settings ---------------------------------------------------------------

  it("GET /settings answers defaults; PATCH turns push off", async () => {
    const app = makeApp();
    const uid = testUid("w4set");
    const get = await app.inject({ method: "GET", url: "/cloud/v1/settings", headers: authHeaders(uid) });
    expect(get.statusCode).toBe(200);
    expect(get.json()).toEqual({ notificationsEnabled: true, byokDefault: null });
    const patch = await app.inject({
      method: "PATCH",
      url: "/cloud/v1/settings",
      headers: authHeaders(uid),
      payload: { notificationsEnabled: false },
    });
    expect(patch.statusCode).toBe(200);
    expect(patch.json().notificationsEnabled).toBe(false);
    expect((await accountSettings.get(db, uid)).notificationsEnabled).toBe(false);
  });

  it("byokDefault must be one of the caller's own keys", async () => {
    const app = makeApp();
    const owner = testUid("w4own");
    const other = testUid("w4oth");
    const keyId = await seedKey(owner);
    const stolen = await app.inject({
      method: "PATCH",
      url: "/cloud/v1/settings",
      headers: authHeaders(other),
      payload: { byokDefault: { keyId, model: "gpt-4.1" } },
    });
    expect(stolen.statusCode).toBe(404);
    const mine = await app.inject({
      method: "PATCH",
      url: "/cloud/v1/settings",
      headers: authHeaders(owner),
      payload: { byokDefault: { keyId, model: "gpt-4.1" } },
    });
    expect(mine.statusCode).toBe(200);
    expect(mine.json().byokDefault).toEqual({ keyId, model: "gpt-4.1" });
  });

  it("deleting the key clears the BYOK default (runs fall back to Ovid models)", async () => {
    const app = makeApp();
    const uid = testUid("w4del");
    const keyId = await seedKey(uid);
    await accountSettings.patch(db, uid, { byokDefault: { keyId, model: "gpt-4.1" } });
    const del = await app.inject({ method: "DELETE", url: `/cloud/v1/byok/${keyId}`, headers: authHeaders(uid) });
    expect(del.statusCode).toBe(204);
    expect((await accountSettings.get(db, uid)).byokDefault).toBeNull();
  });

  it("rejects a malformed patch", async () => {
    const app = makeApp();
    const res = await app.inject({
      method: "PATCH",
      url: "/cloud/v1/settings",
      headers: authHeaders(testUid("w4bad")),
      payload: { notificationsEnabled: "off" },
    });
    expect(res.statusCode).toBe(400);
  });

  // -- /presets ----------------------------------------------------------------

  it("custom presets: create, list with tool groups, apply to a chat, delete", async () => {
    const app = makeApp({ modelCatalog: async () => ["auto", "glm-5.3"] });
    const uid = testUid("w4pre");
    const put = await app.inject({
      method: "PUT",
      url: "/cloud/v1/presets/custom-no-shell",
      headers: authHeaders(uid),
      payload: { label: "No shell", deniedTools: ["run_shell", "run_code"], temperature: 0.3, model: "glm-5.3" },
    });
    expect(put.statusCode).toBe(200);
    expect(put.json()).toMatchObject({ id: "custom-no-shell", deniedTools: ["run_shell", "run_code"] });

    const list = await app.inject({ method: "GET", url: "/cloud/v1/presets", headers: authHeaders(uid) });
    expect(list.json().builtIn).toContain("standard");
    expect(list.json().custom.map((p: { id: string }) => p.id)).toEqual(["custom-no-shell"]);
    expect(list.json().toolGroups.find((g: { id: string }) => g.id === "shell").tools).toContain("run_shell");

    const sid = await createSession(app, uid);
    const apply = await app.inject({
      method: "PUT",
      url: `/cloud/v1/sessions/${sid}/preset`,
      headers: authHeaders(uid),
      payload: { presetId: "custom-no-shell" },
    });
    expect(apply.statusCode).toBe(200);
    expect((await sessionState.get(db, sid)).presetId).toBe("custom-no-shell");

    const del = await app.inject({
      method: "DELETE",
      url: "/cloud/v1/presets/custom-no-shell",
      headers: authHeaders(uid),
    });
    expect(del.statusCode).toBe(204);
  });

  it("presets: unknown model, unknown tool, bad id and someone else's preset are refused", async () => {
    const app = makeApp({ modelCatalog: async () => ["auto"] });
    const uid = testUid("w4prx");
    const badModel = await app.inject({
      method: "PUT",
      url: "/cloud/v1/presets/custom-a",
      headers: authHeaders(uid),
      payload: { label: "A", model: "nope-model" },
    });
    expect(badModel.statusCode).toBe(400);
    expect(badModel.json().error.code).toBe("model_unavailable");
    const badTool = await app.inject({
      method: "PUT",
      url: "/cloud/v1/presets/custom-a",
      headers: authHeaders(uid),
      payload: { label: "A", deniedTools: ["format_disk"] },
    });
    expect(badTool.statusCode).toBe(400);
    const badId = await app.inject({
      method: "PUT",
      url: "/cloud/v1/presets/standard",
      headers: authHeaders(uid),
      payload: { label: "A" },
    });
    expect(badId.statusCode).toBe(400);

    const owner = testUid("w4pro");
    await app.inject({
      method: "PUT",
      url: "/cloud/v1/presets/custom-mine",
      headers: authHeaders(owner),
      payload: { label: "Mine" },
    });
    const sid = await createSession(app, uid);
    const apply = await app.inject({
      method: "PUT",
      url: `/cloud/v1/sessions/${sid}/preset`,
      headers: authHeaders(uid),
      payload: { presetId: "custom-mine" },
    });
    expect(apply.statusCode).toBe(404);
  });

  // -- /memory -----------------------------------------------------------------

  it("memory: no chat yet → empty list and a write asks to start a chat", async () => {
    const app = makeApp({ worker: fakeWorker() });
    const uid = testUid("w4mem0");
    const list = await app.inject({ method: "GET", url: "/cloud/v1/memory", headers: authHeaders(uid) });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toEqual({ items: [] });
    const put = await app.inject({
      method: "PUT",
      url: "/cloud/v1/memory/MEMORY.md",
      headers: authHeaders(uid),
      payload: { content: "x" },
    });
    expect(put.statusCode).toBe(409);
    expect(put.json().error.code).toBe("no_workspace");
  });

  it("memory: list, read, edit with revision, conflict, delete", async () => {
    const worker = fakeWorker();
    const app = makeApp({ worker });
    const uid = testUid("w4mem");
    await createSession(app, uid);
    worker.files.set(".ovid/memory/MEMORY.md", "# Me\n- dog: Bruno\n");
    worker.files.set(".ovid/memory/work.md", "work notes");

    const list = await app.inject({ method: "GET", url: "/cloud/v1/memory", headers: authHeaders(uid) });
    expect(list.json().items.map((i: { name: string }) => i.name)).toEqual(["MEMORY.md", "work.md"]);

    const read = await app.inject({ method: "GET", url: "/cloud/v1/memory/MEMORY.md", headers: authHeaders(uid) });
    expect(read.statusCode).toBe(200);
    expect(read.json().content).toContain("Bruno");
    const revision = read.json().revision as string;

    const edit = await app.inject({
      method: "PUT",
      url: "/cloud/v1/memory/MEMORY.md",
      headers: authHeaders(uid),
      payload: { content: "# Me\n", ifRevision: revision },
    });
    expect(edit.statusCode).toBe(200);
    expect(worker.files.get(".ovid/memory/MEMORY.md")).toBe("# Me\n");

    const stale = await app.inject({
      method: "PUT",
      url: "/cloud/v1/memory/MEMORY.md",
      headers: authHeaders(uid),
      payload: { content: "again", ifRevision: revision },
    });
    expect(stale.statusCode).toBe(409);

    const del = await app.inject({ method: "DELETE", url: "/cloud/v1/memory/work.md", headers: authHeaders(uid) });
    expect(del.statusCode).toBe(204);
    expect(worker.files.has(".ovid/memory/work.md")).toBe(false);
  });

  it("memory: path-like or non-markdown names are refused before the worker", async () => {
    const app = makeApp({ worker: fakeWorker() });
    const uid = testUid("w4memx");
    for (const name of ["..%2Fsecrets.md", "notes.txt", "memory.md", ".hidden.md"]) {
      const res = await app.inject({ method: "GET", url: `/cloud/v1/memory/${name}`, headers: authHeaders(uid) });
      expect(res.statusCode).toBe(400);
    }
  });
});
