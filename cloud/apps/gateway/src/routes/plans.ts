import type { FastifyInstance } from "fastify";
import { plansRepo } from "@ovid/db";
import { PLANS, planFor, type PlanTier } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";

/**
 * The plan table, as the plan screen reads it.
 *
 * The screen used to carry its own copy: four hard-coded plans advertising
 * "50M tokens a day" while the gateway enforces a USD allowance, and prices
 * the mint did not seed. Two sources for one number is how a person is told
 * one thing and billed another.
 *
 * Two halves, merged by plan id:
 *
 *   - the LIVE row (Postgres `plans`) — name, price, multiplier, window. The
 *     owner edits these in /admin, so they must come from the row, not from
 *     a constant;
 *   - the PRODUCT limits (`@ovid/shared`'s table) — storage, connectors,
 *     project files, manual models. These are structural and not editable.
 *
 * A plan the product table does not describe (an owner-created "team" plan)
 * gets `null` for those limits. `null` is "not known"; `0` would claim the
 * plan grants nothing, which is a different statement and a false one.
 */
export function registerPlanRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/plans", async () => {
    const rows = await plansRepo.list(deps.db);

    return {
      plans: rows
        // Disabled means stop selling: a plan nobody can buy does not belong
        // on a screen whose only job is describing what is for sale.
        .filter((row) => row.enabled)
        .map((row) => {
          const tier = planFor(row.id).id;
          const described = describesId(row.id);
          const product = described ? PLANS[tier as PlanTier] : undefined;
          return {
            id: row.id,
            /** The canonical tier this row means (`starter` → `go`). */
            tier,
            name: row.name,
            priceUsd: Number(row.priceUsd),
            /** The Play Store's rupee price — a product price, not a conversion. */
            priceInr: product?.priceInr ?? null,
            /** Allowance multiple over the Free baseline. */
            mult: Number(row.mult),
            windowHours: row.windowHours,
            aliases: row.aliases,
            manualModels: product?.manualModels ?? null,
            storageGb: product?.storageGb ?? null,
            customConnectors: product?.customConnectors ?? null,
            projectFiles: product?.projectFiles ?? null,
            uploads: product?.uploads ?? null,
          };
        }),
    };
  });
}

/**
 * Whether the product table describes this plan id.
 *
 * `planFor` answers Free for anything it does not know, so it cannot be used
 * as an existence check: a row called "mystery" would silently inherit Free's
 * storage and connector limits. Only a canonical id, or a legacy spelling
 * that maps onto one, counts.
 */
function describesId(id: string): boolean {
  const key = id.trim().toLowerCase();
  if (key in PLANS) return true;
  return LEGACY_SPELLINGS.has(key);
}

/** The legacy spellings `planFor` maps onto a real tier. */
const LEGACY_SPELLINGS: ReadonlySet<string> = new Set([
  "starter",
  "max",
  "3x",
  "7x",
  "15x",
]);
