import { afterEach, describe, expect, it, vi } from "vitest";
import { accountSettings, customPresets, type Db } from "@ovid/db";
import { resolveRoute } from "@ovid/agent-core";
import { DEFAULT_NOTIFICATION_PREFERENCES, type KeyResolver } from "@ovid/shared";
import { agentPresetFromCustom, loadRunAccountContext, presetResolverFor, runKeyAdapter, snapshotRunModelContext } from "./runAccount.js";

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

describe("loadRunAccountContext", () => {
  afterEach(() => vi.restoreAllMocks());

  it("fails closed when BYOK settings cannot be read, never falling back to the Ovid allowance", async () => {
    vi.spyOn(accountSettings, "get").mockRejectedValue(new Error("settings unavailable"));
    vi.spyOn(customPresets, "list").mockResolvedValue([]);
    await expect(loadRunAccountContext({} as Db, "u1")).rejects.toThrow("settings unavailable");
  });

  it("fails closed when custom tool restrictions cannot be read", async () => {
    vi.spyOn(accountSettings, "get").mockResolvedValue({
      notificationsEnabled: true,
      notificationPreferences: DEFAULT_NOTIFICATION_PREFERENCES,
      byokDefault: null,
    });
    vi.spyOn(customPresets, "list").mockRejectedValue(new Error("presets unavailable"));
    await expect(loadRunAccountContext({} as Db, "u1")).rejects.toThrow("presets unavailable");
  });
});

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

  it("uses the enqueue-time provider model even if the account default changes before execution", async () => {
    const resolver = recordingResolver();
    const keys = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: KEY_ID },
      byokModel: "gpt-4.1-mini",
      byokDefault: { keyId: "changed-key", model: "changed-model" },
      defaultModel: "auto-default",
    });
    expect((await keys.resolve("u1", "ovid-model"))?.model).toBe("gpt-4.1-mini");
    expect(resolver.ctxs[0]!.byokKeyId).toBe(KEY_ID);
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

describe("inherited model and billing identity", () => {
  it("snapshots the selected preset model and effective BYOK identity without secrets", () => {
    expect(snapshotRunModelContext({
      actorUserId: "participant",
      requestedModel: "picker-model",
      presetModel: "preset-model",
      byokKeyId: null,
      byokDefault: { keyId: KEY_ID, model: "provider-model" },
    })).toEqual({
      requestedModel: "preset-model",
      byokKeyId: KEY_ID,
      byokModel: "provider-model",
      actorUserId: "participant",
    });
  });

  it("inherited null is explicit Auto for both billing classes, never the host pin", async () => {
    const resolver = recordingResolver();
    const ovidAuto = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: null },
      modelContext: {
        requestedModel: null,
        byokKeyId: null,
        actorUserId: "sender-user",
      },
      byokDefault: null,
      defaultModel: "auto-default",
    });
    expect((await ovidAuto.resolve("sender-user", "host-pin"))?.model).toBe("auto-default");

    const byokAuto = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: KEY_ID },
      modelContext: {
        requestedModel: null,
        byokKeyId: KEY_ID,
        byokModel: "accepted-provider-model",
        actorUserId: "sender-user",
      },
      byokDefault: null,
      defaultModel: "auto-default",
    });
    expect((await byokAuto.resolve("sender-user", "host-pin"))?.model)
      .toBe("accepted-provider-model");
    expect(resolver.ctxs.map((ctx) => ctx.byokKeyId ?? null)).toEqual([null, KEY_ID]);
  });

  it("re-resolves only the captured key and never adopts a later billing default", async () => {
    const resolver = recordingResolver();
    const keys = runKeyAdapter({
      resolver,
      ctx: { unattended: false, byokKeyId: "new-default-must-not-apply" },
      modelContext: {
        requestedModel: "captured-model",
        byokKeyId: null,
        actorUserId: "u1",
      },
      byokDefault: { keyId: KEY_ID, model: "new-default-model" },
      defaultModel: "auto-default",
    });
    expect((await keys.resolve("u1", "changed-picker-model"))?.model).toBe("captured-model");
    expect(resolver.ctxs[0]!.byokKeyId).toBeNull();

    const revoked = runKeyAdapter({
      resolver: { resolveForRun: async () => null },
      ctx: { unattended: false, byokKeyId: null },
      modelContext: {
        requestedModel: "captured-model",
        byokKeyId: "revoked-key",
        byokModel: "captured-provider-model",
        actorUserId: "u1",
      },
      byokDefault: null,
      defaultModel: "auto-default",
    });
    expect(await revoked.resolve("u1", "changed-picker-model")).toBeNull();
  });
});

describe("captured route compatibility", () => {
  it("strips an inherited effort suffix without losing route effort", async () => {
    const keys = runKeyAdapter({
      resolver: recordingResolver(),
      ctx: { unattended: false, byokKeyId: null },
      byokDefault: null,
      modelContext: {
        requestedModel: "captured-model · high",
        byokKeyId: null,
        actorUserId: "u1",
      },
      defaultModel: "auto-default",
    });
    const route = await resolveRoute(
      { userId: "u1", requestedModel: "captured-model · high", preset: null },
      { keys, litellmBaseUrl: "https://litellm.test", defaultModel: "auto-default" },
    );
    expect(route).toMatchObject({ model: "captured-model", effort: "high" });
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
