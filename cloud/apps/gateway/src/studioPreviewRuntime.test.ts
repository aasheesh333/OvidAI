// EXECUTED Studio live-preview RUNTIME chain proof.
//
// Composition: real gateway -> real worker routes over loopback TCP -> REAL
// StudioPreviewManager -> REAL Postgres store (migration 0041 applied to a
// throwaway database) -> real static file bytes on disk.
//
// Only the OS jail is substituted: the process runner is an in-memory stand-in,
// because spawning bwrap/cgroup leaves on a host that also runs the live worker
// is not a safe thing for a verification run to do. Everything above that seam
// is the production code path.
//
// Skipped unless TEST_DATABASE_URL is set (same gate as the db package suites).
import Fastify from "fastify";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { createDb, migrate } from "@ovid/db";
import {
  createStudioPreviewStore,
  createStudioPreviewPostgresStore,
} from "@ovid/db";
import { registerStudioPreviewRoutes } from "../../worker/src/studioPreviewRoutes.js";
import {
  createStudioPreviewManager,
  type StudioPreviewProcess,
  type StudioPreviewProcessRunner,
} from "../../worker/src/studioPreview.js";
import { buildGateway } from "./app.js";
import {
  createPreviewTicketStore,
  type PreviewTicketRedis,
} from "./studioPreviewTickets.js";
import { createStudioPreviewWorkerClient } from "./studioPreviewWorkerClient.js";
import type { StudioPreviewGatewayConfig } from "./studioPreviewGateway.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubVerifier,
} from "./test/stubs.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const UID = "preview-runtime-owner";
const SID = "00000000-0000-4000-8000-0000000000f1";
const INTERNAL_TOKEN = "runtime-internal-token-never-public";
const PREVIEW_ORIGIN = "https://preview.example.test";
const WEB_ORIGIN = "https://web.example.test";
const API_BASE = `/cloud/v1/studio/sessions/${SID}/previews`;

const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
}, 30_000);

class MemoryPreviewRedis implements PreviewTicketRedis {
  private readonly values = new Map<string, string>();
  async set(key: string, value: string): Promise<string> {
    this.values.set(key, value);
    return "OK";
  }
  async get(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }
  async call(_command: "GETDEL", key: string): Promise<string | null> {
    const value = this.values.get(key) ?? null;
    this.values.delete(key);
    return value;
  }
}

/** The OS-jail seam only: no bwrap, no cgroup, no child process. */
function fakeRunner(): StudioPreviewProcessRunner {
  const killed: string[] = [];
  return {
    async spawn(request): Promise<StudioPreviewProcess> {
      const callbacks: Array<(code: number | null) => void> = [];
      return {
        processId: 4242,
        processGroupId: `/sys/fs/cgroup/fake/preview-${request.previewId}`,
        onExit(callback) { callbacks.push(callback); },
        async kill() {
          killed.push(request.previewId);
          for (const callback of callbacks.splice(0)) callback(0);
        },
      };
    },
    async killStale() {},
  };
}

