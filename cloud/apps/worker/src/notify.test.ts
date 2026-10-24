/**
 * Task 7 — the push notifier, against REAL Postgres (TEST_DATABASE_URL):
 * Dart notification-copy ports (title/body/route/channel/data), the device
 * fan-out (per-device send + inbox row), unregistered-token pruning, the
 * zero-device skipped record, the never-throws contract, and the Q5
 * key_not_minted push body. Most tests use a capturing PushSender stub; FCM
 * classification/fan-out tests mock only the Firebase transport instead.
 */

import { fileURLToPath } from "node:url";

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import {
  accountSettings,
  createDb,
  devices,
  notificationDeliveryClaims,
  pushSubscriptionsRepo,
  migrate,
  schema,
  users,
  type Db,
  type NotificationRow,
} from "@ovid/db";
import { notificationSummary } from "@ovid/shared";
import {
  createFcmPushSender,
  createNotifier,
  KEY_NOT_MINTED_PUSH_BODY,
  type PushMessage,
  type PushOutcome,
  type PushSender,
} from "./notify.js";
import type { WebPushSender } from "./webPush.js";

const { fcmSend } = vi.hoisted(() => ({ fcmSend: vi.fn() }));
vi.mock("firebase-admin/app", () => ({
  getApps: () => [{ name: "test" }],
  initializeApp: () => ({ name: "test" }),
}));
vi.mock("firebase-admin/messaging", () => ({
  getMessaging: () => ({ send: fcmSend }),
}));

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const FCM_MESSAGE: PushMessage = {
  token: "secret-fcm-token",
  notification: { title: "title", body: "body" },
  data: {},
  androidChannelId: "ovid_agent_updates.chime.v1",
};
const DEAD_FCM_CODES = ["registration-token-not-registered", "invalid-registration-token"] as const;

function firebaseError(code: string, message: string): Error {
  return Object.assign(new Error(message), { code });
}

async function withFcmCredentials<T>(run: () => Promise<T>): Promise<T> {
  const previous = process.env.GOOGLE_APPLICATION_CREDENTIALS;
  // createFcmPushSender only checks readability; Firebase initialization is mocked.
  process.env.GOOGLE_APPLICATION_CREDENTIALS = fileURLToPath(import.meta.url);
  try {
    return await run();
  } finally {
    if (previous === undefined) delete process.env.GOOGLE_APPLICATION_CREDENTIALS;
    else process.env.GOOGLE_APPLICATION_CREDENTIALS = previous;
  }
}

async function sendFcmError(error: unknown): Promise<PushOutcome> {
  return withFcmCredentials(async () => {
    fcmSend.mockReset();
    fcmSend.mockRejectedValueOnce(error);
    return createFcmPushSender().send(FCM_MESSAGE);
  });
}

/** Capturing PushSender stub; `handler` decides the outcome per message. */
function stubPush(
  handler?: (msg: PushMessage) => Promise<PushOutcome>,
): { sent: PushMessage[]; push: PushSender } {
  const sent: PushMessage[] = [];
  const push: PushSender = {
    async send(msg) {
      sent.push(msg);
      return handler ? handler(msg) : { ok: true };
    },
  };
  return { sent, push };
}

