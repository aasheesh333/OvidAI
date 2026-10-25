// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createCuratedCatalog,
  createCuratedProviderSupport,
  createEnvelopeCrypto,
  type ConnectionHealthStore,
  type EgressRequest,
  type EgressResponse,
  type GuardedFetch,
  type HealthConnection,
  type HealthTransition,
  type HealthWrite,
  type McpRouter,
  type ProviderEgress,
  type RunMcpSnapshot,
} from "@ovid/mcp";
import {
  mcpOauthTokens,
  mcpServers as serverRepo,
  type Db,
  type McpOauthTokenRow,
  type McpServerRow,
} from "@ovid/db";

import {
  createWorkerConnectionHealth,
  scopedProviderEgress,
  withLazyConnectionHealth,
} from "./connectionHealth.js";
import { createConnectionHealthInvocations } from "@ovid/mcp";
import { createTestProviderRegistry } from "../../../packages/mcp/src/__fixtures__/providerRegistry.js";
import { createMcpToolProvider } from "./mcpTools.js";
import type { McpAgentTool, McpToolContext, McpToolProvider } from "./mcpTools.js";

const MASTER_KEY = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const CONNECTION_ID = "11111111-1111-4111-8111-111111111111";
const UID = "worker-health-user";
const T1 = new Date("2026-10-25T01:01:00.000Z");

class Store implements ConnectionHealthStore {
  row: HealthConnection;
  tokenWrites = 0;
  beforeTokenWrite?: (token: unknown) => void;

  constructor(providerId: string) {
    this.row = {
      connectionId: CONNECTION_ID,
      userId: UID,
      providerId,
      enabled: true,
      agentEnabled: true,
      authState: providerId === "google-drive" ? "authorized" : "configured",
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
      configVersion: 4,
      disconnectGeneration: 2,
      hasSecrets: true,
    };
  }

  async get(connectionId: string, uid: string) {
    return connectionId === this.row.connectionId && uid === this.row.userId
      ? structuredClone(this.row)
      : null;
  }

  private current(expected: { configVersion: number; disconnectGeneration: number }) {
    return this.row.enabled && this.row.configVersion === expected.configVersion &&
      this.row.disconnectGeneration === expected.disconnectGeneration;
  }

  async writeHealth(write: HealthWrite) {
    if (write.connectionId !== this.row.connectionId || write.userId !== this.row.userId ||
        !this.current(write.expected)) return null;
    if (write.state !== "revoked" &&
        (this.row.authState === "revoked" || this.row.healthState === "revoked")) return null;
    if (write.state === "healthy" && !["configured", "authorized"].includes(this.row.authState)) return null;
    this.row.healthState = write.state;
    if (write.state === "needs_auth" || write.state === "revoked") this.row.authState = write.state;
    if (write.checkedAt !== undefined) this.row.lastCheckedAt = write.checkedAt.toISOString();
    if (write.succeededAt !== undefined) this.row.lastSuccessAt = write.succeededAt.toISOString();
    return structuredClone(this.row);
  }

  async writeRefreshedToken(write: { expected: { configVersion: number; disconnectGeneration: number }; token: unknown }) {
    this.tokenWrites += 1;
    if (!this.current(write.expected) || this.row.authState === "revoked" || this.row.healthState === "revoked") return false;
    this.beforeTokenWrite?.(write.token);
    return true;
  }

  async disconnect(connectionId: string, uid: string, expectedConfigVersion: number) {
    if (connectionId !== this.row.connectionId || uid !== this.row.userId ||
        expectedConfigVersion !== this.row.configVersion) return null;
    this.row = {
      ...this.row,
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
      disconnectGeneration: this.row.disconnectGeneration + 1,
    };
    return structuredClone(this.row);
  }
}

function raw(providerId: string, secretsSealed: McpServerRow["secretsSealed"]): McpServerRow {
  return {
    id: CONNECTION_ID,
    userId: UID,
    name: providerId,
    transport: "native",
    curatedId: providerId,
    providerId,
    agentEnabled: true,
    authState: providerId === "google-drive" ? "authorized" : "configured",
    healthState: "never_checked",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 4,
    disconnectGeneration: 2,
    approvedSourceId: null,
    approvedDigest: null,
    normalizedConnectionName: providerId,
    config: providerId === "fetch" ? { url: "https://example.test/public" } : null,
    secretsSealed,
    enabled: true,
    createdAt: T1,
    updatedAt: T1,
  };
}

function response(request: EgressRequest, status: number, body: unknown): EgressResponse {
  return {
    status,
    headers: new Headers({ "content-type": "application/json" }),
    body: new Response(JSON.stringify(body)).body as ReadableStream<Uint8Array>,
    origin: new URL(request.url.origin),
    remoteAddress: "203.0.113.10",
  };
}

