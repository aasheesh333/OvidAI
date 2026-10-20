import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import postgres from "postgres";
import { createDb, migrate, type Db } from "./client.js";
import { newId, users as usersRepo } from "./repos.js";
import { devices, notifications } from "./deviceRepos.js";
import { devices as devicesTable } from "./schema.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("device/notification repos against real postgres", () => {
  let db: Db;

  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    const admin = postgres(url, { max: 1, onnotice: () => {} });
    try {
      await admin.unsafe(`DROP SCHEMA IF EXISTS drizzle CASCADE`);
      await admin.unsafe(`DROP SEQUENCE IF EXISTS users_sandbox_uid_seq CASCADE`);
      await admin.unsafe(
        `DROP TABLE IF EXISTS browser_credentials, private_memory_files, schedules, schedule_runs, devices, notifications, grants, file_manifests, workspace_objects, attachments, session_event_mirror, session_agent_state, runs, messages, sessions, users,` +
          ` plans, mint_settings, user_plan_overrides, mint_audit, billing_purchases, image_jobs,` +
          ` image_deleted_accounts, image_cards, image_card_history, image_probe_log, image_probe_state,` +
          ` shares, share_forks, reports, account_deletions, byok_keys,` +
          ` mcp_servers, mcp_oauth_tokens, mcp_oauth_flows, plugins, plugin_grants, run_usage CASCADE`,
      );
    } finally {
      await admin.end({ timeout: 5 });
    }
    await migrate(url);
    db = createDb(url);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function seedUser(): Promise<string> {
    const uid = newId();
    await usersRepo.ensure(db, uid, `u-${uid.slice(0, 8)}@test.local`);
    return uid;
  }

  // -------------------------------------------------------------------------

  it("upsert binds a token to the newest user; one row, platform/updatedAt move", async () => {
    const first = await seedUser();
    const second = await seedUser();
    const token = `fcm-${newId()}`;

    const a = await devices.upsert(db, { token, userId: first, platform: "android" });
    expect(a.token).toBe(token);
    expect(a.userId).toBe(first);
    expect(a.platform).toBe("android");
    expect(a.createdAt).toBeInstanceOf(Date);

    await new Promise((resolve) => setTimeout(resolve, 5));
    const b = await devices.upsert(db, { token, userId: second, platform: "ios" });
    expect(b.userId).toBe(second);
    expect(b.platform).toBe("ios");
    expect(b.createdAt).toEqual(a.createdAt); // first write keeps createdAt
    expect(b.updatedAt.getTime()).toBeGreaterThan(a.updatedAt.getTime());

    const rows = await db.select().from(devicesTable).where(eq(devicesTable.token, token));
    expect(rows).toHaveLength(1);
    expect(rows[0]!.userId).toBe(second);
    expect(rows[0]!.platform).toBe("ios");

    // The previous owner no longer lists the re-bound token.
    expect(await devices.listForUser(db, first)).toHaveLength(0);
    expect((await devices.listForUser(db, second)).map((d) => d.token)).toEqual([token]);
  });

  it("removeByToken is owner-scoped: a wrong user cannot unbind a device", async () => {
    const owner = await seedUser();
    const stranger = await seedUser();
    const token = `fcm-${newId()}`;
    await devices.upsert(db, { token, userId: owner, platform: "android" });

    await devices.removeByToken(db, token, stranger);
    expect(await db.select().from(devicesTable).where(eq(devicesTable.token, token))).toHaveLength(
      1,
    );

    await devices.removeByToken(db, token, owner);
    expect(await db.select().from(devicesTable).where(eq(devicesTable.token, token))).toHaveLength(
      0,
    );
  });

  it("notifications.record round-trips the jsonb data payload and status/error", async () => {
    const uid = await seedUser();
    const token = `fcm-${newId()}`;
    await devices.upsert(db, { token, userId: uid, platform: "android" });

    const sent = await notifications.record(db, {
      userId: uid,
      deviceToken: token,
      kind: "schedule_run_succeeded",
      channel: "push",
      title: "Schedule finished",
      body: "Daily digest succeeded",
      route: "/schedules/abc",
      data: { scheduleId: "abc", status: "succeeded" },
      status: "sent",
    });
    expect(sent.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(sent.userId).toBe(uid);
    expect(sent.deviceToken).toBe(token);
    expect(sent.kind).toBe("schedule_run_succeeded");
    expect(sent.channel).toBe("push");
    expect(sent.title).toBe("Schedule finished");
    expect(sent.body).toBe("Daily digest succeeded");
    expect(sent.route).toBe("/schedules/abc");
    expect(sent.data).toEqual({ scheduleId: "abc", status: "succeeded" });
    expect(sent.status).toBe("sent");
    expect(sent.error).toBeNull();
    expect(sent.createdAt).toBeInstanceOf(Date);

    const failed = await notifications.record(db, {
      userId: uid,
      deviceToken: null,
      kind: "schedule_run_failed",
      channel: "inbox",
      title: "Schedule failed",
      body: "No devices",
      route: "/schedules",
      data: {},
      status: "skipped_no_devices",
      error: "no_devices",
    });
    expect(failed.deviceToken).toBeNull();
    expect(failed.status).toBe("skipped_no_devices");
    expect(failed.error).toBe("no_devices");
    expect(failed.data).toEqual({});
  });
});
