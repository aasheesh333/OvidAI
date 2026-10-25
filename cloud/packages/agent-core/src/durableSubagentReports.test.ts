import type { StructuredSubagentReport } from "@ovid/shared";
import {
  admitDispatches,
  createDb,
  drainReports,
  fingerprintRootFinalizationReports,
  markRootFinalized,
  messages,
  migrate,
  newId,
  runs,
  sessions,
  settleAttemptAndMaybeWake,
  snapshotRootFinalization,
  users,
  type AdmissionOutcome,
  type AdmissionRequest,
  type Db,
  type SubagentReportRecord,
} from "@ovid/db";
import { afterEach, describe, expect, it } from "vitest";

import {
  createDurableSubagentReportDrain,
  createPostgresDurableSubagentReportStore,
  DURABLE_SUBAGENT_REPORT_CONTEXT_KEY,
  DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID,
  durableSubagentReportMessageId,
  formatDurableSubagentReports,
  mergeDurableSubagentReports,
  readDurableSubagentReportSnapshot,
  type DurableSubagentReport,
  type DurableSubagentReportAck,
  type DurableSubagentReportInjection,
  type DurableSubagentReportInjectionResult,
  type DurableSubagentReportStore,
} from "./durableSubagentReports.js";
import {
  drainDurableSubagentReportsForLoop,
  projectDurableSubagentReportsForLoop,
} from "./durableSubagentReportLoop.js";
import { createMemoryStateStore } from "./ports.js";
import {
  formatSubagentReports,
  PENDING_SUBAGENT_REPORTS_KEY,
  takePendingSubagentReports,
  type SubagentReport,
} from "./subagents.js";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../db/src/migrationTestKit.js";

interface SeedReport {
  id: string;
  sessionId?: string;
  rootTaskRunId?: string;
  executionEpoch?: number;
  attemptId?: string;
  childSessionId?: string;
  childRunId?: string;
  logicalWorkerId?: string;
  agentType?: string;
  status?: SubagentReportRecord["status"];
  summary?: string;
  task?: string;
  at?: number;
  structuredReport?: StructuredSubagentReport;
}

interface StoredReport {
  id: string;
  sessionId: string;
  report: DurableSubagentReport;
}

interface FakeContext {
  content: string;
  reports: DurableSubagentReport[];
  acknowledged: boolean;
}

const LEGACY_PREFIX =
  "Background subagents you dispatched have finished. Their results are below.\n" +
  "Use them to answer the user. Do NOT dispatch these tasks again — the work is already done; repeating it wastes the user's allowance.\n";
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

function structured(
  childSessionId: string,
  status: StructuredSubagentReport["status"] = "completed",
): StructuredSubagentReport {
  return {
    subagent_id: childSessionId,
    status,
    files_modified: ["src/observed.ts"],
    artifacts_created: ["artifact-observed"],
    key_findings: "Observed finding.",
    error_if_any: status === "failed" ? "actual failure" : null,
  };
}

function legacyLine(record: Pick<
  SubagentReportRecord,
  "childSessionId" | "agentType" | "status" | "summary" | "task"
>): string {
  const task = record.task.replace(/\s+/g, " ").trim();
  const summary = record.summary.trim();
  return `- ${record.childSessionId} (${record.agentType}) ${record.status}: ` +
    `${summary === "" ? "finished without a final answer" : summary}` +
    (task === "" ? "" : `\n  task: ${task}`);
}

function legacyText(record: Parameters<typeof legacyLine>[0]): string {
  return LEGACY_PREFIX + legacyLine(record);
}

function contextFingerprint(content: string, reports: readonly DurableSubagentReport[]): string {
  return JSON.stringify({ content, reports });
}

/** In-memory model of one durable session-state context, never of report ID visibility. */
class FakeDrainStore implements DurableSubagentReportStore {
  readonly rows: StoredReport[] = [];
  readonly injectionAttempts: DurableSubagentReportInjection[] = [];
  readonly acknowledgements: DurableSubagentReportAck[] = [];
  readonly acknowledgedDeliveries = new Map<string, DurableSubagentReport>();
  context: FakeContext | null = null;
  injectWrites = 0;
  ackWrites = 0;
  private failNextInject = false;
  private crashAfterNextInject = false;
  private failNextAck = false;
  private crashAfterNextAck = false;
  private snapshotHook: (() => void) | null = null;

  seed(input: SeedReport): StoredReport {
    const attemptId = input.attemptId ?? `attempt-${input.id}`;
    const childSessionId = input.childSessionId ?? `child-${input.id}`;
    const status = input.status ?? "completed";
    const stored: StoredReport = {
      id: input.id,
      sessionId: input.sessionId ?? "session-a",
      report: {
        logicalWorkerId: input.logicalWorkerId ?? `worker-${attemptId}`,
        attemptId,
        childSessionId,
        childRunId: input.childRunId ?? `run-${attemptId}`,
        agentType: input.agentType ?? "general-purpose",
        status,
        summary: input.summary ?? `summary-${input.id}`,
        task: input.task ?? `task-${input.id}`,
        at: input.at ?? 1,
        rootTaskRunId: input.rootTaskRunId ?? "root-a",
        executionEpoch: input.executionEpoch ?? 1,
        ...(input.structuredReport !== undefined
          ? { structuredReport: input.structuredReport }
          : {}),
      },
    };
    this.rows.push(stored);
    this.rows.sort((a, b) => a.id.localeCompare(b.id));
    return stored;
  }

