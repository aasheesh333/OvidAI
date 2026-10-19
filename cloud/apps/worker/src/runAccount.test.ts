import { describe, expect, it } from "vitest";
import type { KeyResolver } from "@ovid/shared";
import { agentPresetFromCustom, presetResolverFor, runKeyAdapter } from "./runAccount.js";

// Wave 4 — the per-run account context (BYOK default routing, custom presets).

const KEY_ID = "0190a6b2-7c4e-7a10-8000-0000000000aa";

function recordingResolver(): KeyResolver & { ctxs: Array<{ byokKeyId?: string | null }> } {
  const ctxs: Array<{ byokKeyId?: string | null }> = [];
  return {
    ctxs,
    async resolveForRun(_uid, ctx) {
      ctxs.push(ctx);
      return ctx.byokKeyId
        ? { kind: "byok", byokKeyId: ctx.byokKeyId, providerId: "openai", endpoint: "https://api.openai.com/v1", apiKey: "sk-user" }
        : { kind: "litellm", key: "sk-ovid", baseUrl: "https://litellm.test" };
    },
  };
}

describe("runKeyAdapter", () => {
  it("without a BYOK default: Ovid's key, the requested model", async () => {
    const resolver = recordingResolver();
    const keys = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: null },
      byokDefault: null,
      defaultModel: "auto-default",
    });
    const key = await keys.resolve("u1", "glm-5.3");
    expect(key).toEqual({ kind: "litellm", apiKey: "sk-ovid", baseUrl: "https://litellm.test", model: "glm-5.3" });
    expect(resolver.ctxs[0]!.byokKeyId).toBeNull();
  });

  it("with a BYOK default: the user's key and provider model replace the Ovid route", async () => {
    const resolver = recordingResolver();
    const keys = runKeyAdapter({
      resolver,
      ctx: { unattended: true, byokKeyId: null },
      byokDefault: { keyId: KEY_ID, model: "gpt-4.1-mini" },
      defaultModel: "auto-default",
    });
    const key = await keys.resolve("u1", "glm-5.3");
    expect(key).toEqual({
      kind: "litellm",
      apiKey: "sk-user",
      baseUrl: "https://api.openai.com/v1",
      model: "gpt-4.1-mini",
    });
    expect(resolver.ctxs[0]).toEqual({ unattended: true, byokKeyId: KEY_ID });
    expect(keys.ctx.byokKeyId).toBe(KEY_ID);
  });

  it("an explicit job byokKeyId wins over the default (and keeps the requested model)", async () => {
    const resolver = recordingResolver();
    const keys = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: "job-key" },
      byokDefault: { keyId: KEY_ID, model: "gpt-4.1-mini" },
      defaultModel: "auto-default",
    });
    const key = await keys.resolve("u1", "claude-x");
    expect(resolver.ctxs[0]!.byokKeyId).toBe("job-key");
    expect(key?.model).toBe("claude-x");
  });

  it("an undecryptable BYOK key fails (null) — never a silent Ovid fallback", async () => {
    const keys = runKeyAdapter({
      resolver: { resolveForRun: async () => null },
      ctx: { unattended: false, byokKeyId: null },
      byokDefault: { keyId: KEY_ID, model: "m" },
      defaultModel: "d",
    });
    expect(await keys.resolve("u1", "auto")).toBeNull();
  });
});

describe("custom preset resolution", () => {
  const custom = {
    id: "custom-safe",
    label: "Safe",
    description: "d",
    deniedTools: ["run_shell"],
    model: "glm-5.3",
    temperature: 0.4,
  };

  it("maps a stored preset onto a denylist agent preset", () => {
    expect(agentPresetFromCustom(custom)).toEqual({
      id: "custom-safe",
      label: "Safe",
      description: "d",
      allowedTools: [],
      deniedTools: ["run_shell"],
      persona: "",
      model: "glm-5.3",
      modelProviderId: null,
      temperature: 0.4,
    });
  });

  it("resolves built-ins first, then the user's custom ids; unknown → null (standard)", () => {
    const resolve = presetResolverFor([custom]);
    expect(resolve("minimal")?.id).toBe("minimal");
    expect(resolve("custom-safe")?.deniedTools).toEqual(["run_shell"]);
    expect(resolve("custom-gone")).toBeNull();
    expect(resolve(null)).toBeNull();
  });
});
