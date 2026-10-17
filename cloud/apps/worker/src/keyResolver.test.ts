import { describe, expect, it } from "vitest";
import type { Redis } from "ioredis";
import { verifyInternalRequest, type ByokKeyProvider } from "@ovid/shared";
import {
  agentKeyFor,
  byokProviderKind,
  createServerKeyResolver,
} from "./keyResolver.js";

/**
 * P9 Task 9 — the worker-side server key resolver.
 *
 * Pins the resolution order:
 *   1. ctx.byokKeyId → byok.getDecrypted. A referenced BYOK key that cannot
 *      be resolved FAILS the run (null) — it must never silently fall back to
 *      Ovid's LiteLLM key (T11 review carry: silent fallback bills Ovid for
 *      a user's BYOK run).
 *   2. GET user:{uid}:key from the mint db2 projection
 *   3. Redis miss + ctx.unattended → signed POST /internal/mint-key
 *   4. Redis miss + attended → null (P4's key_not_minted contract, unchanged)
 *   5. internal 402/403 → null with the reason logged (never an infra error)
 *
 * USE-TIME SSRF: a decrypted BYOK endpoint is re-checked through the same
 * guarded classifier the egress uses (isNonPublicAddress via SsrfGuard) —
 * POST /byok's own validation is not trusted at run time.
 */

const SECRET = "test-internal-secret-0123456789abcdef0123456789";
const LITELLM_BASE = "http://litellm.internal:4000";

interface FetchCall {
  url: string;
  init: RequestInit;
}

function redisWith(value: string | null): Redis {
  return {
    get: async (key: string) => {
      expect(key).toMatch(/^user:.+:key$/);
      return value;
    },
  } as unknown as Redis;
}

function capturingFetch(
  respond: () => Response,
): { fetchImpl: typeof fetch; calls: FetchCall[] } {
  const calls: FetchCall[] = [];
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    return respond();
  }) as typeof fetch;
  return { fetchImpl, calls };
}

function header(init: RequestInit, name: string): string {
  return new Headers(init.headers).get(name) ?? "";
}

/** The production classifier, stubbed: reject loopback/private, accept public. */
function stubGuard(): { assertSafeUrl(raw: string): Promise<URL> } {
  return {
    async assertSafeUrl(raw: string): Promise<URL> {
      const url = new URL(raw);
      const host = url.hostname;
      if (
        host === "localhost" ||
        host === "127.0.0.1" ||
        host === "[::1]" ||
        host.startsWith("10.") ||
        host.startsWith("192.168.") ||
        host === "169.254.169.254"
      ) {
        throw new Error(`host "${host}" resolves to a non-public address`);
      }
      return url;
    },
  };
}

const ANTHROPIC_BYOK: ByokKeyProvider = {
  async getDecrypted(byokKeyId, uid) {
    expect(byokKeyId).toBe("bk-1");
    expect(uid).toBe("user-1");
    return {
      providerId: "anthropic",
      endpoint: "https://api.anthropic.com",
      apiKey: "sk-ant-byok",
    };
  },
};

