import { createHash, timingSafeEqual } from "node:crypto";
import { BillingError } from "./domain.js";
import type {
  EntitlementApplyResult,
  RevenueCatEvent,
} from "./entitlements.js";

export interface RevenueCatWebhookResult {
  status: number;
  payload: Record<string, unknown>;
}

export interface RevenueCatWebhookOptions {
  secret: string | null | undefined;
  process(event: RevenueCatEvent): Promise<EntitlementApplyResult>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Hashing gives timingSafeEqual fixed-size inputs even for a wrong-length secret. */
export function constantTimeSecretEqual(provided: string, expected: string): boolean {
  const left = createHash("sha256").update(provided, "utf8").digest();
  const right = createHash("sha256").update(expected, "utf8").digest();
  const equal = timingSafeEqual(left, right);
  return expected !== "" && equal;
}

function authorized(header: string, secret: string | null | undefined): boolean {
  if (secret === null || secret === undefined || secret === "") return false;
  const bearer = header.startsWith("Bearer ") ? header.slice(7) : "";
  // Evaluate both candidates; neither a length check nor a direct string compare gates access.
  const direct = constantTimeSecretEqual(header, secret);
  const bearerMatch = constantTimeSecretEqual(bearer, secret);
  return direct || bearerMatch;
}

function text(
  value: unknown,
  maxLength: number,
  required = false,
): string | null {
  if (value === null || value === undefined) return required ? null : null;
  if (typeof value !== "string") return null;
  const result = value.trim();
  if (result.length > maxLength || (required && result === "")) return null;
  return result;
}

function epochSeconds(value: unknown, required: boolean): number | null | undefined {
  if (value === null || value === undefined) return required ? undefined : null;
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) return undefined;
  return value / 1000;
}

function textArray(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length === 0) return null;
  const result: string[] = [];
  for (const entry of value) {
    const parsed = text(entry, 200, true);
    if (parsed === null) return null;
    result.push(parsed);
  }
  return result;
}

/** RevenueCat's signed event wrapper → the small server-owned field set. */
export function parseRevenueCatEvent(body: unknown): RevenueCatEvent | null {
  if (!isRecord(body) || !isRecord(body.event)) return null;
  const raw = body.event;
  const id = text(raw.id, 200, true);
  const type = text(raw.type, 80, true)?.toUpperCase();
  const occurredAt = epochSeconds(raw.event_timestamp_ms, true);
  const environment = raw.environment === null || raw.environment === undefined
    ? null
    : text(raw.environment, 20, true)?.toUpperCase();
  if (id === null || type === undefined || occurredAt === undefined || occurredAt === null ||
      environment === undefined ||
      (raw.auto_renew_status !== undefined && typeof raw.auto_renew_status !== "boolean")) {
    return null;
  }

  const cancelReason = raw.cancel_reason === null || raw.cancel_reason === undefined
    ? null
    : text(raw.cancel_reason, 100, true);
  if (cancelReason === null && raw.cancel_reason !== null && raw.cancel_reason !== undefined) {
    return null;
  }

  if (type === "TRANSFER") {
    const transferredFrom = textArray(raw.transferred_from);
    const transferredTo = textArray(raw.transferred_to);
    if (transferredFrom === null || transferredTo === null || transferredTo.length !== 1) {
      return null;
    }
    return {
      id,
      type,
      occurredAt,
      appUserId: transferredTo[0]!,
      transferredFrom,
      transactionId: null,
      productId: null,
      expiresAt: null,
      autoRenewing: null,
      cancelReason,
      environment,
    };
  }

  const appUserId = text(raw.app_user_id, 200, true);
  const transactionId = text(raw.original_transaction_id ?? raw.transaction_id, 512, true);
  const productId = raw.product_id === null || raw.product_id === undefined
    ? null
    : text(raw.product_id, 200, true);
  const expiresAt = epochSeconds(raw.expiration_at_ms, false);
  const newProductId = type === "PRODUCT_CHANGE" && raw.new_product_id !== undefined
    ? raw.new_product_id === null ? null : text(raw.new_product_id, 200, true)
    : undefined;
  const hasGrace = Object.prototype.hasOwnProperty.call(raw, "grace_period_expiration_at_ms");
  const gracePeriodExpiresAt = hasGrace
    ? epochSeconds(raw.grace_period_expiration_at_ms, false)
    : undefined;
  if (
    appUserId === null || transactionId === null || expiresAt === undefined ||
    productId === null && raw.product_id !== null && raw.product_id !== undefined ||
    newProductId === null && raw.new_product_id !== null ||
    gracePeriodExpiresAt === undefined && hasGrace
  ) {
    return null;
  }
  return {
    id,
    type,
    occurredAt,
    appUserId,
    transactionId,
    productId,
    expiresAt,
    autoRenewing: typeof raw.auto_renew_status === "boolean" ? raw.auto_renew_status : null,
    cancelReason,
    environment,
    ...(newProductId !== undefined ? { newProductId } : {}),
    ...(gracePeriodExpiresAt !== undefined ? { gracePeriodExpiresAt } : {}),
  };
}

export function createRevenueCatWebhook(
  options: RevenueCatWebhookOptions,
): (authorization: string | undefined, body: unknown) => Promise<RevenueCatWebhookResult> {
  return async (authorization, body) => {
    if (options.secret === null || options.secret === undefined || options.secret === "") {
      return {
        status: 503,
        payload: { ok: false, error: { code: "billing_unavailable" } },
      };
    }
    if (!authorized(authorization ?? "", options.secret)) {
      return {
        status: 401,
        payload: { ok: false, error: { code: "unauthorized" } },
      };
    }
    const event = parseRevenueCatEvent(body);
    if (event === null) {
      return {
        status: 400,
        payload: { ok: false, error: { code: "invalid_event" } },
      };
    }
    try {
      const result = await options.process(event);
      return { status: 200, payload: { ok: true, ...result } };
    } catch (error) {
      if (error instanceof BillingError) {
        return {
          status: error.status,
          payload: { ok: false, error: { code: error.code } },
        };
      }
      return {
        status: 503,
        payload: { ok: false, error: { code: "billing_unavailable" } },
      };
    }
  };
}