function providerHarness(providerId: "cloudflare" | "google-drive" | "github" | "vercel", handlers: {
  operation: (request: EgressRequest) => Promise<EgressResponse>;
  oauth?: GuardedFetch;
}) {
  const crypto = createEnvelopeCrypto(MASTER_KEY);
  const registry = createTestProviderRegistry({ supported: [providerId] });
  const support = createCuratedProviderSupport(registry);
  const store = new Store(providerId);
  const secret = providerId === "cloudflare"
    ? { api_token: "cloudflare-health-secret" }
    : providerId === "github"
      ? { GITHUB_TOKEN: "github-health-secret" }
      : providerId === "vercel"
        ? { access_token: "vercel-health-secret" }
        : {};
  const rawRow = raw(providerId, crypto.encrypt(JSON.stringify(secret), `mcp_servers:${CONNECTION_ID}`));
  const serverGet = vi.spyOn(serverRepo, "get").mockResolvedValue(rawRow);
  const operationFetch: GuardedFetch = async () => {
    throw new Error("legacy operation fetch must not be used");
  };
  const egress: ProviderEgress = {
    request: handlers.operation,
    async close() {},
  };
  const lifecycle = createWorkerConnectionHealth({
    db: {} as Db,
    crypto,
    store,
    providers: support.definitions,
    catalogForSignal: (signal) => createCuratedCatalog({
      fetchImpl: operationFetch,
      workspace: {},
      registry,
      providerEgress: scopedProviderEgress(egress, signal),
    }),
    operationFetch,
    oauthFetch: handlers.oauth ?? operationFetch,
    now: () => T1,
  });
  return { lifecycle, store, crypto, rawRow, serverGet };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("real worker health provider composition", () => {
  it("executes the actual typed Cloudflare handler with bounded trusted pagination and per-call decryption", async () => {
    const requests: EgressRequest[] = [];
    const { lifecycle } = providerHarness("cloudflare", {
      operation: async (request) => {
        requests.push(request);
        return response(request, 200, {
          success: true,
          result: [],
          result_info: { page: 1, per_page: 5, count: 0, total_count: 0, total_pages: 0 },
          errors: [],
          messages: [],
        });
      },
    });

    const transition = await lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "list_zones");

    expect(transition).toMatchObject({ to: "healthy", lastCheckedAt: T1.toISOString(), lastSuccessAt: T1.toISOString() });
    expect(requests).toHaveLength(1);
    expect(requests[0]?.url.toString()).toBe("https://api.cloudflare.com/client/v4/zones?page=1&per_page=5");
    expect(requests[0]?.headers.Authorization).toBe("Bearer cloudflare-health-secret");
    expect(JSON.stringify(transition)).not.toContain("cloudflare-health-secret");
  });

  it("executes GitHub GET /user with its real typed handler and no fabricated repository coordinates", async () => {
    const requests: EgressRequest[] = [];
    const { lifecycle } = providerHarness("github", {
      operation: async (request) => {
        requests.push(request);
        return response(request, 200, { login: "health-user" });
      },
    });

    await expect(lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "get_user"))
      .resolves.toMatchObject({ to: "healthy" });
    expect(requests.map((request) => request.url.toString())).toEqual(["https://api.github.com/user"]);
    expect(requests[0]?.headers.Authorization).toBe("Bearer github-health-secret");
  });

  it("executes Vercel's bounded v10 read and leaves resource-specific GitHub probes unavailable", async () => {
    const requests: EgressRequest[] = [];
    const { lifecycle } = providerHarness("vercel", {
      operation: async (request) => {
        requests.push(request);
        return response(request, 200, { projects: [], pagination: { count: 0, next: null } });
      },
    });

    await expect(lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "list_projects"))
      .resolves.toMatchObject({ to: "healthy" });
    expect(requests[0]?.url.toString()).toBe("https://api.vercel.com/v10/projects?limit=1");

    const github = providerHarness("github", {
      operation: async (request) => {
        requests.push(request);
        return response(request, 200, {});
      },
    });
    await expect(github.lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "list_issues"))
      .resolves.toMatchObject({ to: "unavailable" });
    expect(requests).toHaveLength(1);
  });

  it("does not invoke the typed handler when a cross-process generation change appears after decryption", async () => {
    const requests: EgressRequest[] = [];
    const { lifecycle, rawRow, serverGet } = providerHarness("cloudflare", {
      operation: async (request) => {
        requests.push(request);
        return response(request, 200, { success: true, result: [], errors: [] });
      },
    });
    serverGet
      .mockResolvedValueOnce(rawRow)
      .mockResolvedValueOnce({ ...rawRow, disconnectGeneration: rawRow.disconnectGeneration + 1 });

    const transition = await lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "list_zones");

    expect(transition.to).toBe("unavailable");
    expect(requests).toEqual([]);
  });

  it("refreshes through the real OAuth adapter and retries Drive with the newly sealed token", async () => {
    const providerRequests: EgressRequest[] = [];
    let currentMaterial = {
      accessToken: "expired-access",
      refreshToken: "refresh-rotating",
      expiresAt: 0,
      tokenUrl: "https://auth.example.test/token",
      clientId: "ovid",
      clientSecret: null,
      resource: null,
    };
    const crypto = createEnvelopeCrypto(MASTER_KEY);
    vi.spyOn(mcpOauthTokens, "get").mockImplementation(async (): Promise<McpOauthTokenRow | null> => ({
      id: "oauth-row",
      userId: UID,
      serverId: CONNECTION_ID,
      tokensSealed: crypto.encrypt(JSON.stringify(currentMaterial), `mcp_oauth_tokens:${CONNECTION_ID}`),
      updatedAt: T1,
    }));
    const oauth: GuardedFetch = async () => new Response(JSON.stringify({
      access_token: "fresh-access",
      token_type: "Bearer",
      expires_in: 3600,
    }), { status: 200, headers: { "content-type": "application/json" } });
    const { lifecycle, store } = providerHarness("google-drive", {
      oauth,
      operation: async (request) => {
        providerRequests.push(request);
        if (providerRequests.length === 1) return response(request, 401, { error: "unauthorized" });
        return response(request, 200, { files: [] });
      },
    });
    store.beforeTokenWrite = (token) => {
      currentMaterial = JSON.parse(crypto.decrypt(
        token as McpOauthTokenRow["tokensSealed"],
        `mcp_oauth_tokens:${CONNECTION_ID}`,
      )) as typeof currentMaterial;
    };

    const transition = await lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "search");

    expect(transition.to).toBe("healthy");
    expect(store.tokenWrites).toBe(1);
    expect(providerRequests).toHaveLength(2);
    expect(providerRequests.map((request) => request.headers.Authorization)).toEqual([
      "Bearer expired-access",
      "Bearer fresh-access",
    ]);
    expect(JSON.stringify(transition)).not.toContain("fresh-access");
  });

  it("aborts the real provider request on disconnect and never persists the late success", async () => {
    let requestStarted!: () => void;
    const started = new Promise<void>((resolve) => { requestStarted = resolve; });
    let signal: AbortSignal | undefined;
    const { lifecycle, store } = providerHarness("cloudflare", {
      operation: (request) => {
        signal = request.signal;
        requestStarted();
        return new Promise<EgressResponse>((_resolve, reject) => {
          request.signal?.addEventListener("abort", () => reject(request.signal?.reason), { once: true });
        });
      },
    });

    const pending = lifecycle.checkConnectionHealth(CONNECTION_ID, UID, "list_zones");
    await started;
    await lifecycle.disconnectConnection(CONNECTION_ID, UID);

    await expect(pending).resolves.toMatchObject({ code: "disconnected", to: "revoked", persisted: false });
    expect(signal?.aborted).toBe(true);
    expect(store.row.healthState).toBe("revoked");
  });
});

