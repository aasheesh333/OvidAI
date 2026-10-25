/**
 * P5 Task 16 router-level tier-gate e2e (plan acceptance tests ①–⑤).
 *
 * Real Postgres + real Redis, REAL McpRouter / catalog / installer / registry
 * / system bus. Only the outer boundaries are fakes:
 * - sandbox → a fake SandboxManager handle for the plugin-install flow (and a
 *   fake stdio spawner for the custom stdio server);
 * - model sampling → never exercised (these are router-level flows);
 * - egress → separate fixture HTTP (custom MCP) and HTTPS (curated Fetch)
 *   servers on loopback; curated Fetch uses an injected GuardedFetch whose
 *   test-only trust and SSRF boundaries are documented below.
 *
 * This corrected fixture and all flows remain UNEXECUTED.
 *
 * Pinned flows:
 *   ① free: an explicit supported test catalog lists fetch; a stored custom server is
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

import {
  createServer as createHttpServer,
  type IncomingMessage,
  type ServerResponse,
} from "node:http";
import { createServer as createHttpsServer, request as httpsRequest } from "node:https";
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
  createGuardedFetch,
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
import { createTestProviderRegistry } from "../../../packages/mcp/src/__fixtures__/providerRegistry.js";

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
// Fixture HTTP MCP + HTTPS Fetch servers
// ---------------------------------------------------------------------------

// Existing clearly test-only pair copied from
// packages/mcp/src/egress/providerEgress.security.test.ts. Its SAN includes
// 127.0.0.1. It is never installed in a system/global trust store.
const TEST_CERT = `-----BEGIN CERTIFICATE-----
MIIDPTCCAiWgAwIBAgIUbGtBeXoFz8OV08DCCHWlWCN3K5owDQYJKoZIhvcNAQEL
BQAwGDEWMBQGA1UEAwwNcHJvdmlkZXIudGVzdDAeFw0yNjEwMjQxMDM1MjBaFw0z
NjEwMjExMDM1MjBaMBgxFjAUBgNVBAMMDXByb3ZpZGVyLnRlc3QwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQCU6ROAfv1Mu7d3sQpTNAPEy0PgGGhkfDQ/
m0Qgjb3XEKNRpMMVBFI2wwpbzwFZUxDzUba8/l4kHgY5uDZC1ogKF0+b4YhsXNTo
p4jmv96jJwbZlmQYCVmBkb5RccnZMVB526Ou3QbsqOYXkgoUwofYaFQy57Gyu53b
2xlqSGs26uI+0vSxAb8uoTkbFbptoJ1LJrQCj+YuDGBhsNFyQDVdtD0lurBVWa4z
htvgMvnybEvnOPycpNnZ5ljKU0Y/jPImRUwz52/hvbMNyurSFO7oszxktRZ6vTBy
1UR8LPi9+X3OBtmv4/oNGtbx9nOQrIxj4IE9KqgJ7vlIISJ/fk/VAgMBAAGjfzB9
MB0GA1UdDgQWBBT4oqOuoDEKt25SaCZ5+twbfXJjRjAfBgNVHSMEGDAWgBT4oqOu
oDEKt25SaCZ5+twbfXJjRjAPBgNVHRMBAf8EBTADAQH/MCoGA1UdEQQjMCGCDXBy
b3ZpZGVyLnRlc3SCCm90aGVyLnRlc3SHBH8AAAEwDQYJKoZIhvcNAQELBQADggEB
AHWPdQ4rn5flO3ic9l10FDhvMUUqs9bbUgKigu0ZDtG1A7t8xLz7oOTx+Foxes3C
UAVSg+XxtWSEN3TAip+arpn3eDj4kL/z72jr7AhtnFdfIH629ORCMhjzbf8kvOaG
hiV/LCFJ4E45mmr8TTbx0w0zgRvETQF0sPVQq2S+23wusXSK/nK3mUp89qtqRe9g
Py7ZLN2d5xRqmbgcFonDcKYVkasxj4qoteYf3H0bgvlzc18Et1nVTp1DYCxfj6eO
CbCZDiafdeUpSv5Zvpg42HI7IIdjvt5OoKnYIRct55RG/SLYgcBu7D24XwSuX6pT
Je7FW1EpGbX81125anwXhxg=
-----END CERTIFICATE-----`;
const TEST_KEY = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCU6ROAfv1Mu7d3
sQpTNAPEy0PgGGhkfDQ/m0Qgjb3XEKNRpMMVBFI2wwpbzwFZUxDzUba8/l4kHgY5
uDZC1ogKF0+b4YhsXNTop4jmv96jJwbZlmQYCVmBkb5RccnZMVB526Ou3QbsqOYX
kgoUwofYaFQy57Gyu53b2xlqSGs26uI+0vSxAb8uoTkbFbptoJ1LJrQCj+YuDGBh
sNFyQDVdtD0lurBVWa4zhtvgMvnybEvnOPycpNnZ5ljKU0Y/jPImRUwz52/hvbMN
yurSFO7oszxktRZ6vTBy1UR8LPi9+X3OBtmv4/oNGtbx9nOQrIxj4IE9KqgJ7vlI
ISJ/fk/VAgMBAAECggEAGcq1/0Vfi6Ue3bsbIfaqKXGYf83SdQcjSJoUxnuudDv0
Qb2jMXZ2Y/hLyMOVxPozfyV53InFVgWiR+iNc22zkeXgOsxpQ/WfRe3Qs0Dr57/o
epMHIrep2lybRYGLN9SIDxc5Jl4vpxmJAu+fUeGwxE2rucZyO5Yt/SjZodRJx7DL
HLNT8BaH63YsJosRpdT0odc0G/RNYh4OfA2AGbayknGCFhTvyvLsMsupR6zlrA78
0XWwqzhKkLRpaNHvuGqhbGAp15k4jRE2pw+k+QlHvJ+LibJQpWMV44X7Hg2HpCTn
1D7/WlUxUqF9c8eySoNTXtVsqtnsmpimBXQFvBgaSQKBgQDEFoL+RBIcLPzf/oG6
jQ83AF+MYopMUN3iaEWpKeqCZaWW5L76ban1W3V9IRldH9wumcFyzv0akUdZlbIo
AWzv9we61sFN6zBhggDVziv28E9RqLHv/EW2Ij+T/PNq7+rfGCIvx6w74D0X5rAQ
4kt7bee1XxN7nUk04zAW2mdCWQKBgQDCaHbrR+N2vGGEQWg80QhU2L0nYn05PUBX
FHQuOdlqqYb+tt11iACR2e/vJ4O281+UFSW28cHYayqg7jlDOJBEgvQnfZEeZh/9
bKM3s+S2GKr/wO0ruL41LtrJkazWnh1qQWP3FInGPeXKPyAoQQThKxZ7LfEG37dl
Hl4wqv8x3QKBgQCEMLzsVs1yqy1qf/PK5I9uP9UqGcAsBJQgrrTPfs92SrogCGNr
BgT+wEJrMaYcrn7L96F/GWVtxKS6Ev3AlH1xJDLU1TQJqFS8V1zixhPDbGu8nCIg
rAv+5gXAaVVcMRNAhM9/MHe/AcON2lm1eCj0s7nx/n9u5TDV85aWwXO9OQKBgBcO
xtP/EcZ6b2J9U3yrGj7d+gla0Bli32e0oFb/O39AHifFzpxrBg5GeAO4fxHK6dIp
c/Cv2druUv8FYjtL0SifE5A/f1/IoxCuuukXaBAE+vscicS+w6iRJxfzNDm8RSbe
HJookHK30rJbLFg55fdC4ga4GzdCf4D5yhghn+TtAoGAMe8b/Z9UOFgmwgSs2M2i
j12zaVrMSjwQ8XpMe+dnlhX+qnGUt2mNTiHZw4tHUeUm/8DSLHN+vLQ+IYaVIl96
X5zfAq99vBWY/bKRW/UvVj67w9D1FWmudjN7Xu2QI98D6ZrApsDTxowz1GKhyie9
IRTSUB3FPU0ntf+TfIjEkIw=
-----END PRIVATE KEY-----`;

const FIXTURE_FETCH_ORIGIN = "https://127.0.0.1";

interface FixtureServer {
  /** Existing custom Streamable-HTTP MCP origin. */
  url: string;
  /** Port-default HTTPS origin accepted by the real Fetch operation policy. */
  fetchUrl: string;
  fetchImpl: GuardedFetch;
  getCount(): number;
  postCount(): number;
  close(): Promise<void>;
}