  mutate(attemptId: string, patch: Partial<DurableSubagentReport>): void {
    const row = this.rows.find((candidate) => candidate.report.attemptId === attemptId);
    if (row === undefined) throw new Error(`missing fixture ${attemptId}`);
    row.report = { ...row.report, ...patch };
  }

  failBeforeInjection(): void {
    this.failNextInject = true;
  }

  crashAfterInjectionBeforeAck(): void {
    this.crashAfterNextInject = true;
  }

  failAcknowledgement(): void {
    this.failNextAck = true;
  }

  crashAfterAcknowledgement(): void {
    this.crashAfterNextAck = true;
  }

  afterNextSnapshot(hook: () => void): void {
    this.snapshotHook = hook;
  }

  async readSnapshot(input: { sessionId: string }): Promise<DurableSubagentReport[]> {
    const snapshot = this.rows
      .filter((row) => row.sessionId === input.sessionId)
      .map((row) => ({ ...row.report }));
    const hook = this.snapshotHook;
    this.snapshotHook = null;
    hook?.();
    return snapshot;
  }

  async inject(input: DurableSubagentReportInjection): Promise<DurableSubagentReportInjectionResult> {
    this.injectionAttempts.push(input);
    if (this.failNextInject) {
      this.failNextInject = false;
      throw new Error("crash before durable injection");
    }
    const reports = mergeDurableSubagentReports(this.context?.reports ?? [], input.reports);
    const content = formatDurableSubagentReports(reports);
    const outcome = this.context === null
      ? "injected"
      : contextFingerprint(this.context.content, this.context.reports) ===
          contextFingerprint(content, reports)
        ? "replayed"
        : "refreshed";
    if (outcome !== "replayed") this.injectWrites += 1;
    this.context = {
      content,
      reports,
      acknowledged: outcome === "replayed" ? this.context?.acknowledged ?? false : false,
    };
    if (this.crashAfterNextInject) {
      this.crashAfterNextInject = false;
      throw new Error("crash after durable injection, before acknowledgement");
    }
    return { outcome, content, reports };
  }

  async acknowledge(input: DurableSubagentReportAck): Promise<void> {
    if (this.failNextAck) {
      this.failNextAck = false;
      throw new Error("crash before durable acknowledgement");
    }
    if (
      this.context === null ||
      contextFingerprint(this.context.content, this.context.reports) !==
        contextFingerprint(input.content, input.reports)
    ) {
      throw new Error("durable injection evidence does not match acknowledgement");
    }
    this.acknowledgements.push(input);
    if (!this.context.acknowledged) this.ackWrites += 1;
    this.context.acknowledged = true;
    for (const report of input.reports) {
      this.acknowledgedDeliveries.set(report.attemptId, report);
    }
    if (this.crashAfterNextAck) {
      this.crashAfterNextAck = false;
      throw new Error("crash after durable acknowledgement, before caller result");
    }
  }
}

function service(store: DurableSubagentReportStore, pageSize = 17) {
  return createDurableSubagentReportDrain(store, { pageSize });
}

