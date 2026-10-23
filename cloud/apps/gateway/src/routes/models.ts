import type { FastifyInstance } from "fastify";
import { users } from "@ovid/db";
import { manualModelsAllowed } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";

/**
 * The model catalog, as one call.
 *
 * Until now the only way to know which models exist was to send a message and
 * be refused. `deps.modelCatalog` is the same mint-backed list the send route
 * validates against, so this route cannot advertise a model the send route
 * would reject.
 *
 * It reports the account's tier AND whether that tier may pick a manual model.
 * The rule itself still lives only in `plans.ts` — this route calls it rather
 * than restating it, so the catalog, the send route and both clients cannot
 * disagree about which tiers are auto-only.
 *
 * The `auto` alias is not a model: it lets the gateway pick per run. It is
 * always first, because it is the only choice every tier has.
 */
export function registerModelRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/models", async (request) => {
    const { uid, email } = request.principal;
    const user = await users.ensure(deps.db, uid, email);

    let models: string[] = [];
    if (deps.modelCatalog !== undefined) {
      try {
        models = [...((await deps.modelCatalog()) ?? [])];
      } catch {
        // A dead catalog read is "unknown", not "no models": an empty list
        // would grey out every manual choice for a reason that is ours, not
        // the user's. The client treats an empty list as "not known yet".
        models = [];
      }
    }

    return {
      /** Always available; the gateway routes it per run. */
      auto: "auto",
      /** Lowercased ids, sorted so two reads never disagree on order. */
      models: [...new Set(models.map((m) => m.trim().toLowerCase()).filter((m) => m !== ""))].sort(),
      /** The account's plan id (`free` until a purchase lands). */
      tier: user.tier,
      /**
       * True when this tier may name a model instead of `auto`.
       *
       * Comes from the same `plans.ts` table the send route enforces, so a
       * client never has to re-derive it from `tier` (and never disagrees).
       */
      manualModelsAllowed: manualModelsAllowed(user.tier),
      /** True when the catalog was readable — an empty list is not "no models". */
      known: models.length > 0,
    };
  });
}
