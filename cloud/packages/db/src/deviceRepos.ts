import { and, desc, eq, isNull, lt, or } from "drizzle-orm";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  devices as devicesTable,
  notifications as notificationsTable,
  notificationDeliveryClaims as notificationDeliveryClaimsTable,
  type DeviceRow,
  type NotificationRow,
} from "./schema.js";

/**
 * P4 Task 4: push device registry + notification inbox.
 *
 * `devices.token` (the FCM registration token) is the natural primary key:
 * re-registration is always an upsert, and a token re-binds to whichever user
 * authenticated most recently (a shared device switching accounts).
 */
export const devices = {
  /**
   * Register/refresh a token. ON CONFLICT (token) DO UPDATE rebinds user and
   * platform and bumps updatedAt; createdAt keeps the first registration.
   */
  async upsert(
    db: Db,
    input: { token: string; userId: string; platform: string },
  ): Promise<DeviceRow> {
    const [row] = await db
      .insert(devicesTable)
      .values({ token: input.token, userId: input.userId, platform: input.platform })
      .onConflictDoUpdate({
        target: devicesTable.token,
        set: {
          userId: input.userId,
          platform: input.platform,
          updatedAt: new Date(),
        },
      })
      .returning();
    return row!;
  },

  /**
   * Unbind on logout / unregistered-token cleanup. Owner-scoped so a leaked
   * token cannot be used to unbind another account's device. Idempotent.
   */
  async removeByToken(db: Db, token: string, userId: string): Promise<void> {
    await db
      .delete(devicesTable)
      .where(and(eq(devicesTable.token, token), eq(devicesTable.userId, userId)));
  },

  /** The user's registered devices, most recently refreshed first. */
  async listForUser(db: Db, userId: string): Promise<DeviceRow[]> {
    return db
      .select()
      .from(devicesTable)
      .where(eq(devicesTable.userId, userId))
      .orderBy(desc(devicesTable.updatedAt));
  },
};

/**
 * How long an in-progress completion claim may block another worker. A live
 * fan-out is bounded by the provider timeouts (well under this); only a dead
 * worker's row reaches the lease, so takeover cannot duplicate a live send.
 */
export const NOTIFICATION_CLAIM_LEASE_MS = 5 * 60_000;

export const notificationDeliveryClaims = {
  /**
   * True only for the worker that claims a new or unfinished completion.
   *
   * A claim whose worker died mid-fan-out is reclaimable after
   * NOTIFICATION_CLAIM_LEASE_MS: without the lease an `in_progress` row with a
   * claimant would be stuck forever and the completion push would be lost.
   * A live owner keeps the row, so the normal (no-crash) path stays
   * exactly-once; only a crash inside the fan-out can re-send.
   */
  async claim(
    db: Db,
    input: { userId: string; kind: string; runId: string; claimant: string },
    now = new Date(),
  ): Promise<boolean> {
    const leaseCutoff = new Date(now.getTime() - NOTIFICATION_CLAIM_LEASE_MS);
    const inserted = await db
      .insert(notificationDeliveryClaimsTable)
      .values({ ...input, state: "in_progress", claimedAt: now })
      .onConflictDoUpdate({
        target: [
          notificationDeliveryClaimsTable.userId,
          notificationDeliveryClaimsTable.kind,
          notificationDeliveryClaimsTable.runId,
        ],
        set: { state: "in_progress", claimant: input.claimant, claimedAt: now },
        where: or(
          eq(notificationDeliveryClaimsTable.state, "pending"),
          isNull(notificationDeliveryClaimsTable.claimant),
          and(
            eq(notificationDeliveryClaimsTable.state, "in_progress"),
            or(
              isNull(notificationDeliveryClaimsTable.claimedAt),
              lt(notificationDeliveryClaimsTable.claimedAt, leaseCutoff),
            ),
          ),
        ),
      })
      .returning({ runId: notificationDeliveryClaimsTable.runId });
    return inserted.length === 1;
  },

  async delivered(
    db: Db,
    input: { userId: string; kind: string; runId: string; claimant: string },
  ): Promise<void> {
    await db
      .update(notificationDeliveryClaimsTable)
      .set({ state: "delivered" })
      .where(
        and(
          eq(notificationDeliveryClaimsTable.userId, input.userId),
          eq(notificationDeliveryClaimsTable.kind, input.kind),
          eq(notificationDeliveryClaimsTable.runId, input.runId),
          eq(notificationDeliveryClaimsTable.claimant, input.claimant),
        ),
      );
  },

  async release(
    db: Db,
    input: { userId: string; kind: string; runId: string; claimant: string },
  ): Promise<void> {
    await db
      .delete(notificationDeliveryClaimsTable)
      .where(
        and(
          eq(notificationDeliveryClaimsTable.userId, input.userId),
          eq(notificationDeliveryClaimsTable.kind, input.kind),
          eq(notificationDeliveryClaimsTable.runId, input.runId),
          eq(notificationDeliveryClaimsTable.state, "in_progress"),
          eq(notificationDeliveryClaimsTable.claimant, input.claimant),
        ),
      );
  },

  /**
   * Observed state of a completion claim, or null when no row exists.
   *
   * The notifier never throws and reports no outcome, so this read is how the
   * run-delivery outbox learns the TRUTH: "delivered" is a confirmed fan-out,
   * anything else (pending/absent/in_progress) means the push is still owed
   * and the outbox must stay retryable rather than claim delivery.
   */
  async state(
    db: Db,
    input: { userId: string; kind: string; runId: string },
  ): Promise<"pending" | "in_progress" | "delivered" | null> {
    const [row] = await db
      .select({ state: notificationDeliveryClaimsTable.state })
      .from(notificationDeliveryClaimsTable)
      .where(
        and(
          eq(notificationDeliveryClaimsTable.userId, input.userId),
          eq(notificationDeliveryClaimsTable.kind, input.kind),
          eq(notificationDeliveryClaimsTable.runId, input.runId),
        ),
      )
      .limit(1);
    return (row?.state as "pending" | "in_progress" | "delivered" | undefined) ?? null;
  },
};

export const notifications = {
  /**
   * Persist one delivery attempt (the inbox record). A null deviceToken is the
   * "no device registered" record; `status` is caller-supplied
   * (sent|failed|skipped_no_devices) so the notifier owns the taxonomy.
   */
  async record(
    db: Db,
    input: {
      userId: string;
      deviceToken: string | null;
      kind: string;
      channel: string;
      title: string;
      body: string;
      route: string;
      data: Record<string, string>;
      status: string;
      error?: string | null;
    },
  ): Promise<NotificationRow> {
    const [row] = await db
      .insert(notificationsTable)
      .values({
        id: newId(),
        userId: input.userId,
        deviceToken: input.deviceToken,
        kind: input.kind,
        channel: input.channel,
        title: input.title,
        body: input.body,
        route: input.route,
        data: input.data,
        status: input.status,
        error: input.error ?? null,
      })
      .returning();
    return row!;
  },
};
