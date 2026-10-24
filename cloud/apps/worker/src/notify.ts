/**
 * P4 Task 7: the push notifier — the Dart notification copy (titles, bodies,
 * channels, routes — `lib/core/background_notifications.dart`) ported onto
 * FCM via firebase-admin, with every delivery attempt recorded in the
 * `notifications` inbox by the Task 4 repos.
 *
 * The Dart `onResult` contract carries over: the notifier NEVER throws and
 * never affects run/settle bookkeeping — a push failure is logged and
 * recorded, nothing more. The FCM token is treated as a secret: it is never
 * logged and never lands in a `notifications.error` cell.
 */

import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

import { accountSettings, devices, notificationDeliveryClaims, notifications, pushSubscriptionsRepo, type Db } from "@ovid/db";
import type { WebPushSender } from "./webPush.js";
import {
  chatRoute,
  notificationChannelFor,
  notificationSummary,
  scheduleRoute,
  type NotificationKind,
} from "@ovid/shared";

export interface PushMessage {
  token: string;
  notification: { title: string; body: string };
  data: Record<string, string>;
  /** Dart `NotificationChannelIds` formula: `ovid_${channelKey}.chime.v1`. */
  androidChannelId: string;
}

export type PushOutcome =
  | { ok: true }
  | { ok: false; code: "unregistered" | "invalid" | "error"; error?: string };

export interface PushSender {
  send(msg: PushMessage): Promise<PushOutcome>;
}

/** Ledger Q5 pinned copy: unattended run without a minted key → open the app. */
export const KEY_NOT_MINTED_PUSH_BODY =
  "Your account needs a one-time sign-in before scheduled tasks can run. Open Ovid once to fix this.";

function androidChannelIdFor(channelKey: string): string {
  return `ovid_${channelKey}.chime.v1`;
}

// The structural slice of firebase-admin the sender uses. The module is
// loaded lazily INSIDE send() so the worker boots, tests run, and tsc builds
// even where the package or the credentials are absent — push then fails
// soft instead of crashing the process. A variable specifier keeps this file
// free of any build-time dependency on firebase-admin's type declarations.
interface FcmAppLike {
  name: string;
}
interface FcmAppModuleLike {
  getApps(): FcmAppLike[];
  initializeApp(): FcmAppLike;
}
interface FcmMessagingLike {
  send(message: {
    token: string;
    notification: { title: string; body: string };
    data: Record<string, string>;
    android: { channelId: string };
  }): Promise<string>;
}
interface FcmMessagingModuleLike {
  getMessaging(app?: FcmAppLike): FcmMessagingLike;
}
const FIREBASE_APP_MODULE = "firebase-admin/app";
const FIREBASE_MESSAGING_MODULE = "firebase-admin/messaging";

/** FCM error codes that mean "this token is dead, prune it". */
const UNREGISTERED_FCM_CODES = new Set([
  "registration-token-not-registered",
  "invalid-registration-token",
]);

function fcmErrorCode(err: unknown): string | null {
  const e = err as { code?: unknown; errorInfo?: { code?: unknown } };
  const raw = e?.errorInfo?.code ?? e?.code;
  return typeof raw === "string" ? raw : null;
}

function describeError(err: unknown): string {
  return String((err as { message?: unknown })?.message ?? err);
}

/** The registration token is secret-shaped: it never reaches a log or row. */
function redactToken(text: string, token: string): string {
  return token.length === 0 ? text : text.split(token).join("[redacted]");
}