describe("selected lazy health invocation", () => {
  const operation = {
    connectionId: CONNECTION_ID,
    providerId: "cloudflare",
    operationId: "list_zones",
    modelName: "mcp__cloudflare__list_zones",
    definition: {
      name: "list_zones",
      description: "List zones",
      effect: "read" as const,
      approval: "mode" as const,
      requiredScopes: [],
      inputSchema: { type: "object", properties: {}, required: [], additionalProperties: false, maxProperties: 0 },
      outputPolicy: { kind: "redacted_json" as const, maxBytes: 1024 },
      request: { originKey: "cloudflare", method: "GET" as const, pathTemplate: "/zones" },
      limits: { timeoutMs: 1000, responseBytes: 1024, frameBytes: 1024, pageBytes: 1024 },
    },
    configVersion: 4,
    disconnectGeneration: 2,
  };
  const snapshot: RunMcpSnapshot = { generation: "run", operations: [operation] };
  const ctx: McpToolContext = {
    uid: UID,
    sessionId: "session",
    runId: "run",
    mode: "auto",
    planMode: false,
    unattended: false,
    isSubagent: false,
    depth: 0,
    callKey: "call",
    signal: new AbortController().signal,
  };

  function lazyHarness(result: { content: string; isError?: boolean }, healthy = true) {
    const execute = vi.fn(async () => result);
    const base: McpToolProvider = {
      async tools(): Promise<McpAgentTool[]> {
        return [{ name: "integration_call", description: "call", parameters: {}, execute }];
      },
      async specs() {
        return [];
      },
    };
    const lifecycle = {
      checkConnectionHealth: vi.fn(async (): Promise<HealthTransition> => {
        const state = healthy ? "healthy" as const : "needs_auth" as const;
        const connection: HealthConnection = {
          connectionId: CONNECTION_ID,
          userId: UID,
          providerId: "cloudflare",
          enabled: true,
          agentEnabled: true,
          authState: "configured",
          healthState: state,
          lastCheckedAt: T1.toISOString(),
          lastSuccessAt: healthy ? T1.toISOString() : null,
          configVersion: 4,
          disconnectGeneration: 2,
          hasSecrets: true,
        };
        return {
          connection,
          from: "never_checked",
          to: state,
          lastCheckedAt: connection.lastCheckedAt,
          lastSuccessAt: connection.lastSuccessAt,
          persisted: true,
          code: "checked",
        };
      }),
    };
    const invocations = createConnectionHealthInvocations({
      lifecycle,
      revalidate: async () => "current",
    });
    const provider = withLazyConnectionHealth(base, invocations, {
      snapshotFor: async () => snapshot,
    });
    return { provider, execute, health: lifecycle.checkConnectionHealth, invocations };
  }

  it("does not health-check roster/specs or successful calls, but retries a read once after a real healthy refresh", async () => {
    const success = lazyHarness({ content: "ok", isError: false });
    const tools = await success.provider.tools(snapshot);
    await success.provider.specs(snapshot);
    const call = tools.find((tool) => tool.name === "integration_call")!;
    await call.execute({ connectionId: CONNECTION_ID, operationId: "list_zones", args: {} }, ctx);
    expect(success.health).not.toHaveBeenCalled();

    const refreshed = lazyHarness({ content: "Provider request failed (HTTP 401).", isError: true });
    refreshed.execute
      .mockResolvedValueOnce({ content: "Provider request failed (HTTP 401).", isError: true })
      .mockResolvedValueOnce({ content: "ok", isError: false });
    const retry = (await refreshed.provider.tools(snapshot)).find((tool) => tool.name === "integration_call")!;
    const outcome = await retry.execute({ connectionId: CONNECTION_ID, operationId: "list_zones", args: {} }, ctx);
    expect(outcome.content).toBe("ok");
    expect(refreshed.health).toHaveBeenCalledWith(CONNECTION_ID, UID, "list_zones");
    expect(refreshed.execute).toHaveBeenCalledTimes(2);
  });

  it("wraps the legacy runProcessor tool-provider path for the selected model operation", async () => {
    const refreshed = lazyHarness({ content: "Provider request failed (HTTP 401).", isError: true });
    const invocations = refreshed.invocations;
    const callTool = vi.fn()
      .mockResolvedValueOnce({ text: "Provider request failed (HTTP 401).", isError: true, content: [] })
      .mockResolvedValueOnce({ text: "ok", isError: false, content: [] });
    const router = {
      connectionHealthInvocations: invocations,
      callTool,
    } as unknown as McpRouter;
    const provider = createMcpToolProvider(router, {
      snapshotFor: async () => snapshot,
      revalidate: async () => "current",
    });
    const selected = (await provider.tools(snapshot)).find((tool) => tool.name === operation.modelName)!;

    const result = await selected.execute({}, ctx);

    expect(result.content).toBe("ok");
    expect(callTool).toHaveBeenCalledTimes(2);
    expect(refreshed.health).toHaveBeenCalledWith(CONNECTION_ID, UID, "list_zones");
  });

  it("does not invoke health for denied selections or non-401 failures", async () => {
    const denied = lazyHarness({ content: "DENIED: unavailable", isError: true });
    const call = (await denied.provider.tools(snapshot)).find((tool) => tool.name === "integration_call")!;
    await call.execute({ connectionId: CONNECTION_ID, operationId: "list_zones", args: {} }, ctx);
    expect(denied.health).not.toHaveBeenCalled();

    const failed = lazyHarness({ content: "Provider request failed (HTTP 500).", isError: true }, false);
    const failedCall = (await failed.provider.tools(snapshot)).find((tool) => tool.name === "integration_call")!;
    await failedCall.execute({ connectionId: CONNECTION_ID, operationId: "list_zones", args: {} }, ctx);
    expect(failed.health).not.toHaveBeenCalled();
  });
});
