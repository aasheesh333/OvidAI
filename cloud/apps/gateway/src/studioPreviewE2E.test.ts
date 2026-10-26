// EXECUTED Studio live-preview integration proof.
//
// Unlike studioPreviewGateway.test.ts (which fakes the worker HTTP boundary with
// app.inject), this suite composes the REAL worker route module behind a real
// listening Fastify server and lets the real gateway worker client reach it over
// loopback TCP with the real global fetch. The static content is a real file on
// disk read through the worker's real readStudioPreviewStatic path.
//
// Covered: management create/list, ticket mint, single-use exchange, cookie
// content read, CSP frame-ancestors, replay denial, terminal revocation, and the
// honest unavailable path when the worker has no preview routes at all.
import Fastify from "fastify";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";

import { registerStudioPreviewRoutes } from "../../worker/src/studioPreviewRoutes.js";
import type {
  StudioPreviewManager,
  StudioPreviewRecord,
} from "../../worker/src/studioPreview.js";
import { buildGateway } from "./app.js";
import {
  PREVIEW_COOKIE_NAME,
  createPreviewTicketStore,
  type PreviewTicketRedis,
} from "./studioPreviewTickets.js";
import { createStudioPreviewWorkerClient } from "./studioPreviewWorkerClient.js";
import type { StudioPreviewGatewayConfig } from "./studioPreviewGateway.js";
import {
  authHeaders,
  noopDb,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubVerifier,
} from "./test/stubs.js";

const UID = "preview-owner";
const SID = "00000000-0000-4000-8000-0000000000e2";
const PID = "0199aaaa-0000-7000-8000-0000000000e2";
const INTERNAL_TOKEN = "e2e-internal-token-never-public";
const PREVIEW_ORIGIN = "https://preview.example.test";
const WEB_ORIGIN = "https://web.example.test";
const API_BASE = `/cloud/v1/studio/sessions/${SID}/previews`;

const cleanups: Array<() => Promise<void> | void> = [];

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

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

/** A real manager-shaped object; only the DB is replaced, not the route code. */
function memoryManager(record: StudioPreviewRecord) {
  let current = record;
  const manager = {
    async start() { return current; },
    async stop() {
      current = { ...current, status: "stopped", endedAt: new Date().toISOString() };
      return current;
    },
    async get(ref: { id?: string }) {
      if (ref.id === undefined) return [current];
      return ref.id === current.id ? current : null;
    },
    async touch(req: { generation: number }) {
      return (await manager.touchDetailed(req)).record;
    },
    async touchDetailed(req: { generation: number }) {
      if (req.generation !== current.generation) return { touched: false, record: null };
      current = { ...current, lastAccessAt: new Date().toISOString() };
      return { touched: true, record: current };
    },
    async logs() { return { text: "e2e preview log\n", truncated: false }; },
    async sweep() { return 0; },
    async stopSession() { return 0; },
    async close() {},
  } satisfies StudioPreviewManager;
  return manager;
}

function staticRecord(workspacePath: string): StudioPreviewRecord {
  return {
    id: PID,
    sessionId: SID,
    userId: UID,
    generation: 3,
    kind: "static",
    workspacePath,
    projectDir: null,
    startScript: null,
    processId: null,
    processGroupId: null,
    workerEpoch: "e2e",
    bindHost: null,
    port: null,
    status: "running",
    createdAt: new Date().toISOString(),
    lastAccessAt: null,
    expiresAt: new Date(Date.now() + 15 * 60_000).toISOString(),
    endedAt: null,
    exitCode: null,
    failureCode: null,
    logBytes: null,
  };
}

/** The real worker app: the real route module, listening on loopback TCP. */
async function realWorker(previews: StudioPreviewManager | null) {
  const app = Fastify({ logger: false });
  if (previews !== null) {
    registerStudioPreviewRoutes(app, { internalToken: INTERNAL_TOKEN, previews });
  }
  await app.listen({ port: 0, host: "127.0.0.1" });
  cleanups.push(() => app.close());
  const address = app.server.address();
  if (address === null || typeof address === "string") throw new Error("worker did not bind");
  return { app, baseUrl: `http://127.0.0.1:${address.port}` };
}

async function gateway(workerBaseUrl: string) {
  const redis = new MemoryPreviewRedis();
  const now = () => new Date();
  const tickets = createPreviewTicketStore(redis, { now });
  const config: StudioPreviewGatewayConfig = {
    previewOrigin: PREVIEW_ORIGIN,
    webOrigin: WEB_ORIGIN,
    workerHost: "worker.internal",
    worker: createStudioPreviewWorkerClient({ baseUrl: workerBaseUrl, token: INTERNAL_TOKEN }),
    tickets,
    redis,
    now,
    isSessionOwner: async (userId, sessionId) => userId === UID && sessionId === SID,
  };
  const app = buildGateway({
    system: stubSystemBus(),
    db: noopDb,
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
    headers: {
      host: "preview.example.test",
      ...(cookie !== undefined ? { cookie } : {}),
    },
  });
  return { app, api, origin, redis };
}

async function workspaceIndex(html: string): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "ovid-preview-e2e-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  await writeFile(join(dir, "index.html"), html, "utf8");
  return dir;
}