describe("DurableSubagentReportDrain (unit; UNEXECUTED under heavy-command pause)", () => {
  it("retains 53 mixed terminal reports in one batch without the legacy 20-item loss", async () => {
    const store = new FakeDrainStore();
    const outcomes = ["completed", "failed", "cancelled", "timeout"] as const;
    for (let index = 0; index < 53; index += 1) {
      const id = `r${String(index).padStart(3, "0")}`;
      const status = outcomes[index % outcomes.length]!;
      store.seed({
        id,
        rootTaskRunId: index % 2 === 0 ? "root-a" : "root-b",
        executionEpoch: index % 3 + 1,
        status,
        summary: `${status}-summary-${index}`,
        structuredReport: structured(`child-${id}`, status),
      });
    }

    const result = await service(store).drain({ sessionId: "session-a" });

    expect(result.reports).toHaveLength(53);
    expect(new Set(result.reports.map((report) => report.attemptId)).size).toBe(53);
    expect(result.reports.map((report) => report.status)).toEqual(
      Array.from({ length: 53 }, (_, index) => outcomes[index % outcomes.length]!),
    );
    expect(result).toMatchObject({ injected: 1, refreshed: 0, replayed: 0 });
    expect(store.injectWrites).toBe(1);
    expect(store.acknowledgedDeliveries.size).toBe(53);
    expect(store.rows).toHaveLength(53);
  });

  it("formats the complete multi-report batch exactly once and preserves six keys and empty summaries", async () => {
    const store = new FakeDrainStore();
    const first = store.seed({
      id: "r000",
      summary: "  done  ",
      task: "  preserve\n this task  ",
      structuredReport: structured("child-r000"),
    }).report;
    const second = store.seed({
      id: "r001",
      status: "failed",
      summary: "",
      task: "failure task",
      structuredReport: structured("child-r001", "failed"),
    }).report;

    const result = await service(store).drain({ sessionId: "session-a" });

    expect(result.content).toBe(
      LEGACY_PREFIX + legacyLine(first) + "\n" + legacyLine(second),
    );
    expect(result.content).toContain("finished without a final answer");
    expect(result.content?.split(LEGACY_PREFIX)).toHaveLength(2);
    expect(result.reports.map((report) => report.structuredReport)).toEqual([
      first.structuredReport,
      second.structuredReport,
    ]);
    for (const report of result.reports) {
      expect(Object.keys(report.structuredReport!).sort()).toEqual([
        "artifacts_created",
        "error_if_any",
        "files_modified",
        "key_findings",
        "status",
        "subagent_id",
      ]);
    }
  });

  it("projects one refreshed volatile batch and removes the stable history copy", () => {
    const messageId = durableSubagentReportMessageId("session-a");
    const history = [
      { role: "system" as const, id: messageId, content: "stale report" },
      { role: "user" as const, id: "prompt", content: "root task" },
      { role: "assistant" as const, id: "answer", content: "interim" },
    ];

    const projected = projectDurableSubagentReportsForLoop({
      sessionId: "session-a",
      history,
      content: "fresh complete batch",
    });
    expect(projected.history).toEqual(history.slice(1));
    expect(projected.volatileRows).toEqual([{
      role: "system",
      id: messageId,
      content: "fresh complete batch",
      volatile: true,
    }]);

    const replay = projectDurableSubagentReportsForLoop({
      sessionId: "session-a",
      history: [...projected.history, ...projected.volatileRows],
      content: "fresh complete batch",
    });
    expect(replay.volatileRows).toHaveLength(1);
    expect(replay.history).toEqual(history.slice(1));
    expect(projectDurableSubagentReportsForLoop({
      sessionId: "session-a",
      history,
      content: null,
    })).toEqual({ history: history.slice(1), volatileRows: [] });
  });

  it("refreshes legitimate post-insert enrichment in place without duplicate delivery", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000", summary: "initial canonical summary" });
    expect((await service(store).drain({ sessionId: "session-a" })).injected).toBe(1);

    store.mutate("attempt-r000", {
      summary: "enriched summary and observed findings",
      structuredReport: structured("child-r000"),
    });
    const enriched = await service(store).drain({ sessionId: "session-a" });
    expect(enriched).toMatchObject({ injected: 0, refreshed: 1, replayed: 0 });
    expect(enriched.content).toContain("enriched summary and observed findings");
    expect(enriched.reports[0]!.structuredReport).toEqual(structured("child-r000"));
    expect(store.injectWrites).toBe(2);
    expect(store.acknowledgedDeliveries.size).toBe(1);

    const replay = await service(store).drain({ sessionId: "session-a" });
    expect(replay).toMatchObject({ injected: 0, refreshed: 0, replayed: 1 });
    expect(store.injectWrites).toBe(2);
    expect(store.ackWrites).toBe(2);
  });

  it("rejects arbitrary terminal mutation and conflicting post-enrichment summary replacement", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000", status: "failed", summary: "base" });
    await service(store).drain({ sessionId: "session-a" });
    store.mutate("attempt-r000", {
      summary: "enriched failure",
      structuredReport: structured("child-r000", "failed"),
    });
    await service(store).drain({ sessionId: "session-a" });
    const delivered = store.context!.content;

    store.mutate("attempt-r000", {
      status: "completed",
      structuredReport: structured("child-r000", "completed"),
    });
    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("Conflicting durable terminal outcome for attempt attempt-r000");
    expect(store.context!.content).toBe(delivered);

    store.mutate("attempt-r000", {
      status: "failed",
      summary: "x",
      structuredReport: {
        ...structured("child-r000", "failed"),
        files_modified: ["src/observed.ts", "src/additional.ts"],
      },
    });
    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("Conflicting durable report enrichment for attempt attempt-r000");
    expect(store.context!.content).toBe(delivered);
  });

  it("keeps independent roots and epochs distinct and preserves every terminal outcome", async () => {
    const store = new FakeDrainStore();
    store.seed({
      id: "r000",
      attemptId: "attempt-a1",
      rootTaskRunId: "root-a",
      executionEpoch: 1,
      logicalWorkerId: "worker-shared",
    });
    store.seed({
      id: "r001",
      attemptId: "attempt-a2",
      rootTaskRunId: "root-a",
      executionEpoch: 2,
      logicalWorkerId: "worker-shared",
      status: "failed",
    });
    store.seed({
      id: "r002",
      attemptId: "attempt-b1",
      rootTaskRunId: "root-b",
      executionEpoch: 1,
      logicalWorkerId: "worker-shared",
      status: "timeout",
    });

    const result = await service(store).drain({ sessionId: "session-a" });

    expect(result.reports.map((report) => [
      report.rootTaskRunId,
      report.executionEpoch,
      report.attemptId,
      report.status,
    ])).toEqual([
      ["root-a", 1, "attempt-a1", "completed"],
      ["root-a", 2, "attempt-a2", "failed"],
      ["root-b", 1, "attempt-b1", "timeout"],
    ]);
  });

  it("revisits a late report below every earlier UUID cursor instead of stranding it", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r010", summary: "first visible" });
    store.seed({ id: "r020", summary: "second visible" });
    await service(store).drain({ sessionId: "session-a" });

    store.seed({ id: "r005", status: "failed", summary: "late below high-water" });
    const result = await service(store).drain({ sessionId: "session-a" });

    expect(result.reports.map((report) => report.attemptId)).toEqual([
      "attempt-r005",
      "attempt-r010",
      "attempt-r020",
    ]);
    expect(result.content).toContain("late below high-water");
    expect(result.replayed).toBe(0);
    expect(result.refreshed).toBe(1);
    expect(store.acknowledgedDeliveries.size).toBe(3);
  });

  it("leaves arrivals after the read snapshot for the next drain and makes finite progress", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000" });
    store.afterNextSnapshot(() => {
      store.seed({ id: "r001", status: "timeout", summary: "late timeout" });
    });
    const drain = service(store);

    const first = await drain.drain({ sessionId: "session-a" });
    expect(first.reports.map((report) => report.attemptId)).toEqual(["attempt-r000"]);
    const second = await drain.drain({ sessionId: "session-a" });
    expect(second.reports.map((report) => report.attemptId)).toEqual([
      "attempt-r000",
      "attempt-r001",
    ]);
    expect(second.content).toContain("late timeout");
    expect(second.refreshed).toBe(1);
    expect((await drain.drain({ sessionId: "session-a" })).replayed).toBe(1);
  });

  it("makes progress under sustained arrivals instead of starving the newest report", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000" });
    const drain = service(store);

    for (let index = 1; index <= 5; index += 1) {
      store.afterNextSnapshot(() => {
        store.seed({ id: `r00${index}`, summary: `arrival-${index}` });
      });
      const result = await drain.drain({ sessionId: "session-a" });
      expect(result.reports).toHaveLength(index);
      expect(result.reports.map((report) => report.attemptId)).toContain(`attempt-r00${index - 1}`);
    }
    const caughtUp = await drain.drain({ sessionId: "session-a" });
    expect(caughtUp.reports).toHaveLength(6);
    expect(caughtUp.content).toContain("arrival-5");
    expect((await drain.drain({ sessionId: "session-a" })).replayed).toBe(1);
  });

  it("does not acknowledge when crash happens before durable injection", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000", status: "failed" });
    store.failBeforeInjection();

    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("crash before durable injection");
    expect(store.context).toBeNull();
    expect(store.acknowledgements).toEqual([]);

    const restarted = await service(store).drain({ sessionId: "session-a" });
    expect(restarted.injected).toBe(1);
    expect(store.context?.acknowledged).toBe(true);
  });

  it("replays crash-after-injection/before-ack without a duplicate durable side effect", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000", status: "failed" });
    store.crashAfterInjectionBeforeAck();

    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("crash after durable injection, before acknowledgement");
    expect(store.context?.acknowledged).toBe(false);
    expect(store.injectWrites).toBe(1);
    expect(store.acknowledgements).toEqual([]);

    const restarted = await service(store).drain({ sessionId: "session-a" });
    expect(restarted).toMatchObject({ injected: 0, refreshed: 0, replayed: 1 });
    expect(store.injectWrites).toBe(1);
    expect(store.context?.acknowledged).toBe(true);
  });

  it("does not advance acknowledgement when its persistence fails", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000" });
    store.failAcknowledgement();

    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("crash before durable acknowledgement");
    expect(store.context?.acknowledged).toBe(false);

    const restarted = await service(store).drain({ sessionId: "session-a" });
    expect(restarted.replayed).toBe(1);
    expect(store.context?.acknowledged).toBe(true);
    expect(store.injectWrites).toBe(1);
  });

  it("replays an uncertain crash-after-ack without duplicate acknowledgement effects", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000" });
    store.crashAfterAcknowledgement();

    await expect(service(store).drain({ sessionId: "session-a" }))
      .rejects.toThrow("crash after durable acknowledgement, before caller result");
    expect(store.context?.acknowledged).toBe(true);
    expect(store.ackWrites).toBe(1);

    const restarted = await service(store).drain({ sessionId: "session-a" });
    expect(restarted.replayed).toBe(1);
    expect(store.injectWrites).toBe(1);
    expect(store.ackWrites).toBe(1);
  });

  it("uses durable state rather than process-local dedupe after restart", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000" });
    await service(store).drain({ sessionId: "session-a" });
    store.seed({ id: "r001", status: "failed" });

    const restarted = await service(store).drain({ sessionId: "session-a" });
    expect(restarted.reports).toHaveLength(2);
    expect(restarted.refreshed).toBe(1);
    expect(store.acknowledgedDeliveries.size).toBe(2);
    expect((await service(store).drain({ sessionId: "session-a" })).replayed).toBe(1);
  });

  it("returns an empty drain without injecting, acknowledging, or manufacturing work", async () => {
    const store = new FakeDrainStore();
    store.seed({ id: "r000", sessionId: "session-other" });

    const result = await service(store).drain({ sessionId: "session-a" });

    expect(result).toEqual({
      reports: [],
      content: null,
      injected: 0,
      refreshed: 0,
      replayed: 0,
    });
    expect(store.injectionAttempts).toEqual([]);
    expect(store.acknowledgements).toEqual([]);
    expect(store.rows).toHaveLength(1);
  });

  it("keeps the legacy in-memory queue as explicit compat behavior, never a production fallback", async () => {
    const state = createMemoryStateStore();
    const legacy: SubagentReport = {
      childSessionId: "legacy-child",
      childRunId: "legacy-run",
      agentType: "general-purpose",
      status: "failed",
      summary: "legacy actual failure",
      task: "legacy task",
      at: 1,
    };
    await state.patch("session-a", {
      [PENDING_SUBAGENT_REPORTS_KEY]: [legacy],
    } as unknown as Parameters<ReturnType<typeof createMemoryStateStore>["patch"]>[1]);

    const compat = await takePendingSubagentReports(state, "session-a");
    expect(formatSubagentReports(compat)).toBe(legacyText(legacy));
    expect(await takePendingSubagentReports(state, "session-a")).toEqual([]);

    const store = new FakeDrainStore();
    const result = await service(store).drain({ sessionId: "session-a" });
    expect(result.reports).toEqual([]);
    expect(store.injectionAttempts).toEqual([]);
  });

  it("honors Task 5 page-size bounds without substituting the legacy cap", async () => {
    const store = new FakeDrainStore();
    expect(() => createDurableSubagentReportDrain(store, { pageSize: 20 })).not.toThrow();
    expect(() => createDurableSubagentReportDrain(store, { pageSize: 0 })).toThrow(RangeError);
    expect(() => createDurableSubagentReportDrain(store, { pageSize: 51 })).toThrow(RangeError);
    expect(() => createDurableSubagentReportDrain(store, { pageSize: 1.5 })).toThrow(RangeError);
    expect((await service(store, 50).drain({ sessionId: "session-a" })).reports).toEqual([]);
  });
});

