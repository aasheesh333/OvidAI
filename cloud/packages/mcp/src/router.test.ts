/**
 * McpRouter — the central P5 surface. Gated on TEST_DATABASE_URL like the
 * other DB-backed mcp suites (idempotent migrate only: parallel P5 lanes share
 * this dev Postgres and this file never needs a from-scratch journal re-run).
 *
 * Fakes: spawner (canned stdio JSON-RPC server), workspace, system bus, and a
 * fetch that serves BOTH the curated fetch handler's HTML GETs and a scripted
 * Streamable-HTTP MCP server's JSON-RPC POSTs.
 */

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate } from "../../db/src/client.js";
import { mcpServers } from "../../db/src/repos.js";
import { users } from "../../db/src/schema.js";
import { createCuratedCatalog } from "./catalog.js";
import { createEnvelopeCrypto } from "./crypto.js";
import { createFetchHandler } from "./native/fetch.js";
import {
  PRO_REQUIRED_MESSAGE,
  ProRequiredError,
  createMcpRouter,
  isCurated,
  type McpRouter,
  type McpRouterDeps,
  type RunContext,
} from "./router.js";
import type { GuardedFetch } from "./ssrf.js";
import type { UserSystemBus, SystemEventKind, SystemResponse } from "./systemBus.js";
import type { SandboxSpawner, SandboxedProcess } from "./transports/stdio.js";
import { canonicalToolId, toolNameFor } from "./toolNames.js";
import type { WorkspaceFiles } from "./workspace.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

const RUN1: RunContext = { sessionId: "session-1", runId: "run-1" };
const RUN2: RunContext = { sessionId: "session-1", runId: "run-2" };
const RUN3: RunContext = { sessionId: "session-1", runId: "run-3" };

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const workspace: WorkspaceFiles = {
  async read() {
    return null;
  },
  async write() {},
  async list() {
    return [];
  },
  async stat() {
    return null;
  },
  async remove() {},
};

interface SpawnCall {
  uid: string;
  spec: { command: string; args: string[]; env?: Record<string, string>; cwd?: string };
}

interface FakeToolDef {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

let procSeq = 0;

/** A canned stdio MCP server: answers initialize/tools/list/tools/call and
 *  can emit one server→client request during tools/call. */
class FakeStdioProcess implements SandboxedProcess {
  readonly id = `proc-${++procSeq}`;
  readonly pid = 10_000 + procSeq;
  killed = false;
  lines: string[] = [];
  /** Client→server RESPONSES (the server-request answers under test). */
  serverResponses: { id: number | string; result?: unknown; error?: { code: number; message: string } }[] = [];
  private stdoutCb: ((line: string) => void) | undefined;
  private exitCb: ((code: number | null) => void) | undefined;

  constructor(
    private readonly tools: FakeToolDef[],
    private readonly serverRequest: "sampling" | "elicitation" | null,
  ) {}

  writeLine(line: string): void {
    this.lines.push(line);
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    if (msg.method === undefined && msg.id !== undefined) {
      this.serverResponses.push(msg as never);
      return;
    }
    switch (msg.method) {
      case "initialize":
        this.respond(msg.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "fake-stdio", version: "1.0.0" },
        });
        return;
      case "tools/list":
        this.respond(msg.id, { tools: this.tools });
        return;
      case "tools/call": {
        if (this.serverRequest === "sampling") {
          this.emit({
            jsonrpc: "2.0",
            id: 900,
            method: "sampling/createMessage",
            params: {
              messages: [{ role: "user", content: { type: "text", text: "hello there" } }],
              maxTokens: 64,
            },
          });
        } else if (this.serverRequest === "elicitation") {
          this.emit({
            jsonrpc: "2.0",
            id: 901,
            method: "elicitation/create",
            params: {
              message: "Your name?",
              requestedSchema: {
                type: "object",
                properties: { name: { type: "string" } },
                required: ["name"],
              },
            },
          });
        }
        const params = (msg.params ?? {}) as Record<string, unknown>;
        this.respond(msg.id, {
          content: [{ type: "text", text: `ok:${String(params.name ?? "")}` }],
          isError: false,
        });
        return;
      }
      default:
        return; // notifications/initialized etc.
    }
  }

  private respond(id: unknown, result: unknown): void {
    queueMicrotask(() => this.emit({ jsonrpc: "2.0", id, result }));
  }

  private emit(obj: unknown): void {
    this.stdoutCb?.(JSON.stringify(obj));
  }

  onStdoutLine(cb: (line: string) => void): void {
    this.stdoutCb = cb;
  }

  onExit(cb: (code: number | null) => void): void {
    this.exitCb = cb;
  }

  async kill(): Promise<void> {
    if (this.killed) return;
    this.killed = true;
    this.exitCb?.(0);
  }

  /** An exit the client did not ask for (reconnector territory). */
  unexpectedExit(): void {
    this.exitCb?.(1);
  }
}

