import { describe, expect, it } from "vitest";

import { AUTO_ALIASES, parseModelEffort, resolveRoute } from "./routing.js";
import { litellmKeyResolver, type KeyResolver, type ResolvedKey } from "./keys.js";
import type { KeyProvider } from "@ovid/shared";

// Ported from test/agent_dispatch_route_contract_test.dart (route resolution
// half) + lib/core/agent_service.dart's effort-suffix strip (RegExp
// r'·\s*(low|medium|high)$', case-insensitive) + presets.dart G3 pins.

// ── fixtures ────────────────────────────────────────────────────────────────

const LITELLM_BASE = "https://litellm.internal";
const DEFAULT_MODEL = "gpt-default";
const VIRTUAL_KEY = "lit-virtual-key";

function stubKeyProvider(key: string | null = VIRTUAL_KEY): KeyProvider {
  return { async getKeyForUser(_uid: string): Promise<string | null> { return key; } };
}

function litellmDeps(over?: Partial<{ keys: KeyProvider; resolverKeys: KeyResolver }>) {
  const provider = over?.keys ?? stubKeyProvider();
  return {
    keys: over?.resolverKeys ?? litellmKeyResolver({
      keys: provider, baseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL,
    }),
    litellmBaseUrl: LITELLM_BASE,
    defaultModel: DEFAULT_MODEL,
  };
}

function byokResolver(key: ResolvedKey | null): KeyResolver {
  return { async resolve(): Promise<ResolvedKey | null> { return key; } };
}

const BYOK_KEY: ResolvedKey = {
  kind: "byok-anthropic", apiKey: "sk-ant-byok", baseUrl: "https://api.anthropic.com", model: "claude-byok",
};

// ── parseModelEffort ────────────────────────────────────────────────────────

describe("parseModelEffort", () => {
  it("strips the effort suffix and lowercases the effort", () => {
    expect(parseModelEffort("claude-x · high")).toEqual({ model: "claude-x", effort: "high" });
    expect(parseModelEffort("gpt-5.2 · High")).toEqual({ model: "gpt-5.2", effort: "high" });
    expect(parseModelEffort("gpt-5.2·Medium")).toEqual({ model: "gpt-5.2", effort: "medium" });
  });

  it("no suffix → effort null, model unchanged", () => {
    expect(parseModelEffort("claude-x")).toEqual({ model: "claude-x", effort: null });
    expect(parseModelEffort("deepseek-v4.1 · flash")).toEqual({ model: "deepseek-v4.1 · flash", effort: null });
  });

  it("AUTO_ALIASES covers the bare and fully-qualified alias", () => {
    expect([...AUTO_ALIASES]).toEqual(["auto", "ovid-cloud/auto"]);
  });
});

// ── alias routing (litellm resolver over a stub KeyProvider) ────────────────

describe("resolveRoute — auto alias", () => {
  it("'auto' and 'ovid-cloud/auto' both resolve to the default model on the openai transport", async () => {
    for (const alias of AUTO_ALIASES) {
      const route = await resolveRoute(
        { userId: "u1", requestedModel: alias, preset: null },
        litellmDeps(),
      );
      expect(route).not.toBeNull();
      expect(route).toMatchObject({ transportKind: "openai", model: DEFAULT_MODEL, baseUrl: LITELLM_BASE, apiKey: VIRTUAL_KEY, effort: null, cacheMode: "implicit" });
    }
  });

  it("null requestedModel (no preset) falls back to the default model", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: null, preset: null },
      litellmDeps(),
    );
    expect(route).toMatchObject({ transportKind: "openai", model: DEFAULT_MODEL });
  });

  it("an explicit concrete model passes through verbatim; empty falls back", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "concrete-model", preset: null },
      litellmDeps(),
    );
    expect(route).toMatchObject({ transportKind: "openai", model: "concrete-model" });

    const empty = await resolveRoute(
      { userId: "u1", requestedModel: "", preset: null },
      litellmDeps(),
    );
    expect(empty).toMatchObject({ model: DEFAULT_MODEL });
  });

  it("the effort suffix is parsed off the winner — even off an alias", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto · high", preset: null },
      litellmDeps(),
    );
    expect(route).toMatchObject({ model: DEFAULT_MODEL, effort: "high" });
  });
});

// ── preset pins (presets.dart G3) ───────────────────────────────────────────

