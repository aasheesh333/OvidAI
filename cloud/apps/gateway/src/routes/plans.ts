import type { FastifyInstance } from "fastify";
import { plansRepo } from "@ovid/db";
import {
  PLAN_TIERS,
  PLANS,
  planFor,
  signInternalRequest,
  type PlanTier,
} from "@ovid/shared";
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

export const BILLING_ENTITLEMENT_PATH = "/internal/billing/entitlement";

export interface BillingEntitlement {
  tier: PlanTier;
  productId: string | null;
  period: "monthly" | "yearly" | null;
  expiresAt: number | null;
  autoRenewing: boolean;
  purchaseState: "active" | "cancelled" | "expired" | "refunded" | "pending" | "unknown";
}

export interface BillingEntitlementClient {
  /** Null means unavailable/malformed; it never means Free. */
  entitlement(uid: string): Promise<BillingEntitlement | null>;
}

export interface BillingEntitlementClientOptions {
  baseUrl: string;
  secret: string;
  fetchImpl?: typeof fetch;
  clock?: () => number;
  timeoutMs?: number;
}

const PURCHASE_STATES: ReadonlySet<string> = new Set([
  "active",
  "cancelled",
  "expired",
  "refunded",
  "pending",
  "unknown",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseEntitlement(body: unknown): BillingEntitlement | null {
  if (!isRecord(body) || !isRecord(body.entitlement)) return null;
  const value = body.entitlement;
  if (
    typeof value.tier !== "string" || !(PLAN_TIERS as readonly string[]).includes(value.tier) ||
    !(typeof value.productId === "string" || value.productId === null) ||
    !(value.period === "monthly" || value.period === "yearly" || value.period === null) ||
    !(typeof value.expiresAt === "number" && Number.isFinite(value.expiresAt) || value.expiresAt === null) ||
    typeof value.autoRenewing !== "boolean" ||
    typeof value.purchaseState !== "string" || !PURCHASE_STATES.has(value.purchaseState)
  ) {
    return null;
  }
  return {
    tier: value.tier as PlanTier,
    productId: value.productId,
    period: value.period,
    expiresAt: value.expiresAt,
    autoRenewing: value.autoRenewing,
    purchaseState: value.purchaseState as BillingEntitlement["purchaseState"],
  };
}

/** HMAC-signed, read-only mint client. No purchase, cache or checkout methods exist. */
export function createBillingEntitlementClient(
  options: BillingEntitlementClientOptions,
): BillingEntitlementClient {
  const base = options.baseUrl.trim().replace(/\/+$/, "");
  const secret = options.secret.trim();
  const fetchImpl = options.fetchImpl ?? fetch;
  const clock = options.clock ?? (() => Math.floor(Date.now() / 1000));
  if (base === "" || secret === "") return { entitlement: async () => null };
  return {
    async entitlement(uid) {
      const timestamp = Math.trunc(clock());
      const path = BILLING_ENTITLEMENT_PATH;
      try {
        const timeout = options.timeoutMs ?? 5000;
        const res = await fetchImpl(`${base}${path}?uid=${encodeURIComponent(uid)}`, {
          method: "GET",
          headers: {
            "cache-control": "no-store",
            "X-Ovid-Timestamp": Buffer.from(String(timestamp), "utf8").toString("base64"),
            "X-Ovid-Signature": signInternalRequest(secret, "GET", path, uid, timestamp),
          },
          ...(Number.isFinite(timeout) && timeout > 0
            ? { signal: AbortSignal.timeout(timeout) }
            : {}),
        });
        if (!res.ok) return null;
        return parseEntitlement(await res.json());
      } catch {
        return null;
      }
    },
  };
}

export function billingEntitlementClientFromEnv(
  env: NodeJS.ProcessEnv = process.env,
): BillingEntitlementClient {
  return createBillingEntitlementClient({
    baseUrl: env.OVID_INTERNAL_MINT_URL ?? "",
    secret: env.OVID_INTERNAL_API_SECRET ?? "",
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
