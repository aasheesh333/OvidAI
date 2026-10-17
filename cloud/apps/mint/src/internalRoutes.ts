import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { INTERNAL_MINT_PATH } from "@ovid/shared";
import { isBanned } from "./antiAbuse.js";
import type { MintDeps } from "./app.js";
import { HttpContractError } from "./app.js";
import { requireInternalSignature } from "./internalAuth.js";
import { litellmMintOrGet } from "./keyMint.js";
import { requireNoDeletionFence } from "./mintRoutes.js";
import { storedTier } from "./planMath.js";
import { effectiveTier, freeCapRemaining, planFor } from "./windows.js";

/**
 * P9 Task 9 — the INTERNAL server-to-server mint route.
 *
 * Registered on the ADMIN listener ONLY (port 8092, loopback / compose
 * network). It is never registered on publicApp: the public surface keeps
 * Firebase verification, while this route trusts the signed caller and the
 * uid that signature binds.
 *
 * Ladder (identical to /mint minus the Firebase and per-IP/signup rungs):
 *   signature 401 → banned 403 → deletion fence 403 → free cap 402 →
 *   lock 409 (inside litellmMintOrGet) → key.
 *
 * Replays inside the ±300 s window are accepted: the route is idempotent by
 * design (one key per (uid, platform) + the mint lock), so a replayed request
 * returns the same key and creates nothing new. There is no nonce store.
 */

const internalMintBody = z
  .object({
    uid: z.string().trim().min(1).max(200),
    platform: z.enum(["android", "web"]).optional(),
  })
  .strict();

export function registerInternalRoutes(adminApp: FastifyInstance, deps: MintDeps): void {
  adminApp.post(INTERNAL_MINT_PATH, async (request, reply) => {
    const parsed = internalMintBody.safeParse(request.body ?? {});
    if (!parsed.success) {
      throw new HttpContractError(400, "uid is required");
    }
    const uid = parsed.data.uid;
    const platform = parsed.data.platform ?? "android";

    // Signature BEFORE any lookup: an unsigned caller learns nothing about
    // the uid (not even whether it exists).
    const now = Math.floor((deps.clock?.() ?? new Date()).getTime() / 1000);
    requireInternalSignature(deps, request, INTERNAL_MINT_PATH, uid, now);

    if (await isBanned(deps, uid, "")) {
      throw new HttpContractError(403, "account suspended");
    }
    await requireNoDeletionFence(deps, uid);

    const tier = await effectiveTier(deps, uid);
    if (tier === "free" && (await freeCapRemaining(deps, uid)) <= 0) {
      throw new HttpContractError(402, "monthly free limit reached");
    }

    const key = await litellmMintOrGet(deps, uid, tier, platform, deps.mintLock);
    const plan = await planFor(deps, uid);
    return reply.send({
      key,
      tier: storedTier(plan),
      baseUrl: deps.env.publicBaseUrl,
    });
  });
}