describe("resolveRoute — preset pin", () => {
  it("preset.model pin wins over the requested model", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "requested-model", preset: { model: "pinned-model" } },
      litellmDeps(),
    );
    expect(route).toMatchObject({ model: "pinned-model" });
  });

  it("an empty-string pin is absent — the requested model wins", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "requested-model", preset: { model: "" } },
      litellmDeps(),
    );
    expect(route).toMatchObject({ model: "requested-model" });
  });

  it("effort suffix is parsed off the pinned winner too", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "requested-model", preset: { model: "cheap-fast · low" } },
      litellmDeps(),
    );
    expect(route).toMatchObject({ model: "cheap-fast", effort: "low" });
  });

  it("preset.temperature:null → route has NO temperature property (never a synthetic default)", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: { model: null, temperature: null } },
      litellmDeps(),
    );
    expect(route).not.toBeNull();
    expect(route).not.toHaveProperty("temperature");
  });

  it("preset.temperature:0.3 is carried onto the route", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: { temperature: 0.3 } },
      litellmDeps(),
    );
    expect(route).toHaveProperty("temperature", 0.3);
  });

  it("preset.temperature:0 is carried (0 is a value, not an absence)", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: { temperature: 0 } },
      litellmDeps(),
    );
    expect(route).toHaveProperty("temperature", 0);
  });
});

// ── byok-anthropic keys ─────────────────────────────────────────────────────

describe("resolveRoute — byok-anthropic", () => {
  it("routes to the anthropic transport with anthropicNative caching (auto override)", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "claude-byok", preset: null },
      { keys: byokResolver(BYOK_KEY), litellmBaseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL },
    );
    expect(route).not.toBeNull();
    expect(route).toMatchObject({
      transportKind: "anthropic",
      baseUrl: "https://api.anthropic.com",
      apiKey: "sk-ant-byok",
      model: "claude-byok",
      effort: null,
      cacheMode: "anthropicNative",
    });
    expect(route).not.toHaveProperty("temperature");
  });

  it("cacheOverride 'off' → cacheMode 'none' on BOTH kinds", async () => {
    const byok = await resolveRoute(
      { userId: "u1", requestedModel: "claude-byok", preset: null },
      { keys: byokResolver(BYOK_KEY), litellmBaseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL, cacheOverride: "off" },
    );
    expect(byok).toMatchObject({ cacheMode: "none", transportKind: "anthropic" });

    const litellm = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: null },
      { ...litellmDeps(), cacheOverride: "off" },
    );
    expect(litellm).toMatchObject({ cacheMode: "none", transportKind: "openai" });
  });

  it("cacheOverride 'on' on litellm → openaiBlocks", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: null },
      { ...litellmDeps(), cacheOverride: "on" },
    );
    expect(route).toMatchObject({ cacheMode: "openaiBlocks", transportKind: "openai" });
  });
});

// ── no key → null route (P1: run_failed key_not_minted) ─────────────────────

describe("resolveRoute — null key", () => {
  it("a null key yields a null route (no synthetic fallback)", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "auto", preset: null },
      litellmDeps({ keys: stubKeyProvider(null) }),
    );
    expect(route).toBeNull();
  });

  it("a null ResolvedKey from a custom resolver yields a null route", async () => {
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "claude-byok", preset: null },
      { keys: byokResolver(null), litellmBaseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL },
    );
    expect(route).toBeNull();
  });
});

// ── litellmKeyResolver unit contract ────────────────────────────────────────

describe("litellmKeyResolver", () => {
  const resolver = litellmKeyResolver({
    keys: stubKeyProvider(), baseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL,
  });

  it("alias and empty requests map to the default model; kind always litellm", async () => {
    for (const requested of [...AUTO_ALIASES, "", "  "]) {
      const key = await resolver.resolve("u1", requested);
      expect(key).toEqual({ kind: "litellm", apiKey: VIRTUAL_KEY, baseUrl: LITELLM_BASE, model: DEFAULT_MODEL });
    }
  });

  it("a concrete model passes through", async () => {
    expect(await resolver.resolve("u1", "concrete-model")).toEqual({
      kind: "litellm", apiKey: VIRTUAL_KEY, baseUrl: LITELLM_BASE, model: "concrete-model",
    });
  });

  it("null key from the provider → null (P1: run_failed key_not_minted)", async () => {
    const nullish = litellmKeyResolver({
      keys: stubKeyProvider(null), baseUrl: LITELLM_BASE, defaultModel: DEFAULT_MODEL,
    });
    expect(await nullish.resolve("u1", "auto")).toBeNull();
  });
});