// UNEXECUTED test-only transport boundary. The real GuardedFetch retains its
// normal scheme/port/address classification and non-production literal-loopback
// exemption. The wire then refuses every origin except https://127.0.0.1,
// trusts only TEST_CERT with normal TLS hostname verification, and maps that
// URL's default HTTPS port to this harness's ephemeral loopback listener. No
// rejectUnauthorized:false, global CA, NODE_TLS override, DNS rewrite, external
// provider access, production Fetch policy edit, or production SSRF edit exists.
function createFixtureFetch(httpsPort: number): GuardedFetch {
  const wire: typeof fetch = async (input, init) => {
    const rawUrl = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    const parsed = new URL(rawUrl);
    if (
      parsed.protocol !== "https:" ||
      parsed.origin !== FIXTURE_FETCH_ORIGIN ||
      parsed.username !== "" ||
      parsed.password !== "" ||
      parsed.port !== ""
    ) {
      throw new Error("Fixture Fetch refused a non-fixture URL.");
    }
    const method = init?.method ?? (input instanceof Request ? input.method : "GET");
    if (method !== "GET" || init?.body != null) {
      throw new Error("Fixture Fetch accepts only GET requests without a body.");
    }
    const headers = Object.fromEntries(new Headers(init?.headers).entries());
    return new Promise<Response>((resolve, reject) => {
      const request = httpsRequest(parsed, {
        port: httpsPort,
        method,
        headers,
        ca: TEST_CERT,
        agent: false,
        rejectUnauthorized: true,
        signal: init?.signal ?? undefined,
      }, (response) => {
        const chunks: Buffer[] = [];
        response.on("data", (chunk: Buffer) => chunks.push(chunk));
        response.on("error", reject);
        response.on("end", () => {
          const responseHeaders = new Headers();
          for (let index = 0; index < response.rawHeaders.length; index += 2) {
            const name = response.rawHeaders[index];
            const value = response.rawHeaders[index + 1];
            if (name !== undefined && value !== undefined) responseHeaders.append(name, value);
          }
          resolve(new Response(Buffer.concat(chunks), {
            status: response.statusCode ?? 500,
            headers: responseHeaders,
          }));
        });
      });
      request.on("error", reject);
      request.end();
    });
  };
  return createGuardedFetch({ allowedPorts: [443], fetchImpl: wire });
}

