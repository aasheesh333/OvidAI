import type { FastifyInstance } from "fastify";
import { z } from "zod";
import {
  accountSettings,
  byokKeysRepo,
  createResponseWaitStore,
  customPresets,
  sessions,
  sessionState,
  userPreferences,
  users,
} from "@ovid/db";
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
  type UserPreferences,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
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

const preferencePatchSchema = z
  .object({
    memoryEnabled: z.boolean().optional(),
    shareSessionMemory: z.boolean().optional(),
    showReasoning: z.boolean().optional(),
    responseWaitSeconds: z.number().int().min(15).max(600).optional(),
  })
  .strict()
  .refine((body) => Object.values(body).some((value) => value !== undefined), {
    message: "At least one preference is required.",
  });

/** Compose the JSON preferences and migration 0033's independent response-wait scalar. */
export function registerPreferenceRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  const responseWait = createResponseWaitStore(deps.db);
  const read = async (uid: string): Promise<UserPreferences & { responseWaitSeconds: number }> => {
    const [preferences, responseWaitSeconds] = await Promise.all([
      userPreferences.get(deps.db, uid),
      responseWait.get(uid),
    ]);
    return { ...preferences, responseWaitSeconds };
  };

  app.get("/preferences", async (request) => read(request.principal.uid));

  app.patch("/preferences", async (request, reply) => {
    const parsed = preferencePatchSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { uid, email } = request.principal;
    const { responseWaitSeconds, ...jsonPatch } = parsed.data;
    await users.ensure(deps.db, uid, email);
    await userPreferences.patch(deps.db, uid, jsonPatch);
    if (responseWaitSeconds !== undefined) {
      await responseWait.set(uid, responseWaitSeconds);
    }
    return read(uid);
  });
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
    if (body.model !== null) {
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
    const { uid, email } = request.principal;
    const existing = await customPresets.list(deps.db, uid);
    if (!existing.some((p) => p.id === id) && existing.length >= MAX_CUSTOM_PRESETS) {
      return sendError(
        reply,
        409,
        "limit_reached",
        `You can keep up to ${MAX_CUSTOM_PRESETS} custom presets. Delete one first.`,
      );
    }
    await users.ensure(deps.db, uid, email);
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
    if (!isBuiltInPreset(presetId) && (await customPresets.get(deps.db, uid, presetId)) === null) {
      return sendError(reply, 404, "not_found", "Preset not found.");
    }
    await sessionState.patch(deps.db, sessionId, { presetId });
    return { sessionId, presetId };
  });
}
