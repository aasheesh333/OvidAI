/**
 * P5 Task 16 router-level tier-gate e2e (plan acceptance tests ①–⑤).
 *
 * Real Postgres + real Redis, REAL McpRouter / catalog / installer / registry
 * / system bus. Only the outer boundaries are fakes:
 * - sandbox → a fake SandboxManager handle for the plugin-install flow (and a
 *   fake stdio spawner for the custom stdio server);
 * - model sampling → never exercised (these are router-level flows);
 * - egress → a fixture HTTP server on 127.0.0.1 reached through an injected
 *   GuardedFetch (the production SSRF guard is a package unit concern).
 *
 * Pinned flows:
 *   ① free: catalog lists 20 curated; fetch works; a stored custom server is
 *      refused with `pro_required` BEFORE any dial; addServer throws.
 *   ② pro: custom Streamable-HTTP server connects/lists/calls; custom stdio
 *      server (fake spawner) lists/calls.
 *   ③ shared singleton: free A and pro B both call `mcp__fetch__fetch` — the
 *      fixture saw two GETs and the catalog constructed ONE handler.
 *   ④ downgrade B mid-flight: the next custom call is `pro_required`, curated
 *      fetch still works.
 *   ⑤ plugin install as pro with an auto-approving bus: row active, registry
 *      populated, progress events observed on sys:{uid}:out in phase order.
 *
 * NOTE (scope): flow ① pins the ROUTER's gate (`code: "pro_required"`). The
 * HTTP 402 mapping lives in Task 15's gateway route tests; that lane was in
 * flight when this suite landed, so this file deliberately does not import
 * @ovid/gateway's REST surface.
 */

import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { cp, mkdir, mkdtemp, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { Redis } from "ioredis";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, mcpServers, plugins, schema, type Db } from "@ovid/db";
import {
  PRO_REQUIRED_MESSAGE,
  ProRequiredError,
  createContributionRegistry,
  createCuratedCatalog,
  createEnvelopeCrypto,
  createFetchHandler,
  createMcpRouter,
  createPluginInstaller,
  createRedisSystemBus,
  type EnvelopeCrypto,
  type GuardedFetch,
  type McpRouter,
  type PluginSourceInput,
  type ResolvedSource,
  type SandboxSpawner,
  type SandboxedProcess,
  type UserSystemBus,
  type WorkspaceFiles,
} from "@ovid/mcp";
import { createSandboxSeam } from "@ovid/worker";
import type { SandboxHandle, SandboxManager } from "@ovid/sandbox";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
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

function run(prefix: string): { sessionId: string; runId: string } {
  return { sessionId: `session-${prefix}`, runId: `run-${prefix}` };
}

// ---------------------------------------------------------------------------
// Fixture HTTP server: curated fetch GETs + a scripted Streamable-HTTP MCP
// ---------------------------------------------------------------------------

interface FixtureServer {
  url: string;
  getCount(): number;
  postCount(): number;
  close(): Promise<void>;
}