describe.skipIf(!TEST_DATABASE_URL)("Studio live preview runtime chain (real manager + real Postgres)", () => {
  it("runs create -> list -> ticket -> exchange -> content -> stop through the real stack", async () => {
    const database = `preview_runtime_${process.pid}_${Date.now()}`;
    const admin = createDb(`${TEST_DATABASE_URL!.replace(/\/[^/]*$/, "")}/postgres`);
    await admin.$client.unsafe(`CREATE DATABASE "${database}"`);
    const url = `${TEST_DATABASE_URL!.replace(/\/[^/]*$/, "")}/${database}`;
    cleanups.push(async () => {
      await admin.$client.end({ timeout: 5 });
      const cleanup = createDb(`${TEST_DATABASE_URL!.replace(/\/[^/]*$/, "")}/postgres`);
      await cleanup.$client.unsafe(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`).catch(() => {});
      await cleanup.$client.end({ timeout: 5 });
    });
    await migrate(url);
    const db = createDb(url);
    cleanups.push(() => db.$client.end({ timeout: 5 }));

    // The session and user rows the 0041 FKs require.
    await db.$client`INSERT INTO users (uid, email) VALUES (${UID}, ${`${UID}@runtime.test`})`;
    await db.$client`
      INSERT INTO sessions (id, user_id, title, mode)
      VALUES (${SID}, ${UID}, 'runtime preview', 'studio')`;

    const workspace = await mkdtemp(join(tmpdir(), "ovid-preview-runtime-"));
    cleanups.push(() => rm(workspace, { recursive: true, force: true }));
    await mkdir(join(workspace, "site"), { recursive: true });
    await writeFile(join(workspace, "site", "index.html"), "<h1>runtime chain</h1>", "utf8");

    const store = createStudioPreviewStore(createStudioPreviewPostgresStore(db));
    const previews = createStudioPreviewManager({
      store,
      manager: {
        attach: async (userId: string) => ({
          userId,
          uid: 20001,
          workspaceDir: workspace,
          homeDir: join(workspace, "..", "home"),
          jailWorkspaceDir: "/workspace",
        }),
        workspaceDir: workspace,
      } as never,
      binding: { get: async () => null },
      redact: (text: string) => text,
      workerEpoch: "runtime-epoch",
      processes: fakeRunner(),
      probe: async () => true,
      sleep: async () => {},
    });
    cleanups.push(() => previews.close());

    const workerApp = Fastify({ logger: false });
    registerStudioPreviewRoutes(workerApp, { internalToken: INTERNAL_TOKEN, previews });
    await workerApp.listen({ port: 0, host: "127.0.0.1" });
    cleanups.push(() => workerApp.close());
    const address = workerApp.server.address();
    if (address === null || typeof address === "string") throw new Error("worker did not bind");
    const workerBaseUrl = `http://127.0.0.1:${address.port}`;

    const redis = new MemoryPreviewRedis();
    const now = () => new Date();
    const config: StudioPreviewGatewayConfig = {
      previewOrigin: PREVIEW_ORIGIN,
      webOrigin: WEB_ORIGIN,
      workerHost: "worker.internal",
      worker: createStudioPreviewWorkerClient({ baseUrl: workerBaseUrl, token: INTERNAL_TOKEN }),
      tickets: createPreviewTicketStore(redis, { now }),
      redis,
      now,
      isSessionOwner: async (userId, sessionId) => userId === UID && sessionId === SID,
    };
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: { mint: async () => "ws-ticket", verify: async () => null },
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      clock: now,
      studioPreview: config,
    });
    cleanups.push(() => app.close());

    const api = (method: "GET" | "POST", url: string, payload?: unknown) => app.inject({
      method,
      url,
      headers: { ...authHeaders(UID), host: "api.example.test" },
      ...(payload !== undefined ? { payload } : {}),
    });
    const origin = (method: "GET" | "HEAD", url: string, cookie?: string) => app.inject({
      method,
      url,
      headers: { host: "preview.example.test", ...(cookie !== undefined ? { cookie } : {}) },
    });

    const created = await api("POST", API_BASE, { kind: "static", workspacePath: "site" });
    expect(created.statusCode).toBe(201);
    const previewId = created.json().id as string;
    expect(created.json()).toMatchObject({ kind: "static", status: "running", generation: 1 });

    const listed = await api("GET", API_BASE);
    expect(listed.statusCode).toBe(200);
    expect(listed.json().items.map((item: { id: string }) => item.id)).toEqual([previewId]);

    const ticket = await api("POST", `${API_BASE}/${previewId}/ticket`);
    expect(ticket.statusCode).toBe(200);
    const launch = new URL(ticket.json().launchUrl);
    expect(launch.origin).toBe(PREVIEW_ORIGIN);

    const exchanged = await origin("GET", `${launch.pathname}${launch.search}`);
    expect(exchanged.statusCode).toBe(303);
    const setCookie = String(exchanged.headers["set-cookie"]);
    const cookie = `__Host-ovid_preview=${/__Host-ovid_preview=([A-Za-z0-9_-]{43})/.exec(setCookie)![1]}`;

    const content = await origin("GET", `/preview/${previewId}/`, cookie);
    expect(content.statusCode).toBe(200);
    expect(content.body).toContain("runtime chain");

    // The real Postgres row was touched and is still the same generation.
    const [row] = await db.$client<{ status: string; generation: string; last_access_at: Date | null }[]>`
      SELECT status, generation, last_access_at FROM studio_previews WHERE id = ${previewId}`;
    expect(row.status).toBe("running");
    expect(Number(row.generation)).toBe(1);
    expect(row.last_access_at).not.toBeNull();

    const stopped = await api("POST", `${API_BASE}/${previewId}/stop`);
    expect(stopped.statusCode).toBe(200);
    expect(stopped.json().status).toBe("stopped");
    expect((await origin("GET", `/preview/${previewId}/`, cookie)).statusCode).toBe(404);
  }, 120_000);

  it("refuses a dev-server preview with no repository binding as 409 no_repo", async () => {
    const database = `preview_runtime_dev_${process.pid}_${Date.now()}`;
    const base = TEST_DATABASE_URL!.replace(/\/[^/]*$/, "");
    const admin = createDb(`${base}/postgres`);
    await admin.$client.unsafe(`CREATE DATABASE "${database}"`);
    const url = `${base}/${database}`;
    cleanups.push(async () => {
      await admin.$client.end({ timeout: 5 });
      const cleanup = createDb(`${base}/postgres`);
      await cleanup.$client.unsafe(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`).catch(() => {});
      await cleanup.$client.end({ timeout: 5 });
    });
    await migrate(url);
    const db = createDb(url);
    cleanups.push(() => db.$client.end({ timeout: 5 }));
    await db.$client`INSERT INTO users (uid, email) VALUES (${UID}, ${`${UID}@runtime.test`})`;
    await db.$client`
      INSERT INTO sessions (id, user_id, title, mode)
      VALUES (${SID}, ${UID}, 'runtime preview', 'studio')`;

    const workspace = await mkdtemp(join(tmpdir(), "ovid-preview-runtime-dev-"));
    cleanups.push(() => rm(workspace, { recursive: true, force: true }));
    await mkdir(join(workspace, "app"), { recursive: true });
    await writeFile(join(workspace, "app", "package.json"), JSON.stringify({ scripts: { dev: "vite" } }), "utf8");

    const previews = createStudioPreviewManager({
      store: createStudioPreviewStore(createStudioPreviewPostgresStore(db)),
      manager: {
        attach: async (userId: string) => ({
          userId,
          uid: 20002,
          workspaceDir: workspace,
          homeDir: join(workspace, "..", "home"),
          jailWorkspaceDir: "/workspace",
        }),
        workspaceDir: workspace,
      } as never,
      binding: { get: async () => null },
      redact: (text: string) => text,
      workerEpoch: "runtime-epoch",
      processes: fakeRunner(),
      probe: async () => true,
      sleep: async () => {},
    });
    cleanups.push(() => previews.close());

    const workerApp = Fastify({ logger: false });
    registerStudioPreviewRoutes(workerApp, { internalToken: INTERNAL_TOKEN, previews });
    await workerApp.listen({ port: 0, host: "127.0.0.1" });
    cleanups.push(() => workerApp.close());
    const address = workerApp.server.address();
    if (address === null || typeof address === "string") throw new Error("worker did not bind");

    const redis = new MemoryPreviewRedis();
    const now = () => new Date();
    const app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: { mint: async () => "ws-ticket", verify: async () => null },
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      clock: now,
      studioPreview: {
        previewOrigin: PREVIEW_ORIGIN,
        webOrigin: WEB_ORIGIN,
        workerHost: "worker.internal",
        worker: createStudioPreviewWorkerClient({
          baseUrl: `http://127.0.0.1:${address.port}`,
          token: INTERNAL_TOKEN,
        }),
        tickets: createPreviewTicketStore(redis, { now }),
        redis,
        now,
        isSessionOwner: async (userId, sessionId) => userId === UID && sessionId === SID,
      } satisfies StudioPreviewGatewayConfig,
    });
    cleanups.push(() => app.close());

    const created = await app.inject({
      method: "POST",
      url: API_BASE,
      headers: { ...authHeaders(UID), host: "api.example.test" },
      payload: { kind: "dev_server", projectDir: "app", script: "dev" },
    });
    expect(created.statusCode).toBe(409);
    expect(created.json().error.code).toBe("no_repo");
  }, 120_000);
});
