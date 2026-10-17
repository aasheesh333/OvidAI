import { and, desc, eq } from "drizzle-orm";
import type { Db } from "./client.js";
import { newId } from "./repos.js";
import {
  devices as devicesTable,
  notifications as notificationsTable,
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
