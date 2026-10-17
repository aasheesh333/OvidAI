import { money, type Money } from "@ovid/money";
import { ImageError } from "./types.js";
import type { ImagesIdentity } from "./auth.js";

/**
 * Port of images_gateway.admission: the shared budget authority.
 *
 * LiteLLM enforces the per-user key budget on the forwarded call; this
 * supplies the ledger's per-request reservation bound from the SAME plan
 * window, subtracts the current text spend exactly, and rejects before any
 * admission/upstream work when the free monthly cap or the window is spent.
 */

export interface AdmissionContext {
  window: string;
  budget: Money;
}

export interface AdmissionDeps {
  effectiveTier(uid: string): Promise<string>;
  tierBudget(uid: string, tier: string): Promise<{ budget: number; duration: string }>;
  freeCapRemaining(uid: string): Promise<number>;
  keySpend(keyId: string): Promise<number | null>;
  /**
   * P9 final review H1: true while an account-deletion tombstone is pending/
   * fenced/deleting. Checked before any budget read so a user in the 24 h
   * grace window cannot keep generating/editing and spending. Optional so
   * unit tests that predate the fence keep their shape; the composition root
   * always supplies it.
   */
  deletionPending?(uid: string): Promise<boolean>;
}

export type Admission = (
  identity: ImagesIdentity,
  fn: (ctx: AdmissionContext) => Promise<Record<string, unknown>>,
) => Promise<Record<string, unknown>>;

/**
 * images_gateway.admission: the tier is re-read at admission time (a plan
 * change between auth and the budget lookup must take effect), the window
 * budget is resolved first, then the free monthly cap is checked, then the
 * live key spend is subtracted. An unreadable key/info is treated as zero,
 * exactly like the Python `_key_spend(...) or 0.0`.
 */
export function createAdmission(deps: AdmissionDeps): Admission {
  return async (identity, fn) => {
    // P9 final review H1: the account-deletion fence runs FIRST — before the
    // tier/budget reads and before any upstream work or spend.
    if (deps.deletionPending !== undefined && (await deps.deletionPending(identity.uid))) {
      throw new ImageError(403, "account_deletion_pending");
    }
    const tier = await deps.effectiveTier(identity.uid);
    const { budget, duration } = await deps.tierBudget(identity.uid, tier);
    if (tier === "free" && (await deps.freeCapRemaining(identity.uid)) <= 0) {
      throw new ImageError(402, "image_limit_reached");
    }
    let spend: number | null;
    try {
      spend = await deps.keySpend(identity.keyId);
    } catch {
      spend = null;
    }
    const remaining = money(String(budget)).minus(money(String(spend ?? 0)));
    if (remaining.lessThanOrEqualTo(0)) {
      throw new ImageError(402, "image_limit_reached");
    }
    return fn({ window: `${identity.uid}:${duration}`, budget: remaining });
  };
}
