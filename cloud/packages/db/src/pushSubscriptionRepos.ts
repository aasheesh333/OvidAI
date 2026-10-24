import { and, desc, eq, sql } from "drizzle-orm";
import type { Db } from "./client.js";
import { pushSubscriptions, type PushSubscriptionRow } from "./schema.js";

export async function lockPushSubscriptions(db: Db, uid: string): Promise<void> {
  await db.execute(sql`select pg_advisory_xact_lock(hashtextextended(${`web-push:${uid}`}, 0))`);
}

export const pushSubscriptionsRepo = {
  async upsert(
    db: Db,
    input: { userId: string; endpoint: string; p256dh: string; auth: string },
  ): Promise<PushSubscriptionRow> {
    const [row] = await db
      .insert(pushSubscriptions)
      .values(input)
      .onConflictDoUpdate({
        target: pushSubscriptions.endpoint,
        set: {
          userId: input.userId,
          p256dh: input.p256dh,
          auth: input.auth,
          updatedAt: new Date(),
        },
      })
      .returning();
    return row!;
  },

  async remove(db: Db, userId: string, endpoint: string): Promise<boolean> {
    const removed = await db
      .delete(pushSubscriptions)
      .where(and(eq(pushSubscriptions.userId, userId), eq(pushSubscriptions.endpoint, endpoint)))
      .returning({ endpoint: pushSubscriptions.endpoint });
    return removed.length > 0;
  },

  async listForUser(db: Db, userId: string): Promise<PushSubscriptionRow[]> {
    return db
      .select()
      .from(pushSubscriptions)
      .where(eq(pushSubscriptions.userId, userId))
      .orderBy(desc(pushSubscriptions.updatedAt));
  },
};