interface RealFixture {
  scratch: MigrationScratch;
  db: Db;
  userId: string;
  sessionId: string;
  connections: Db[];
  connect(maxConnections?: number): Db;
  close(): Promise<void>;
}

async function createRealFixture(prefix: string): Promise<RealFixture> {
  const scratch = await createMigrationScratch(TEST_DATABASE_URL!, prefix);
  await migrate(scratch.url);
  const db = createDb(scratch.url, { max: 12 });
  const userId = `${prefix}-user`;
  await users.ensure(db, userId, null);
  const session = await sessions.create(db, userId, prefix);
  const fixture: RealFixture = {
    scratch,
    db,
    userId,
    sessionId: session.id,
    connections: [db],
    connect(maxConnections = 4) {
      const connection = createDb(scratch.url, { max: maxConnections });
      fixture.connections.push(connection);
      return connection;
    },
    async close() {
      for (const connection of fixture.connections) {
        await connection.$client.end({ timeout: 5 });
      }
      await scratch.close();
    },
  };
  return fixture;
}

async function createRealRoot(fixture: RealFixture, text: string): Promise<string> {
  const prompt = await messages.append(fixture.db, {
    sessionId: fixture.sessionId,
    role: "user",
    content: text,
  });
  const run = await runs.create(fixture.db, {
    sessionId: fixture.sessionId,
    promptMessageId: prompt.id,
  });
  expect(await runs.claimNext(fixture.db, run.id)).toBe(true);
  return run.id;
}