async function startFixtureServer(): Promise<FixtureServer> {
  let gets = 0;
  let posts = 0;
  const server: Server = createServer((req, res) => {
    if (req.method === "GET") {
      gets += 1;
      res.writeHead(200, { "content-type": "text/html" });
      res.end("<html><body><h1>fixture page</h1><p>body</p></body></html>");
      return;
    }
    if (req.method !== "POST") {
      res.writeHead(405);
      res.end();
      return;
    }
    posts += 1;
    let body = "";
    req.on("data", (chunk: Buffer) => {
      body += chunk.toString("utf8");
    });
    req.on("end", () => {
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(body) as Record<string, unknown>;
      } catch {
        res.writeHead(400);
        res.end();
        return;
      }
      if (msg.id === undefined) {
        res.writeHead(202); // notification accepted
        res.end();
        return;
      }
      let result: unknown;
      switch (msg.method) {
        case "initialize":
          result = {
            protocolVersion: "2025-06-18",
            capabilities: { tools: {} },
            serverInfo: { name: "fixture-http", version: "1.0.0" },
          };
          break;
        case "tools/list":
          result = {
            tools: [
              {
                name: "echo",
                description: "Echo a value.",
                inputSchema: { type: "object", properties: { name: { type: "string" } } },
              },
            ],
          };
          break;
        case "tools/call": {
          const params = (msg.params ?? {}) as Record<string, unknown>;
          const args = (params.arguments ?? {}) as Record<string, unknown>;
          result = {
            content: [{ type: "text", text: `ok:${String(args.name ?? "")}` }],
            isError: false,
          };
          break;
        }
        default:
          res.writeHead(200, { "content-type": "application/json" });
          res.end(
            JSON.stringify({
              jsonrpc: "2.0",
              id: msg.id,
              error: { code: -32601, message: "method not found" },
            }),
          );
          return;
      }
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }));
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${port}`,
    getCount: () => gets,
    postCount: () => posts,
    close: () => new Promise<void>((resolve) => server.close(() => resolve())),
  };
}

// ---------------------------------------------------------------------------
// Fake stdio MCP process (the custom stdio server's canned peer)
// ---------------------------------------------------------------------------

class FakeStdioProcess implements SandboxedProcess {
  readonly id = `proc-${++counter}`;
  readonly pid = 20_000 + counter;
  private stdoutCb: ((line: string) => void) | undefined;
  private exitCb: ((code: number | null) => void) | undefined;

  writeLine(line: string): void {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(line) as Record<string, unknown>;
    } catch {
      return;
    }
    if (msg.method === undefined) return; // responses/notifications from us
    switch (msg.method) {
      case "initialize":
        this.respond(msg.id, {
          protocolVersion: "2025-06-18",
          capabilities: { tools: {} },
          serverInfo: { name: "fake-stdio", version: "1.0.0" },
        });
        return;
      case "tools/list":
        this.respond(msg.id, {
          tools: [
            {
              name: "echo",
              description: "Echo a value.",
              inputSchema: { type: "object", properties: { name: { type: "string" } } },
            },
          ],
        });
        return;
      case "tools/call": {
        const params = (msg.params ?? {}) as Record<string, unknown>;
        const args = (params.arguments ?? {}) as Record<string, unknown>;
        this.respond(msg.id, {
          content: [{ type: "text", text: `ok:${String(args.name ?? "")}` }],
          isError: false,
        });
        return;
      }
      default:
        return;
    }
  }

  private respond(id: unknown, result: unknown): void {
    queueMicrotask(() => this.stdoutCb?.(JSON.stringify({ jsonrpc: "2.0", id, result })));
  }

  onStdoutLine(cb: (line: string) => void): void {
    this.stdoutCb = cb;
  }

  onExit(cb: (code: number | null) => void): void {
    this.exitCb = cb;
  }

  async kill(): Promise<void> {
    this.exitCb?.(0);
  }
}

class FakeSpawner implements SandboxSpawner {
  processes: FakeStdioProcess[] = [];
  async spawn(): Promise<SandboxedProcess> {
    const proc = new FakeStdioProcess();
    this.processes.push(proc);
    return proc;
  }
}

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

// The fixture server is on loopback; the injected fetch bypasses the
// production SSRF guard (that guard has its own package unit tests).
const fetchImpl: GuardedFetch = (url, init) => fetch(url, init);

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

let db: Db;
let redis: Redis;
let crypto: EnvelopeCrypto;

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const id = uid("mcp-tier");
  await db.insert(schema.users).values({ uid: id, email: `${id}@test.local`, tier });
  return id;
}

interface Harness {
  router: McpRouter;
  spawner: FakeSpawner;
  server: FixtureServer;
  fetchFactories(): number;
  close(): Promise<void>;
}

async function makeHarness(): Promise<Harness> {
  const server = await startFixtureServer();
  const spawner = new FakeSpawner();
  let factories = 0;
  const catalog = createCuratedCatalog({
    fetchImpl,
    workspace,
    handlerOverrides: {
      fetch: () => {
        factories += 1;
        return createFetchHandler();
      },
    },
  });
  const router = createMcpRouter({
    db,
    crypto,
    catalog,
    systemBus: {
      async publish() {},
      async request() {
        return null;
      },
      async close() {},
    },
    spawner,
    workspace,
    fetchImpl,
    oauth: {
      getAccessToken: async () => null,
      start: async () => ({ authorizeUrl: "" }),
    },
  });
  return {
    router,
    spawner,
    server,
    fetchFactories: () => factories,
    close: async () => {
      await router.shutdown();
      await server.close();
    },
  };
}

async function expectProRequired(p: Promise<unknown>): Promise<void> {
  let caught: unknown;
  try {
    await p;
  } catch (err) {
    caught = err;
  }
  expect(caught).toBeInstanceOf(ProRequiredError);
  expect((caught as ProRequiredError).code).toBe("pro_required");
  expect((caught as Error).message).toBe(PRO_REQUIRED_MESSAGE);
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)("MCP tier gate (router-level e2e)", () => {
  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    redis = new Redis(TEST_REDIS_URL!);
    crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  }, 60_000);

  afterAll(async () => {
    await redis?.quit();
    await db?.$client.end({ timeout: 5 });
  });

  it("① free: 20 curated servers, fetch works, custom is pro_required before any dial", async () => {
    const h = await makeHarness();
    try {
      const id = await seedUser("free");

      const servers = await h.router.listServers(id);
      expect(servers.filter((s) => s.curatedId !== null)).toHaveLength(20);

      const getsBefore = h.server.getCount();
      const fetched = await h.router.callTool(
        id,
        "mcp__fetch__fetch",
        { url: `${h.server.url}/page` },
        run(id),
      );
      expect(fetched.isError).toBe(false);
      expect(h.server.getCount()).toBe(getsBefore + 1);

      // A stored custom server (as if it had been added while Pro): the
      // ROUTER gate refuses the call before dialing the fixture.
      await mcpServers.create(db, {
        userId: id,
        name: "free-custom",
        transport: "http",
        config: { type: "http", url: `${h.server.url}/mcp` },
      });
      const postsBefore = h.server.postCount();
      await expectProRequired(
        h.router.callTool(id, "mcp__free-custom__echo", { name: "x" }, run(id)),
      );
      expect(h.server.postCount()).toBe(postsBefore); // never dialed

      await expectProRequired(
        h.router.addServer(id, {
          imported: { name: "other", transport: "http", url: `${h.server.url}/mcp` },
        }),
      );
    } finally {
      await h.close();
    }
  });

  it("② pro: custom http and stdio servers connect, list and call", async () => {
    const h = await makeHarness();
    try {
      const id = await seedUser("pro");

      const httpServer = await h.router.addServer(id, {
        imported: { name: "fixture-http", transport: "http", url: `${h.server.url}/mcp` },
      });
      expect(httpServer.transport).toBe("http");
      const httpTools = await h.router.listTools(id);
      expect(httpTools.some((t) => t.name === "mcp__fixture-http__echo")).toBe(true);

      const httpCall = await h.router.callTool(
        id,
        "mcp__fixture-http__echo",
        { name: "x" },
        run(id),
      );
      expect(httpCall.text).toBe("ok:x");
      expect(httpCall.isError).toBe(false);

      await h.router.addServer(id, {
        imported: {
          name: "fixture-stdio",
          transport: "stdio",
          command: "fake-mcp",
          args: ["--stdio"],
        },
      });
      const stdioTools = await h.router.listTools(id);
      expect(stdioTools.some((t) => t.name === "mcp__fixture-stdio__echo")).toBe(true);

      const stdioCall = await h.router.callTool(
        id,
        "mcp__fixture-stdio__echo",
        { name: "y" },
        run(id),
      );
      expect(stdioCall.text).toBe("ok:y");
      expect(stdioCall.isError).toBe(false);
    } finally {
      await h.close();
    }
  });

  it("③ shared singleton: free A + pro B both call fetch → 2 requests, 1 catalog instance", async () => {
    const h = await makeHarness();
    try {
      const a = await seedUser("free");
      const b = await seedUser("pro");

      const before = h.server.getCount();
      const resA = await h.router.callTool(
        a,
        "mcp__fetch__fetch",
        { url: `${h.server.url}/a` },
        run(a),
      );
      const resB = await h.router.callTool(
        b,
        "mcp__fetch__fetch",
        { url: `${h.server.url}/b` },
        run(b),
      );

      expect(resA.isError).toBe(false);
      expect(resB.isError).toBe(false);
      expect(h.server.getCount() - before).toBe(2);
      expect(h.fetchFactories()).toBe(1);
    } finally {
      await h.close();
    }
  });

  it("④ downgrade mid-flight: next custom call is pro_required, curated still works", async () => {
    const h = await makeHarness();
    try {
      const id = await seedUser("pro");
      await h.router.addServer(id, {
        imported: { name: "fixture-http", transport: "http", url: `${h.server.url}/mcp` },
      });
      const first = await h.router.callTool(
        id,
        "mcp__fixture-http__echo",
        { name: "before" },
        run(id),
      );
      expect(first.text).toBe("ok:before");

      await db.$client.unsafe("UPDATE users SET tier = 'free' WHERE uid = $1", [id]);

      await expectProRequired(
        h.router.callTool(id, "mcp__fixture-http__echo", { name: "after" }, run(id)),
      );

      const curated = await h.router.callTool(
        id,
        "mcp__fetch__fetch",
        { url: `${h.server.url}/still-works` },
        run(id),
      );
      expect(curated.isError).toBe(false);
    } finally {
      await h.close();
    }
  });

  it("⑤ plugin install as pro: active row, registry entries, ordered progress events", async () => {
    const id = await seedUser("pro");

    // -- fixture plugin tree (Claude-Code bundle) --------------------------
    const fixture = await mkdtemp(join(tmpdir(), "mcp-tier-plugin-"));
    await mkdir(join(fixture, ".claude-plugin"), { recursive: true });
    await writeFile(
      join(fixture, ".claude-plugin", "plugin.json"),
      JSON.stringify({ name: "demo", version: "1.0.0", author: { name: "acme" } }),
      "utf8",
    );
    await mkdir(join(fixture, "commands"), { recursive: true });
    await writeFile(join(fixture, "commands", "foo.md"), "# foo\n", "utf8");

    const workspaceRoot = await mkdtemp(join(tmpdir(), "mcp-tier-workspace-"));

    // -- real redis bus; approvals are answered automatically --------------
    const realBus = createRedisSystemBus(redis);
    const autoBus: UserSystemBus = {
      publish: (uidValue, event) => realBus.publish(uidValue, event),
      async request() {
        return { id: randomUUID(), payload: { approve: true } };
      },
      close: () => realBus.close(),
    };

    const subscriber = redis.duplicate();
    const phases: string[] = [];
    await subscriber.subscribe(`sys:${id}:out`);
    subscriber.on("message", (channel, message) => {
      if (channel !== `sys:${id}:out`) return;
      try {
        const envelope = JSON.parse(message) as {
          kind?: string;
          payload?: { phase?: string };
        };
        if (envelope.kind === "plugin_install_progress" && envelope.payload?.phase !== undefined) {
          phases.push(envelope.payload.phase);
        }
      } catch {
        // ignore non-envelope noise
      }
    });

    // -- P2 manager handle adapted through the REAL sandbox seam -----------
    const hostUid = typeof process.getuid === "function" ? process.getuid() : 0;
    const hostOf = (jailPath: string): string => {
      if (jailPath === "/workspace") return workspaceRoot;
      if (!jailPath.startsWith("/workspace/")) {
        throw new Error(`unexpected jail path: ${jailPath}`);
      }
      return join(workspaceRoot, jailPath.slice("/workspace/".length));
    };
    const handle = {
      userId: id,
      uid: hostUid,
      workspaceDir: workspaceRoot,
      homeDir: workspaceRoot,
      jailWorkspaceDir: "/workspace",
      exec: async (req: { argv?: string[] }) => {
        const argv = req.argv ?? [];
        if (argv[0] === "mv" && argv.length === 3) {
          await rename(hostOf(argv[1]!), hostOf(argv[2]!));
        }
        return {
          exitCode: 0,
          stdout: "",
          stderr: "",
          timedOut: false,
          truncated: false,
          blocked: false,
          refusal: null,
        };
      },
      createPty: async () => {
        throw new Error("unused");
      },
      getPty: () => undefined,
      jobs: {},
      spawnProcess: async () => {
        throw new Error("unused");
      },
      destroy: async () => {},
    } as unknown as SandboxHandle;
    const manager = {
      attach: async () => handle,
      get: () => handle,
      destroy: async () => {},
      list: () => [],
      activeCount: () => 1,
      workspaceDir: async () => workspaceRoot,
      recover: async () => {},
      close: async () => {},
    } as unknown as SandboxManager;
    const sandbox = createSandboxSeam({ manager });

    const resolver = {
      async resolve(input: PluginSourceInput): Promise<ResolvedSource> {
        const staging = await mkdtemp(join(tmpdir(), "mcp-tier-staging-"));
        await cp(fixture, staging, { recursive: true });
        return {
          stagingDir: staging,
          bytes: 1,
          provenance: { kind: input.kind },
          discard: () => rm(staging, { recursive: true, force: true }),
        };
      },
    };
    const registry = createContributionRegistry();
    const installer = createPluginInstaller({
      db,
      crypto,
      systemBus: autoBus,
      resolver,
      sandbox,
      registry,
      approvalTimeoutMs: 2000,
    });

    try {
      const outcome = await installer.install({
        installId: randomUUID(),
        userId: id,
        pluginId: "acme/demo",
        mode: "install",
        source: { kind: "paste", label: "fixture", config: "{}" },
      });

      expect(outcome.status).toBe("active");
      expect(outcome.pluginId).toBe("acme/demo");

      await waitFor(() => phases.length >= 7, "plugin install progress phases");
      expect(phases).toEqual([
        "resolved",
        "normalized",
        "pending_grant",
        "deps",
        "probe",
        "activate",
        "committed",
      ]);

      const row = await plugins.getByPluginId(db, id, "acme/demo");
      expect(row?.status).toBe("active");
      expect(registry.list({ pluginId: "acme/demo" }).length).toBeGreaterThan(0);
    } finally {
      await subscriber.quit();
      await autoBus.close();
      await rm(workspaceRoot, { recursive: true, force: true });
      await rm(fixture, { recursive: true, force: true });
    }
  });
});