class FakeSpawner implements SandboxSpawner {
  calls: SpawnCall[] = [];
  processes: FakeStdioProcess[] = [];
  tools: FakeToolDef[] = [
    { name: "echo", description: "Echo a value.", inputSchema: { type: "object" } },
    { name: "search", description: "Search.", inputSchema: { type: "object" } },
  ];
  serverRequest: "sampling" | "elicitation" | null = null;

  async spawn(
    uid: string,
    spec: { command: string; args: string[]; env?: Record<string, string>; cwd?: string },
  ): Promise<SandboxedProcess> {
    this.calls.push({ uid, spec });
    const proc = new FakeStdioProcess(this.tools, this.serverRequest);
    this.processes.push(proc);
    return proc;
  }
}

interface FetchCall {
  url: string;
  init: RequestInit | undefined;
}

function jsonResponse(obj: unknown, status = 200): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Serves curated-fetch HTML GETs and scripted MCP JSON-RPC POSTs. */
class FakeMcpFetch {
  calls: FetchCall[] = [];
  toolsByUrl = new Map<string, FakeToolDef[]>();
  /** POSTs to these URLs answer 401 (OAuth required). */
  unauthorized = new Set<string>();
  readonly impl: GuardedFetch = async (url, init) => {
    this.calls.push({ url, init });
    const method = init?.method ?? "GET";
    if (method !== "POST") {
      return new Response("<html><body><h1>Hello</h1><p>page body</p></body></html>", {
        status: 200,
        headers: { "content-type": "text/html" },
      });
    }
    if (this.unauthorized.has(url)) {
      return new Response(null, {
        status: 401,
        headers: { "www-authenticate": 'Bearer realm="mcp"' },
      });
    }
    const body = JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>;
    if (body.id === undefined) return new Response(null, { status: 202 });
    const tools = this.toolsByUrl.get(url) ?? [
      { name: "echo", description: "Echo." },
      { name: "search", description: "Search." },
    ];
    switch (body.method) {
      case "initialize":
        return jsonResponse({
          jsonrpc: "2.0",
          id: body.id,
          result: {
            protocolVersion: "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "fake-http", version: "1.0.0" },
          },
        });
      case "tools/list":
        return jsonResponse({ jsonrpc: "2.0", id: body.id, result: { tools } });
      case "tools/call": {
        const params = (body.params ?? {}) as Record<string, unknown>;
        return jsonResponse({
          jsonrpc: "2.0",
          id: body.id,
          result: {
            content: [{ type: "text", text: `ok:${String(params.name ?? "")}` }],
            isError: false,
          },
        });
      }
      default:
        return jsonResponse({
          jsonrpc: "2.0",
          id: body.id,
          error: { code: -32601, message: "method not found" },
        });
    }
  };

  /** POST initialize count for one server URL. */
  initCount(url: string): number {
    return this.calls.filter((c) => {
      if (c.url !== url || (c.init?.method ?? "GET") !== "POST") return false;
      try {
        return (JSON.parse(String(c.init?.body ?? "{}")) as { method?: string }).method === "initialize";
      } catch {
        return false;
      }
    }).length;
  }

  /** GET count (the curated fetch handler's egress). */
  getCount(): number {
    return this.calls.filter((c) => (c.init?.method ?? "GET") !== "POST").length;
  }
}

interface BusRequest {
  uid: string;
  kind: SystemEventKind;
  payload: Record<string, unknown>;
}

