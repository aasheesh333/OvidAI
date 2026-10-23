import type { FastifyInstance } from "fastify";
import { users } from "@ovid/db";
import type { GatewayDeps } from "../app.js";

/**
 * The model catalog, as one call.
 *
 * Until now the only way to know which models exist was to send a message and
 * be refused. `deps.modelCatalog` is the same mint-backed list the send route
 * validates against, so this route cannot advertise a model the send route
 * would reject.
 *
 * It reports the account's tier rather than deciding what the tier may use.
 * The plan table lives in the product (and in the client's own plan screen);
 * duplicating it here would give the same rule two homes that can disagree —
 * which is exactly how "the plan page says one thing and the gateway bills
 * another" happens.
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
      /** True when the catalog was readable — an empty list is not "no models". */
      known: models.length > 0,
    };
  });
}
