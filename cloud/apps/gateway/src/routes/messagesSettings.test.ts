// Wave 1a (CT-001 / CH-001 / CH-007 / CH-008 / CH-010 / R1): the per-turn
// settings on POST /sessions/:id/messages, the session PATCH mode → agent
// state sync, and GET/PATCH /preferences.

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { sessionState, userPreferences, users, type Db } from "@ovid/db";
import { planFor } from "@ovid/shared";
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
  type MintStub,
  type QueueAdd,
} from "../test/stubs.js";

interface TestApp {
  app: FastifyInstance;
  adds: QueueAdd[];
  mint: MintStub;
}

describe.skipIf(!TEST_DATABASE_URL)("Wave 1a send settings + preferences (real postgres)", () => {
  let db: Db;
  const built: TestApp[] = [];

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.app.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  function makeApp(o: { catalog?: GatewayDeps["modelCatalog"]; mintThrows?: unknown } = {}): TestApp {
    const { queues, adds } = stubQueues();
    const mint = stubMint(o.mintThrows === undefined ? {} : { throws: o.mintThrows });
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint,
      events: noopEvents,
      ...(o.catalog !== undefined ? { modelCatalog: o.catalog } : {}),
    });
    const handle = { app, adds, mint };
    built.push(handle);
    return handle;
  }

  const catalog = async (): Promise<readonly string[]> => ["auto", "glm-5.3", "gemini-3.8-flash"];

  async function createManualModelUser(uid: string): Promise<void> {
    await users.ensure(db, uid, `${uid}@stub.test`);
    const row = await users.ensure(db, uid, `${uid}@stub.test`);
    const tier = ["plus", "pro", "max", "7x", "15x"].find(
      (candidate) => planFor(candidate).manualModels,
    );
    expect(tier).not.toBeNull();
    await db.$client.unsafe("UPDATE users SET tier = $2 WHERE uid = $1", [uid, tier!]);
    expect(row.uid).toBe(uid);
  }

  async function createSession(h: TestApp, uid: string, title?: string): Promise<string> {
    const res = await h.app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: title === undefined ? {} : { title },
    });
    expect(res.statusCode).toBe(201);
    return res.json().id as string;
  }

  function send(h: TestApp, uid: string, sid: string, body: object) {
    return h.app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/messages`,
      headers: authHeaders(uid),
      payload: body,
    });
  }

  async function runCount(sid: string): Promise<number> {
    const r = await db.$client.unsafe("SELECT count(*)::int AS n FROM runs WHERE session_id = $1", [sid]);
    return r[0]!.n as number;
  }

  it("persists model/mode/planMode/presetId into agent state, mode on the job and the row, and echoes the model", async () => {
    const h = makeApp({ catalog });
    const uid = testUid("w1a-set");
    await createManualModelUser(uid);
    const sid = await createSession(h, uid);
    const res = await send(h, uid, sid, {
      content: "hi",
      model: "glm-5.3 · high",
      mode: "safe",
      planMode: true,
      presetId: "code",
    });
    expect(res.statusCode).toBe(202);
    expect(res.json().model).toBe("glm-5.3 · high");
    const state = await sessionState.get(db, sid);
    expect(state).toMatchObject({
      modelPin: "glm-5.3 · high",
      mode: "safe",
      pendingPlanMode: true,
      presetId: "code",
    });
    expect(h.adds).toHaveLength(1);
    expect(h.adds[0]!.data.mode).toBe("safe");
    const session = await h.app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}`,
      headers: authHeaders(uid),
    });
    expect(session.json().mode).toBe("safe");
  });

  it("model 'auto' clears the pin; an unchanged planMode queues no transition; absent fields keep state", async () => {
    const h = makeApp({ catalog });
    const uid = testUid("w1a-auto");
    const sid = await createSession(h, uid);
    await sessionState.patch(db, sid, { modelPin: "glm-5.3", presetId: "minimal" });
    const res = await send(h, uid, sid, { content: "hi", model: "auto", planMode: false });
    expect(res.statusCode).toBe(202);
    expect(res.json().model).toBe("auto");
    const state = await sessionState.get(db, sid);
    expect(state.modelPin).toBeNull();
    expect(state.pendingPlanMode).toBeNull();
    expect(state.presetId).toBe("minimal");
    expect(h.adds[0]!.data.mode).toBeUndefined();
  });

  it("unknown model while the catalog is known → 400 model_unavailable before mint or any write", async () => {
    const h = makeApp({ catalog });
    const uid = testUid("w1a-badmodel");
    await createManualModelUser(uid);
    const sid = await createSession(h, uid);
    const res = await send(h, uid, sid, { content: "hi", model: "not-a-model" });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe("model_unavailable");
    expect(h.mint.calls).toHaveLength(0);
    expect(h.adds).toHaveLength(0);
    expect(await runCount(sid)).toBe(0);
  });

  it("catalog unavailable → the model is accepted (documented fail-open)", async () => {
    const h = makeApp({
      catalog: async () => {
        throw new Error("redis down");
      },
    });
    const uid = testUid("w1a-failopen");
    await createManualModelUser(uid);
    const sid = await createSession(h, uid);
    const res = await send(h, uid, sid, { content: "hi", model: "anything-x" });
    expect(res.statusCode).toBe(202);
    expect((await sessionState.get(db, sid)).modelPin).toBe("anything-x");
  });

  it("unknown presetId → 400 and nothing is persisted", async () => {
    const h = makeApp({ catalog });
    const uid = testUid("w1a-preset");
    const sid = await createSession(h, uid);
    const res = await send(h, uid, sid, { content: "hi", presetId: "my-custom" });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe("bad_request");
    expect((await sessionState.get(db, sid)).presetId).toBeNull();
  });

  it("a failed mint persists no settings", async () => {
    const h = makeApp({ catalog, mintThrows: new Error("mint down") });
    const uid = testUid("w1a-mintfail");
    await createManualModelUser(uid);
    const sid = await createSession(h, uid);
    const res = await send(h, uid, sid, { content: "hi", model: "glm-5.3", mode: "drive" });
    expect(res.statusCode).toBe(409);
    const state = await sessionState.get(db, sid);
    expect(state.modelPin).toBeNull();
    expect(state.mode).toBe("auto");
  });

  it("CH-010: a clientMsgId retry replays the original run with no second run and no re-persisted settings", async () => {
    const h = makeApp({ catalog });
    const uid = testUid("w1a-replay");
    await createManualModelUser(uid);
    const sid = await createSession(h, uid);
    const first = await send(h, uid, sid, { content: "hi", clientMsgId: "k-1", model: "glm-5.3", mode: "safe" });
    expect(first.statusCode).toBe(202);
    const second = await send(h, uid, sid, {
      content: "hi",
      clientMsgId: "k-1",
      model: "gemini-3.8-flash",
      mode: "drive",
    });
    expect(second.statusCode).toBe(202);
    expect(second.json().runId).toBe(first.json().runId);
    expect(second.json().userMessageId).toBe(first.json().userMessageId);
    expect(await runCount(sid)).toBe(1);
    expect(h.adds).toHaveLength(1);
    const state = await sessionState.get(db, sid);
    expect(state.modelPin).toBe("glm-5.3");
    expect(state.mode).toBe("safe");
  });

  describe("sessionRefs + @[Title] mentions (R1)", () => {
    it("owned sessionRefs ride the job; a foreign or self ref is a 400", async () => {
      const h = makeApp({ catalog });
      const uid = testUid("w1a-refs");
      const other = testUid("w1a-refs-other");
      const sid = await createSession(h, uid);
      const mine = await createSession(h, uid, "Project notes");
      const theirs = await createSession(h, other, "Secret");

      const ok = await send(h, uid, sid, { content: "use that", sessionRefs: [mine] });
      expect(ok.statusCode).toBe(202);
      expect(h.adds[0]!.data.sessionRefs).toEqual([mine]);

      for (const bad of [theirs, sid]) {
        const res = await send(h, uid, sid, { content: "x", sessionRefs: [bad] });
        expect(res.statusCode).toBe(400);
        expect(res.json().error.message).toBe("sessionRefs contains an unknown session.");
      }
      expect(h.adds).toHaveLength(1);
    });

    it("resolves @[Title] tokens case-insensitively among the caller's sessions; ambiguous/unknown/foreign titles are ignored", async () => {
      const h = makeApp({ catalog });
      const uid = testUid("w1a-mention");
      const other = testUid("w1a-mention-other");
      const sid = await createSession(h, uid, "Current");
      const notes = await createSession(h, uid, "Project Notes");
      await createSession(h, uid, "Dup");
      await createSession(h, uid, "dup");
      await createSession(h, other, "Theirs");

      const res = await send(h, uid, sid, {
        content: "compare @[project notes] with @[Dup] and @[Theirs] and @[Current] and @[nope]",
      });
      expect(res.statusCode).toBe(202);
      expect(h.adds[0]!.data.sessionRefs).toEqual([notes]);
    });

    it("no refs and no mentions → no sessionRefs on the job", async () => {
      const h = makeApp({ catalog });
      const uid = testUid("w1a-norefs");
      const sid = await createSession(h, uid);
      await send(h, uid, sid, { content: "plain @someone text" });
      expect(h.adds[0]!.data.sessionRefs).toBeUndefined();
    });
  });

  it("CH-001: PATCH /sessions/:id mode also writes the agent state the worker reads", async () => {
    const h = makeApp();
    const uid = testUid("w1a-patch");
    const sid = await createSession(h, uid);
    const res = await h.app.inject({
      method: "PATCH",
      url: `/cloud/v1/sessions/${sid}`,
      headers: authHeaders(uid),
      payload: { mode: "safe" },
    });
    expect(res.statusCode).toBe(200);
    expect((await sessionState.get(db, sid)).mode).toBe("safe");
  });

  describe("GET/PATCH /preferences (SE-005)", () => {
    it("defaults, partial patch, strict body", async () => {
      const h = makeApp();
      const uid = testUid("w1a-prefs");
      const get = await h.app.inject({ method: "GET", url: "/cloud/v1/preferences", headers: authHeaders(uid) });
      expect(get.statusCode).toBe(200);
      expect(get.json()).toEqual({ memoryEnabled: true, shareSessionMemory: false, showReasoning: true, responseWaitSeconds: 45 });

      const patch = await h.app.inject({
        method: "PATCH",
        url: "/cloud/v1/preferences",
        headers: authHeaders(uid),
        payload: { memoryEnabled: false },
      });
      expect(patch.statusCode).toBe(200);
      expect(patch.json()).toEqual({ memoryEnabled: false, shareSessionMemory: false, showReasoning: true, responseWaitSeconds: 45 });
      expect(await userPreferences.get(db, uid)).toEqual({
        memoryEnabled: false,
        shareSessionMemory: false,
        showReasoning: true,
      });

      // showReasoning is a first-class switch, not an unknown key.
      const reasoning = await h.app.inject({
        method: "PATCH",
        url: "/cloud/v1/preferences",
        headers: authHeaders(uid),
        payload: { showReasoning: false },
      });
      expect(reasoning.statusCode).toBe(200);
      expect(reasoning.json()).toEqual({ memoryEnabled: false, shareSessionMemory: false, showReasoning: false, responseWaitSeconds: 45 });

      for (const bad of [{}, { memoryEnabled: "no" }, { memoryEnabled: true, extra: 1 }]) {
        const res = await h.app.inject({
          method: "PATCH",
          url: "/cloud/v1/preferences",
          headers: authHeaders(uid),
          payload: bad,
        });
        expect(res.statusCode).toBe(400);
      }
    });

    it("requires auth", async () => {
      const h = makeApp();
      const res = await h.app.inject({ method: "GET", url: "/cloud/v1/preferences" });
      expect(res.statusCode).toBe(401);
    });
  });
});