describe("createServerKeyResolver", () => {
  it("resolves a BYOK id through the escrow provider before touching Redis", async () => {
    const resolver = createServerKeyResolver({
      redisMint: redisWith("sk-should-not-be-read"),
      internalMint: { baseUrl: "http://mint.invalid:8092", secret: SECRET },
      byok: ANTHROPIC_BYOK,
      litellmBaseUrl: LITELLM_BASE,
      guard: stubGuard(),
    });

    await expect(
      resolver.resolveForRun("user-1", { unattended: true, byokKeyId: "bk-1" }),
    ).resolves.toEqual({
      kind: "byok",
      byokKeyId: "bk-1",
      providerId: "anthropic",
      endpoint: "https://api.anthropic.com",
      apiKey: "sk-ant-byok",
    });
  });

  it("FAILS the run when a referenced BYOK key cannot be decrypted (no silent Ovid fallback)", async () => {
    const byok: ByokKeyProvider = { async getDecrypted() { return null; } };
    const logs: Array<{ message: string; detail?: unknown }> = [];
    const resolver = createServerKeyResolver({
      redisMint: redisWith("sk-litellm-must-not-be-used"),
      internalMint: { baseUrl: "http://mint.invalid:8092", secret: SECRET },
      byok,
      litellmBaseUrl: LITELLM_BASE,
      log: (message, detail) => logs.push({ message, detail }),
    });

    await expect(
      resolver.resolveForRun("user-2", { unattended: true, byokKeyId: "bk-gone" }),
    ).resolves.toBeNull();
    expect(logs.some((l) => l.message.includes("byok"))).toBe(true);
  });

  it("rejects a BYOK endpoint that resolves non-public at USE time (SSRF)", async () => {
    const byok: ByokKeyProvider = {
      async getDecrypted() {
        return {
          providerId: "openai",
          endpoint: "https://127.0.0.1/v1",
          apiKey: "sk-private",
        };
      },
    };
    const logs: Array<{ message: string; detail?: unknown }> = [];
    const resolver = createServerKeyResolver({
      redisMint: redisWith("sk-litellm-must-not-be-used"),
      internalMint: { baseUrl: "http://mint.invalid:8092", secret: SECRET },
      byok,
      litellmBaseUrl: LITELLM_BASE,
      guard: stubGuard(),
      log: (message, detail) => logs.push({ message, detail }),
    });

    await expect(
      resolver.resolveForRun("user-3", { unattended: false, byokKeyId: "bk-ssrf" }),
    ).resolves.toBeNull();
    // Logging carries identifiers only — never the endpoint or the key.
    const serialized = JSON.stringify(logs);
    expect(serialized).not.toContain("127.0.0.1");
    expect(serialized).not.toContain("sk-private");
  });

  it("returns the Redis key as kind litellm when no BYOK id is supplied", async () => {
    const resolver = createServerKeyResolver({
      redisMint: redisWith("sk-litellm-2"),
      internalMint: { baseUrl: "http://mint.invalid:8092", secret: SECRET },
      byok: null,
      litellmBaseUrl: LITELLM_BASE,
    });

    await expect(resolver.resolveForRun("user-4", { unattended: false })).resolves.toEqual({
      kind: "litellm",
      key: "sk-litellm-2",
      baseUrl: LITELLM_BASE,
    });
  });

  it("mints internally for an unattended Redis miss with a valid HMAC signature", async () => {
    const { fetchImpl, calls } = capturingFetch(
      () =>
        new Response(JSON.stringify({ key: "sk-internal", tier: "free", baseUrl: "http://x" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
    );
    const resolver = createServerKeyResolver({
      redisMint: redisWith(null),
      internalMint: { baseUrl: "http://mint.internal:8092", secret: SECRET },
      byok: null,
      litellmBaseUrl: LITELLM_BASE,
      fetchImpl,
    });

    await expect(resolver.resolveForRun("user-5", { unattended: true })).resolves.toEqual({
      kind: "litellm",
      key: "sk-internal",
      baseUrl: LITELLM_BASE,
    });

    expect(calls).toHaveLength(1);
    const call = calls[0]!;
    expect(call.url).toBe("http://mint.internal:8092/internal/mint-key");
    expect(call.init.method).toBe("POST");
    expect(JSON.parse(String(call.init.body))).toEqual({ uid: "user-5" });

    const timestamp = header(call.init, "x-ovid-timestamp");
    const signature = header(call.init, "x-ovid-signature");
    expect(
      verifyInternalRequest(
        SECRET,
        "POST",
        "/internal/mint-key",
        "user-5",
        timestamp,
        signature,
        Number(Buffer.from(timestamp, "base64").toString("utf8")),
      ),
    ).toBe(true);
  });

  it("returns null for an attended Redis miss without calling the internal endpoint", async () => {
    const { fetchImpl, calls } = capturingFetch(
      () => new Response(JSON.stringify({ key: "sk-never" }), { status: 200 }),
    );
    const resolver = createServerKeyResolver({
      redisMint: redisWith(null),
      internalMint: { baseUrl: "http://mint.internal:8092", secret: SECRET },
      byok: null,
      litellmBaseUrl: LITELLM_BASE,
      fetchImpl,
    });

    await expect(resolver.resolveForRun("user-6", { unattended: false })).resolves.toBeNull();
    expect(calls).toHaveLength(0);
  });

  it("returns null (never throws) when internal mint answers 402", async () => {
    const { fetchImpl } = capturingFetch(
      () =>
        new Response(JSON.stringify({ detail: "monthly free limit reached" }), {
          status: 402,
          headers: { "content-type": "application/json" },
        }),
    );
    const resolver = createServerKeyResolver({
      redisMint: redisWith(null),
      internalMint: { baseUrl: "http://mint.internal:8092", secret: SECRET },
      byok: null,
      litellmBaseUrl: LITELLM_BASE,
      fetchImpl,
    });

    await expect(resolver.resolveForRun("user-7", { unattended: true })).resolves.toBeNull();
  });
});

describe("BYOK provider-kind mapping", () => {
  it("maps anthropic-family provider ids to the anthropic transport", () => {
    for (const id of ["anthropic", "Anthropic", "claude", "anthropic-compatible"]) {
      expect(byokProviderKind(id), id).toBe("anthropic");
    }
  });

  it("maps openai and every other provider id to the openai-compatible transport", () => {
    for (const id of ["openai", "OPENAI", "openai-compatible", "deepseek", "custom"]) {
      expect(byokProviderKind(id), id).toBe("openai");
    }
  });

  it("agentKeyFor stamps the resolved endpoint (never litellmBaseUrl) on BYOK routes", () => {
    const anthropic = agentKeyFor(
      {
        kind: "byok",
        byokKeyId: "bk-a",
        providerId: "anthropic",
        endpoint: "https://api.anthropic.com",
        apiKey: "sk-ant",
      },
      "",
      "default-model",
    );
    expect(anthropic).toEqual({
      kind: "byok-anthropic",
      apiKey: "sk-ant",
      baseUrl: "https://api.anthropic.com",
      model: "default-model",
    });

    const openai = agentKeyFor(
      {
        kind: "byok",
        byokKeyId: "bk-o",
        providerId: "openai",
        endpoint: "https://api.openai.com/v1",
        apiKey: "sk-openai",
      },
      "gpt-5.6-luna",
      "default-model",
    );
    expect(openai).toEqual({
      kind: "litellm",
      apiKey: "sk-openai",
      baseUrl: "https://api.openai.com/v1",
      model: "gpt-5.6-luna",
    });
  });

  it("agentKeyFor maps a litellm resolution onto the configured LiteLLM origin", () => {
    expect(
      agentKeyFor({ kind: "litellm", key: "sk-live", baseUrl: "" }, "", "default-model"),
    ).toEqual({
      kind: "litellm",
      apiKey: "sk-live",
      baseUrl: "",
      model: "default-model",
    });
  });
});