// The custom MCP side keeps the original ordinary-fetch HTTP transport, but
// only for this harness's exact credential-free loopback origin. Both custom
// HTTP and SSE pass redirect:"manual"; their methods, headers, and JSON-RPC
// bodies are forwarded unchanged. There is no unrestricted fallback.
function createCustomFixtureFetch(origin: string): GuardedFetch {
  return (url, init) => {
    const parsed = new URL(url);
    if (
      parsed.protocol !== "http:" ||
      parsed.origin !== origin ||
      parsed.username !== "" ||
      parsed.password !== ""
    ) {
      throw new Error("Custom fixture MCP refused a non-fixture URL.");
    }
    return fetch(url, init);
  };
}

async function startFixtureServer(): Promise<FixtureServer> {
  let gets = 0;
  let posts = 0;
  const handleRequest = (req: IncomingMessage, res: ServerResponse): void => {
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
  };

  const httpServer = createHttpServer(handleRequest);
  const httpsServer = createHttpsServer({ key: TEST_KEY, cert: TEST_CERT }, handleRequest);
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  try {
    await new Promise<void>((resolve) => httpsServer.listen(0, "127.0.0.1", resolve));
  } catch (error) {
    httpServer.close();
    throw error;
  }
  const httpPort = (httpServer.address() as AddressInfo).port;
  const httpsPort = (httpsServer.address() as AddressInfo).port;
  return {
    url: `http://127.0.0.1:${httpPort}`,
    fetchUrl: FIXTURE_FETCH_ORIGIN,
    fetchImpl: createFixtureFetch(httpsPort),
    getCount: () => gets,
    postCount: () => posts,
    close: async () => {
      httpServer.closeAllConnections();
      httpsServer.closeAllConnections();
      await Promise.all([
        new Promise<void>((resolve) => httpServer.close(() => resolve())),
        new Promise<void>((resolve) => httpsServer.close(() => resolve())),
      ]);
    },
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
  const fetchImpl = server.fetchImpl;
  const customFetchImpl = createCustomFixtureFetch(server.url);
  // The router dependency also supplies native handlers' per-call context, so
  // dispatch between the two exact fixture origins instead of replacing the
  // curated guard. Unknown origins fall into the custom wire and are refused.
  // Custom stdio never uses either fetch path.
  const routerFetchImpl: GuardedFetch = (url, init) => {
    const parsed = new URL(url);
    return parsed.origin === FIXTURE_FETCH_ORIGIN
      ? fetchImpl(url, init)
      : customFetchImpl(url, init);
  };
  const spawner = new FakeSpawner();
  let factories = 0;
  const catalog = createCuratedCatalog({
    fetchImpl,
    workspace,
    registry: createTestProviderRegistry({ supported: ["fetch"] }),
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
    fetchImpl: routerFetchImpl,
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

  it("① free: supported test fetch works, custom is pro_required before any dial", async () => {
    const h = await makeHarness();
    try {
      const id = await seedUser("free");

      const servers = await h.router.listServers(id);
      expect(servers.filter((s) => s.curatedId !== null).map((s) => s.curatedId)).toEqual(["fetch"]);

      const getsBefore = h.server.getCount();
      const fetched = await h.router.callTool(
        id,
        "mcp__fetch__fetch",
        { url: `${h.server.fetchUrl}/page` },
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

      const postsBeforeCall = h.server.postCount();
      const httpCall = await h.router.callTool(
        id,
        "mcp__fixture-http__echo",
        { name: "x" },
        run(id),
      );
      expect(httpCall.text).toBe("ok:x");
      expect(httpCall.isError).toBe(false);
      expect(h.server.postCount()).toBe(postsBeforeCall + 1);

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
        { url: `${h.server.fetchUrl}/a` },
        run(a),
      );
      const resB = await h.router.callTool(
        b,
        "mcp__fetch__fetch",
        { url: `${h.server.fetchUrl}/b` },
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
        { url: `${h.server.fetchUrl}/still-works` },
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
    // ioredis's `Redis` is structurally compatible with the narrow
    // `SystemRedis` port at runtime; the event-listener variance differs in
    // the type system only.
    const realBus = createRedisSystemBus(
      redis as unknown as Parameters<typeof createRedisSystemBus>[0],
    );
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
