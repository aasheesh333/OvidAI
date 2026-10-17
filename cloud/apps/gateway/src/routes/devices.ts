import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { devices, users } from "@ovid/db";
import { deviceRegisterRequestSchema, type DeviceDto } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { zodBadRequest } from "./http.js";

// FCM device registration (P4 Task 11). The token travels in the BODY even on
// DELETE: registration tokens are long, opaque, and not URL-safe. Deletes are
// owner-scoped at the repo, so a wrong-owner token is a silent 204 no-op (no
// existence leak).

const deviceDeleteRequestSchema = z
  .object({ token: z.string().min(1).max(4096) })
  .strict();

export function registerDevicesRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.post("/devices", async (request, reply) => {
    const parsed = deviceRegisterRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    const { uid, email } = request.principal;
    // devices.userId has an FK to users.uid; provision idempotently (the same
    // discipline every user-owned insert follows).
    await users.ensure(deps.db, uid, email);
    const row = await devices.upsert(deps.db, {
      token: parsed.data.token,
      userId: uid,
      platform: parsed.data.platform,
    });
    const dto: DeviceDto = { token: row.token, platform: "android" };
    return dto;
  });

  app.delete("/devices", async (request, reply) => {
    const parsed = deviceDeleteRequestSchema.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    await devices.removeByToken(deps.db, parsed.data.token, request.principal.uid);
    return reply.code(204).send();
  });
}