async function admitReal(
  fixture: RealFixture,
  rootTaskRunId: string,
  count: number,
  prefix: string,
): Promise<AdmissionOutcome[]> {
  const batchId = newId();
  const requests: AdmissionRequest[] = Array.from({ length: count }, (_, index) => ({
    requestId: newId(),
    index,
    sessionId: fixture.sessionId,
    userId: fixture.userId,
    rootTaskRunId,
    parentRunId: rootTaskRunId,
    batchId,
    prompt: `${prefix}-${index}: preserve the complete prompt`,
    agentType: index % 2 === 0 ? "general-purpose" : "research",
    provenance: index % 2 === 0 ? "web" : "android",
    requestedAt: new Date(),
    modelContext: {
      requestedModel: null,
      byokKeyId: null,
      actorUserId: fixture.userId,
    },
  }));
  const outcomes = await admitDispatches(fixture.db, requests);
  expect(outcomes.every((outcome) => outcome.admission === "admitted")).toBe(true);
  return outcomes;
}

async function settleReal(
  db: Db,
  admitted: readonly AdmissionOutcome[],
): Promise<void> {
  const outcomes = ["completed", "failed", "cancelled", "timeout"] as const;
  for (const [index, admission] of admitted.entries()) {
    await settleAttemptAndMaybeWake(db, {
      attemptId: admission.attemptId!,
      outcome: outcomes[index % outcomes.length]!,
    });
  }
}

