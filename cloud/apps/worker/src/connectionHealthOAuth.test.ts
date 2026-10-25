// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createEnvelopeCrypto,
  type EncryptedEnvelope,
  type GuardedFetch,
} from "@ovid/mcp";
import {
  mcpOauthTokens,
  mcpServers as serverRepo,
  type Db,
  type McpOauthTokenRow,
  type McpServerRow,
} from "@ovid/db";

import { createConnectionHealthOAuthRefresher } from "./connectionHealthOAuth.js";

const MASTER_KEY = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const CONNECTION_ID = "11111111-1111-4111-8111-111111111111";
const UID = "oauth-health-user";
const EXPECTED = { configVersion: 8, disconnectGeneration: 3 };

afterEach(() => {
  vi.restoreAllMocks();
});

const NOW = new Date("2026-10-25T01:00:00.000Z");

interface TokenMaterial {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number | null;
  tokenUrl: string;
  clientId: string;
  clientSecret: string | null;
  resource: string | null;
}

function material(overrides: Partial<TokenMaterial> = {}): TokenMaterial {
  return {
    accessToken: "old-access-token",
    refreshToken: "old-refresh-token",
    expiresAt: Date.parse("2026-10-25T00:30:00.000Z"),
    tokenUrl: "https://auth.example.test/token",
    clientId: "ovid-test-client",
    clientSecret: "old-client-secret",
    resource: "https://provider.example.test/mcp",
    ...overrides,
  };
}

function setup(options: {
  fetchImpl: GuardedFetch;
  tokens?: TokenMaterial | null;
}) {
  const crypto = createEnvelopeCrypto(MASTER_KEY);
  const tokens = options.tokens === undefined ? material() : options.tokens;
  const row: McpOauthTokenRow | null = tokens === null ? null : {
    id: "token-row",
    userId: UID,
    serverId: CONNECTION_ID,
    tokensSealed: crypto.encrypt(JSON.stringify(tokens), `mcp_oauth_tokens:${CONNECTION_ID}`) as EncryptedEnvelope,
    updatedAt: NOW,
  };
  const server: McpServerRow = {
    id: CONNECTION_ID,
    userId: UID,
    name: "OAuth connection",
    transport: "native",
    curatedId: "google-drive",
    providerId: "google-drive",
    agentEnabled: true,
    authState: "authorized",
    healthState: "never_checked",
    lastCheckedAt: null,
    lastSuccessAt: null,
    configVersion: EXPECTED.configVersion,
    disconnectGeneration: EXPECTED.disconnectGeneration,
    approvedSourceId: null,
    approvedDigest: null,
    normalizedConnectionName: "oauth connection",
    config: null,
    secretsSealed: null,
    enabled: true,
    createdAt: NOW,
    updatedAt: NOW,
  };
  const get = vi.spyOn(mcpOauthTokens, "get").mockResolvedValue(row);
  const serverGet = vi.spyOn(serverRepo, "get").mockResolvedValue(server);
  const put = vi.spyOn(mcpOauthTokens, "put").mockRejectedValue(new Error("unfenced put must not be called"));
  const refresh = createConnectionHealthOAuthRefresher({
    db: {} as Db,
    crypto,
    fetchImpl: options.fetchImpl,
    now: () => NOW,
  });
  return {
    crypto,
    get,
    server,
    serverGet,
    put,
    refresh,
    async run(writeToken: (token: unknown) => Promise<boolean> = async () => true, signal = new AbortController().signal) {
      return refresh({ connectionId: CONNECTION_ID, userId: UID }, {
        expected: EXPECTED,
        signal,
        writeToken,
      });
    },
  };
}