class FakeBus implements UserSystemBus {
  requests: BusRequest[] = [];
  published: { uid: string; kind: SystemEventKind; payload: Record<string, unknown> }[] = [];
  reply: ((kind: SystemEventKind, payload: Record<string, unknown>) => SystemResponse | null) | null =
    null;

  async publish(
    uid: string,
    event: { kind: SystemEventKind; requiresResponse?: boolean; payload: Record<string, unknown>; ts?: string },
  ): Promise<void> {
    this.published.push({ uid, kind: event.kind, payload: event.payload });
  }

  async request(
    uid: string,
    kind: SystemEventKind,
    payload: Record<string, unknown>,
  ): Promise<SystemResponse | null> {
    this.requests.push({ uid, kind, payload });
    return this.reply === null ? null : this.reply(kind, payload);
  }

  async close(): Promise<void> {}
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(cond: () => boolean, what: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(10);
  }
}

// ---------------------------------------------------------------------------
// Router harness
// ---------------------------------------------------------------------------

// Module-scope because the harness runs inside the gated describe but the
// factories must see the DB/crypto initialized by its beforeAll.
let db: ReturnType<typeof createDb>;
let crypto: ReturnType<typeof createEnvelopeCrypto>;
const routers: McpRouter[] = [];

function makeRouter(over: Partial<McpRouterDeps> = {}): McpRouter {
  const fetchImpl = over.fetchImpl ?? new FakeMcpFetch().impl;
  const catalog =
    over.catalog ??
    createCuratedCatalog({
      fetchImpl,
      workspace,
    });
  const router = createMcpRouter({
    db,
    crypto,
    catalog,
    systemBus: new FakeBus(),
    spawner: new FakeSpawner(),
    workspace,
    fetchImpl,
    oauth: {
      getAccessToken: async () => null,
      start: async () => ({ authorizeUrl: "" }),
    },
    ...over,
  });
  routers.push(router);
  return router;
}