async function storedContext(db: Db, sessionId: string): Promise<{
  content: string;
  reports: DurableSubagentReport[];
  acknowledged: boolean;
} | null> {
  const rows = await db.$client`
    SELECT state -> ${DURABLE_SUBAGENT_REPORT_CONTEXT_KEY} AS context
    FROM session_agent_state WHERE session_id = ${sessionId}`;
  return (rows[0]?.context ?? null) as {
    content: string;
    reports: DurableSubagentReport[];
    acknowledged: boolean;
  } | null;
}

async function storedReportMessages(
  db: Db,
  sessionId: string,
): Promise<Array<{ id: string; content: string }>> {
  const rows = await db.$client`
    SELECT id, content FROM messages
    WHERE session_id = ${sessionId} AND client_msg_id = ${DURABLE_SUBAGENT_REPORT_MESSAGE_CLIENT_ID}`;
  return rows.map((row) => ({ id: row.id, content: row.content }));
}

async function waitForAdvisoryLock(db: Db, key: number): Promise<void> {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const rows = await db.$client`SELECT pg_try_advisory_lock(${key}) AS acquired`;
    if (rows[0]?.acquired === false) return;
    await db.$client`SELECT pg_advisory_unlock(${key})`;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("late report trigger did not reach its gate");
}

async function visibleLegacyHighWater(db: Db, sessionId: string): Promise<string | null> {
  let afterId: string | undefined;
  let cursor: string | null = null;
  do {
    const page = await drainReports(db, {
      sessionId,
      ...(afterId !== undefined ? { afterId } : {}),
      limit: 1,
    });
    if (page.nextCursor !== null) cursor = page.nextCursor;
    afterId = page.nextCursor ?? undefined;
  } while (afterId !== undefined);
  return cursor;
}

