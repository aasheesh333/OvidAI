// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { afterEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import {
  mcpOauthFlows,
  mcpServers as serverRepo,
  type Db,
  type McpServerRow,
} from "@ovid/db";
import {
  createOAuthFlow,
  type ConnectionHealthInvocations,
  type HealthConnection,
  type HealthTransition,
} from "@ovid/mcp";

import { buildGateway } from "../app.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";
import { createEnvelopeCrypto } from "../../../../packages/mcp/src/crypto.js";

const UID = "gateway-health-owner";
const ID = "11111111-1111-4111-8111-111111111111";

function raw(overrides: Partial<McpServerRow> = {}): McpServerRow {
  return {
    id: ID,
    userId: UID,
    name: "GitHub",
    transport: "native",
    curatedId: "github",
    providerId: "github",
    agentEnabled: true,
    authState: "authorized",
    healthState: "never_checked",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 4,
    disconnectGeneration: 2,
    approvedSourceId: null,
    approvedDigest: null,
    normalizedConnectionName: "github",
    config: null,
    secretsSealed: null,
    enabled: true,
    createdAt: new Date("2026-10-25T00:00:00.000Z"),
    updatedAt: new Date("2026-10-25T00:00:00.000Z"),
    ...overrides,
  };
}

function health(overrides: Partial<HealthConnection> = {}): HealthConnection {
  return {
    connectionId: ID,
    userId: UID,
    providerId: "github",
    enabled: true,
    agentEnabled: true,
    authState: "authorized",
    healthState: "checking",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: 4,
    disconnectGeneration: 2,
    hasSecrets: false,
    ...overrides,
  };
}

function transition(): HealthTransition {
  const connection = health();
  return {
    connection,
    from: "never_checked",
    to: connection.healthState,
    lastCheckedAt: null,
    lastSuccessAt: null,
    persisted: true,
    code: "checked",
  };
}

