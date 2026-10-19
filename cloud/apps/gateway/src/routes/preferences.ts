import type { FastifyInstance } from "fastify";
import { userPreferences, users } from "@ovid/db";
import { userPreferencesPatchSchema, type UserPreferences } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { zodBadRequest } from "./http.js";

/**
 * Wave 1a (SE-005 / owner rule R1): per-user preferences the worker enforces
 * on every run — memoryEnabled (memory_* tools) and shareSessionMemory
 * (cross-session session_search). Mounted inside the authenticated
 * /cloud/v1 scope. Defaults: memory on, sharing OFF.
 */
export function registerPreferenceRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/preferences", async (request): Promise<UserPreferences> => {
    return userPreferences.get(deps.db, request.principal.uid);
  });

  app.patch("/preferences", async (request, reply) => {
    const parsed = userPreferencesPatchSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { uid, email } = request.principal;
    await users.ensure(deps.db, uid, email);
    const prefs: UserPreferences = await userPreferences.patch(deps.db, uid, parsed.data);
    return prefs;
  });
}