describe.skipIf(!TEST_DATABASE_URL).sequential(
  "DurableSubagentReportDrain real Postgres regressions (UNEXECUTED under pause)",
  () => {
    const cleanups: Array<() => Promise<void>> = [];
    afterEach(async () => {
      await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()));
    }, 30_000);

    it("uses real drainReports for 53 rows, restart replay, and independent roots", async () => {
      const fixture = await createRealFixture("drain_53");
      cleanups.push(fixture.close);
      const rootA = await createRealRoot(fixture, "root A");
      const rootB = await createRealRoot(fixture, "root B");
      const firstA = await admitReal(fixture, rootA, 30, "root-a-first");
      const firstB = await admitReal(fixture, rootB, 20, "root-b-first");
      await settleReal(fixture.db, [...firstA, ...firstB]);
      const secondA = await admitReal(fixture, rootA, 3, "root-a-second");
      await settleReal(fixture.db, secondA);
      const all = [...firstA, ...firstB, ...secondA];
      const store = createPostgresDurableSubagentReportStore(fixture.db, { pageSize: 7 });

      const result = await service(store, 7).drain({ sessionId: fixture.sessionId });

      expect(result.reports).toHaveLength(53);
      expect(new Set(result.reports.map((report) => report.attemptId))).toEqual(
        new Set(all.map((outcome) => outcome.attemptId)),
      );
      expect(result).toMatchObject({ injected: 1, refreshed: 0, replayed: 0 });
      expect(result.content?.split(LEGACY_PREFIX)).toHaveLength(2);
      expect((await storedContext(fixture.db, fixture.sessionId))?.acknowledged).toBe(true);
      expect((await storedContext(fixture.db, fixture.sessionId))?.reports).toHaveLength(53);

      const restartedDb = fixture.connect();
      const restarted = await service(
        createPostgresDurableSubagentReportStore(restartedDb, { pageSize: 7 }),
        7,
      ).drain({ sessionId: fixture.sessionId });
      expect(restarted).toMatchObject({ injected: 0, refreshed: 0, replayed: 1 });
      expect(restarted.content).toBe(result.content);
      expect(await storedReportMessages(fixture.db, fixture.sessionId)).toEqual([
        { id: expect.any(String), content: result.content },
      ]);
      const loopProjection = await drainDurableSubagentReportsForLoop({
        db: fixture.db,
        sessionId: fixture.sessionId,
        history: [
          {
            role: "system",
            id: durableSubagentReportMessageId(fixture.sessionId),
            content: "stale report context",
          },
          { role: "user", id: "root-prompt", content: "root task" },
        ],
      });
      expect(loopProjection.history).toEqual([
        { role: "user", id: "root-prompt", content: "root task" },
      ]);
      expect(loopProjection.volatileRows).toEqual([{
        role: "system",
        id: durableSubagentReportMessageId(fixture.sessionId),
        content: result.content,
        volatile: true,
      }]);

      const rootAReports = await readDurableSubagentReportSnapshot(fixture.db, {
        sessionId: fixture.sessionId,
        rootTaskRunId: rootA,
        pageSize: 7,
      });
      const rootBReports = await readDurableSubagentReportSnapshot(fixture.db, {
        sessionId: fixture.sessionId,
        rootTaskRunId: rootB,
        pageSize: 7,
      });
      expect(rootAReports).toHaveLength(33);
      expect(rootBReports).toHaveLength(20);
    }, 180_000);

    it("revisits late admit+settle below cursor, fences stale final, and fresh final sees every report", async () => {
      const fixture = await createRealFixture("drain_late_final");
      cleanups.push(fixture.close);
      const rootA = await createRealRoot(fixture, "late root A");
      const rootB = await createRealRoot(fixture, "visible root B");
      const rootC = await createRealRoot(fixture, "visible root C");
      const initial = await admitReal(fixture, rootA, 1, "initial-a");
      await settleReal(fixture.db, initial);
      const stale = await snapshotRootFinalization(fixture.db, { rootTaskRunId: rootA });
      expect(stale).toMatchObject({ activeAttemptIds: [], finalized: false });
      expect(stale?.reports).toHaveLength(1);

      const late = await admitReal(fixture, rootA, 1, "late-a");
      const visibleB = await admitReal(fixture, rootB, 1, "visible-b");
      const visibleC = await admitReal(fixture, rootC, 1, "visible-c");
      const lateAttemptId = late[0]!.attemptId!;
      const earlierReportId = "00000000-0000-7000-8000-000000000001";
      const enteredKey = 861_234_567;
      const gateKey = 861_234_568;
      await fixture.db.$client.unsafe(`
        CREATE OR REPLACE FUNCTION ovid_test_gate_late_report() RETURNS trigger
        LANGUAGE plpgsql AS $function$
        BEGIN
          IF NEW.attempt_id = '${lateAttemptId}' THEN
            NEW.id := '${earlierReportId}';
            PERFORM pg_advisory_xact_lock(${enteredKey});
            PERFORM pg_advisory_xact_lock(${gateKey});
          END IF;
          RETURN NEW;
        END
        $function$`);
      await fixture.db.$client.unsafe(`
        CREATE TRIGGER ovid_test_gate_late_report
        BEFORE INSERT ON subagent_reports FOR EACH ROW
        EXECUTE FUNCTION ovid_test_gate_late_report()`);

      const control = fixture.connect(1);
      const lateDb = fixture.connect();
      await control.$client`SELECT pg_advisory_lock(${gateKey})`;
      let lateSettlement: Promise<unknown> | undefined;
      try {
        lateSettlement = lateDb.transaction(async (tx) => {
          await settleAttemptAndMaybeWake(tx as unknown as Db, {
            attemptId: lateAttemptId,
            outcome: "failed",
          });
        });
        await waitForAdvisoryLock(control, enteredKey);
        await settleReal(fixture.db, [visibleB[0]!, visibleC[0]!]);
        const highWater = await visibleLegacyHighWater(fixture.db, fixture.sessionId);
        expect(highWater).not.toBeNull();
        expect(earlierReportId < highWater!).toBe(true);
      } finally {
        await control.$client`SELECT pg_advisory_unlock(${gateKey})`;
        if (lateSettlement !== undefined) await lateSettlement;
      }

      // The late attempt is now terminal and its earlier-UUID report committed.
      // Retry the ORIGINAL stale CAS: activeAttemptIds is still empty, so only
      // the original one-report expected set can fence this report-set ABA.
      expect(stale!.activeAttemptIds).toEqual([]);
      expect(stale!.reports.map((report) => report.attemptId)).toEqual([
        initial[0]!.attemptId,
      ]);
      expect(await markRootFinalized(fixture.db, {
        rootTaskRunId: rootA,
        executionEpoch: stale!.executionEpoch,
        activeAttemptIds: stale!.activeAttemptIds,
        expectedReportAttemptIds: stale!.reports.map((report) => report.attemptId),
      })).toBe("fenced");

      const oldCursorMissesLate = await drainReports(fixture.db, {
        sessionId: fixture.sessionId,
        afterId: (await visibleLegacyHighWater(fixture.db, fixture.sessionId))!,
        limit: 50,
      });
      expect(oldCursorMissesLate.items.map((report) => report.attemptId)).not.toContain(lateAttemptId);

      const adapted = await readDurableSubagentReportSnapshot(fixture.db, {
        sessionId: fixture.sessionId,
        pageSize: 1,
      });
      expect(adapted.map((report) => report.attemptId)).toEqual(expect.arrayContaining([
        initial[0]!.attemptId,
        lateAttemptId,
        visibleB[0]!.attemptId,
        visibleC[0]!.attemptId,
      ]));
      expect(adapted.find((report) => report.attemptId === lateAttemptId)).toMatchObject({
        rootTaskRunId: rootA,
        status: "failed",
      });

      const fresh = await snapshotRootFinalization(fixture.db, { rootTaskRunId: rootA });
      expect(fresh?.activeAttemptIds).toEqual([]);
      expect(fresh?.reports.map((report) => report.attemptId)).toEqual(
        expect.arrayContaining([initial[0]!.attemptId, lateAttemptId]),
      );
      expect(fresh?.reports).toHaveLength(2);
      expect(await markRootFinalized(fixture.db, {
        rootTaskRunId: rootA,
        executionEpoch: fresh!.executionEpoch,
        activeAttemptIds: fresh!.activeAttemptIds,
        expectedReportAttemptIds: fresh!.reports.map((report) => report.attemptId),
        expectedReportFingerprint: fingerprintRootFinalizationReports(fresh!.reports),
      })).toBe("committed");
    }, 180_000);

    it("refreshes real post-insert enrichment after restart and fences terminal outcome mutation", async () => {
      const fixture = await createRealFixture("drain_enrichment");
      cleanups.push(fixture.close);
      const root = await createRealRoot(fixture, "enrichment root");
      const admitted = await admitReal(fixture, root, 1, "enrichment");
      await settleReal(fixture.db, admitted);
      const attemptId = admitted[0]!.attemptId!;
      const childSessionId = admitted[0]!.childSessionId!;
      await service(createPostgresDurableSubagentReportStore(fixture.db))
        .drain({ sessionId: fixture.sessionId });
      const before = await storedContext(fixture.db, fixture.sessionId);
      expect(before?.reports[0]?.structuredReport).toBeUndefined();
      const enrichedReport = structured(childSessionId);
      await fixture.db.$client`
        UPDATE subagent_reports
        SET summary = ${"enriched summary and observed findings"},
          structured_report = ${JSON.stringify(enrichedReport)}::jsonb
        WHERE attempt_id = ${attemptId}`;

      const restartedDb = fixture.connect();
      const enriched = await service(createPostgresDurableSubagentReportStore(restartedDb))
        .drain({ sessionId: fixture.sessionId });
      expect(enriched).toMatchObject({ injected: 0, refreshed: 1, replayed: 0 });
      expect(enriched.reports[0]!.structuredReport).toEqual(enrichedReport);
      expect(enriched.content).toContain("enriched summary and observed findings");
      expect(enriched.content).not.toBe(before!.content);
      expect((await storedContext(fixture.db, fixture.sessionId))?.acknowledged).toBe(true);
      expect((await service(createPostgresDurableSubagentReportStore(restartedDb))
        .drain({ sessionId: fixture.sessionId })).replayed).toBe(1);
      expect(await storedReportMessages(fixture.db, fixture.sessionId)).toEqual([
        { id: expect.any(String), content: enriched.content },
      ]);
      const delivered = await storedContext(fixture.db, fixture.sessionId);

      await fixture.db.$client`
        UPDATE subagent_reports SET status = 'failed', summary = 'false failure'
        WHERE attempt_id = ${attemptId}`;
      await expect(service(createPostgresDurableSubagentReportStore(fixture.db))
        .drain({ sessionId: fixture.sessionId }))
        .rejects.toThrow("Canonical terminal outcome mismatch");
      expect(await storedContext(fixture.db, fixture.sessionId)).toEqual(delivered);
    }, 180_000);

    it("recovers a real committed injection after crash-before-ack with one durable context", async () => {
      const fixture = await createRealFixture("drain_crash_restart");
      cleanups.push(fixture.close);
      const root = await createRealRoot(fixture, "crash root");
      const admitted = await admitReal(fixture, root, 1, "crash");
      await settleReal(fixture.db, admitted);
      const inner = createPostgresDurableSubagentReportStore(fixture.db);
      const crashing: DurableSubagentReportStore = {
        readSnapshot: (input) => inner.readSnapshot(input),
        async inject(input) {
          await inner.inject(input);
          throw new Error("simulated process crash after committed injection");
        },
        acknowledge: (input) => inner.acknowledge(input),
      };

      await expect(service(crashing).drain({ sessionId: fixture.sessionId }))
        .rejects.toThrow("simulated process crash after committed injection");
      expect((await storedContext(fixture.db, fixture.sessionId))?.acknowledged).toBe(false);
      expect(await storedReportMessages(fixture.db, fixture.sessionId)).toHaveLength(1);

      const restartedDb = fixture.connect();
      const restarted = await service(createPostgresDurableSubagentReportStore(restartedDb))
        .drain({ sessionId: fixture.sessionId });
      expect(restarted).toMatchObject({ injected: 0, refreshed: 0, replayed: 1 });
      expect((await storedContext(fixture.db, fixture.sessionId))?.acknowledged).toBe(true);
      expect((await service(createPostgresDurableSubagentReportStore(restartedDb))
        .drain({ sessionId: fixture.sessionId })).replayed).toBe(1);
      expect((await storedContext(fixture.db, fixture.sessionId))?.reports).toHaveLength(1);
      expect(await storedReportMessages(fixture.db, fixture.sessionId)).toHaveLength(1);
    }, 180_000);
  },
);
