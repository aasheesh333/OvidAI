/**
 * Task 7 — the unattended-approval seam over P3's approval gate, against REAL
 * Postgres (TEST_DATABASE_URL): `isUnattendedRun` is exactly "a schedule_runs
 * row references this run", the hooks are strict no-ops for attended runs,
 * `onApprovalRequested` pushes the approval notification (with the session
 * title from `sessions.get`), and `onApprovalAutoDenied` ledgers the denial
 * on the occurrence's `auto_denied` jsonb.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createDb,
  devices,
  messages,
  migrate,
  runs,
  scheduleRuns,
  schedules,
  schema,
  sessions,
  users,
  type Db,
} from "@ovid/db";
import { createNotifier, type PushMessage, type PushOutcome, type PushSender } from "./notify.js";
import { createUnattendedApprovalHook, unattendedTimeoutPolicy } from "./unattended.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function stubPush(): { sent: PushMessage[]; push: PushSender } {
  const sent: PushMessage[] = [];
  const push: PushSender = {
    async send(msg) {
      sent.push(msg);
      return { ok: true } satisfies PushOutcome;
    },
  };
  return { sent, push };
}

describe.skipIf(!TEST_DATABASE_URL)("createUnattendedApprovalHook (real postgres)", () => {
  let db: Db;
  let uid: string;
  let sessionId: string;
  let runId: string;
  let sent: PushMessage[];
  let hook: ReturnType<typeof createUnattendedApprovalHook>;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    uid = `uh-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    await users.ensure(db, uid, null);
    await devices.upsert(db, { token: `tok-${uid}`, userId: uid, platform: "android" });
    const session = await sessions.create(db, uid, "Sess");
    sessionId = session.id;
    const msg = await messages.append(db, { sessionId, role: "user", content: "hi" });
    const run = await runs.create(db, { sessionId, promptMessageId: msg.id });
    runId = run.id;
    const stubbed = stubPush();
    sent = stubbed.sent;
    // The real notifier against the real db — the hook is what's under test.
    const notifier = createNotifier({ db, push: stubbed.push });
    hook = createUnattendedApprovalHook({ db, notifier });
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function inbox(userId: string) {
    const rows = await db.select().from(schema.notifications);
    return rows.filter((r) => r.userId === userId);
  }

  it("a plain session run is attended: isUnattendedRun false and both hooks are no-ops", async () => {
    expect(await hook.isUnattendedRun(runId)).toBe(false);

    await hook.onApprovalRequested(runId, { toolName: "run_shell", summary: "Run: echo hi" });
    await hook.onApprovalAutoDenied(runId, { toolName: "run_shell", summary: "Run: echo hi" });

    expect(await inbox(uid)).toHaveLength(0);
    expect(sent).toHaveLength(0);
    const untouched = await scheduleRuns.getByRunId(db, runId);
    expect(untouched).toBeNull();
  });

  it("a claimed schedule_run flips the run unattended", async () => {
    const schedule = await schedules.create(db, {
      userId: uid,
      sessionId,
      title: "Morning",
      description: "check inbox",
      trigger: { kind: "at", at: "2026-10-17T08:00:00.000Z" },
      autonomy: "safe",
      maxRetries: 0,
      nextRunAt: new Date(1_700_000_000_000),
    });
    const claimed = await scheduleRuns.claim(db, {
      scheduleId: schedule.id,
      scheduledFor: new Date(1_700_000_000_000),
      runId,
      ranLate: false,
      sessionId,
      triggerKind: "at",
    });
    expect(claimed).not.toBeNull();

    expect(await hook.isUnattendedRun(runId)).toBe(true);
  });

  it("onApprovalRequested pushes the approval notification (session title from sessions.get)", async () => {
    await hook.onApprovalRequested(runId, {
      toolName: "run_shell",
      summary: "Run: echo hi",
      question: true,
    });

    expect(sent).toHaveLength(1);
    expect(sent[0]!.notification.title).toBe("Ovid has a question");
    expect(sent[0]!.notification.body).toBe("Sess — Run: echo hi");
    expect(sent[0]!.data.route).toBe(`/c/${sessionId}`);

    const rows = await inbox(uid);
    expect(rows).toHaveLength(1);
    expect(rows[0]!.kind).toBe("agentNeedsInput");
    expect(rows[0]!.title).toBe("Ovid has a question");
    expect(rows[0]!.body).toBe("Sess — Run: echo hi");
    expect(rows[0]!.route).toBe(`/c/${sessionId}`);
  });

  it("onApprovalAutoDenied appends to the occurrence's auto_denied ledger", async () => {
    await hook.onApprovalAutoDenied(runId, { toolName: "bash", summary: "rm -rf /tmp/x" });

    const row = await scheduleRuns.getByRunId(db, runId);
    expect(row).not.toBeNull();
    expect(row!.autoDenied).toHaveLength(1);
    expect(row!.autoDenied[0]!.toolName).toBe("bash");
    expect(row!.autoDenied[0]!.summary).toBe("rm -rf /tmp/x");
    expect(typeof row!.autoDenied[0]!.ts).toBe("string");
    expect(Number.isNaN(Date.parse(row!.autoDenied[0]!.ts))).toBe(false);
  });
});

describe("unattendedTimeoutPolicy (P4 Task 10 P3 seam)", () => {
  const req = {
    approvalId: "a",
    kind: "tool" as const,
    tool: "bash",
    summary: "Run: echo hi",
    detail: "",
    allowAlways: false,
    pathTargets: [],
    hostTargets: [],
  };
  const hook = {} as Parameters<typeof unattendedTimeoutPolicy>[0];

  it("is undefined without the hook (gate keeps its pre-P4 behavior)", () => {
    expect(unattendedTimeoutPolicy(undefined, 500)).toBeUndefined();
  });

  it("unattended → the pinned 120 s default-deny; attended → the env value", () => {
    const policy = unattendedTimeoutPolicy(hook, 500);
    expect(policy).toBeDefined();
    expect(policy!(req, { unattended: true, runId: "run-1" })).toBe(120_000);
    expect(policy!(req, { unattended: false, runId: "run-1" })).toBe(500);
  });
});
