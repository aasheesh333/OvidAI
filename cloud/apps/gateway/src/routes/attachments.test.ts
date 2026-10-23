import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { attachments, newId, type Db } from "@ovid/db";
import {
  attachmentUploadResponseSchema,
  type AttachmentUploadResponse,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import type { AttachmentPresigner, AttachmentUploadConditions } from "./attachments.js";
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

const UUIDV7_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/**
 * Fake presigner injected via deps (the P8-Q3 seam): captures every
 * (key, ttlSeconds) pair and answers a deterministic URL derived from the key,
 * so the route's key-layout pin is exact.
 */
interface PresignCall {
  key: string;
  ttlSeconds: number;
  conditions?: AttachmentUploadConditions;
}

function stubPresigner(behavior: { fail?: boolean } = {}): AttachmentPresigner & { calls: PresignCall[] } {
  const calls: PresignCall[] = [];
  return {
    calls,
    async presignPut(key, ttlSeconds, conditions) {
      calls.push({ key, ttlSeconds, ...(conditions !== undefined ? { conditions } : {}) });
      if (behavior.fail) throw new Error("presigner unavailable");
      return `https://r2.test/bucket/${encodeURIComponent(key)}?X-Signature=stub`;
    },
  };
}

const built: FastifyInstance[] = [];

describe.skipIf(!TEST_DATABASE_URL)("gateway attachment routes (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    db = await openTestDb();
  }, 60_000);

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  afterAll(async () => {
    await closeDb(db);
  });

  /**
   * Fresh gateway per test with the fake presigner injected (or deliberately
   * absent when `noPresigner` — the loud-fallback pin).
   */
  function makeApp(opts: { noPresigner?: boolean; failPresign?: boolean } = {}):
    { app: FastifyInstance; presigner: AttachmentPresigner & { calls: PresignCall[] } } {
    const presigner = stubPresigner({ fail: opts.failPresign });
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      ...(opts.noPresigner ? {} : { presigner }),
    });
    built.push(app);
    return { app, presigner };
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

  function postAttachment(
    app: FastifyInstance,
    uid: string,
    sessionId: string,
    body: unknown,
    headers: Record<string, string> | null = null,
  ) {
    return app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sessionId}/attachments`,
      headers: headers ?? authHeaders(uid),
      payload: body as object,
    });
  }

  /** Pin the canonical Free plan first so the project cap is deterministically 80. */
  async function pinFreeCap(uid: string): Promise<void> {
    await db.$client.unsafe(
      `INSERT INTO plans (id, name, price_usd, enabled, aliases, window_hours, mult, slow_mode, auto_oss, position)
       VALUES ('free', 'Free', '0', true, '[]'::jsonb, 24, '1', false, false, -1000000)
       ON CONFLICT (id) DO UPDATE SET enabled = true, position = -1000000`,
    );
    await db.$client.unsafe(`UPDATE users SET tier = 'free' WHERE uid = $1`, [uid]);
  }

  it("create → 201 with attachmentId/uploadUrl/path/expiresAt, key layout pinned, db row written", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-ok");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "photo 1.png", size: 1234 });
    expect(res.statusCode).toBe(201);
    const body = attachmentUploadResponseSchema.parse(res.json()) as AttachmentUploadResponse;
    expect(body.attachmentId).toMatch(UUIDV7_RE);

    // Key layout pin (brief): users/{uid}/sessions/{sessionId}/uploads/{attachmentId}
    const expectedKey = `users/${uid}/sessions/${sid}/uploads/${body.attachmentId}`;
    expect(presigner.calls).toEqual([
      {
        key: expectedKey,
        ttlSeconds: 900,
        conditions: { contentLength: 1234, contentType: "application/octet-stream" },
      },
    ]);
    expect(body.uploadUrl).toBe(`https://r2.test/bucket/${encodeURIComponent(expectedKey)}?X-Signature=stub`);

    // path is the workspace-relative uploads/{sanitizedName}
    expect(body.path).toBe("uploads/photo_1.png");

    // expiresAt is a parseable ISO timestamp ~15 min in the future.
    const ms = Date.parse(body.expiresAt);
    expect(ms).not.toBeNaN();
    expect(ms).toBeGreaterThan(Date.now());

    // The db row: one attachment for the session with the exact r2Key/name/size/user.
    const rows = await attachments.getForSession(db, sid);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: body.attachmentId,
      sessionId: sid,
      userId: uid,
      name: "photo 1.png",
      size: 1234,
      r2Key: expectedKey,
    });
  });

  it("SECURITY: the presigned PUT is bound to the declared size and media type", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-conditions");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, {
      name: "photo.png",
      size: 4321,
      contentType: "image/png",
    });
    expect(res.statusCode).toBe(201);
    expect(presigner.calls).toHaveLength(1);
    expect(presigner.calls[0]!.conditions).toEqual({
      contentLength: 4321,
      contentType: "image/png",
    });

    // Only a canonical type/subtype token may be signed: a parameterized,
    // header-injecting or malformed value is refused before any signing.
    for (const contentType of [
      "",
      "image/png; charset=utf-8",
      "nope",
      "a/b/c",
      "text/plain\r\nX-Injected: 1",
      42,
    ]) {
      const bad = await postAttachment(app, uid, sid, { name: "x.png", size: 10, contentType });
      expect(bad.statusCode, JSON.stringify(contentType)).toBe(400);
      expect(bad.json().error.code).toBe("bad_request");
    }
    expect(presigner.calls).toHaveLength(1);
  });

  it("size over the 25 MB cap → 400 attachment_too_large; exactly 25_000_000 is allowed; nothing written over the cap", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-big");
    const sid = await createSession(app, uid);

    const over = await postAttachment(app, uid, sid, { name: "big.bin", size: 25_000_001 });
    expect(over.statusCode).toBe(400);
    expect(over.json()).toEqual({
      error: {
        code: "attachment_too_large",
        message: expect.any(String) as string,
      },
    });

    // The boundary itself passes, and the cap check happens before the
    // presigner (no wasted signing) and before any write.
    expect(presigner.calls).toHaveLength(0);
    const atCap = await postAttachment(app, uid, sid, { name: "edge.bin", size: 25_000_000 });
    expect(atCap.statusCode).toBe(201);
    expect(await attachments.getForSession(db, sid)).toHaveLength(1);
  });

  it("malformed bodies → 400 bad_request: missing/empty name, non-integer or non-positive size, unknown keys", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-bad");
    const sid = await createSession(app, uid);

    for (const body of [
      { size: 10 },
      { name: "", size: 10 },
      { name: "ok" },
      { name: "ok", size: 0 },
      { name: "ok", size: -5 },
      { name: "ok", size: 1.5 },
      { name: "ok", size: "10" },
      { name: "ok", size: 10, extra: 1 },
    ]) {
      const res = await postAttachment(app, uid, sid, body);
      expect(res.statusCode, JSON.stringify(body)).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect(presigner.calls).toHaveLength(0);
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("non-owner session, unknown session, malformed :id → 404 not_found (checked BEFORE body validation and signing)", async () => {
    const { app, presigner } = makeApp();
    const owner = testUid("att-owner");
    const stranger = testUid("att-stranger");
    const sid = await createSession(app, owner);

    // A stranger with a VALID body gets the same 404 as one with garbage —
    // no existence leaks through validation behavior.
    for (const body of [{ name: "sneak.txt", size: 1 }, { name: "" }]) {
      const res = await postAttachment(app, stranger, sid, body);
      expect(res.statusCode, JSON.stringify(body)).toBe(404);
      expect(res.json().error.code).toBe("not_found");
    }
    const unknown = await postAttachment(app, owner, newId(), { name: "x.txt", size: 1 });
    expect(unknown.statusCode).toBe(404);
    for (const bad of ["not-a-uuid", "1234567"]) {
      const res = await postAttachment(app, owner, bad, { name: "x.txt", size: 1 });
      expect(res.statusCode, bad).toBe(404);
      expect(res.statusCode, bad).not.toBe(500);
    }
    expect(presigner.calls).toHaveLength(0);
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("no presigner configured → loud 503 attachments_not_configured (never a silent no-op, never a 500)", async () => {
    const { app } = makeApp({ noPresigner: true });
    const uid = testUid("att-nopresign");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 });
    expect(res.statusCode).toBe(503);
    expect(res.json()).toEqual({
      error: {
        code: "attachments_not_configured",
        message: expect.any(String) as string,
      },
    });
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("presigner rejection → 500 internal, no attachment row left behind (sign happens BEFORE the insert)", async () => {
    const { app } = makeApp({ failPresign: true });
    const uid = testUid("att-fail");
    const sid = await createSession(app, uid);

    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 });
    expect(res.statusCode).toBe(500);
    expect(res.json().error.code).toBe("internal");
    expect(await attachments.getForSession(db, sid)).toEqual([]);
  });

  it("hostile names sanitize into a safe single uploads/ segment for `path`", async () => {
    const { app } = makeApp();
    const uid = testUid("att-sanitize");
    const sid = await createSession(app, uid);

    const cases: Array<[string, string]> = [
      // "../../etc/passwd": both "/" runs → "_", leading dots stripped, the
      // interior ".." run collapsed → three underscores then "etc_passwd".
      ["../../etc/passwd", "___etc_passwd"],
      ["..", "attachment"],
      ["a..b", "a_b"],
      [".hidden", "hidden"],
    ];
    for (const [name, expected] of cases) {
      const res = await postAttachment(app, uid, sid, { name, size: 1 });
      expect(res.statusCode, name).toBe(201);
      expect((res.json() as AttachmentUploadResponse).path).toBe(`uploads/${expected}`);
    }
    // The raw name is stored verbatim in the row (sanitization is a
    // workspace-path concern, never a display rewrite).
    const rows = await attachments.getForSession(db, sid);
    expect(rows.map((r) => r.name)).toEqual(cases.map(([name]) => name));
  });

  it("project chat: cap 80 counts uploads; the 81st is refused BEFORE presign, deleting one frees it; standalone is unaffected", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-project-cap");
    await pinFreeCap(uid);
    const sid = await createSession(app, uid);

    const projectRes = await app.inject({
      method: "POST",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
      payload: { name: "Cap project" },
    });
    expect(projectRes.statusCode).toBe(201);
    const projectId = projectRes.json().id as string;
    const moved = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${sid}/project`,
      headers: authHeaders(uid),
      payload: { projectId },
    });
    expect(moved.statusCode).toBe(200);

    // Fill the project's budget directly (the route's own enforcement is what
    // this test exercises; the seed goes through the same repo check).
    for (let i = 0; i < 80; i++) {
      await attachments.create(db, {
        id: newId(),
        sessionId: sid,
        userId: uid,
        name: `f${i}.bin`,
        size: 1,
        r2Key: `seed/${uid}/${i}/${newId()}`,
        projectId,
      });
    }
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);
    // The seeded files are older than the Free plan's 24 h upload window, so
    // THIS test keeps measuring the project cap; the window has its own suite
    // (uploadWindow.test.ts + the daily-cap case below).
    await db.$client.unsafe(
      `UPDATE attachments SET created_at = now() - interval '2 days' WHERE session_id = $1`,
      [sid],
    );

    const refused = await postAttachment(app, uid, sid, { name: "81.bin", size: 1 });
    expect(refused.statusCode).toBe(409);
    expect(refused.json()).toEqual({
      error: { code: "project_file_limit", message: expect.any(String) as string },
    });
    // Refused before signing and before any row: no presign call, still 80.
    expect(presigner.calls).toEqual([]);
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);

    // Deleting a file frees exactly one slot.
    const [oldest] = await attachments.getForSession(db, sid);
    await db.$client`delete from attachments where id = ${oldest!.id}`;
    const accepted = await postAttachment(app, uid, sid, { name: "again.bin", size: 1 });
    expect(accepted.statusCode).toBe(201);
    expect(presigner.calls).toHaveLength(1);
    expect(await attachments.getForSession(db, sid)).toHaveLength(80);

    // A standalone chat in the same account is not subject to the project cap.
    const standalone = await createSession(app, uid);
    const standaloneRes = await postAttachment(app, uid, standalone, { name: "free.bin", size: 1 });
    expect(standaloneRes.statusCode).toBe(201);
  });

  it("free plan: the 51st upload inside 24 h is refused BEFORE presign", async () => {
    const { app, presigner } = makeApp();
    const uid = testUid("att-daily-cap");
    const sid = await createSession(app, uid);
    await pinFreeCap(uid);

    for (let i = 0; i < 50; i++) {
      await attachments.create(db, {
        id: newId(),
        sessionId: sid,
        userId: uid,
        name: `d${i}.bin`,
        size: 1,
        r2Key: `seed/${uid}/d/${i}/${newId()}`,
      });
    }

    const refused = await postAttachment(app, uid, sid, { name: "51.bin", size: 1 });
    expect(refused.statusCode).toBe(429);
    expect(refused.json()).toEqual({
      error: { code: "upload_limit_reached", message: expect.any(String) as string },
    });
    // Refused before signing and before any row.
    expect(presigner.calls).toEqual([]);
    expect(await attachments.getForSession(db, sid)).toHaveLength(50);
  });

  it("a file older than the window stops counting against it", async () => {
    const { app } = makeApp();
    const uid = testUid("att-window-age");
    const sid = await createSession(app, uid);
    await pinFreeCap(uid);

    for (let i = 0; i < 50; i++) {
      await attachments.create(db, {
        id: newId(),
        sessionId: sid,
        userId: uid,
        name: `a${i}.bin`,
        size: 1,
        r2Key: `seed/${uid}/a/${i}/${newId()}`,
      });
    }
    await db.$client.unsafe(
      `UPDATE attachments SET created_at = now() - interval '25 hours' WHERE session_id = $1`,
      [sid],
    );

    const accepted = await postAttachment(app, uid, sid, { name: "next.bin", size: 1 });
    expect(accepted.statusCode).toBe(201);
  });

  it("attachment routes answer 401 unauthenticated with the shared envelope", async () => {
    const { app } = makeApp();
    const uid = testUid("att-401");
    const sid = await createSession(app, uid);
    const res = await postAttachment(app, uid, sid, { name: "x.txt", size: 1 }, {});
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
  });
});