export function createFcmPushSender(): PushSender {
  let warned = false;
  let messaging: FcmMessagingLike | null = null;
  let messagingUnavailable = false;

  /** This deployment's ADC path is GOOGLE_APPLICATION_CREDENTIALS. */
  function credentialProblem(): string | null {
    const path = process.env.GOOGLE_APPLICATION_CREDENTIALS;
    if (path === undefined || path === "") {
      return "GOOGLE_APPLICATION_CREDENTIALS is not set";
    }
    try {
      readFileSync(path);
      return null;
    } catch (err) {
      return `cannot read GOOGLE_APPLICATION_CREDENTIALS (${describeError(err)})`;
    }
  }

  function warnOnce(problem: string): void {
    if (warned) return;
    warned = true;
    console.error(`[notify] FCM push unavailable: ${problem}`);
  }

  async function loadMessaging(): Promise<FcmMessagingLike> {
    const appMod = (await import(FIREBASE_APP_MODULE)) as unknown as FcmAppModuleLike;
    const msgMod = (await import(FIREBASE_MESSAGING_MODULE)) as unknown as FcmMessagingModuleLike;
    const app = appMod.getApps()[0] ?? appMod.initializeApp();
    return msgMod.getMessaging(app);
  }

  return {
    async send(msg) {
      // Missing/unreadable credentials: fail soft on EVERY send, log ONCE.
      const problem = credentialProblem();
      if (problem !== null) {
        warnOnce(problem);
        return { ok: false, code: "error", error: problem };
      }
      if (messagingUnavailable) {
        return { ok: false, code: "error", error: "firebase-admin unavailable" };
      }
      if (messaging === null) {
        try {
          messaging = await loadMessaging();
        } catch (err) {
          messagingUnavailable = true;
          warnOnce(`firebase-admin failed to initialize (${describeError(err)})`);
          return { ok: false, code: "error", error: "firebase-admin unavailable" };
        }
      }
      try {
        await messaging.send({
          token: msg.token,
          notification: msg.notification,
          data: msg.data,
          android: { channelId: msg.androidChannelId },
        });
        return { ok: true };
      } catch (err) {
        const code = fcmErrorCode(err);
        if (code !== null && UNREGISTERED_FCM_CODES.has(code)) {
          return { ok: false, code: "unregistered", error: code };
        }
        return { ok: false, code: "error", error: redactToken(describeError(err), msg.token) };
      }
    },
  };
}

export interface NotifierDeps {
  db: Db;
  push: PushSender;
  /** Optional browser fan-out beside Android FCM; null means not configured. */
  webPush?: WebPushSender | null;
  clock?: () => Date;
}

export interface Notifier {
  notifyAgentFinished(a: {
    userId: string;
    runId: string;
    sessionId: string;
  }): Promise<void>;
  notifyScheduleSucceeded(a: {
    userId: string;
    scheduleId: string;
    sessionId: string;
    title: string;
    summary: string | null;
  }): Promise<void>;
  notifyScheduleFailed(a: {
    userId: string;
    scheduleId: string;
    sessionId: string;
    title: string;
    code: string;
    error: string | null;
  }): Promise<void>;
  notifyApprovalRequest(a: {
    userId: string;
    sessionId: string;
    sessionTitle: string;
    summary: string;
    question: boolean;
  }): Promise<void>;
  /**
   * A run failed for a reason the user must act on (owner directive
   * 2026-10-18). Delivered when the app is closed or backgrounded, so a
   * failure that only existed in a stream the user was not watching still
   * reaches them. Never throws.
   */
  notifyAgentFailed(a: {
    userId: string;
    sessionId: string;
    sessionTitle: string;
    code: string;
    message: string;
  }): Promise<void>;
}

