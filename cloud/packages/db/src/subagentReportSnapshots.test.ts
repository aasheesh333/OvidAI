import { describe, expect, it } from "vitest";

import type { Db } from "./client.js";
import type { SubagentReportRecord } from "./subagentAdmission.js";
import {
  readDurableSubagentReportSnapshot,
  readDurableSubagentReportSnapshotWithin,
  type DurableSubagentReportPageReader,
  type DurableSubagentReportTransaction,
} from "./subagentReportSnapshots.js";

interface Row {
  id: string;
  record: SubagentReportRecord;
}

interface Attempt {
  id: string;
  rootTaskRunId: string;
  executionEpoch: number;
  status: SubagentReportRecord["status"];
}

function record(id: string, root = "root-a"): Row {
  const status = (["completed", "failed", "cancelled", "timeout"] as const)[
    Number(id.slice(1)) % 4
  ]!;
  return {
    id,
    record: {
      logicalWorkerId: `worker-${id}`,
      attemptId: `attempt-${id}`,
      childSessionId: `child-${id}`,
      childRunId: `run-${id}`,
      agentType: "general-purpose",
      status,
      summary: `${status}-${id}`,
      task: `task-${id}`,
      at: Number(id.slice(1)),
    },
  };
}

function attemptsFor(rows: readonly Row[], rootFor = (_id: string) => "root-a"): Attempt[] {
  return rows.map((row) => ({
    id: row.record.attemptId,
    rootTaskRunId: rootFor(row.id),
    executionEpoch: 1,
    status: row.record.status,
  }));
}

function transaction(attempts: readonly Attempt[]): DurableSubagentReportTransaction {
  // Only the reader's public Drizzle selection boundary is modeled; the real
  // Postgres integration lives in durableSubagentReports.test.ts and exercises
  // actual drainReports/finalization, not this lightweight unit double.
  return {
    select() {
      return {
        from() {
          return {
            where: async () => attempts,
          };
        },
      };
    },
  } as unknown as DurableSubagentReportTransaction;
}

function pages(rows: readonly Row[], calls: Array<string | undefined> = []): DurableSubagentReportPageReader {
  return async (_db, input) => {
    if (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > 50) {
      throw new RangeError("Report page limit must be an integer from 1 to 50");
    }
    calls.push(input.afterId);
    const found = rows
      .filter((row) => input.afterId === undefined || row.id > input.afterId)
      .sort((a, b) => a.id.localeCompare(b.id));
    const hasMore = found.length > input.limit;
    const page = hasMore ? found.slice(0, input.limit) : found;
    return {
      items: page.map((row) => ({ ...row.record })),
      nextCursor: hasMore ? page[page.length - 1]!.id : null,
    };
  };
}

describe("DB durable subagent report snapshots (UNEXECUTED under pause)", () => {
  it("pages all 53 records and preserves independent root/epoch lineage", async () => {
    const rows = Array.from({ length: 53 }, (_, index) =>
      record(`r${String(index).padStart(3, "0")}`));
    const attempts = attemptsFor(rows, (id) => Number(id.slice(1)) % 2 === 0 ? "root-a" : "root-b")
      .map((attempt, index) => ({ ...attempt, executionEpoch: index % 3 + 1 }));
    const calls: Array<string | undefined> = [];

    const result = await readDurableSubagentReportSnapshotWithin(
      transaction(attempts),
      { sessionId: "session", pageSize: 17 },
      pages(rows, calls),
    );

    expect(result).toHaveLength(53);
    expect(new Set(result.map((report) => report.attemptId)).size).toBe(53);
    expect(calls).toEqual([undefined, "r016", "r033", "r050"]);
    expect(result[0]).toMatchObject({ rootTaskRunId: "root-a", executionEpoch: 1 });
    expect(result[1]).toMatchObject({ rootTaskRunId: "root-b", executionEpoch: 2 });

    const rootB = await readDurableSubagentReportSnapshotWithin(
      transaction(attempts),
      { sessionId: "session", rootTaskRunId: "root-b", pageSize: 50 },
      pages(rows),
    );
    expect(rootB).toHaveLength(26);
    expect(rootB.every((report) => report.rootTaskRunId === "root-b")).toBe(true);
  });

  it("restarts every standalone backfill so a late lower UUID is revisited", async () => {
    const rows = [record("r010"), record("r020")];
    const attempts = attemptsFor(rows);
    const tx = transaction(attempts);
    const isolation: unknown[] = [];
    const db = {
      async transaction<T>(
        callback: (transaction: DurableSubagentReportTransaction) => Promise<T>,
        config: unknown,
      ): Promise<T> {
        isolation.push(config);
        return callback(tx);
      },
    } as unknown as Db;

    expect((await readDurableSubagentReportSnapshot(
      db,
      { sessionId: "session", pageSize: 1 },
      pages(rows),
    )).map((report) => report.attemptId)).toEqual(["attempt-r010", "attempt-r020"]);

    rows.push(record("r005"));
    attempts.push(...attemptsFor([rows[2]!]));
    const afterLateCommit = await readDurableSubagentReportSnapshot(
      db,
      { sessionId: "session", pageSize: 1 },
      pages(rows),
    );
    expect(afterLateCommit.map((report) => report.attemptId)).toEqual([
      "attempt-r005",
      "attempt-r010",
      "attempt-r020",
    ]);
    expect(isolation).toEqual([
      { isolationLevel: "repeatable read" },
      { isolationLevel: "repeatable read" },
    ]);
  });

  it("does not let an unrelated root's terminal mismatch block root-scoped reads", async () => {
    const rows = [record("r001"), record("r002")];
    const attempts = attemptsFor(rows, (id) => id === "r001" ? "root-a" : "root-b");
    attempts[0] = { ...attempts[0]!, status: "completed" };

    const result = await readDurableSubagentReportSnapshotWithin(
      transaction(attempts),
      { sessionId: "session", rootTaskRunId: "root-b" },
      pages(rows),
    );
    expect(result.map((report) => report.attemptId)).toEqual(["attempt-r002"]);
    expect(result[0]).toMatchObject({ rootTaskRunId: "root-b", status: "cancelled" });
  });

  it("fences noncanonical terminal mutation before returning a snapshot", async () => {
    const rows = [record("r001")];
    const attempts = attemptsFor(rows);
    attempts[0] = { ...attempts[0]!, status: "completed" };

    await expect(readDurableSubagentReportSnapshotWithin(
      transaction(attempts),
      { sessionId: "session" },
      pages(rows),
    )).rejects.toThrow("Canonical terminal outcome mismatch for attempt attempt-r001");
  });
});
