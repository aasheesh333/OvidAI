import { eq } from "drizzle-orm";
import type { Db } from "./client.js";
import { users as usersTable } from "./schema.js";

/**
 * P9 Task 10: the durable users.tier projection used by the billing tier sink.
 *
 * `users.tier` is the Postgres authority (Ruling Q4); the Redis
 * `user:{uid}:tier` pair is the request-time projection. This repo keeps the
 * two billing-specific column reads/writes in one place so the mint app never
 * imports drizzle-orm directly and moneyRepos.ts (Task 2, another lane's hot
 * file) stays untouched.
 */

export interface BillingUserTier {
  tier: string;
  tierExpiresAt: Date | null;
}

export const billingUsers = {
  /** Current durable tier; a missing row reads as free (never throws). */
  async getTier(db: Db, uid: string): Promise<BillingUserTier> {
    const [row] = await db
      .select({ tier: usersTable.tier, tierExpiresAt: usersTable.tierExpiresAt })
      .from(usersTable)
      .where(eq(usersTable.uid, uid))
      .limit(1);
    return { tier: row?.tier ?? "free", tierExpiresAt: row?.tierExpiresAt ?? null };
  },

  /**
   * Upsert the durable tier. Insert-if-absent so a purchase verified before
   * the user ever minted a key still persists (the gateway may have created
   * the row already; either way it is not clobbered).
   *
   * P9 final review M6: `mint_provisioned = true` in BOTH the insert and the
   * update. `resyncAtBoot` and every all-users reapply/export iterate
   * `plansRepo.mintUids` (mint_provisioned only); without this flag a
   * billing-only user's paid tier is lost when Redis loses the EXAT tier key.
   */
  async setTier(
    db: Db,
    uid: string,
    tier: string,
    tierExpiresAtEpoch: number | null,
  ): Promise<void> {
    const tierExpiresAt =
      tierExpiresAtEpoch === null || tierExpiresAtEpoch === undefined
        ? null
        : new Date(tierExpiresAtEpoch * 1000);
    await db
      .insert(usersTable)
      .values({ uid, tier, tierExpiresAt, mintProvisioned: true })
      .onConflictDoUpdate({
        target: usersTable.uid,
        set: { tier, tierExpiresAt, mintProvisioned: true },
      });
  },
};