export function createNotifier(deps: NotifierDeps): Notifier {
  const clock = deps.clock ?? (() => new Date());

  /**
   * One notification, fanned out to every registered device: one push.send
   * plus one inbox row per device (unregistered tokens are pruned and the
   * attempt recorded as failed/unregistered; other failures recorded as
   * failed; zero devices → a single skipped_no_devices row and no send).
   * Never throws — the Dart onResult contract.
   */
  async function fanOut(args: {
    userId: string;
    kind: NotificationKind;
    title: string;
    body: string;
    route: string;
    data: Record<string, string>;
  }): Promise<"delivered" | "retry"> {
    // Wave 4 (SE-010): the user's Notifications switch. Off = no push to any
    // device; the attempt is still kept in the inbox so nothing is lost. A
    // settings read failure fails OPEN (push is the documented default).
    let pushEnabled = true;
    try {
      pushEnabled = (await accountSettings.get(deps.db, args.userId)).notificationsEnabled;
    } catch (err) {
      console.error("[notify] settings read failed; sending", err);
    }
    if (!pushEnabled) {
      try {
        await notifications.record(deps.db, {
          userId: args.userId,
          deviceToken: null,
          kind: args.kind,
          channel: notificationChannelFor(args.kind),
          title: args.title,
          body: args.body,
          route: args.route,
          data: args.data,
          status: "skipped_disabled",
        });
      } catch (err) {
        console.error("[notify] inbox record failed", err);
      }
      return "delivered";
    }

    let userDevices;
    let browserSubscriptions: Awaited<ReturnType<typeof pushSubscriptionsRepo.listForUser>> = [];
    try {
      [userDevices, browserSubscriptions] = await Promise.all([
        devices.listForUser(deps.db, args.userId),
        deps.webPush
          ? pushSubscriptionsRepo.listForUser(deps.db, args.userId)
          : Promise.resolve([]),
      ]);
    } catch (err) {
      console.error("[notify] device/subscription list failed", err);
      return "retry";
    }

    if (userDevices.length === 0 && browserSubscriptions.length === 0) {
      try {
        await notifications.record(deps.db, {
          userId: args.userId,
          deviceToken: null,
          kind: args.kind,
          channel: notificationChannelFor(args.kind),
          title: args.title,
          body: args.body,
          route: args.route,
          data: args.data,
          status: "skipped_no_devices",
        });
      } catch (err) {
        console.error("[notify] inbox record failed", err);
      }
      return "delivered";
    }

    let delivered = false;
    const androidChannelId = androidChannelIdFor(notificationChannelFor(args.kind));
    for (const device of userDevices) {
      try {
        let outcome: PushOutcome;
        try {
          outcome = await deps.push.send({
            token: device.token,
            notification: { title: args.title, body: args.body },
            data: args.data,
            androidChannelId,
          });
        } catch (err) {
          outcome = {
            ok: false,
            code: "error",
            error: redactToken(describeError(err), device.token),
          };
        }

        if (outcome.ok) {
          delivered = true;
          await notifications.record(deps.db, {
            userId: args.userId,
            deviceToken: device.token,
            kind: args.kind,
            channel: notificationChannelFor(args.kind),
            title: args.title,
            body: args.body,
            route: args.route,
            data: args.data,
            status: "sent",
          });
        } else {
          if (outcome.code === "unregistered") {
            // Dead token: prune the registry row (owner-scoped) so it stops
            // consuming every future fan-out, and keep the failed attempt.
            try {
              await devices.removeByToken(deps.db, device.token, args.userId);
            } catch (err) {
              console.error(
                "[notify] unregistered-token prune failed",
                redactToken(describeError(err), device.token),
              );
            }
          }
          await notifications.record(deps.db, {
            userId: args.userId,
            deviceToken: device.token,
            kind: args.kind,
            channel: notificationChannelFor(args.kind),
            title: args.title,
            body: args.body,
            route: args.route,
            data: args.data,
            status: "failed",
            error: outcome.code === "unregistered" ? "unregistered" : outcome.error ?? outcome.code,
          });
        }
      } catch (err) {
        console.error(
          "[notify] delivery failed",
          redactToken(describeError(err), device.token),
        );
      }
    }

    for (const subscription of browserSubscriptions) {
      try {
        const outcome = await deps.webPush!.send({
          subscription: {
            endpoint: subscription.endpoint,
            p256dh: subscription.p256dh,
            auth: subscription.auth,
          },
          title: args.title,
          body: args.body,
          route: args.route,
          data: args.data,
        });
        if (outcome.ok) {
          delivered = true;
          await notifications.record(deps.db, {
            userId: args.userId,
            deviceToken: subscription.endpoint,
            kind: args.kind,
            channel: notificationChannelFor(args.kind),
            title: args.title,
            body: args.body,
            route: args.route,
            data: args.data,
            status: "sent",
          });
        } else {
          if (outcome.code === "unregistered") {
            await pushSubscriptionsRepo.remove(deps.db, args.userId, subscription.endpoint);
          }
          await notifications.record(deps.db, {
            userId: args.userId,
            deviceToken: subscription.endpoint,
            kind: args.kind,
            channel: notificationChannelFor(args.kind),
            title: args.title,
            body: args.body,
            route: args.route,
            data: args.data,
            status: "failed",
            error: outcome.error ?? outcome.code,
          });
        }
      } catch {
        // One endpoint must not prevent delivery to other browsers/devices.
      }
    }
    return delivered ? "delivered" : "retry";
  }

  return {
    async notifyAgentFinished(a) {
      const kind: NotificationKind = "agentFinished";
      const claimant = randomUUID();
      try {
        const claimed = await notificationDeliveryClaims.claim(deps.db, {
          userId: a.userId,
          kind,
          runId: a.runId,
          claimant,
        });
        if (!claimed) return;
      } catch (err) {
        console.error("[notify] completion claim failed; skipping duplicate-risk fan-out", err);
        return;
      }
      const route = chatRoute(a.sessionId);
      try {
        const outcome = await fanOut({
          userId: a.userId,
          kind,
          title: "Ovid finished your task",
          body: "Tap to see the answer.",
          route,
          data: {
            kind,
            channel: notificationChannelFor(kind),
            route,
            sessionId: a.sessionId,
            runId: a.runId,
            ts: clock().toISOString(),
          },
        });
        if (outcome === "retry") {
          await notificationDeliveryClaims.release(deps.db, {
            userId: a.userId,
            kind,
            runId: a.runId,
            claimant,
          });
          return;
        }
        await notificationDeliveryClaims.delivered(deps.db, {
          userId: a.userId,
          kind,
          runId: a.runId,
          claimant,
        });
      } catch (err) {
        // A crash or transient read failure is retryable. A delivered claim is
        // never reclaimed, so replaying the durable run cannot duplicate push.
        await notificationDeliveryClaims.release(deps.db, {
          userId: a.userId,
          kind,
          runId: a.runId,
          claimant,
        }).catch(() => {});
        console.error("[notify] completion delivery remains pending for retry", err);
      }
    },

    async notifyScheduleSucceeded(a) {
      const kind: NotificationKind = "scheduleSucceeded";
      const title = `Scheduled task done: ${notificationSummary(a.title, { max: 48 })}`;
      const summary = a.summary === null ? "" : notificationSummary(a.summary);
      const body = summary === "" ? "Tap to see the result." : summary;
      const route = scheduleRoute(a.sessionId);
      await fanOut({
        userId: a.userId,
        kind,
        title,
        body,
        route,
        data: {
          kind,
          channel: notificationChannelFor(kind),
          route,
          sessionId: a.sessionId,
          scheduleId: a.scheduleId,
          ts: clock().toISOString(),
        },
      });
    },

    async notifyScheduleFailed(a) {
      const kind: NotificationKind = "scheduleFailed";
      const title = `Scheduled task failed: ${notificationSummary(a.title, { max: 48 })}`;
      const body =
        a.code === "key_not_minted"
          ? KEY_NOT_MINTED_PUSH_BODY
          : notificationSummary(a.error ?? "Unknown error");
      const route = scheduleRoute(a.sessionId);
      await fanOut({
        userId: a.userId,
        kind,
        title,
        body,
        route,
        data: {
          kind,
          channel: notificationChannelFor(kind),
          route,
          sessionId: a.sessionId,
          scheduleId: a.scheduleId,
          ts: clock().toISOString(),
        },
      });
    },

    async notifyApprovalRequest(a) {
      const kind: NotificationKind = a.question ? "agentNeedsInput" : "agentNeedsApproval";
      const title = a.question ? "Ovid has a question" : "Ovid needs your approval";
      const summary = notificationSummary(a.summary);
      const body = a.sessionTitle === "" ? summary : `${a.sessionTitle} — ${summary}`;
      const route = chatRoute(a.sessionId);
      await fanOut({
        userId: a.userId,
        kind,
        title,
        body,
        route,
        data: {
          kind,
          channel: notificationChannelFor(kind),
          route,
          sessionId: a.sessionId,
          ts: clock().toISOString(),
        },
      });
    },
    async notifyAgentFailed(a) {
      const kind: NotificationKind = "agentFailed";
      const title = a.sessionTitle === ""
        ? "Ovid could not finish this run"
        : `Ovid could not finish: ${notificationSummary(a.sessionTitle, { max: 40 })}`;
      const route = chatRoute(a.sessionId);
      await fanOut({
        userId: a.userId,
        kind,
        title,
        body: notificationSummary(a.message, { max: 180 }),
        route,
        data: {
          kind,
          channel: notificationChannelFor(kind),
          route,
          sessionId: a.sessionId,
          code: a.code,
          ts: clock().toISOString(),
        },
      });
    },

  };
}
