import type { FastifyInstance } from "fastify";
import type { PlanTier } from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import {
  billingEntitlementClientFromEnv,
  type BillingEntitlement,
} from "./plans.js";
import { sendError } from "./http.js";

type BillingPeriod = "monthly" | "yearly";
type PaidTier = Exclude<PlanTier, "free">;
type KnownPurchaseState = Exclude<BillingEntitlement["purchaseState"], "unknown">;

/** Exact canonical tier/period pairs shared by mint and Flutter's Play catalog. */
const BILLING_PRODUCTS = {
  ovid_plus_monthly: { tier: "go", period: "monthly" },
  ovid_plus_yearly: { tier: "go", period: "yearly" },
  ovid_pro_monthly: { tier: "plus", period: "monthly" },
  ovid_pro_yearly: { tier: "plus", period: "yearly" },
  ovid_max_monthly: { tier: "pro", period: "monthly" },
  ovid_max_yearly: { tier: "pro", period: "yearly" },
} as const satisfies Record<string, { tier: PaidTier; period: BillingPeriod }>;

type ProductId = keyof typeof BILLING_PRODUCTS;

interface FlutterBillingEntitlement {
  tier: PlanTier;
  productId: string | null;
  period: BillingPeriod | null;
  expiresAt: string | null;
  autoRenewing: boolean;
  purchaseState: KnownPurchaseState;
}

function isProductId(value: string): value is ProductId {
  return Object.prototype.hasOwnProperty.call(BILLING_PRODUCTS, value);
}

/** Mint uses epoch seconds; EntitlementClient.current() requires an ISO string. */
function epochIso(seconds: number | null): string | null {
  if (seconds === null) return null;
  if (!Number.isFinite(seconds) || seconds <= 0) return null;
  const at = new Date(seconds * 1000);
  return Number.isNaN(at.getTime()) ? null : at.toISOString();
}

/**
 * Validate the mint's current entitlement and project its epoch expiry to the
 * Flutter wire shape. A null result means unknown authority, never Free.
 */
function flutterEntitlement(value: BillingEntitlement): FlutterBillingEntitlement | null {
  const state = value.purchaseState;
  // Flutter intentionally has no "unknown" purchase state. Returning 200 with
  // null/a placeholder would make its billing coordinator infer Free.
  if (state === "unknown") return null;

  const expiresAt = epochIso(value.expiresAt);
  if (value.expiresAt !== null && expiresAt === null) return null;

  const productId = value.productId;
  const product = productId !== null && isProductId(productId)
    ? BILLING_PRODUCTS[productId]
    : null;
  if (productId !== null && product === null) return null;
  if ((productId === null) !== (value.period === null)) return null;
  if (product !== null && value.period !== product.period) return null;

  const paid = value.tier !== "free";
  if (paid && (product === null || product.tier !== value.tier)) return null;

  const accessState = state === "active" || state === "cancelled";
  // There is no active Free store product. Conversely, paid access needs a
  // canonical product and a real period end, exactly as Flutter requires.
  if (!paid && accessState) return null;
  if (paid && accessState && expiresAt === null) return null;
  if (state !== "active" && value.autoRenewing) return null;

  return {
    tier: value.tier,
    // Terminal mint rows retain the historical product while explicitly saying
    // Free. Flutter rejects Free + a paid product as contradictory current
    // authority, so the public Free projection omits that historical marker.
    // This does not infer a tier: both the tier and terminal state came from mint.
    productId: paid ? productId : null,
    period: paid ? value.period : null,
    expiresAt,
    autoRenewing: value.autoRenewing,
    purchaseState: state,
  };
}

/**
 * Authenticated-scope route for Flutter EntitlementClient.current().
 *
 * The uid is exclusively the verified principal. The only upstream operation
 * is the existing HMAC-signed, read-only mint entitlement GET: no users/plan
 * fallback, store mutation, RevenueCat SDK or Play Developer API call exists
 * here. Unconfigured, failed, malformed and unknown authority all produce a
 * non-2xx response so Flutter cannot mistake them for a confirmed Free tier.
 * GatewayDeps is optional only for isolated route composition; production can
 * register with the same (scope, deps) convention as the other gateway routes.
 */
export function registerBillingEntitlementRoutes(app: FastifyInstance, _deps?: GatewayDeps): void {
  app.get("/billing/entitlement", async (request, reply) => {
    reply.header("Cache-Control", "no-store");

    let value: BillingEntitlement | null;
    try {
      value = await billingEntitlementClientFromEnv().entitlement(request.principal.uid);
    } catch {
      value = null;
    }

    const entitlement = value === null ? null : flutterEntitlement(value);
    if (entitlement === null) {
      return sendError(reply, 503, "unavailable", "Billing entitlement is unavailable.");
    }
    return { entitlement };
  });
}