describe.skipIf(!TEST_DATABASE_URL)("createNotifier (real postgres)", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  /** Fresh user per test → inbox assertions stay exact on the shared dev DB. */
  async function newUser(): Promise<string> {
    const uid = `nt-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    return uid;
  }

  async function inbox(userId: string): Promise<NotificationRow[]> {
    const rows = await db.select().from(schema.notifications);
    return rows.filter((r) => r.userId === userId);
  }

  it("(a) success copy: Dart title/body, route, data, channel id; one sent row per device", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-a", userId: uid, platform: "android" });
    await devices.upsert(db, { token: "tok-b", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push, clock: () => new Date(1_700_000_000_000) });

    await notifier.notifyScheduleSucceeded({
      userId: uid,
      scheduleId: "sch-1",
      sessionId: "ses-1",
      title: "Morning report",
      summary: null,
    });

    expect(sent).toHaveLength(2);
    for (const msg of sent) {
      expect(msg.notification.title).toBe("Scheduled task done: Morning report");
      expect(msg.notification.body).toBe("Tap to see the result.");
      expect(msg.androidChannelId).toBe("ovid_scheduler_results.chime.v1");
      expect(msg.data.kind).toBe("scheduleSucceeded");
      expect(msg.data.channel).toBe("scheduler_results");
      expect(msg.data.route).toBe("/schedule/ses-1");
      expect(msg.data.sessionId).toBe("ses-1");
      expect(msg.data.scheduleId).toBe("sch-1");
      expect(msg.data.ts).toBe(new Date(1_700_000_000_000).toISOString());
      expect(["tok-a", "tok-b"]).toContain(msg.token);
    }
    const rows = await inbox(uid);
    expect(rows).toHaveLength(2);
    expect(rows.every((r) => r.status === "sent" && r.deviceToken !== null)).toBe(true);
    expect(new Set(rows.map((r) => r.deviceToken))).toEqual(new Set(["tok-a", "tok-b"]));
  });

  it("agentFinished is private, run-scoped, and delivered once across competing workers", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-finished", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await Promise.all([
      notifier.notifyAgentFinished({ userId: uid, runId: "run-finished-1", sessionId: "ses-finished" }),
      notifier.notifyAgentFinished({ userId: uid, runId: "run-finished-1", sessionId: "ses-finished" }),
    ]);
    await notifier.notifyAgentFinished({ userId: uid, runId: "run-finished-1", sessionId: "ses-finished" });

    expect(sent).toHaveLength(1);
    expect(sent[0]!.notification).toEqual({
      title: "Ovid finished your task",
      body: "Tap to see the answer.",
    });
    expect(sent[0]!.data).toMatchObject({
      kind: "agentFinished",
      runId: "run-finished-1",
      sessionId: "ses-finished",
      route: "/c/ses-finished",
    });
    expect(JSON.stringify(sent[0])).not.toContain("private answer");
  });

  it("only one claimant owns an already-pending completion", async () => {
    const uid = await newUser();
    const args = { userId: uid, kind: "agentFinished", runId: "run-pending-lease" };
    await notificationDeliveryClaims.claim(db, { ...args, claimant: "first" });
    await notificationDeliveryClaims.release(db, { ...args, claimant: "first" });
    const results = await Promise.all([
      notificationDeliveryClaims.claim(db, { ...args, claimant: "second" }),
      notificationDeliveryClaims.claim(db, { ...args, claimant: "third" }),
    ]);
    expect(results.filter(Boolean)).toHaveLength(1);
    const deliveredBySecond = notificationDeliveryClaims.delivered(db, { ...args, claimant: "second" });
    const deliveredByThird = notificationDeliveryClaims.delivered(db, { ...args, claimant: "third" });
    await Promise.all([deliveredBySecond, deliveredByThird]);
    const rows = await db.select().from(schema.notificationDeliveryClaims);
    const claim = rows.find((row) => row.userId === uid && row.runId.trim() === args.runId);
    expect(claim?.state).toBe("delivered");
    // One winner alone completes the delivery; losing claimants cannot alter it.
    expect(await notificationDeliveryClaims.claim(db, { ...args, claimant: "fourth" })).toBe(false);
  });

  it("a transient device-list failure releases the completion for a retry", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-finished-retry", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const original = devices.listForUser;
    let failures = 1;
    devices.listForUser = async (...args) => {
      if (failures > 0) {
        failures -= 1;
        throw new Error("temporary device read failure");
      }
      return original(...args);
    };
    try {
      const notifier = createNotifier({ db, push });
      const args = { userId: uid, runId: "run-retry-1", sessionId: "ses-retry" };
      await notifier.notifyAgentFinished(args);
      expect(sent).toHaveLength(0);
      await notifier.notifyAgentFinished(args);
      expect(sent).toHaveLength(1);
      await notifier.notifyAgentFinished(args);
      expect(sent).toHaveLength(1);
    } finally {
      devices.listForUser = original;
    }
  });

  it("browser delivery shares the completion event and prunes an expired endpoint", async () => {
    const uid = await newUser();
    const endpoint = "https://push.example.test/expired";
    await pushSubscriptionsRepo.upsert(db, {
      userId: uid, endpoint, p256dh: "client-key", auth: "client-auth",
    });
    const webPush = {
      send: vi.fn<WebPushSender["send"]>(async () => ({ ok: false as const, code: "unregistered" as const })),
    };
    const notifier = createNotifier({ db, push: stubPush().push, webPush });
    await notifier.notifyAgentFinished({ userId: uid, runId: "run-web-1", sessionId: "ses-web" });

    expect(webPush.send).toHaveBeenCalledOnce();
    expect(webPush.send.mock.calls[0]![0]).toMatchObject({
      route: "/c/ses-web",
      subscription: { endpoint, p256dh: "client-key", auth: "client-auth" },
    });
    expect(await pushSubscriptionsRepo.listForUser(db, uid)).toHaveLength(0);
  });

  it("Wave 4 (SE-010): Notifications off → no push to any device, inbox keeps a skipped row", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-off", userId: uid, platform: "android" });
    await accountSettings.patch(db, uid, { notificationsEnabled: false });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await notifier.notifyAgentFailed({
      userId: uid,
      sessionId: "ses-off",
      sessionTitle: "Report",
      code: "model_error",
      message: "boom",
    });

    expect(sent).toHaveLength(0);
    const rows = await inbox(uid);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.status).toBe("skipped_disabled");

    // Back on → push resumes.
    await accountSettings.patch(db, uid, { notificationsEnabled: true });
    await notifier.notifyAgentFailed({
      userId: uid,
      sessionId: "ses-off",
      sessionTitle: "Report",
      code: "model_error",
      message: "boom",
    });
    expect(sent).toHaveLength(1);
  });

  it("(a) 48-cap title and markdown-stripped summary", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-cap", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    const longTitle = "W".repeat(60);
    await notifier.notifyScheduleSucceeded({
      userId: uid,
      scheduleId: "sch-2",
      sessionId: "ses-2",
      title: longTitle,
      summary: "**bold** _it_ `code`",
    });

    expect(sent).toHaveLength(1);
    expect(sent[0]!.notification.title).toBe(
      `Scheduled task done: ${notificationSummary(longTitle, { max: 48 })}`,
    );
    expect(sent[0]!.notification.title.endsWith("…")).toBe(true);
    expect(sent[0]!.notification.body).toBe("bold it code");
  });

  it("(b) failure copy: key_not_minted swaps in the Q5 body; other codes summarize the error", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-f", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await notifier.notifyScheduleFailed({
      userId: uid,
      scheduleId: "sch-3",
      sessionId: "ses-3",
      title: "Morning report",
      code: "key_not_minted",
      error: "session key was never minted",
    });
    await notifier.notifyScheduleFailed({
      userId: uid,
      scheduleId: "sch-4",
      sessionId: "ses-4",
      title: "Evening report",
      code: "model_transient_exhausted",
      error: "boom **now**",
    });
    await notifier.notifyScheduleFailed({
      userId: uid,
      scheduleId: "sch-5",
      sessionId: "ses-5",
      title: "Night report",
      code: "run_lost",
      error: null,
    });

    expect(sent).toHaveLength(3);
    const [minted, transient, lost] = sent;
    expect(minted!.notification.title).toBe("Scheduled task failed: Morning report");
    expect(minted!.notification.body).toBe(KEY_NOT_MINTED_PUSH_BODY);
    expect(minted!.data.kind).toBe("scheduleFailed");
    expect(minted!.data.channel).toBe("scheduler_results");
    expect(minted!.androidChannelId).toBe("ovid_scheduler_results.chime.v1");
    expect(transient!.notification.body).toBe("boom now");
    expect(lost!.notification.body).toBe("Unknown error");
  });

  it("(c) unregistered token: pruned from devices, failed/unregistered row; the other device still sent", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "dead-token", userId: uid, platform: "android" });
    await devices.upsert(db, { token: "live-token", userId: uid, platform: "android" });
    const { sent, push } = stubPush((msg) =>
      msg.token === "dead-token"
        ? Promise.resolve({ ok: false, code: "unregistered", error: "registration-token-not-registered" })
        : Promise.resolve({ ok: true }),
    );
    const notifier = createNotifier({ db, push });

    await notifier.notifyScheduleSucceeded({
      userId: uid,
      scheduleId: "sch-6",
      sessionId: "ses-6",
      title: "Report",
      summary: "done",
    });

    expect(sent).toHaveLength(2);
    const remaining = await devices.listForUser(db, uid);
    expect(remaining.map((r) => r.token)).toEqual(["live-token"]);
    const rows = await inbox(uid);
    expect(rows).toHaveLength(2);
    const failedRow = rows.find((r) => r.deviceToken === "dead-token");
    const sentRow = rows.find((r) => r.deviceToken === "live-token");
    expect(failedRow?.status).toBe("failed");
    expect(failedRow?.error).toBe("unregistered");
    expect(sentRow?.status).toBe("sent");
  });

  it("Firebase-shaped dead-token errors prune only the dead device and later fan-out skips it", async () => {
    const uid = await newUser();
    const deadToken = "firebase-dead-token";
    const liveToken = "firebase-live-token";
    await devices.upsert(db, { token: deadToken, userId: uid, platform: "android" });
    await devices.upsert(db, { token: liveToken, userId: uid, platform: "android" });

    await withFcmCredentials(async () => {
      fcmSend.mockReset();
      fcmSend.mockImplementation(async ({ token }: { token: string }) => {
        if (token === deadToken) {
          throw firebaseError(
            "messaging/registration-token-not-registered",
            `Requested entity was not found: ${token}`,
          );
        }
        return "live-message-id";
      });
      const notifier = createNotifier({ db, push: createFcmPushSender() });
      const first = { userId: uid, runId: "run-firebase-dead-live-1", sessionId: "ses-firebase" };
      await notifier.notifyAgentFinished(first);

      expect(fcmSend).toHaveBeenCalledTimes(2);
      expect(fcmSend.mock.calls.map(([message]) => message.token)).toEqual(
        expect.arrayContaining([deadToken, liveToken]),
      );
      expect((await devices.listForUser(db, uid)).map((device) => device.token)).toEqual([liveToken]);
      const rows = await inbox(uid);
      expect(rows).toHaveLength(2);
      expect(rows.find((row) => row.deviceToken === deadToken)).toMatchObject({
        status: "failed",
        error: "unregistered",
      });
      expect(rows.find((row) => row.deviceToken === liveToken)?.status).toBe("sent");
      expect(JSON.stringify(rows)).not.toContain(`Requested entity was not found: ${deadToken}`);

      await notifier.notifyAgentFinished({ ...first, runId: "run-firebase-dead-live-2" });
      expect(fcmSend).toHaveBeenCalledTimes(3);
      expect(fcmSend.mock.calls[2]![0].token).toBe(liveToken);

      const claims = await db.select().from(schema.notificationDeliveryClaims);
      expect(claims.filter((row) => row.userId === uid).map((row) => row.state)).toEqual([
        "delivered",
        "delivered",
      ]);
    });
  });

  it("a pruned last device lets the next completion attempt settle as skipped_no_devices", async () => {
    const uid = await newUser();
    const deadToken = "firebase-only-dead-token";
    await devices.upsert(db, { token: deadToken, userId: uid, platform: "android" });

    await withFcmCredentials(async () => {
      fcmSend.mockReset();
      fcmSend.mockRejectedValue(firebaseError(
        "messaging/invalid-registration-token",
        `Invalid registration token: ${deadToken}`,
      ));
      const notifier = createNotifier({ db, push: createFcmPushSender() });
      const completion = { userId: uid, runId: "run-firebase-no-devices", sessionId: "ses-firebase-only" };
      await notifier.notifyAgentFinished(completion);

      expect(await devices.listForUser(db, uid)).toHaveLength(0);
      let claims = await db.select().from(schema.notificationDeliveryClaims);
      expect(claims.some((row) => row.userId === uid && row.runId.trim() === completion.runId)).toBe(false);

      await notifier.notifyAgentFinished(completion);
      expect(fcmSend).toHaveBeenCalledTimes(1);
      const rows = await inbox(uid);
      expect(rows).toHaveLength(2);
      expect(rows.find((row) => row.deviceToken === deadToken)).toMatchObject({
        status: "failed",
        error: "unregistered",
      });
      expect(rows.find((row) => row.status === "skipped_no_devices")?.deviceToken).toBeNull();
      claims = await db.select().from(schema.notificationDeliveryClaims);
      expect(claims.find((row) => row.userId === uid && row.runId.trim() === completion.runId)?.state)
        .toBe("delivered");
    });
  });

  it("(d) zero devices: exactly one skipped_no_devices row with a null token, zero sends", async () => {
    const uid = await newUser();
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await notifier.notifyScheduleFailed({
      userId: uid,
      scheduleId: "sch-7",
      sessionId: "ses-7",
      title: "Report",
      code: "run_lost",
      error: "orphaned",
    });

    expect(sent).toHaveLength(0);
    const rows = await inbox(uid);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.deviceToken).toBeNull();
    expect(rows[0]!.status).toBe("skipped_no_devices");
  });

  it("(e) push.send throwing: notifier resolves, record is failed, token never appears in the error", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-throw", userId: uid, platform: "android" });
    const { sent, push } = stubPush(() => Promise.reject(new Error("fcm exploded")));
    const notifier = createNotifier({ db, push });

    await expect(
      notifier.notifyScheduleSucceeded({
        userId: uid,
        scheduleId: "sch-8",
        sessionId: "ses-8",
        title: "Report",
        summary: "done",
      }),
    ).resolves.toBeUndefined();

    expect(sent).toHaveLength(1);
    const rows = await inbox(uid);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.status).toBe("failed");
    expect(rows[0]!.error).toContain("fcm exploded");
    expect(rows[0]!.error).not.toContain("tok-throw");
  });

  it("(f) approval copy: question vs approval kinds, session-prefixed body, chat route", async () => {
    const uid = await newUser();
    await devices.upsert(db, { token: "tok-ap", userId: uid, platform: "android" });
    const { sent, push } = stubPush();
    const notifier = createNotifier({ db, push });

    await notifier.notifyApprovalRequest({
      userId: uid,
      sessionId: "ses-9",
      sessionTitle: "Sess",
      summary: "Summ",
      question: true,
    });
    await notifier.notifyApprovalRequest({
      userId: uid,
      sessionId: "ses-10",
      sessionTitle: "Sess",
      summary: "Summ",
      question: false,
    });
    await notifier.notifyApprovalRequest({
      userId: uid,
      sessionId: "ses-11",
      sessionTitle: "",
      summary: "Summ",
      question: false,
    });

    expect(sent).toHaveLength(3);
    const [question, approval, untitled] = sent;
    expect(question!.notification.title).toBe("Ovid has a question");
    expect(question!.data.kind).toBe("agentNeedsInput");
    expect(question!.data.channel).toBe("agent_updates");
    expect(question!.androidChannelId).toBe("ovid_agent_updates.chime.v1");
    expect(question!.notification.body).toBe("Sess — Summ");
    expect(question!.data.route).toBe("/c/ses-9");
    expect(question!.data.sessionId).toBe("ses-9");
    expect(approval!.notification.title).toBe("Ovid needs your approval");
    expect(approval!.data.kind).toBe("agentNeedsApproval");
    expect(approval!.notification.body).toBe("Sess — Summ");
    expect(untitled!.notification.body).toBe("Summ");
  });
});

describe("createFcmPushSender error classification", () => {
  it.each(DEAD_FCM_CODES)("classifies Firebase public code messaging/%s as unregistered", async (code) => {
    const outcome = await sendFcmError(firebaseError(
      `messaging/${code}`,
      `Firebase rejected ${FCM_MESSAGE.token}`,
    ));

    expect(outcome).toMatchObject({ ok: false, code: "unregistered" });
    expect(JSON.stringify(outcome)).not.toContain(FCM_MESSAGE.token);
  });

  it.each(DEAD_FCM_CODES)("retains legacy bare errorInfo.code %s as unregistered", async (code) => {
    const outcome = await sendFcmError({
      errorInfo: { code },
      message: `Firebase rejected ${FCM_MESSAGE.token}`,
    });

    expect(outcome).toMatchObject({ ok: false, code: "unregistered" });
    expect(JSON.stringify(outcome)).not.toContain(FCM_MESSAGE.token);
  });

  it.each([
    "messaging/mismatched-credential",
    "messaging/authentication-error",
    "messaging/third-party-auth-error",
    "messaging/message-rate-exceeded",
    "messaging/server-unavailable",
    "messaging/internal-error",
    "ECONNRESET",
    "ETIMEDOUT",
    "messaging/registration-token-not-registered-extra",
    "messaging/messaging/registration-token-not-registered",
  ])("does not classify non-dead error %s as unregistered", async (code) => {
    const outcome = await sendFcmError(firebaseError(code, `Firebase rejected ${FCM_MESSAGE.token}`));

    expect(outcome).toMatchObject({ ok: false, code: "error" });
    expect(JSON.stringify(outcome)).not.toContain(FCM_MESSAGE.token);
  });
});

describe("createFcmPushSender (construction smoke)", () => {
  it("resolves {ok:false,code:'error'} on every send when credentials are unset — never throws", async () => {
    const prev = process.env.GOOGLE_APPLICATION_CREDENTIALS;
    delete process.env.GOOGLE_APPLICATION_CREDENTIALS;
    try {
      const sender = createFcmPushSender();
      const msg: PushMessage = {
        token: "tok-smoke",
        notification: { title: "t", body: "b" },
        data: {},
        androidChannelId: "ovid_agent_updates.chime.v1",
      };
      const first = await sender.send(msg);
      const second = await sender.send(msg);
      for (const out of [first, second]) {
        expect(out.ok).toBe(false);
        if (!out.ok) expect(out.code).toBe("error");
      }
    } finally {
      if (prev !== undefined) process.env.GOOGLE_APPLICATION_CREDENTIALS = prev;
    }
  });
});