describe.skipIf(!TEST_DATABASE_URL)("McpRouter", () => {
  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    await migrate(url);
    db = createDb(url);
    crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  }, 60_000);

  afterEach(async () => {
    while (routers.length > 0) await routers.pop()!.shutdown().catch(() => {});
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  function testUid(prefix: string): string {
    return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  }

  async function seedUser(tier: "free" | "pro" = "free"): Promise<string> {
    const uid = testUid("mcprouter");
    await db.insert(users).values({ uid, email: `u-${uid.slice(0, 16)}@test.local`, tier });
    return uid;
  }

  async function setTier(uid: string, tier: "free" | "pro"): Promise<void> {
    // Raw parameterized SQL: drizzle-orm is not a dependency of @ovid/mcp, so
    // the test cannot import its query builder (the repos module resolves it
    // from inside @ovid/db, which is why the repo calls below are fine).
    await db.$client.unsafe("UPDATE users SET tier = $1 WHERE uid = $2", [tier, uid]);
  }

  async function addHttpServer(
    router: McpRouter,
    uid: string,
    name: string,
    url = `https://${name}.mcp.test/rpc`,
  ) {
    return router.addServer(uid, {
      imported: { name, transport: "http", url },
    });
  }

  async function addStdioServer(router: McpRouter, uid: string, name: string, env?: Record<string, string>) {
    return router.addServer(uid, {
      imported: { name, transport: "stdio", command: "node", args: ["server.js"], env },
    });
  }

  // -------------------------------------------------------------------------
  // Tier gate
  // -------------------------------------------------------------------------

  it("free user addServer(custom http) throws ProRequiredError with code pro_required", async () => {
    const uid = await seedUser("free");
    const router = makeRouter();

    const attempt = router.addServer(uid, {
      imported: { name: "custom-http", transport: "http", url: "https://mcp.test/rpc" },
    });
    await expect(attempt).rejects.toBeInstanceOf(ProRequiredError);
    await attempt.catch((err: unknown) => {
      expect((err as ProRequiredError).code).toBe("pro_required");
      expect((err as Error).message).toBe(PRO_REQUIRED_MESSAGE);
    });
    // nothing was persisted
    expect(await mcpServers.findByName(db, uid, "custom-http")).toBeNull();
  });

  it("free user callTool on a hand-inserted custom row throws ProRequiredError (router-level gate)", async () => {
    const uid = await seedUser("free");
    // Hand-inserted, bypassing addServer entirely — Review Focus 3: the gate
    // lives in the router, not in REST.
    const row = await mcpServers.create(db, {
      userId: uid,
      name: "hand-inserted",
      transport: "http",
      config: { url: "https://hand.mcp.test/rpc", type: "http" },
    });
    const fakeFetch = new FakeMcpFetch();
    const router = makeRouter({ fetchImpl: fakeFetch.impl });

    const published = toolNameFor("hand-inserted", "search");
    const attempt = router.callTool(uid, published, {}, RUN1);
    await expect(attempt).rejects.toBeInstanceOf(ProRequiredError);
    // Canonical ids are gated too.
    await expect(
      router.callTool(uid, canonicalToolId(row.id, "search"), {}, RUN1),
    ).rejects.toBeInstanceOf(ProRequiredError);
    // …and the gate refused BEFORE any network egress.
    expect(fakeFetch.calls).toHaveLength(0);
  });

  it("pro downgrade mid-session: next callTool throws and the custom connection is torn down", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    const router = makeRouter({ spawner });
    await addStdioServer(router, uid, "downgrade-srv");

    await router.connectForRun(uid, RUN1);
    expect(spawner.processes).toHaveLength(1);
    expect(spawner.processes[0]!.killed).toBe(false);

    await setTier(uid, "free");
    await expect(
      router.callTool(uid, toolNameFor("downgrade-srv", "echo"), {}, RUN1),
    ).rejects.toBeInstanceOf(ProRequiredError);
    expect(spawner.processes[0]!.killed).toBe(true);
  });

  it("curated works for free users; curated addServer is not tier-gated", async () => {
    const uid = await seedUser("free");
    const fakeFetch = new FakeMcpFetch();
    const router = makeRouter({ fetchImpl: fakeFetch.impl });

    const summary = await router.addServer(uid, { curatedId: "github" });
    expect(summary.curatedId).toBe("github");
    expect(summary.name).toBe("github");
    expect(isCurated(summary)).toBe(true);
    await expect(router.addServer(uid, { curatedId: "github" })).rejects.toThrow("server_exists");

    const result = await router.callTool(uid, "mcp__fetch__fetch", { url: "https://example.test/page" }, RUN1);
    expect(result.isError).toBe(false);
    expect(result.text).toContain("Hello");
    expect(fakeFetch.getCount()).toBe(1);
  });

  it("curated credential rows: update seals secrets; remove deletes only the row", async () => {
    const uid = await seedUser("free");
    const router = makeRouter();
    const added = await router.addServer(uid, { curatedId: "github" });

    const updated = await router.updateServer(uid, added.id, {
      secrets: { GITHUB_TOKEN: "ghp_secret_value" },
    });
    expect(updated.hasSecrets).toBe(true);
    // The summary never carries secret material.
    expect(JSON.stringify(updated)).not.toContain("ghp_secret_value");
    const stored = await mcpServers.get(db, added.id, uid);
    expect(JSON.stringify(stored?.secretsSealed)).not.toContain("ghp_secret_value");

    await router.removeServer(uid, added.id);
    expect(await mcpServers.get(db, added.id, uid)).toBeNull();
    // The curated catalog entry itself survives — only credentials were deleted.
    const servers = await router.listServers(uid);
    const github = servers.find((s) => s.curatedId === "github")!;
    expect(github.id).toBe("curated:github");
    expect(github.hasSecrets).toBe(false);
  });

  // -------------------------------------------------------------------------
  // Listings + resolution
  // -------------------------------------------------------------------------

  it("listServers merges 20 curated entries with the user's custom rows", async () => {
    const uid = await seedUser("pro");
    const router = makeRouter();
    await addHttpServer(router, uid, "acme");

    const servers = await router.listServers(uid);
    expect(servers.filter((s) => s.curatedId !== null)).toHaveLength(20);
    const fetchSummary = servers.find((s) => s.curatedId === "fetch")!;
    expect(fetchSummary).toMatchObject({
      id: "curated:fetch",
      name: "fetch",
      transport: "native",
      enabled: true,
      hasSecrets: false,
      status: "disconnected",
    });
    const custom = servers.find((s) => s.curatedId === null)!;
    expect(custom).toMatchObject({ name: "acme", transport: "http", hasSecrets: false });
  });

  it("listTools merges curated + custom with published names; custom hidden for free", async () => {
    const uid = await seedUser("pro");
    const fakeFetch = new FakeMcpFetch();
    fakeFetch.toolsByUrl.set("https://acme.mcp.test/rpc", [
      { name: "search", description: "Search the ACME corpus.", inputSchema: { type: "object" } },
      { name: "only", description: "A unique tool." },
    ]);
    const router = makeRouter({ fetchImpl: fakeFetch.impl });
    const custom = await addHttpServer(router, uid, "acme");

    const listings = await router.listTools(uid, RUN1);
    const curatedFetch = listings.find((l) => l.name === "mcp__fetch__fetch")!;
    expect(curatedFetch).toMatchObject({
      canonicalId: "mcp:curated:fetch/fetch",
      serverId: "curated:fetch",
      curatedId: "fetch",
    });
    const customSearch = listings.find((l) => l.name === "mcp__acme__search")!;
    expect(customSearch).toMatchObject({
      canonicalId: `mcp:${custom.id}/search`,
      serverId: custom.id,
      curatedId: null,
      description: "Search the ACME corpus.",
    });
    expect(customSearch.inputSchema).toEqual({ type: "object" });

    // Free: curated remains, custom disappears (no custom connection is made).
    await setTier(uid, "free");
    const freeListings = await router.listTools(uid, RUN1);
    expect(freeListings.some((l) => l.name === "mcp__fetch__fetch")).toBe(true);
    expect(freeListings.some((l) => l.name.startsWith("mcp__acme__"))).toBe(false);
  });

  it("resolveTool: exact published name → canonicalId → unique bare alias; ambiguous/unknown → null", async () => {
    const uid = await seedUser("pro");
    const fakeFetch = new FakeMcpFetch();
    fakeFetch.toolsByUrl.set("https://a.mcp.test/rpc", [{ name: "search" }]);
    fakeFetch.toolsByUrl.set("https://b.mcp.test/rpc", [{ name: "search" }, { name: "only" }]);
    const router = makeRouter({ fetchImpl: fakeFetch.impl });
    const a = await addHttpServer(router, uid, "a");
    const b = await addHttpServer(router, uid, "b");

    const exact = await router.resolveTool(uid, "mcp__a__search");
    expect(exact?.server.id).toBe(a.id);
    expect(exact?.listing.name).toBe("mcp__a__search");

    const canonical = await router.resolveTool(uid, canonicalToolId(a.id, "search"));
    expect(canonical?.server.id).toBe(a.id);

    const alias = await router.resolveTool(uid, "only");
    expect(alias?.server.id).toBe(b.id);

    // Two servers expose "search": the bare alias is ambiguous → null.
    expect(await router.resolveTool(uid, "search")).toBeNull();
    // Exact published names still resolve.
    expect((await router.resolveTool(uid, "mcp__b__search"))?.server.id).toBe(b.id);

    expect(await router.resolveTool(uid, "mcp__a__nope")).toBeNull();
    expect(await router.resolveTool(uid, "totally_unknown")).toBeNull();
  });

  it("McpAuthRequiredError during connect marks needs_auth without failing the run", async () => {
    const uid = await seedUser("pro");
    const fakeFetch = new FakeMcpFetch();
    const url = "https://auth.mcp.test/rpc";
    fakeFetch.unauthorized.add(url);
    const router = makeRouter({ fetchImpl: fakeFetch.impl });
    await addHttpServer(router, uid, "auth-srv", url);

    // connectForRun swallows the per-server auth failure; Task 15's REST
    // route reads needs_auth and starts the OAuth flow.
    await router.connectForRun(uid, RUN1);
    const summary = (await router.listServers(uid)).find((s) => s.name === "auth-srv")!;
    expect(summary.status).toBe("needs_auth");
    expect(fakeFetch.initCount(url)).toBe(1);
  });

  // -------------------------------------------------------------------------
  // Per-run lifecycle
  // -------------------------------------------------------------------------

  it("connectForRun spawns stdio with the decrypted env; the secret never reaches the bus", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    const bus = new FakeBus();
    const router = makeRouter({ spawner, systemBus: bus });
    const secret = "s3cr3t-env-value-4f7c";
    await addStdioServer(router, uid, "stdio-srv", { API_TOKEN: secret });

    await router.connectForRun(uid, RUN1);
    expect(spawner.calls).toHaveLength(1);
    expect(spawner.calls[0]!.spec.env).toEqual({ API_TOKEN: secret });

    // Hygiene: the plaintext secret is never published anywhere.
    expect(JSON.stringify(bus.published)).not.toContain(secret);
    expect(JSON.stringify(bus.requests)).not.toContain(secret);
  });

  it("releaseRun kills the run's stdio process", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    const router = makeRouter({ spawner });
    await addStdioServer(router, uid, "stdio-srv");

    await router.connectForRun(uid, RUN1);
    expect(spawner.processes[0]!.killed).toBe(false);
    await router.releaseRun(uid, RUN1);
    expect(spawner.processes[0]!.killed).toBe(true);
  });

  it("http client is cached between runs and evicted after idleTtl", async () => {
    const uid = await seedUser("pro");
    let nowMs = 1_000_000;
    const fakeFetch = new FakeMcpFetch();
    const url = "https://cache.mcp.test/rpc";
    const router = makeRouter({
      fetchImpl: fakeFetch.impl,
      idleTtlMs: 1000,
      now: () => new Date(nowMs),
    });
    await addHttpServer(router, uid, "cache-srv", url);

    await router.connectForRun(uid, RUN1);
    expect(fakeFetch.initCount(url)).toBe(1);

    await router.releaseRun(uid, RUN1);
    await router.connectForRun(uid, RUN2);
    expect(fakeFetch.initCount(url)).toBe(1); // still cached

    nowMs += 1001; // past idleTtl
    await router.connectForRun(uid, RUN3);
    expect(fakeFetch.initCount(url)).toBe(2); // evicted + reconnected
  });

  it("LRU-evicts at maxCustomConnections=1", async () => {
    const uid = await seedUser("pro");
    const fakeFetch = new FakeMcpFetch();
    const urlA = "https://lru-a.mcp.test/rpc";
    const urlB = "https://lru-b.mcp.test/rpc";
    const router = makeRouter({ fetchImpl: fakeFetch.impl, maxCustomConnections: 1 });
    await addHttpServer(router, uid, "lru-a", urlA);
    await addHttpServer(router, uid, "lru-b", urlB);

    await router.connectForRun(uid, RUN1);
    expect(fakeFetch.initCount(urlA)).toBe(1);
    expect(fakeFetch.initCount(urlB)).toBe(1); // B evicted A

    // A is no longer cached: calling it reconnects (a second initialize).
    const result = await router.callTool(uid, toolNameFor("lru-a", "echo"), {}, RUN1);
    expect(result.isError).toBe(false);
    expect(fakeFetch.initCount(urlA)).toBe(2);
  });

  it("unexpected stdio exit schedules a reconnect; removeServer cancels it", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    const router = makeRouter({ spawner });
    const server = await addStdioServer(router, uid, "reconnect-srv");

    await router.connectForRun(uid, RUN1);
    expect(spawner.calls).toHaveLength(1);

    spawner.processes[0]!.unexpectedExit();
    await waitFor(() => spawner.calls.length === 2, "reconnect spawn");
    expect(spawner.calls[1]!.uid).toBe(uid);

    // The fresh incarnation is installed: the next call reuses it (no third
    // process), proving the reconnect replaced the dead entry.
    const result = await router.callTool(uid, toolNameFor("reconnect-srv", "echo"), {}, RUN1);
    expect(result.isError).toBe(false);
    expect(spawner.calls).toHaveLength(2);

    // Cancel path: trigger another unexpected exit, then remove immediately.
    const spawnedBefore = spawner.calls.length;
    spawner.processes[1]!.unexpectedExit();
    await router.removeServer(uid, server.id);
    await sleep(800); // longer than the 500ms first backoff step
    expect(spawner.calls).toHaveLength(spawnedBefore);
  });

  // -------------------------------------------------------------------------
  // Client-request wiring (sampling / elicitation over the system bus)
  // -------------------------------------------------------------------------

  it("sampling: bus approval with preview; timeout → JSON-RPC -1; approve → sampler result", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    spawner.serverRequest = "sampling";
    const bus = new FakeBus();
    const router = makeRouter({ spawner, systemBus: bus });
    const server = await addStdioServer(router, uid, "sampling-srv");

    // 1) timeout → deny (-1)
    const result = await router.callTool(uid, toolNameFor("sampling-srv", "echo"), {}, RUN1);
    expect(result.isError).toBe(false);
    await waitFor(
      () => spawner.processes[0]!.serverResponses.some((r) => r.id === 900),
      "sampling response",
    );
    expect(bus.requests).toHaveLength(1);
    expect(bus.requests[0]!.kind).toBe("mcp_sampling_approval");
    expect(bus.requests[0]!.payload).toMatchObject({ serverId: server.id, server: "sampling-srv" });
    expect(String(bus.requests[0]!.payload.preview)).toContain("hello there");
    expect(spawner.processes[0]!.serverResponses.find((r) => r.id === 900)!.error?.code).toBe(-1);

    // 2) approve + runCtx.sampler → the sampler result is returned to the server
    bus.requests.length = 0;
    bus.reply = () => ({ id: "approval-1", payload: { approved: true } });
    let sampled: unknown = null;
    const sampledRun: RunContext = {
      ...RUN1,
      sampler: async (req) => {
        sampled = req;
        return { role: "assistant", content: { type: "text", text: "sampled-answer" } };
      },
    };
    await router.callTool(uid, toolNameFor("sampling-srv", "echo"), {}, sampledRun);
    await waitFor(
      () => spawner.processes[0]!.serverResponses.filter((r) => r.id === 900).length === 2,
      "approved sampling response",
    );
    const approved = spawner.processes[0]!.serverResponses.filter((r) => r.id === 900)[1]!;
    expect((approved.result as { content: { text: string } }).content.text).toBe("sampled-answer");
    expect((sampled as { preview: string }).preview).toContain("hello there");
  });

  it("elicitation: bus kind mcp_elicitation; accept-response is validated and returned", async () => {
    const uid = await seedUser("pro");
    const spawner = new FakeSpawner();
    spawner.serverRequest = "elicitation";
    const bus = new FakeBus();
    bus.reply = () => ({
      id: "elicitation-1",
      payload: { action: "accept", content: { name: "Ovid" } },
    });
    const router = makeRouter({ spawner, systemBus: bus });
    await addStdioServer(router, uid, "elicit-srv");

    await router.callTool(uid, toolNameFor("elicit-srv", "echo"), {}, RUN1);
    await waitFor(
      () => spawner.processes[0]!.serverResponses.some((r) => r.id === 901),
      "elicitation response",
    );
    expect(bus.requests[0]!.kind).toBe("mcp_elicitation");
    expect(bus.requests[0]!.payload).toMatchObject({ message: "Your name?" });
    const response = spawner.processes[0]!.serverResponses.find((r) => r.id === 901)!;
    expect(response.result).toEqual({ action: "accept", content: { name: "Ovid" } });
  });

  // -------------------------------------------------------------------------
  // Singleton through the router
  // -------------------------------------------------------------------------

  it("two uids calling mcp__fetch__fetch share ONE catalog handler instance", async () => {
    const freeUid = await seedUser("free");
    const proUid = await seedUser("pro");
    const fakeFetch = new FakeMcpFetch();
    const instances = { count: 0 };
    const catalog = createCuratedCatalog({
      fetchImpl: fakeFetch.impl,
      workspace,
      handlerOverrides: {
        fetch: () => {
          instances.count++;
          return createFetchHandler();
        },
      },
    });
    const router = makeRouter({ fetchImpl: fakeFetch.impl, catalog });

    const a = await router.callTool(
      freeUid,
      "mcp__fetch__fetch",
      { url: "https://example.test/a" },
      RUN1,
    );
    const b = await router.callTool(
      proUid,
      "mcp__fetch__fetch",
      { url: "https://example.test/b" },
      RUN1,
    );
    expect(a.isError).toBe(false);
    expect(b.isError).toBe(false);
    expect(fakeFetch.getCount()).toBe(2);
    expect(instances.count).toBe(1);
  });
});