describe("Studio live preview end to end (real worker HTTP, real gateway)", () => {
  it("serves a static preview: create, mint, single-use exchange, cookie content, CSP", async () => {
    const dir = await workspaceIndex("<h1>e2e preview body</h1>");
    const worker = await realWorker(memoryManager(staticRecord(dir)));
    const h = await gateway(worker.baseUrl);

    const created = await h.api("POST", API_BASE, { kind: "static", workspacePath: dir });
    expect(created.statusCode).toBe(201);
    expect(created.json()).toMatchObject({ id: PID, kind: "static", status: "running" });

    const list = await h.api("GET", API_BASE);
    expect(list.statusCode).toBe(200);
    expect(list.json().items).toHaveLength(1);

    const ticket = await h.api("POST", `${API_BASE}/${PID}/ticket`);
    expect(ticket.statusCode).toBe(200);
    const launch = new URL(ticket.json().launchUrl);
    expect(launch.origin).toBe(PREVIEW_ORIGIN);
    const ticketValue = launch.searchParams.get("ticket");
    expect(ticketValue).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const exchanged = await h.origin("GET", `${launch.pathname}${launch.search}`);
    expect(exchanged.statusCode).toBe(303);
    expect(exchanged.headers.location).toBe(`/preview/${PID}/`);
    const setCookie = String(exchanged.headers["set-cookie"]);
    expect(setCookie).toContain(`${PREVIEW_COOKIE_NAME}=`);
    expect(setCookie).toContain("HttpOnly");
    expect(setCookie).toContain("Secure");
    expect(setCookie).toContain("SameSite=Strict");
    expect(setCookie).not.toContain("Domain=");
    const cookie = `${PREVIEW_COOKIE_NAME}=${/__Host-ovid_preview=([A-Za-z0-9_-]{43})/.exec(setCookie)![1]}`;

    // Replaying the consumed ticket is a denial, not a second grant.
    const replay = await h.origin("GET", `${launch.pathname}${launch.search}`);
    expect(replay.statusCode).toBe(404);

    const content = await h.origin("GET", `/preview/${PID}/`, cookie);
    expect(content.statusCode).toBe(200);
    expect(content.body).toContain("e2e preview body");
    const csp = String(content.headers["content-security-policy"]);
    expect(csp).toContain(`frame-ancestors ${WEB_ORIGIN}`);
    expect(csp).toContain("script-src 'none'");
    expect(content.headers["cache-control"]).toBe("private, no-store");

    // No cookie, and a wrong host, are both refusals.
    expect((await h.origin("GET", `/preview/${PID}/`)).statusCode).toBe(404);
    const wrongHost = await h.app.inject({
      method: "GET",
      url: `/preview/${PID}/`,
      headers: { host: "api.example.test", cookie },
    });
    expect(wrongHost.statusCode).toBe(404);

    // A cookie grant is bound to one preview id: a sibling id cannot borrow it.
    const otherPid = "0199aaaa-0000-7000-8000-0000000000e3";
    expect((await h.origin("GET", `/preview/${otherPid}/`, cookie)).statusCode).toBe(404);

    // HMR/WebSocket upgrades are refused before any grant is consumed.
    const hmr = await h.app.inject({
      method: "GET",
      url: `/preview/${PID}/@vite/client`,
      headers: {
        host: "preview.example.test",
        cookie,
        connection: "Upgrade",
        upgrade: "websocket",
      },
    });
    expect(hmr.statusCode).toBe(501);
    expect(hmr.json().error.code).toBe("preview_hmr_unavailable");

    // A static preview never serves a path outside its workspace.
    const escape = await h.origin("GET", `/preview/${PID}/../../etc/passwd`, cookie);
    expect([400, 404]).toContain(escape.statusCode);
    expect(escape.body).not.toContain("root:");

    // Stop revokes content access without any client-side trust.
    expect((await h.api("POST", `${API_BASE}/${PID}/stop`)).statusCode).toBe(200);
    expect((await h.origin("GET", `/preview/${PID}/`, cookie)).statusCode).toBe(404);
  });

  it("answers the honest unavailable path when the worker has no preview routes", async () => {
    const worker = await realWorker(null);
    const h = await gateway(worker.baseUrl);

    const list = await h.api("GET", API_BASE);
    expect(list.statusCode).toBe(404);
    expect(list.json().error.code).toBe("not_found");

    const created = await h.api("POST", API_BASE, { kind: "static", workspacePath: "/tmp/x" });
    expect(created.statusCode).toBe(404);

    // The dedicated origin never fabricates a grant when no worker route exists.
    const exchanged = await h.origin("GET", "/preview/exchange?ticket=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    expect(exchanged.statusCode).toBe(404);
  });

  it("refuses worker calls without the internal token", async () => {
    const dir = await workspaceIndex("<h1>guarded</h1>");
    const worker = await realWorker(memoryManager(staticRecord(dir)));
    const response = await fetch(`${worker.baseUrl}/internal/sessions/${SID}/previews`, {
      headers: { "x-ovid-user-id": UID },
    });
    expect(response.status).toBe(401);
  });
});
