import http from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Redis } from "ioredis";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { fileManifests, type Db } from "@ovid/db";
import {
  createQueues,
  HYDRATE_JOB_NAME,
  HIBERNATE_JOB_NAME,
  storageJobId,
} from "@ovid/queue";
import { ACTIVITY_KEY_PREFIX, createActivityTracker, createStorage } from "@ovid/storage";
import {
  workspaceFileRedirectSchema,
  workspaceFileResponseSchema,
  workspaceFileWriteResponseSchema,
  workspaceTreeResponseSchema,
  type UiManifest,
  type WorkspaceState,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import { loadGatewayEnv } from "../env.js";
import { createWorkerClient } from "../workerClient.js";
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

// P7 Task 12 — gateway workspace routes against REAL dev Postgres + Redis,
// an fs storage adapter and a STUB worker file service (a node:http server on
// an ephemeral port that records every request, wired in as workerInternalUrl).

const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

const INTERNAL_TOKEN = "t12-internal-token";

/** A valid manifest the stub worker serves for the live tree path. */
const LIVE_TREE: UiManifest = {
  version: 1,
  generatedAt: "2026-10-17T00:00:00.000Z",
  truncated: false,
  totals: { files: 1, dirs: 0, bytes: 5 },
  roots: [
    {
      name: "live.txt",
      path: "live.txt",
      type: "file",
      sizeBytes: 5,
      mtime: "2026-10-17T00:00:00Z",
    },
  ],
};

/** The uiTree a hibernated (cold) row would carry. */
const COLD_TREE: UiManifest = {
  version: 1,
  generatedAt: "2026-10-16T12:00:00.000Z",
  truncated: false,
  totals: { files: 2, dirs: 1, bytes: 30 },
  roots: [
    {
      name: "src",
      path: "src",
      type: "dir",
      files: 1,
      bytes: 20,
      dirs: 0,
      children: [
        {
          name: "main.ts",
          path: "src/main.ts",
          type: "file",
          sizeBytes: 20,
          mtime: "2026-10-16T11:00:00Z",
        },
      ],
    },
    {
      name: "notes.md",
      path: "notes.md",
      type: "file",
      sizeBytes: 10,
      mtime: "2026-10-16T11:30:00Z",
    },
  ],
};

// ---------------------------------------------------------------------------
// Stub worker file service
// ---------------------------------------------------------------------------

interface StubRequest {
  method: string;
  url: string;
  token: string | null;
  userId: string | null;
  body: string;
}

interface StubResponse {
  status: number;
  body: unknown;
}

interface StubSlot {
  queue: StubResponse[];
  fallback: StubResponse;
}

interface StubWorker {
  url: string;
  requests: StubRequest[];
  tree: StubSlot;
  file: StubSlot;
  put: StubSlot;
  close(): Promise<void>;
}

function headerOf(v: string | string[] | undefined): string | null {
  return typeof v === "string" ? v : null;
}

const DEFAULT_FILE_FALLBACK: StubResponse = {
  status: 200,
  body: {
    kind: "content",
    path: "a.txt",
    sizeBytes: 5,
    sha256Hex: "aa".repeat(32),
    contentType: "text/plain",
    contentBase64: Buffer.from("hello").toString("base64"),
    source: "warm",
  },
};

async function startStubWorker(): Promise<StubWorker> {
  const requests: StubRequest[] = [];
  const tree: StubSlot = {
    queue: [],
    fallback: { status: 200, body: { tree: LIVE_TREE } },
  };
  const file: StubSlot = {
    queue: [],
    fallback: DEFAULT_FILE_FALLBACK,
  };
  const put: StubSlot = {
    queue: [],
    fallback: {
      status: 200,
      body: { path: "a.txt", sizeBytes: 5, sha256: "bb".repeat(32) },
    },
  };

  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const url = req.url ?? "";
      requests.push({
        method: req.method ?? "",
        url,
        token: headerOf(req.headers["x-ovid-internal-token"]),
        userId: headerOf(req.headers["x-ovid-user-id"]),
        body: Buffer.concat(chunks).toString("utf8"),
      });
      const slot = url.endsWith("/tree")
        ? tree
        : req.method === "PUT"
          ? put
          : file;
      const r = slot.queue.length > 0 ? slot.queue.shift()! : slot.fallback;
      res.writeHead(r.status, { "content-type": "application/json" });
      res.end(JSON.stringify(r.body));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    tree,
    file,
    put,
    close: () =>
      new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

const built: FastifyInstance[] = [];

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "gateway workspace routes (real postgres + redis)",
  () => {
    let db: Db;
    let redis: Redis;
    let queues: ReturnType<typeof createQueues>;
    let stub: StubWorker;
    let fsRoot: string;

    beforeAll(async () => {
      db = await openTestDb();
      redis = new Redis(TEST_REDIS_URL!);
      queues = createQueues(
        { url: TEST_REDIS_URL! },
        { prefix: `p7t12gw-${process.pid}-${Date.now().toString(36)}` },
      );
      stub = await startStubWorker();
      fsRoot = await mkdtemp(join(tmpdir(), "p7t12-gw-"));
    }, 60_000);

    afterEach(async () => {
      while (built.length > 0) await built.pop()!.close();
      stub.requests.length = 0;
      stub.tree.queue.length = 0;
      stub.file.queue.length = 0;
      stub.put.queue.length = 0;
      stub.file.fallback = DEFAULT_FILE_FALLBACK;
    });

    afterAll(async () => {
      await queues.hydrate.obliterate({ force: true }).catch(() => {});
      await queues.hibernate.obliterate({ force: true }).catch(() => {});
      await queues.agentRuns.obliterate({ force: true }).catch(() => {});
      await queues.hydrate.close();
      await queues.hibernate.close();
      await queues.agentRuns.close();
      await stub.close();
      redis.disconnect();
      await rm(fsRoot, { recursive: true, force: true }).catch(() => {});
      await closeDb(db);
    });

    function makeApp(
      opts: { hydrateWaitMs?: number; putMaxBytes?: number; workerUrl?: string } = {},
    ): FastifyInstance {
      const app = buildGateway({
        system: stubSystemBus(),
        db,
        queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
        storage: createStorage({ backend: "fs", fsRoot }),
        activity: createActivityTracker(redis),
        worker: createWorkerClient({
          baseUrl: opts.workerUrl ?? stub.url,
          token: INTERNAL_TOKEN,
        }),
        inlineMaxBytes: 1_048_576,
        ...(opts.putMaxBytes !== undefined ? { putMaxBytes: opts.putMaxBytes } : {}),
        presignTtlSeconds: 3600,
        ...(opts.hydrateWaitMs !== undefined ? { hydrateWaitMs: opts.hydrateWaitMs } : {}),
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

    /** Seed a file_manifests row in the given state through the real repos. */
    async function seedRow(
      sid: string,
      uid: string,
      state: Exclude<WorkspaceState, "cold" | "hydrating"> | "cold" | "hydrating",
    ): Promise<void> {
      await fileManifests.upsertWarm(db, { sessionId: sid, userId: uid, workspaceBytes: 0 });
      if (state === "warm") return;
      const claimed = await fileManifests.beginHibernation(db, sid);
      expect(claimed).toBe(true);
      if (state === "hibernating") return;
      await fileManifests.markCold(db, {
        sessionId: sid,
        generation: 1,
        archiveKey: `users/${uid}/workspaces/${sid}.tar.zst`,
        archiveBytes: 10,
        archiveSha256: "0".repeat(64),
        entryCount: 1,
        uiTree: COLD_TREE,
      });
      if (state === "cold") return;
      const hydrating = await fileManifests.beginHydration(db, sid);
      expect(hydrating).toBe(true);
    }

    // -- GET tree -----------------------------------------------------------

    it("cold row → 200 source:manifest, tree deep-equals row.uiTree, ZERO stub calls (the <100 ms SLA path)", async () => {
      const app = makeApp();
      const uid = testUid("t12-tree-cold");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "cold");

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/tree`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      const body = workspaceTreeResponseSchema.parse(res.json());
      expect(body).toMatchObject({
        sessionId: sid,
        state: "cold",
        generation: 1,
        source: "manifest",
      });
      expect(body.tree).toEqual(COLD_TREE);
      expect(stub.requests).toEqual([]);
    });

    it("hydrating row → 200 source:manifest with state hydrating (no extraction either)", async () => {
      const app = makeApp();
      const uid = testUid("t12-tree-hydr");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "hydrating");

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/tree`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      const body = workspaceTreeResponseSchema.parse(res.json());
      expect(body).toMatchObject({ state: "hydrating", source: "manifest" });
      expect(body.tree).toEqual(COLD_TREE);
      expect(stub.requests).toEqual([]);
    });

    it("warm row and no-row session → proxied live tree, source:live, generation from row (0 when absent)", async () => {
      const app = makeApp();
      const uid = testUid("t12-tree-live");
      const sidWarm = await createSession(app, uid);
      await seedRow(sidWarm, uid, "warm");
      const sidBare = await createSession(app, uid);

      const warm = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sidWarm}/workspace/tree`,
        headers: authHeaders(uid),
      });
      expect(warm.statusCode).toBe(200);
      const warmBody = workspaceTreeResponseSchema.parse(warm.json());
      expect(warmBody).toMatchObject({
        sessionId: sidWarm,
        state: "warm",
        generation: 0,
        source: "live",
      });
      expect(warmBody.tree).toEqual(LIVE_TREE);

      const bare = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sidBare}/workspace/tree`,
        headers: authHeaders(uid),
      });
      expect(bare.statusCode).toBe(200);
      expect(workspaceTreeResponseSchema.parse(bare.json())).toMatchObject({
        sessionId: sidBare,
        state: "warm",
        generation: 0,
        source: "live",
      });

      // Both proxy calls carried the internal token + user id.
      expect(stub.requests).toHaveLength(2);
      for (const r of stub.requests) {
        expect(r.token).toBe(INTERNAL_TOKEN);
        expect(r.userId).toBe(uid);
      }
    });

    it("stub down (closed port) → 503 unavailable", async () => {
      const app = makeApp({ workerUrl: "http://127.0.0.1:1" });
      const uid = testUid("t12-tree-down");
      const sid = await createSession(app, uid);

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/tree`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(503);
      expect(res.json()).toEqual({
        error: { code: "unavailable", message: expect.any(String) as string },
      });
    });

    // -- GET file -----------------------------------------------------------

    it("content form (text) → 200 encoding utf8 with decoded content", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-text");
      const sid = await createSession(app, uid);

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=a.txt`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      const body = workspaceFileResponseSchema.parse(res.json());
      expect(body).toEqual({
        path: "a.txt",
        sizeBytes: 5,
        contentType: "text/plain",
        encoding: "utf8",
        content: "hello",
      });
    });

    it("content form (binary) → 200 encoding base64, raw base64 passthrough", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-bin");
      const sid = await createSession(app, uid);
      stub.file.fallback = {
        status: 200,
        body: {
          kind: "content",
          path: "img.png",
          sizeBytes: 3,
          sha256Hex: "cc".repeat(32),
          contentType: "image/png",
          contentBase64: Buffer.from([1, 2, 3]).toString("base64"),
        },
      };

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=img.png`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      const body = workspaceFileResponseSchema.parse(res.json());
      expect(body.encoding).toBe("base64");
      expect(body.content).toBe(Buffer.from([1, 2, 3]).toString("base64"));
    });

    it("redirect form → passthrough with downloadUrl/expiresAt", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-redir");
      const sid = await createSession(app, uid);
      stub.file.fallback = {
        status: 200,
        body: {
          kind: "redirect",
          path: "big.bin",
          sizeBytes: 9_000_000,
          contentType: "application/octet-stream",
          downloadUrl: "https://r2.test/bucket/big?X-Signature=stub",
          expiresAt: "2026-10-17T01:00:00.000Z",
        },
      };

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=big.bin`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      expect(workspaceFileRedirectSchema.parse(res.json())).toEqual({
        path: "big.bin",
        sizeBytes: 9_000_000,
        contentType: "application/octet-stream",
        downloadUrl: "https://r2.test/bucket/big?X-Signature=stub",
        expiresAt: "2026-10-17T01:00:00.000Z",
      });
    });

    it("worker 404 → 404 not_found; worker 400 → 400; worker 413 → 413 file_too_large; unavailable → 503", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-errs");
      const sid = await createSession(app, uid);

      stub.file.queue.push({
        status: 404,
        body: { error: { code: "not_found", message: "no such file" } },
      });
      const notThere = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=gone.txt`,
        headers: authHeaders(uid),
      });
      expect(notThere.statusCode).toBe(404);
      expect(notThere.json()).toEqual({
        error: { code: "not_found", message: expect.any(String) as string },
      });

      stub.file.queue.push({
        status: 400,
        body: { error: { code: "bad_request", message: "bad path" } },
      });
      const bad = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=x.txt`,
        headers: authHeaders(uid),
      });
      expect(bad.statusCode).toBe(400);
      expect(bad.json().error.code).toBe("bad_request");

      stub.file.queue.push({
        status: 413,
        body: { error: { code: "file_too_large", message: "too big" } },
      });
      const big = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=huge.bin`,
        headers: authHeaders(uid),
      });
      expect(big.statusCode).toBe(413);
      expect(big.json().error.code).toBe("file_too_large");

      const down = makeApp({ workerUrl: "http://127.0.0.1:1" });
      const downSid = await createSession(down, uid);
      const unavailable = await down.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${downSid}/workspace/file?path=a.txt`,
        headers: authHeaders(uid),
      });
      expect(unavailable.statusCode).toBe(503);
      expect(unavailable.json().error.code).toBe("unavailable");
    });

    it("?path=../x → 400 with NO stub call; missing path → 400", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-path");
      const sid = await createSession(app, uid);

      const escape = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=${encodeURIComponent("../x")}`,
        headers: authHeaders(uid),
      });
      expect(escape.statusCode).toBe(400);
      expect(escape.json().error.code).toBe("bad_request");

      const missing = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
      });
      expect(missing.statusCode).toBe(400);

      expect(stub.requests).toEqual([]);
    });

    it("file GET bumps the session activity key", async () => {
      const app = makeApp();
      const uid = testUid("t12-file-act");
      const sid = await createSession(app, uid);

      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/file?path=a.txt`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      expect(await redis.get(`${ACTIVITY_KEY_PREFIX}${sid}`)).not.toBeNull();
    });

    // -- PUT file -----------------------------------------------------------

    it("warm row + stub 200 → 200 write response, activity bumped, stub sees base64 body + headers", async () => {
      const app = makeApp();
      const uid = testUid("t12-put-ok");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "warm");

      const res = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentUtf8: "hello world" },
      });
      expect(res.statusCode).toBe(200);
      const body = workspaceFileWriteResponseSchema.parse(res.json());
      expect(body).toEqual({ path: "a.txt", sizeBytes: 5, sha256: "bb".repeat(32) });

      expect(stub.requests).toHaveLength(1);
      const call = stub.requests[0]!;
      expect(call.method).toBe("PUT");
      expect(call.url).toBe(`/internal/sessions/${sid}/file?path=a.txt`);
      expect(call.token).toBe(INTERNAL_TOKEN);
      expect(call.userId).toBe(uid);
      expect(JSON.parse(call.body)).toEqual({
        contentBase64: Buffer.from("hello world").toString("base64"),
      });

      expect(await redis.get(`${ACTIVITY_KEY_PREFIX}${sid}`)).not.toBeNull();
    });

    it("cold row: row flips to warm mid-poll → awaitWarm unblocks and PUT proceeds", async () => {
      const app = makeApp();
      const uid = testUid("t12-put-flip");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "cold");

      const pending = app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentBase64: Buffer.from("x").toString("base64") },
      });
      // awaitWarm is now polling the cold row; flip it to warm underneath.
      await sleep(120);
      await fileManifests.markWarm(db, { sessionId: sid, workspaceBytes: 0 });
      const res = await pending;
      expect(res.statusCode).toBe(200);
      expect(stub.requests.some((r) => r.method === "PUT")).toBe(true);
    });

    it("cold row that stays cold (hydrateWaitMs=300) → 202 {status:'hydrating'} and a hydrate job is queued", async () => {
      const app = makeApp({ hydrateWaitMs: 300 });
      const uid = testUid("t12-put-timeout");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "cold");

      const res = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentUtf8: "x" },
      });
      expect(res.statusCode).toBe(202);
      expect(res.json()).toEqual({ status: "hydrating" });
      // No PUT reached the worker.
      expect(stub.requests.some((r) => r.method === "PUT")).toBe(false);

      const job = await queues.hydrate.getJob(storageJobId(sid, 1));
      expect(job).not.toBeNull();
      expect(job?.data).toMatchObject({
        sessionId: sid,
        userId: uid,
        generation: 1,
        reason: "write",
      });
      // The row is still cold — hydration is the worker's job, not the route's.
      expect((await fileManifests.get(db, sid))?.state).toBe("cold");
    });

    it("oversize decoded content → 400; both content fields → 400; invalid base64 → 400; no stub call", async () => {
      const app = makeApp({ putMaxBytes: 4 });
      const uid = testUid("t12-put-bad");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "warm");

      const oversize = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentUtf8: "hello" },
      });
      expect(oversize.statusCode).toBe(400);
      expect(oversize.json().error.code).toBe("bad_request");

      const both = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: {
          path: "a.txt",
          contentBase64: "aGk=",
          contentUtf8: "hi",
        },
      });
      expect(both.statusCode).toBe(400);

      const notB64 = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentBase64: "!!!not-base64!!!" },
      });
      expect(notB64.statusCode).toBe(400);

      expect(stub.requests).toEqual([]);
    });

    it("worker 409 not_warm once (eviction race) → one re-warm + retry → 200 with two stub PUTs", async () => {
      const app = makeApp();
      const uid = testUid("t12-put-409ok");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "warm");
      stub.put.queue.push(
        { status: 409, body: { error: { code: "not_warm", message: "evicted" } } },
        { status: 200, body: { path: "a.txt", sizeBytes: 1, sha256: "dd".repeat(32) } },
      );

      const res = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentUtf8: "x" },
      });
      expect(res.statusCode).toBe(200);
      expect(workspaceFileWriteResponseSchema.parse(res.json()).sha256).toBe("dd".repeat(32));
      expect(stub.requests.filter((r) => r.method === "PUT")).toHaveLength(2);
    });

    it("worker 409 twice → 503", async () => {
      const app = makeApp();
      const uid = testUid("t12-put-409bad");
      const sid = await createSession(app, uid);
      await seedRow(sid, uid, "warm");
      stub.put.queue.push(
        { status: 409, body: { error: { code: "not_warm", message: "evicted" } } },
        { status: 409, body: { error: { code: "not_warm", message: "evicted again" } } },
      );

      const res = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(uid),
        payload: { path: "a.txt", contentUtf8: "x" },
      });
      expect(res.statusCode).toBe(503);
      expect(stub.requests.filter((r) => r.method === "PUT")).toHaveLength(2);
    });

    // -- hydrate / hibernate controls ----------------------------------------

    it("POST hydrate state table: warm→200 warm, no-row→200 warm, cold→202 + manual job, hydrating→202, hibernating→409", async () => {
      const app = makeApp();
      const uid = testUid("t12-hydrate");

      const sidWarm = await createSession(app, uid);
      await seedRow(sidWarm, uid, "warm");
      const warm = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidWarm}/workspace/hydrate`,
        headers: authHeaders(uid),
      });
      expect(warm.statusCode).toBe(200);
      expect(warm.json()).toEqual({ status: "warm" });

      const sidBare = await createSession(app, uid);
      const bare = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidBare}/workspace/hydrate`,
        headers: authHeaders(uid),
      });
      expect(bare.statusCode).toBe(200);
      expect(bare.json()).toEqual({ status: "warm" });

      const sidCold = await createSession(app, uid);
      await seedRow(sidCold, uid, "cold");
      const cold = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidCold}/workspace/hydrate`,
        headers: authHeaders(uid),
      });
      expect(cold.statusCode).toBe(202);
      expect(cold.json()).toEqual({ status: "hydrating" });
      const job = await queues.hydrate.getJob(storageJobId(sidCold, 1));
      expect(job).not.toBeNull();
      expect(job?.data).toMatchObject({
        sessionId: sidCold,
        userId: uid,
        generation: 1,
        reason: "manual",
      });
      expect(HYDRATE_JOB_NAME).toBe("hydrate-workspace");

      const sidHydrating = await createSession(app, uid);
      await seedRow(sidHydrating, uid, "hydrating");
      const hydrating = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidHydrating}/workspace/hydrate`,
        headers: authHeaders(uid),
      });
      expect(hydrating.statusCode).toBe(202);
      expect(hydrating.json()).toEqual({ status: "hydrating" });

      const sidHibernating = await createSession(app, uid);
      await seedRow(sidHibernating, uid, "hibernating");
      const hibernating = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidHibernating}/workspace/hydrate`,
        headers: authHeaders(uid),
      });
      expect(hibernating.statusCode).toBe(409);
      expect(hibernating.json().error.code).toBe("invalid_state");
    });

    it("POST hibernate state table: warm→202 + manual job with generation+1, cold→200 cold, hydrating/hibernating→409, no-row→409", async () => {
      const app = makeApp();
      const uid = testUid("t12-hibernate");

      const sidWarm = await createSession(app, uid);
      await seedRow(sidWarm, uid, "warm");
      const warm = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidWarm}/workspace/hibernate`,
        headers: authHeaders(uid),
      });
      expect(warm.statusCode).toBe(202);
      expect(warm.json()).toEqual({ status: "hibernating" });
      // row.generation is 0 → the job claims generation 1.
      const job = await queues.hibernate.getJob(storageJobId(sidWarm, 1));
      expect(job).not.toBeNull();
      expect(job?.data).toMatchObject({
        sessionId: sidWarm,
        userId: uid,
        generation: 1,
        reason: "manual",
      });
      expect(HIBERNATE_JOB_NAME).toBe("hibernate-workspace");

      const sidCold = await createSession(app, uid);
      await seedRow(sidCold, uid, "cold");
      const cold = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidCold}/workspace/hibernate`,
        headers: authHeaders(uid),
      });
      expect(cold.statusCode).toBe(200);
      expect(cold.json()).toEqual({ status: "cold" });

      for (const state of ["hydrating", "hibernating"] as const) {
        const sid = await createSession(app, uid);
        await seedRow(sid, uid, state);
        const res = await app.inject({
          method: "POST",
          url: `/cloud/v1/sessions/${sid}/workspace/hibernate`,
          headers: authHeaders(uid),
        });
        expect(res.statusCode, state).toBe(409);
        expect(res.json().error.code).toBe("invalid_state");
      }

      const sidBare = await createSession(app, uid);
      const bare = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sidBare}/workspace/hibernate`,
        headers: authHeaders(uid),
      });
      expect(bare.statusCode).toBe(409);
      expect(bare.json().error.code).toBe("invalid_state");
      expect(bare.json().error.message).toMatch(/sweeper/i);
    });

    // -- ownership + messages bump -------------------------------------------

    it("owner mismatch and malformed :id → 404 on every workspace route (never 403), no stub call for the stranger", async () => {
      const app = makeApp();
      const owner = testUid("t12-owner");
      const stranger = testUid("t12-stranger");
      const sid = await createSession(app, owner);

      const calls: Array<{ method: "GET" | "POST"; url: string }> = [
        { method: "GET", url: `/cloud/v1/sessions/${sid}/workspace/tree` },
        { method: "GET", url: `/cloud/v1/sessions/${sid}/workspace/file?path=a.txt` },
        { method: "POST", url: `/cloud/v1/sessions/${sid}/workspace/hydrate` },
        { method: "POST", url: `/cloud/v1/sessions/${sid}/workspace/hibernate` },
      ];
      for (const call of calls) {
        const res = await app.inject({
          method: call.method,
          url: call.url,
          headers: authHeaders(stranger),
        });
        expect(res.statusCode, call.url).toBe(404);
        expect(res.json().error.code).toBe("not_found");
      }
      // The stranger never reached the worker.
      expect(stub.requests).toEqual([]);

      for (const bad of ["not-a-uuid", "1234567"]) {
        const res = await app.inject({
          method: "GET",
          url: `/cloud/v1/sessions/${bad}/workspace/tree`,
          headers: authHeaders(owner),
        });
        expect(res.statusCode, bad).toBe(404);
      }

      // The PUT route, too (owner gate before body validation).
      const putStranger = await app.inject({
        method: "PUT",
        url: `/cloud/v1/sessions/${sid}/workspace/file`,
        headers: authHeaders(stranger),
        payload: { path: "a.txt", contentUtf8: "x" },
      });
      expect(putStranger.statusCode).toBe(404);
    });

    it("POST messages bumps the session activity key (best-effort, after the queue add)", async () => {
      const app = makeApp();
      const uid = testUid("t12-msg-bump");
      const sid = await createSession(app, uid);

      const res = await app.inject({
        method: "POST",
        url: `/cloud/v1/sessions/${sid}/messages`,
        headers: authHeaders(uid),
        payload: { content: "hello" },
      });
      expect(res.statusCode).toBe(202);
      expect(await redis.get(`${ACTIVITY_KEY_PREFIX}${sid}`)).not.toBeNull();
    });
  },
);