describe("real OAuth health refresh adapter", () => {
  it("uses guarded refresh and seals rotated access tokens only through the fenced callback", async () => {
    let request: { url: string; init?: RequestInit } | undefined;
    const wire: GuardedFetch = async (url, init) => {
      request = { url, init };
      return new Response(JSON.stringify({
        access_token: "new-access-token",
        token_type: "Bearer",
        expires_in: 3600,
      }), { status: 200, headers: { "content-type": "application/json" } });
    };
    const { crypto, put, run } = setup({ fetchImpl: wire });
    let sealed: EncryptedEnvelope | undefined;

    const outcome = await run(async (token) => {
      sealed = token as EncryptedEnvelope;
      return true;
    });

    expect(outcome).toEqual({ status: "refreshed" });
    expect(outcome).not.toHaveProperty("token");
    expect(put).not.toHaveBeenCalled();
    expect(request?.url).toBe("https://auth.example.test/token");
    expect(request?.init?.method).toBe("POST");
    const fields = new URLSearchParams(String(request?.init?.body));
    expect(fields.get("grant_type")).toBe("refresh_token");
    expect(fields.get("refresh_token")).toBe("old-refresh-token");
    expect(fields.get("client_secret")).toBe("old-client-secret");
    expect(sealed).toBeDefined();
    const persisted = JSON.parse(crypto.decrypt(sealed!, `mcp_oauth_tokens:${CONNECTION_ID}`)) as TokenMaterial;
    expect(persisted).toMatchObject({
      accessToken: "new-access-token",
      refreshToken: "old-refresh-token",
      expiresAt: Date.parse("2026-10-25T02:00:00.000Z"),
    });
  });

  it.each([
    [400, { error: "invalid_grant", error_description: "provider secret text" }, "invalid_grant"],
    [401, { error: "invalid_token", error_description: "provider secret text" }, "unauthorized"],
    [503, { error: "temporarily_unavailable" }, "unavailable"],
  ] as const)("maps OAuth HTTP %i without exposing provider payloads", async (status, body, reason) => {
    const wire: GuardedFetch = async () => new Response(JSON.stringify(body), { status });
    const { put, run } = setup({ fetchImpl: wire });
    const writeToken = vi.fn(async () => true);

    const outcome = await run(writeToken);

    expect(outcome).toEqual({ status: "failed", reason });
    expect(JSON.stringify(outcome)).not.toContain("provider secret text");
    expect(writeToken).not.toHaveBeenCalled();
    expect(put).not.toHaveBeenCalled();
  });

  it("does not dispatch refresh after a cross-process parent generation change", async () => {
    let calls = 0;
    const wire: GuardedFetch = async () => {
      calls += 1;
      return new Response(JSON.stringify({ access_token: "must-not-refresh" }), { status: 200 });
    };
    const { run, server, serverGet } = setup({ fetchImpl: wire });
    serverGet.mockResolvedValue({ ...server, disconnectGeneration: server.disconnectGeneration + 1 });

    const outcome = await run();

    expect(outcome).toEqual({ status: "failed", reason: "unavailable" });
    expect(calls).toBe(0);
  });

  it("aborts the actual refresh request and never writes its late token", async () => {
    const controller = new AbortController();
    let observedSignal: AbortSignal | undefined;
    let requestStarted!: () => void;
    const started = new Promise<void>((resolve) => { requestStarted = resolve; });
    const wire: GuardedFetch = async (_url, init) => {
      observedSignal = init?.signal ?? undefined;
      requestStarted();
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(init.signal?.reason), { once: true });
      });
    };
    const { run } = setup({ fetchImpl: wire });
    const writeToken = vi.fn(async () => true);
    const pending = run(writeToken, controller.signal);
    await started;
    controller.abort("disconnect");

    await expect(pending).resolves.toEqual({ status: "failed", reason: "unavailable" });
    expect(observedSignal?.aborted).toBe(true);
    expect(writeToken).not.toHaveBeenCalled();
  });

  it("bounds a token endpoint that stalls before response headers", async () => {
    vi.useFakeTimers();
    try {
      let observedSignal: AbortSignal | undefined;
      const wire: GuardedFetch = async (_url, init) => {
        observedSignal = init?.signal ?? undefined;
        return new Promise<Response>(() => {});
      };
      const { run } = setup({ fetchImpl: wire });
      const pending = run();

      await vi.advanceTimersByTimeAsync(30_000);

      await expect(pending).resolves.toEqual({ status: "failed", reason: "unavailable" });
      expect(observedSignal?.aborted).toBe(true);
    } finally {
      vi.useRealTimers();
    }
  });

  it("aborts an active stalled body read after headers, not only the pre-read fast path", async () => {
    const controller = new AbortController();
    let bodyReadStarted!: () => void;
    const started = new Promise<void>((resolve) => { bodyReadStarted = resolve; });
    let readerCancelled = false;
    const body = new ReadableStream<Uint8Array>({
      start(stream) {
        const underlying = stream.getReader();
        let readStarted = false;
        // Instrument the same underlying reader shape consumed by readOAuthBody:
        // signal only when the real bounded reader is blocked in reader.read().
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
    const wire: GuardedFetch = async () => new Response(body, {
      status: 200,
      headers: { "content-type": "application/json" },
    });
    const { run } = setup({ fetchImpl: wire });
    const pending = run(undefined, controller.signal);
    const deadline = new Promise<"settled">((resolve) => setTimeout(() => resolve("settled"), 100));
    let settled = false;
    void pending.finally(() => { settled = true; });
    await started;

    controller.abort("disconnect-after-body-read-started");
    const outcome = await Promise.race([pending, deadline]);

    expect(outcome).toEqual({ status: "failed", reason: "unavailable" });
    expect(settled).toBe(true);
    expect(readerCancelled).toBe(true);
  });

  it("returns unavailable when the fenced token write loses and retains no token in the outcome", async () => {
    const wire: GuardedFetch = async () => new Response(JSON.stringify({
      access_token: "must-not-be-shared",
      token_type: "Bearer",
    }), { status: 200 });
    const { run } = setup({ fetchImpl: wire });

    const outcome = await run(async () => false);

    expect(outcome).toEqual({ status: "failed", reason: "unavailable" });
    expect(JSON.stringify(outcome)).not.toContain("must-not-be-shared");
  });

  it("does not refresh missing or malformed grants and never falls back to the legacy unfenced put", async () => {
    const wire: GuardedFetch = async () => {
      throw new Error("network must not be called");
    };
    const missing = setup({ fetchImpl: wire, tokens: null });
    await expect(missing.run()).resolves.toEqual({ status: "failed", reason: "unauthorized" });
    expect(missing.put).not.toHaveBeenCalled();
    const noRefresh = setup({ fetchImpl: wire, tokens: material({ refreshToken: null }) });
    await expect(noRefresh.run()).resolves.toEqual({ status: "failed", reason: "unauthorized" });
    expect(noRefresh.put).not.toHaveBeenCalled();
  });
});
