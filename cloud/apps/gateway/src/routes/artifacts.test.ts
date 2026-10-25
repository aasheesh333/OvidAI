import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { assertSessionFileCapacity, createStorageQuotaRepos, eventMirror, workspaceObjects, type Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import { createStorage, registerArtifact } from "@ovid/storage";
import {
  artifactDtoSchema,
  type ArtifactDto,
  type Page,
  type SessionEvent,
  type SessionEventType,
} from "@ovid/shared";
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

// P7 Task 12 — artifact routes. Artifacts are registered through the REAL
// Task 9 engine (fs storage + real db repos), then served through the route.

const built: FastifyInstance[] = [];

/** Minimal recording EventLog for the engine (no redis needed). */
function recordingEventLog(): { log: EventLog; events: SessionEvent[] } {
  const events: SessionEvent[] = [];
  let seq = 0;
  const log = {
    async append(
      sessionId: string,
      type: SessionEventType,
      payload: Record<string, unknown>,
    ): Promise<SessionEvent> {
      const e: SessionEvent = {
        sessionId,
        seq: String(++seq),
        type,
        payload,
        ts: new Date().toISOString(),
      };
      events.push(e);
      return e;
    },
    async readSince(): Promise<SessionEvent[]> {
      return [];
    },
    async subscribe(): Promise<() => Promise<void>> {
      return async () => {};
    },
  };
  return { log: log as unknown as EventLog, events };
}

describe.skipIf(!TEST_DATABASE_URL)("gateway artifact routes (real postgres)", () => {
  let db: Db;
  let fsRoot: string;

  beforeAll(async () => {
    db = await openTestDb();
    fsRoot = await mkdtemp(join(tmpdir(), "p7t12-art-"));
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await rm(fsRoot, { recursive: true, force: true }).catch(() => {});
    await closeDb(db);
  });

  function makeApp(): FastifyInstance {
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      storage: createStorage({ backend: "fs", fsRoot }),
      presignTtlSeconds: 3600,
    });
    built.push(app);
    return app;
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

  async function registerThree(app: FastifyInstance, uid: string, sid: string): Promise<ArtifactDto["id"][]> {
    const storage = createStorage({ backend: "fs", fsRoot });
    const { log } = recordingEventLog();
    const ids: string[] = [];
    for (const [name, content] of [
      ["report.pdf", "pdf-bytes"],
      ["chart.png", "png-bytes"],
      ["notes.txt", "txt-bytes"],
    ] as const) {
      const record = await registerArtifact(
        {
          db,
          events: log,
          storage,
          workspaceObjects,
          eventMirror,
          quota: createStorageQuotaRepos(db),
          assertProjectFileCapacity: assertSessionFileCapacity,
          presignTtlSeconds: 3600,
        },
        {
          userId: uid,
          sessionId: sid,
          name,
          contentType: "application/octet-stream",
          content: Buffer.from(content, "utf8"),
        },
      );
      ids.push(record.id);
    }
    return ids;
  }

  it("list → Page<ArtifactDto> newest-first; keyset cursor pages with limit=2; url → 200 file:// url + expiresAt", async () => {
    const app = makeApp();
    const uid = testUid("t12-art-ok");
    const sid = await createSession(app, uid);
    const ids = await registerThree(app, uid, sid);
    expect(ids).toHaveLength(3);

    // Full page: newest (last registered) first.
    const first = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts`,
      headers: authHeaders(uid),
    });
    expect(first.statusCode).toBe(200);
    const page1 = first.json() as Page<ArtifactDto>;
    expect(page1.items.map((i) => i.id)).toEqual([ids[2], ids[1], ids[0]]);
    expect(page1.nextCursor).toBeNull();
    for (const item of page1.items) {
      expect(() => artifactDtoSchema.parse(item)).not.toThrow();
    }
    expect(page1.items.map((i) => i.name)).toEqual(["notes.txt", "chart.png", "report.pdf"]);
    expect(page1.items.every((i) => i.sessionId === sid)).toBe(true);
    expect(page1.items.every((i) => i.sizeBytes === "pdf-bytes".length)).toBe(true);

    // Keyset page with limit=2.
    const limited = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts?limit=2`,
      headers: authHeaders(uid),
    });
    expect(limited.statusCode).toBe(200);
    const pageA = limited.json() as Page<ArtifactDto>;
    expect(pageA.items.map((i) => i.id)).toEqual([ids[2], ids[1]]);
    expect(pageA.nextCursor).toBe(ids[1]);

    const next = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts?limit=2&cursor=${pageA.nextCursor}`,
      headers: authHeaders(uid),
    });
    expect(next.statusCode).toBe(200);
    const pageB = next.json() as Page<ArtifactDto>;
    expect(pageB.items.map((i) => i.id)).toEqual([ids[0]]);
    expect(pageB.nextCursor).toBeNull();

    // URL route: fs presignGet answers a file:// pseudo-URL; expiresAt is
    // ~ttl in the future. The URL itself must be present in the body (and is
    // never logged by the route).
    const urlRes = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts/${ids[0]}/url`,
      headers: authHeaders(uid),
    });
    expect(urlRes.statusCode).toBe(200);
    const body = urlRes.json() as { url: string; expiresAt: string };
    expect(body.url.startsWith("file://")).toBe(true);
    // W12 content-addressed layout: …/artifacts/{sid}/{artifactId}-{sha16}-{name}
    // (sanitizeArtifactName keeps dots — "report.pdf" stays "report.pdf").
    expect(body.url).toContain(ids[0]!);
    expect(body.url).toContain("-report.pdf");
    const ms = Date.parse(body.expiresAt);
    expect(ms).not.toBeNaN();
    expect(ms).toBeGreaterThan(Date.now());
  });

  it("wrong owner → 404 on list and url; unknown and malformed artifactId → 404", async () => {
    const app = makeApp();
    const owner = testUid("t12-art-owner");
    const stranger = testUid("t12-art-stranger");
    const sid = await createSession(app, owner);
    const ids = await registerThree(app, owner, sid);

    const strangerList = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts`,
      headers: authHeaders(stranger),
    });
    expect(strangerList.statusCode).toBe(404);
    expect(strangerList.json().error.code).toBe("not_found");

    const strangerUrl = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts/${ids[0]}/url`,
      headers: authHeaders(stranger),
    });
    expect(strangerUrl.statusCode).toBe(404);

    const unknown = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts/00000000-0000-7000-8000-000000000000/url`,
      headers: authHeaders(owner),
    });
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error.code).toBe("not_found");

    const malformed = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/${sid}/artifacts/not-a-uuid/url`,
      headers: authHeaders(owner),
    });
    expect(malformed.statusCode).toBe(404);

    // Malformed session id → same 404, never a 500.
    const badSession = await app.inject({
      method: "GET",
      url: `/cloud/v1/sessions/not-a-uuid/artifacts`,
      headers: authHeaders(owner),
    });
    expect(badSession.statusCode).toBe(404);
  });
});
