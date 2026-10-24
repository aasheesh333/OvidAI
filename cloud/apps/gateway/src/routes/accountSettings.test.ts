import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { accountSettings, byokKeysRepo, sessionState, users, userPreferences, type Db } from "@ovid/db";
import { buildGateway, type GatewayDeps } from "../app.js";
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
// real Postgres. R1: the /memory API rides the private_memory_files store
// (migration 0019) directly — no worker file service, no workspace paths,
// no legacy .ovid/memory access.

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
      wrappedDek: Buffer.from("d").toString("base64"),
      iv: Buffer.from("i").toString("base64"),
      ciphertext: Buffer.from("c").toString("base64"),
      tag: Buffer.from("t").toString("base64"),
    });
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
    expect(get.json()).toEqual({
      notificationsEnabled: true,
      notificationPreferences: {
        agentUpdates: { enabled: true, sound: "chime" },
        schedulerResults: { enabled: true, sound: "chime" },
        backgroundStatus: { enabled: true, sound: "silent" },
        quietHours: {
          enabled: false,
          startMinutes: 22 * 60,
          endMinutes: 8 * 60,
          utcOffsetMinutes: 0,
        },
      },
      byokDefault: null,
    });
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
    const app = makeApp();
    const uid = testUid("w4mem0");
    const list = await app.inject({ method: "GET", url: "/cloud/v1/memory", headers: authHeaders(uid) });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toMatchObject({ items: [], requiresSession: true });
    const put = await app.inject({
      method: "PUT",
      url: "/cloud/v1/memory/MEMORY.md",
      headers: authHeaders(uid),
      payload: { content: "x" },
    });
    expect(put.statusCode).toBe(409);
    expect(put.json().error.code).toBe("no_workspace");
  });

  it("memory: list, read, edit with revision, conflict, delete — private DB store only", async () => {
    const app = makeApp();
    const uid = testUid("w4mem");
    const sid = await createSession(app, uid);
    const memoryUrl = `/cloud/v1/memory?sessionId=${sid}`;
    const fileUrl = (name: string) => `/cloud/v1/memory/${name}?sessionId=${sid}`;
    const put = (name: string, content: string, ifRevision?: string) =>
      app.inject({ method: "PUT", url: fileUrl(name), headers: authHeaders(uid), payload: { content, ifRevision } });

    // Facts arrive through the private store, never through workspace files.
    expect((await put("MEMORY.md", "# Me\n- dog: Bruno\n")).statusCode).toBe(200);
    expect((await put("work.md", "work notes")).statusCode).toBe(200);

    const list = await app.inject({ method: "GET", url: memoryUrl, headers: authHeaders(uid) });
    expect(list.json().scope).toBe("chat");
    expect(list.json().items.map((i: { name: string }) => i.name)).toEqual(["MEMORY.md", "work.md"]);

    const read = await app.inject({ method: "GET", url: fileUrl("MEMORY.md"), headers: authHeaders(uid) });
    expect(read.statusCode).toBe(200);
    expect(read.json().content).toContain("Bruno");
    const revision = read.json().revision as string;

    const edit = await app.inject({
      method: "PUT",
      url: fileUrl("MEMORY.md"),
      headers: authHeaders(uid),
      payload: { content: "# Me\n", ifRevision: revision },
    });
    expect(edit.statusCode).toBe(200);

    const stale = await app.inject({
      method: "PUT",
      url: fileUrl("MEMORY.md"),
      headers: authHeaders(uid),
      payload: { content: "again", ifRevision: revision },
    });
    expect(stale.statusCode).toBe(409);

    const del = await app.inject({ method: "DELETE", url: fileUrl("work.md"), headers: authHeaders(uid) });
    expect(del.statusCode).toBe(204);
    expect((await app.inject({ method: "GET", url: fileUrl("work.md"), headers: authHeaders(uid) })).statusCode).toBe(404);
  });

  it("memory API never chooses a recent/global chat implicitly, checks ownership, and sharing only opens the shared scope", async () => {
    const app = makeApp();
    const uid = testUid("w4iso");
    const other = testUid("w4iso-other");
    const a = await createSession(app, uid);
    const b = await createSession(app, uid);
    const foreign = await createSession(app, other);
    await app.inject({
      method: "PUT",
      url: `/cloud/v1/memory/MEMORY.md?sessionId=${a}`,
      headers: authHeaders(uid),
      payload: { content: "A secret fact" },
    });
    const get = (sid?: string) => app.inject({ method: "GET", url: `/cloud/v1/memory/MEMORY.md${sid === undefined ? '' : `?sessionId=${sid}`}`, headers: authHeaders(uid) });
    expect((await get(a)).json().content).toBe("A secret fact");
    expect((await get(b)).statusCode).toBe(404);
    expect((await get()).statusCode).toBe(409);
    expect((await get(foreign)).statusCode).toBe(404);
    expect((await get("not-a-uuid")).statusCode).toBe(404);
    // Sharing ON opens the SHARED scope; it never imports A's isolated fact.
    await userPreferences.patch(db, uid, { shareSessionMemory: true });
    expect((await get(b)).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/cloud/v1/memory?sessionId=${b}`, headers: authHeaders(uid) })).json().scope).toBe("shared");
    await app.inject({
      method: "PUT",
      url: `/cloud/v1/memory/MEMORY.md?sessionId=${b}`,
      headers: authHeaders(uid),
      payload: { content: "explicitly shared fact" },
    });
    expect((await get(a)).json().content).toBe("explicitly shared fact");
    expect((await get(foreign)).statusCode).toBe(404);
    // Sharing OFF again re-isolates: B loses the shared scope, A keeps its own fact.
    await userPreferences.patch(db, uid, { shareSessionMemory: false });
    expect((await get(b)).statusCode).toBe(404);
    expect((await get(a)).json().content).toBe("A secret fact");
  });

  it("memory: path-like or non-markdown names are refused before the store", async () => {
    const app = makeApp();
    const uid = testUid("w4memx");
    for (const name of ["..%2Fsecrets.md", "notes.txt", "memory.md", ".hidden.md"]) {
      const res = await app.inject({ method: "GET", url: `/cloud/v1/memory/${name}`, headers: authHeaders(uid) });
      expect(res.statusCode).toBe(400);
    }
  });
});
