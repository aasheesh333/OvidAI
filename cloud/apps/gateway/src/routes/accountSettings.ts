import type { FastifyInstance } from "fastify";
import { accountSettings, byokKeysRepo, customPresets, sessions, sessionState, users } from "@ovid/db";
import {
  accountSettingsPatchSchema,
  CLOUD_PRESET_IDS,
  CUSTOM_PRESET_ID_RE,
  customPresetBodySchema,
  MAX_CUSTOM_PRESETS,
  PRESET_TOOL_GROUPS,
  sessionPresetBodySchema,
  type AccountSettings,
  type CustomPreset,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { assertModelAllowed, PlanGateError } from "../planGate.js";
import { badRequest, isUuid, notFound, sendError, zodBadRequest } from "./http.js";

/**
 * Wave 4 (Settings truthfulness) — account settings the worker enforces.
 * All mounted inside the authenticated /cloud/v1 scope.
 *
 *  - GET/PATCH /settings: push notifications on/off (SE-010) and the BYOK
 *    key + model runs use (SE-004). A byokDefault must name one of the
 *    caller's own escrowed keys.
 *  - GET /presets, PUT/DELETE /presets/:id: the caller's custom agent
 *    presets (SE-007) — denied tool families, an optional Ovid model pin and
 *    temperature. The worker resolves them per run; a denied tool is removed
 *    from the roster and refused if the model calls it anyway.
 *  - PUT /sessions/:id/preset: applies a built-in or custom preset to a
 *    chat (the per-message `presetId` only accepts built-ins).
 */

/** Allowed Ovid model ids (lowercased) or null = cannot judge (fail open). */
async function modelCatalog(deps: GatewayDeps): Promise<Set<string> | null> {
  if (deps.modelCatalog === undefined) return null;
  try {
    const list = await deps.modelCatalog();
    if (list === null || list.length === 0) return null;
    return new Set(list.map((m) => m.trim().toLowerCase()));
  } catch {
    return null;
  }
}

function isBuiltInPreset(id: string): boolean {
  return (CLOUD_PRESET_IDS as readonly string[]).includes(id);
}

export function registerAccountSettingsRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  // -- account settings -----------------------------------------------------

  app.get("/settings", async (request): Promise<AccountSettings> => {
    return accountSettings.get(deps.db, request.principal.uid);
  });

  app.patch("/settings", async (request, reply) => {
    const parsed = accountSettingsPatchSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { uid, email } = request.principal;
    const byokDefault = parsed.data.byokDefault;
    if (byokDefault !== undefined && byokDefault !== null) {
      const key = await byokKeysRepo.get(deps.db, byokDefault.keyId, uid);
      if (key === null) {
        return sendError(reply, 404, "not_found", "That API key was not found. Add it again.");
      }
    }
    await users.ensure(deps.db, uid, email);
    const next: AccountSettings = await accountSettings.patch(deps.db, uid, parsed.data);
    return next;
  });

  // -- custom presets ---------------------------------------------------------

  app.get("/presets", async (request) => {
    return {
      builtIn: [...CLOUD_PRESET_IDS],
      custom: await customPresets.list(deps.db, request.principal.uid),
      toolGroups: PRESET_TOOL_GROUPS.map((g) => ({ id: g.id, label: g.label, tools: [...g.tools] })),
      maxCustom: MAX_CUSTOM_PRESETS,
    };
  });

  app.put("/presets/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!CUSTOM_PRESET_ID_RE.test(id)) {
      return badRequest(reply, "Custom preset ids look like custom-my-preset.");
    }
    const parsed = customPresetBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const body = parsed.data;
    const { uid, email } = request.principal;
    // P3 plan gate: a preset's model is a ROUTED model — runs that apply the
    // preset use it directly, so Free/Go must not be able to store one.
    const user = await users.ensure(deps.db, uid, email);
    if (body.model !== null) {
      try {
        assertModelAllowed(user.tier, body.model);
      } catch (err) {
        if (err instanceof PlanGateError) {
          return sendError(reply, err.status, err.code, err.message);
        }
        throw err;
      }
      const known = await modelCatalog(deps);
      if (known !== null && !known.has(body.model.toLowerCase())) {
        return sendError(
          reply,
          400,
          "model_unavailable",
          "That model is not available on Ovid Cloud. Pick another model.",
        );
      }
    }
    const existing = await customPresets.list(deps.db, uid);
    if (!existing.some((p) => p.id === id) && existing.length >= MAX_CUSTOM_PRESETS) {
      return sendError(
        reply,
        409,
        "limit_reached",
        `You can keep up to ${MAX_CUSTOM_PRESETS} custom presets. Delete one first.`,
      );
    }
    const preset: CustomPreset = {
      id,
      label: body.label,
      description: body.description,
      deniedTools: [...new Set(body.deniedTools)],
      model: body.model,
      temperature: body.temperature,
    };
    await customPresets.upsert(deps.db, uid, preset);
    return preset;
  });

  app.delete("/presets/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    const removed = CUSTOM_PRESET_ID_RE.test(id)
      ? await customPresets.remove(deps.db, request.principal.uid, id)
      : false;
    if (!removed) return sendError(reply, 404, "not_found", "Preset not found.");
    return reply.code(204).send();
  });

  app.put("/sessions/:id/preset", async (request, reply) => {
    const { id: sessionId } = request.params as { id: string };
    const { uid } = request.principal;
    if (!isUuid(sessionId)) return notFound(reply);
    const session = await sessions.get(deps.db, sessionId, uid);
    if (session === null) return notFound(reply);
    const parsed = sessionPresetBodySchema.safeParse(request.body ?? undefined);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const presetId = parsed.data.presetId;
    if (!isBuiltInPreset(presetId)) {
      const preset = await customPresets.get(deps.db, uid, presetId);
      if (preset === null) return sendError(reply, 404, "not_found", "Preset not found.");
      // P3 plan gate for the routed-model path: applying a preset pins its
      // model for the chat's next runs. A manual model requires Plus/Pro —
      // enforced here even if the preset was stored before a downgrade.
      if (preset.model !== null) {
        const user = await users.ensure(deps.db, uid, null);
        try {
          assertModelAllowed(user.tier, preset.model);
        } catch (err) {
          if (err instanceof PlanGateError) {
            return sendError(reply, err.status, err.code, err.message);
          }
          throw err;
        }
      }
    }
    await sessionState.patch(deps.db, sessionId, { presetId });
    return { sessionId, presetId };
  });
}