// ---------------------------------------------------------------------------
// env additions (pure — no services needed)
// ---------------------------------------------------------------------------

describe("gateway env additions", () => {
  const base: NodeJS.ProcessEnv = {
    NODE_ENV: "test",
    OVID_AUTH_MODE: "test",
    DATABASE_URL: "postgres://db",
    REDIS_Q_URL: "redis://q",
    REDIS_MINT_URL: "redis://m",
    OVID_INTERNAL_MINT_URL: "http://mint:8092",
  };

  it("test-mode defaults: empty worker url/token, 1 MiB inline, 8 MiB PUT, 3600 s ttl, 20 s wait, redisC falls back to redisQ", () => {
    const env = loadGatewayEnv({ ...base });
    expect(env.workerInternalUrl).toBe("");
    expect(env.internalToken).toBe("");
    expect(env.fileInlineMaxBytes).toBe(1_048_576);
    expect(env.putMaxBytes).toBe(8_388_608);
    expect(env.presignTtlSeconds).toBe(3600);
    expect(env.hydrateWaitMs).toBe(20_000);
    expect(env.redisCUrl).toBe("redis://q");
  });

  it("firebase mode requires OVID_WORKER_INTERNAL_URL then OVID_INTERNAL_TOKEN", () => {
    const firebase: NodeJS.ProcessEnv = { ...base, OVID_AUTH_MODE: "firebase" };
    expect(() => loadGatewayEnv(firebase)).toThrow(/OVID_WORKER_INTERNAL_URL/);
    expect(() =>
      loadGatewayEnv({ ...firebase, OVID_WORKER_INTERNAL_URL: "http://127.0.0.1:8091" }),
    ).toThrow(/OVID_INTERNAL_TOKEN/);
    const ok = loadGatewayEnv({
      ...firebase,
      OVID_WORKER_INTERNAL_URL: "http://127.0.0.1:8091",
      OVID_INTERNAL_TOKEN: "tok",
      OVID_INTERNAL_API_SECRET: "test-internal-secret-0123456789abcdef",
      // P5 Task 15: required in firebase mode (envelope sealing).
      OVID_MASTER_KEY: "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829",
      REDIS_C_URL: "redis://c",
      OVID_FILE_INLINE_MAX_BYTES: "2048",
      OVID_PUT_MAX_BYTES: "4096",
      OVID_PRESIGN_TTL_SECONDS: "650",
      OVID_HYDRATE_WAIT_MS: "1500",
    });
    expect(ok.workerInternalUrl).toBe("http://127.0.0.1:8091");
    expect(ok.internalToken).toBe("tok");
    expect(ok.redisCUrl).toBe("redis://c");
    expect(ok.fileInlineMaxBytes).toBe(2048);
    expect(ok.putMaxBytes).toBe(4096);
    expect(ok.presignTtlSeconds).toBe(650);
    expect(ok.hydrateWaitMs).toBe(1500);
  });

  it("OVID_PRESIGN_TTL_SECONDS clamps into 60..86400", () => {
    expect(loadGatewayEnv({ ...base, OVID_PRESIGN_TTL_SECONDS: "10" }).presignTtlSeconds).toBe(60);
    expect(loadGatewayEnv({ ...base, OVID_PRESIGN_TTL_SECONDS: "9999999" }).presignTtlSeconds).toBe(86_400);
  });

  it("byte/wait knobs reject non-positive-integers", () => {
    const cases: Array<[string, string]> = [
      ["OVID_FILE_INLINE_MAX_BYTES", "0"],
      ["OVID_PUT_MAX_BYTES", "-3"],
      ["OVID_HYDRATE_WAIT_MS", "1.5"],
      ["OVID_HYDRATE_WAIT_MS", "abc"],
    ];
    for (const [name, value] of cases) {
      expect(() => loadGatewayEnv({ ...base, [name]: value }), `${name}=${value}`).toThrow(name);
    }
  });
});