describe("gateway worker-owned connection health composition", () => {
  let app: FastifyInstance | undefined;
  afterEach(async () => {
    await app?.close();
    app = undefined;
    vi.restoreAllMocks();
  });

  function setup(row = raw()) {
    vi.spyOn(serverRepo, "get").mockImplementation(async (_db, _id, uid) => uid === UID ? row : null);
    const disconnectAuthenticated = vi.fn(async () => health({
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
      disconnectGeneration: 3,
    }));
    const invocations: ConnectionHealthInvocations = {
      checkAuthenticated: vi.fn(async () => transition()),
      getAuthenticated: vi.fn(async () => health({ healthState: "refreshing" })),
      disconnectAuthenticated,
      checkSelectedOperation: vi.fn(async () => {
        throw new Error("gateway must not use selected lazy snapshots");
      }),
    };
    const invalidate = vi.fn();
    const deps = {
      system: stubSystemBus(),
      db: {} as Db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      connectionHealthInvocations: invocations,
      connectionGenerationListener: { invalidate },
    };
    app = buildGateway(deps);
    return { invocations, invalidate, disconnectAuthenticated };
  }

  it("POST passes the reviewed default operationId and strict caller-selected operationId", async () => {
    const { invocations } = setup();

    const checked = await app!.inject({
      method: "POST",
      url: `/cloud/v1/mcp/connections/${ID}`,
      headers: authHeaders(UID),
    });
    expect(checked.statusCode, checked.body).toBe(200);
    expect(invocations.checkAuthenticated).toHaveBeenNthCalledWith(1, {
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
      operationId: "get_user",
    });

    await app!.inject({
      method: "POST",
      url: `/cloud/v1/mcp/connections/${ID}`,
      headers: authHeaders(UID),
      payload: { operationId: "list_issues" },
    });
    expect(invocations.checkAuthenticated).toHaveBeenNthCalledWith(2, {
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
      operationId: "list_issues",
    });
  });

  it("GET uses worker-live checking/refreshing projection rather than only persisted health", async () => {
    const { invocations } = setup(raw({ healthState: "healthy" }));
    const read = await app!.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${ID}`,
      headers: authHeaders(UID),
    });

    expect(read.statusCode).toBe(200);
    expect(read.json()).toMatchObject({ healthState: "refreshing" });
    expect(invocations.getAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
  });

  it.each(["connections", "servers"] as const)(
    "gateway-local callback body abort precedes worker disconnect for /mcp/%s/:id",
    async (collection) => {
      const { invocations, disconnectAuthenticated } = setup();
      const crypto = createEnvelopeCrypto(
        "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829",
      );
      const state = "gateway-local-abort-state";
      const verifierSealed = crypto.encrypt(
        JSON.stringify({ verifier: "verifier", clientSecret: null }),
        `mcp_oauth_flows:${state}`,
      );
      const config = {
        authorizationUrl: "https://auth.example.test/authorize",
        tokenUrl: "https://auth.example.test/token",
        clientId: "client",
        scopes: [],
        discovered: true,
        redirectUri: "https://ovidsi.com/oauth/callback",
      };
      vi.spyOn(mcpOauthFlows, "consume").mockResolvedValue({
        state,
        userId: UID,
        serverId: ID,
        verifierSealed,
        config,
        expiresAt: new Date("2026-10-26T00:00:00.000Z"),
        used: true,
        createdAt: new Date("2026-10-25T00:00:00.000Z"),
      });
      let bodyReadStarted!: () => void;
      const started = new Promise<void>((resolve) => { bodyReadStarted = resolve; });
      let readerCancelled = false;
      const body = new ReadableStream<Uint8Array>({
        start(stream) {
          const underlying = stream.getReader();
          let readStarted = false;
          Object.defineProperty(stream, "getReader", {
            value: () => ({
              read: () => {
                if (!readStarted) {
                  readStarted = true;
                  bodyReadStarted();
                }
                return new Promise<never>(() => {});
              },
              cancel: async () => {
                readerCancelled = true;
              },
              releaseLock: () => underlying.releaseLock(),
            }),
          });
        },
      });
      const oauth = createOAuthFlow({
        db: {} as Db,
        crypto,
        systemBus: { async publish() {} },
        fetchImpl: async () => new Response(body, {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      });
      const callback = oauth.handleCallback({ state, code: "code" });
      await started;
      const ordering: string[] = [];
      disconnectAuthenticated.mockImplementationOnce(async () => {
        ordering.push(`worker-disconnect:${readerCancelled}`);
        return health({
          enabled: false,
          agentEnabled: false,
          authState: "revoked",
          healthState: "revoked",
          disconnectGeneration: 3,
        });
      });
      const remove = collection === "servers"
        ? vi.spyOn(serverRepo, "remove").mockImplementationOnce(async () => {
            ordering.push("row-remove");
            return true;
          })
        : undefined;
      await app?.close();
      app = buildGateway({
        system: stubSystemBus(),
        db: {} as Db,
        queues: stubQueues().queues,
        verifier: stubVerifier(),
        tickets: stubTickets(),
        keys: stubKeys(),
        mint: stubMint(),
        events: noopEvents,
        oauth,
        connectionHealthInvocations: invocations,
      });

      const foreign = await app.inject({
        method: "DELETE",
        url: `/cloud/v1/mcp/${collection}/${ID}`,
        headers: authHeaders("someone-else"),
      });
      expect(foreign.statusCode).toBe(404);
      expect(readerCancelled).toBe(false);
      expect(disconnectAuthenticated).not.toHaveBeenCalled();
      if (remove !== undefined) expect(remove).not.toHaveBeenCalled();

      const removed = await app.inject({
        method: "DELETE",
        url: `/cloud/v1/mcp/${collection}/${ID}`,
        headers: authHeaders(UID),
      });

      expect(removed.statusCode).toBe(204);
      expect(readerCancelled).toBe(true);
      expect(ordering).toEqual(collection === "servers"
        ? ["worker-disconnect:true", "row-remove"]
        : ["worker-disconnect:true"]);
      await expect(Promise.race([
        callback,
        new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 1_000)),
      ])).resolves.toMatchObject({ ok: false, reason: "oauth_failed" });
    },
    5_000,
  );

  it("legacy server DELETE disconnects and closes before owned row removal, preserving wrong-owner 404", async () => {
    const { invocations, disconnectAuthenticated } = setup();
    const remove = vi.spyOn(serverRepo, "remove").mockResolvedValue(true);

    const foreign = await app!.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/servers/${ID}`,
      headers: authHeaders("someone-else"),
    });
    expect(foreign.statusCode).toBe(404);
    expect(invocations.disconnectAuthenticated).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();

    const removed = await app!.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/servers/${ID}`,
      headers: authHeaders(UID),
    });
    expect(removed.statusCode).toBe(204);
    expect(invocations.disconnectAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
    expect(remove).toHaveBeenCalledWith(expect.anything(), ID, UID);
    expect(disconnectAuthenticated.mock.invocationCallOrder[0])
      .toBeLessThan(remove.mock.invocationCallOrder[0]!);
  });

  it("DELETE calls disconnectAuthenticated and rejects strict health-body extras before invocation", async () => {
    const { invocations, invalidate } = setup();
    const invalid = await app!.inject({
      method: "POST",
      url: `/cloud/v1/mcp/connections/${ID}`,
      headers: authHeaders(UID),
      payload: { operationId: "get_user", extra: true },
    });
    expect(invalid.statusCode).toBe(400);
    expect(invocations.checkAuthenticated).not.toHaveBeenCalled();

    const removed = await app!.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/connections/${ID}`,
      headers: authHeaders(UID),
    });
    expect(removed.statusCode).toBe(204);
    expect(invocations.disconnectAuthenticated).toHaveBeenCalledWith({
      principal: { uid: UID, authenticated: true },
      connectionId: ID,
    });
    expect(invalidate).toHaveBeenCalledWith({
      connectionId: ID,
      userId: UID,
      configVersion: 4,
      disconnectGeneration: 3,
    });
  });
});
