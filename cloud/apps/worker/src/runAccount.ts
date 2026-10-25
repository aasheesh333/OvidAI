import { accountSettings, customPresets, type Db, type InheritedModelContext } from "@ovid/db";
import {
  parseModelEffort,
  presetById,
  type AgentPreset,
  type ResolvedKey as AgentResolvedKey,
} from "@ovid/agent-core";
import type { ByokDefault, CustomPreset, KeyResolver } from "@ovid/shared";
import { agentKeyFor } from "./keyResolver.js";

/**
 * Wave 4 (Settings truthfulness) — the per-run account context the worker
 * reads once per run, beside the Wave 1a memory switches:
 *
 *  - byokDefault (SE-004): the user's own escrowed key + provider model.
 *    When set (and the job carries no explicit byokKeyId), EVERY model call
 *    of the run — engine turns, compaction, prompt hooks — rides that key and
 *    that model. LiteLLM never sees the call, so it is not metered against
 *    the Ovid allowance. A referenced key that cannot be decrypted fails the
 *    run (keyResolver step 1) — never a silent fallback onto Ovid's key.
 *  - custom presets (SE-007): resolved next to the built-ins, so a session
 *    whose presetId is one of the user's custom ids gets its denied tools
 *    (roster + execution gate), model pin and temperature.
 */
export interface RunAccountContext {
  byokDefault: ByokDefault | null;
  /** Built-ins first, then the user's custom presets; null = standard. */
  presets: (id: string | null) => AgentPreset | null;
}

/** A stored custom preset as the agent-core preset shape (a pure denylist). */
export function agentPresetFromCustom(p: CustomPreset): AgentPreset {
  return {
    id: p.id,
    label: p.label,
    description: p.description,
    allowedTools: [],
    deniedTools: [...p.deniedTools],
    persona: "",
    model: p.model,
    modelProviderId: null,
    temperature: p.temperature,
  };
}

export function presetResolverFor(custom: readonly CustomPreset[]): (id: string | null) => AgentPreset | null {
  const byId = new Map(custom.map((p) => [p.id, agentPresetFromCustom(p)]));
  return (id) => {
    if (id == null) return null;
    return presetById(id) ?? byId.get(id) ?? null;
  };
}

/**
 * Billing choices and tool restrictions are not cache-class settings. A read
 * failure must fail the job (and let its normal retry/recovery handle it), not
 * silently route a BYOK user onto Ovid's allowance or drop their deny-list.
 */
export async function loadRunAccountContext(db: Db, userId: string): Promise<RunAccountContext> {
  const [settings, custom] = await Promise.all([
    accountSettings.get(db, userId),
    customPresets.list(db, userId),
  ]);
  return {
    byokDefault: settings.byokDefault,
    presets: presetResolverFor(custom),
  };
}

/**
 * The per-run agent-core key adapter. With a BYOK default, the resolver is
 * asked for that key and the provider model replaces whatever model the
 * session/preset requested (an Ovid catalog id means nothing to the user's
 * provider).
 */
export function snapshotRunModelContext(o: {
  actorUserId: string;
  requestedModel: string | null;
  presetModel?: string | null;
  presetTemperature?: number | null;
  byokKeyId: string | null;
  byokDefault: ByokDefault | null;
  byokModel?: string;
}): InheritedModelContext {
  const presetModel = o.presetModel?.trim() ?? "";
  const useDefault = o.byokKeyId === null && o.byokDefault !== null;
  const byokModel = o.byokModel ?? (useDefault ? o.byokDefault!.model : undefined);
  return {
    requestedModel: presetModel !== "" ? presetModel : o.requestedModel,
    byokKeyId: useDefault ? o.byokDefault!.keyId : o.byokKeyId,
    ...(byokModel !== undefined ? { byokModel } : {}),
    ...(o.presetTemperature !== undefined ? { temperature: o.presetTemperature } : {}),
    actorUserId: o.actorUserId,
  };
}

export function runKeyAdapter(o: {
  resolver: KeyResolver;
  ctx: { unattended: boolean; byokKeyId: string | null };
  byokDefault: ByokDefault | null;
  byokModel?: string;
  defaultModel: string;
  /** A dispatch snapshot freezes both model selection and billing identity. */
  modelContext?: InheritedModelContext;
}): {
  ctx: { unattended: boolean; byokKeyId: string | null };
  resolve(uid: string, requestedModel: string): Promise<AgentResolvedKey | null>;
} {
  const useDefault = o.modelContext === undefined && o.ctx.byokKeyId === null && o.byokDefault !== null;
  const ctx = o.modelContext !== undefined
    ? { ...o.ctx, byokKeyId: o.modelContext.byokKeyId }
    : useDefault ? { ...o.ctx, byokKeyId: o.byokDefault!.keyId } : o.ctx;
  return {
    ctx,
    async resolve(uid, requestedModel) {
      const key = await o.resolver.resolveForRun(uid, ctx);
      if (key === null) return null;
      const captured = o.modelContext !== undefined
        ? o.modelContext.requestedModel
        : requestedModel;
      // An inherited null is explicit Auto; only an absent snapshot falls back
      // to the caller's current model. Ordinary legacy jobs are unchanged.
      const capturedModel = captured === null ? "" : parseModelEffort(captured).model;
      const model = key.kind === "byok"
        ? (o.byokModel ?? o.modelContext?.byokModel ?? (useDefault ? o.byokDefault!.model : capturedModel))
        : capturedModel;
      return agentKeyFor(key, model, o.defaultModel);
    },
  };
}
