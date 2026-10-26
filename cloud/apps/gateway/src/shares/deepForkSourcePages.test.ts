import { describe, expect, it } from "vitest";
import {
  createDeepForkPlanFromPages,
  initialDeepForkSourceCheckpoint,
  readDeepForkSourcePage,
  type DeepForkCanonicalPage,
  type DeepForkCanonicalSourceReader,
  type DeepForkSourceCheckpoint,
  type DeepForkSourceStream,
} from "./deepForkSourcePages.js";
import {
  resumeDeepForkPlan,
  type DeepForkOperation,
  type DeepForkPlan,
  type DeepForkPublishedRevision,
  type DeepForkSourceArtifact,
  type DeepForkSourceAttachment,
  type DeepForkSourceEvent,
  type DeepForkSourceMessage,
  type DeepForkSourceObject,
  type DeepForkSourceRun,
  type DeepForkSourceSession,
} from "./deepForkPlan.js";

// UNEXECUTED: authored under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// Pure in-memory canonical reader fixtures only: no Postgres, storage, queue, or app.

const STREAMS: readonly DeepForkSourceStream[] = ["messages", "runs", "objects", "events"];

function at(index: number): string {
  return new Date(Date.UTC(2026, 0, 1) + index * 1_000).toISOString();
}

function messageId(index: number): string {
  return `00000000-0000-7000-8000-${index.toString(16).padStart(12, "0")}`;
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareDigits(a: string, b: string): number {
  const left = a.replace(/^0+(?=\d)/, "");
  const right = b.replace(/^0+(?=\d)/, "");
  return left.length === right.length ? compareText(left, right) : left.length - right.length;
}

function compareSeq(a: string, b: string): number {
  const [ams, asub] = a.split("-") as [string, string];
  const [bms, bsub] = b.split("-") as [string, string];
  return compareDigits(ams, bms) || compareDigits(asub, bsub);
}

interface ReadCall {
  stream: DeepForkSourceStream;
  limit: number;
  rowCount: number;
}

interface CombinedFixture {
  published: DeepForkPublishedRevision;
  reader: DeepForkCanonicalSourceReader;
  calls: ReadCall[];
  messages: DeepForkSourceMessage[];
  runs: DeepForkSourceRun[];
  objects: DeepForkSourceObject[];
  events: DeepForkSourceEvent[];
  expectedActualBytes: number;
}

/** Emulates a canonical keyset index while holding at most limit+1 result rows. */
function canonicalPage<T>(
  rows: readonly T[],
  key: (row: T) => string,
  compare: (a: string, b: string) => number,
  exposed: (row: T) => boolean,
  cursor: string | null,
  limit: number,
): DeepForkCanonicalPage<T> {
  const found: T[] = [];
  for (const row of rows) {
    if (!exposed(row)) continue;
    const rowKey = key(row);
    if (cursor !== null && compare(rowKey, cursor) <= 0) continue;
    found.push(row);
    if (found.length > limit) break;
  }
  const page = found.slice(0, limit);
  const last = page.at(-1);
  return {
    rows: page,
    nextCursor: found.length > limit && last !== undefined ? key(last) : null,
  };
}

function combinedFixture(): CombinedFixture {
  const session: DeepForkSourceSession = {
    id: "source-session",
    title: "Large published canonical history",
    mode: "auto",
    createdAt: at(0),
  };
  const messages: DeepForkSourceMessage[] = Array.from({ length: 603 }, (_, index) => ({
    id: messageId(index + 1),
    sessionId: session.id,
    role: index % 2 === 0 ? "user" : "assistant",
    content: `visible-${index}:${"x".repeat(410)}`,
    // Imported history: fresh UUID keyset order deliberately disagrees with
    // display timestamps. The reader/planner must not reorder by createdAt.
    createdAt: at(10_000 - index),
    ...(index % 2 === 1 ? { reasoning: `PRIVATE_REASONING_${index}` } : {}),
  }));
  messages.push({
    id: "message-private-unpublished",
    sessionId: session.id,
    role: "system",
    content: "PRIVATE_UNPUBLISHED_MESSAGE",
    createdAt: at(20_000),
  });

  const runs: DeepForkSourceRun[] = [
    {
      id: "run-complete",
      sessionId: session.id,
      promptMessageId: messageId(1),
      status: "completed",
      createdAt: at(1),
      startedAt: at(2),
      finishedAt: at(3),
    },
    {
      id: "run-failed",
      sessionId: session.id,
      promptMessageId: messageId(3),
      status: "failed",
      createdAt: at(4),
      startedAt: at(4),
      finishedAt: at(5),
    },
    {
      id: "run-cancelled",
      sessionId: session.id,
      promptMessageId: messageId(5),
      status: "cancelled",
      createdAt: at(6),
      startedAt: null,
      finishedAt: at(7),
    },
    {
      id: "run-active",
      sessionId: session.id,
      promptMessageId: messageId(7),
      status: "running",
      createdAt: at(8),
      startedAt: at(8),
      finishedAt: null,
    },
    {
      id: "run-queued",
      sessionId: session.id,
      promptMessageId: messageId(9),
      status: "queued",
      createdAt: at(9),
      startedAt: null,
      finishedAt: null,
    },
  ];

  const artifacts: DeepForkSourceArtifact[] = Array.from({ length: 3 }, (_, index) => ({
    id: `artifact-${index}`,
    sessionId: session.id,
    kind: "artifact",
    status: "active",
    r2Key: `users/source/sessions/source-session/artifacts/${index}`,
    bytes: 101 + index,
    sha256: (index + 1).toString(16).repeat(64),
    contentType: "text/plain",
    meta: { name: `artifact-${index}.txt`, private: "PRIVATE_ARTIFACT_METADATA" },
    createdAt: at(100 + index),
  }));
  const attachments: DeepForkSourceAttachment[] = Array.from({ length: 4 }, (_, index) => ({
    id: `attachment-${index}`,
    sessionId: session.id,
    name: `attachment-${index}.txt`,
    uploadStatus: "ready",
    r2Key: `users/source/sessions/source-session/uploads/${index}`,
    size: 900_000 + index,
    actualBytes: 201 + index,
    sha256: (index + 4).toString(16).repeat(64),
    contentType: "application/octet-stream",
    actualContentType: "text/plain",
    contentTypeDeclared: true,
    messageId: messageId(index * 2 + 1),
    createdAt: at(100 + index),
    finalizedAt: at(200 + index),
  }));
  const objects: DeepForkSourceObject[] = [
    ...artifacts.map((artifact): DeepForkSourceObject => ({ kind: "artifact", artifact })),
    ...attachments.map((attachment): DeepForkSourceObject => ({ kind: "attachment", attachment })),
    {
      kind: "artifact",
      artifact: {
        id: "artifact-private",
        sessionId: session.id,
        kind: "artifact",
        status: "deleted",
        r2Key: "users/source/PRIVATE_REVOKED",
        bytes: 1,
        sha256: "f".repeat(64),
        contentType: "text/plain",
        meta: { name: "PRIVATE_REVOKED" },
        createdAt: at(300),
      },
    },
  ].sort((a, b) => {
    const aRow = a.kind === "artifact" ? a.artifact : a.attachment;
    const bRow = b.kind === "artifact" ? b.artifact : b.attachment;
    return compareText(aRow.createdAt, bRow.createdAt) ||
      compareText(`${a.kind}:${aRow.id}`, `${b.kind}:${bRow.id}`);
  });

  const events: DeepForkSourceEvent[] = [];
  let sequence = 0;
  const emit = (
    type: string,
    payload: Record<string, unknown>,
    ts = sequence,
  ): void => {
    sequence += 1;
    events.push({ sessionId: session.id, seq: `${sequence}-0`, type, payload, ts: at(ts) });
  };
  emit("run_started", { runId: "run-complete" });
  for (const message of messages.slice(0, 603)) {
    if (message.role !== "assistant") continue;
    // Canonical message_completed has no runId. Content/reasoning in this
    // envelope are forgeable; the planner must use the canonical message row.
    emit("message_completed", {
      messageId: message.id,
      content: "DUPLICATE_CLIENT_TEXT",
      reasoning: "PRIVATE_EVENT_REASONING",
    }, parseInt(message.id.slice(-12), 16));
  }
  emit("tool_started", {
    runId: "run-active",
    callId: "active-call",
    name: "safe_tool",
    input: "PRIVATE_ACTIVE_TOOL_INPUT",
  });
  emit("message_segment", { runId: "run-active", content: "Visible active segment" });
  for (const [index, artifact] of artifacts.entries()) {
    emit("artifact_created", {
      runId: index === 0 ? "run-active" : "run-complete",
      artifactId: artifact.id,
      sessionId: session.id,
      name: "FORGED_ARTIFACT_NAME",
      sizeBytes: 999_999,
      contentType: "text/html",
      url: "https://signed.invalid/PRIVATE_URL",
      expiresAt: at(50_000),
    }, 100 + index);
  }
  emit("run_completed", { runId: "run-complete", usage: "PRIVATE_USAGE" });
  emit("run_failed", { code: "model_terminal", message: "SAFE_FAILURE" });
  emit("run_failed", { code: "cancelled", message: "Stopped by user." });
  emit("run_cancelled", { runId: "run-cancelled", reason: "user_requested" });
  emit("subagent_started", { runId: "run-active", prompt: "PRIVATE_UNPUBLISHED_EVENT" });

  const published: DeepForkPublishedRevision = {
    shareId: "share-large",
    revisionId: "revision-large",
    state: "published",
    sessionId: session.id,
    messageIds: messages.slice(0, 603).map((message) => message.id).reverse(),
    runIds: runs.map((run) => run.id),
    eventSeqs: events.slice(0, -1).map((event) => event.seq).reverse(),
    artifactIds: artifacts.map((artifact) => artifact.id),
    attachmentIds: attachments.map((attachment) => attachment.id),
  };
  const calls: ReadCall[] = [];
  const record = (stream: DeepForkSourceStream, limit: number, rowCount: number): void => {
    calls.push({ stream, limit, rowCount });
  };
  const reader: DeepForkCanonicalSourceReader = {
    async readSession() {
      return session;
    },
    async readMessages({ cursor, limit }) {
      const page = canonicalPage(
        messages,
        (row) => row.id,
        compareText,
        (row) => published.messageIds.includes(row.id),
        cursor,
        limit,
      );
      record("messages", limit, page.rows.length);
      return page;
    },
    async readRuns({ cursor, limit }) {
      const page = canonicalPage(
        runs,
        (row) => `${row.createdAt}\0${row.id}`,
        compareText,
        (row) => published.runIds.includes(row.id),
        cursor,
        limit,
      );
      record("runs", limit, page.rows.length);
      return page;
    },
    async readObjects({ cursor, limit }) {
      const page = canonicalPage(
        objects,
        (row) => {
          const value = row.kind === "artifact" ? row.artifact : row.attachment;
          return `${value.createdAt}\0${row.kind}:${value.id}`;
        },
        compareText,
        (row) => row.kind === "artifact"
          ? published.artifactIds.includes(row.artifact.id)
          : published.attachmentIds.includes(row.attachment.id),
        cursor,
        limit,
      );
      record("objects", limit, page.rows.length);
      return page;
    },
    async readEvents({ cursor, limit }) {
      const page = canonicalPage(
        events,
        (row) => row.seq,
        compareSeq,
        (row) => published.eventSeqs.includes(row.seq),
        cursor,
        limit,
      );
      record("events", limit, page.rows.length);
      return page;
    },
  };
  return {
    published,
    reader,
    calls,
    messages,
    runs,
    objects,
    events,
    expectedActualBytes:
      artifacts.reduce((sum, row) => sum + row.bytes, 0) +
      attachments.reduce((sum, row) => sum + row.actualBytes!, 0),
  };
}

function operationsOf<K extends DeepForkOperation["kind"]>(
  plan: DeepForkPlan,
  kind: K,
): Array<Extract<DeepForkOperation, { kind: K }>> {
  return plan.operations.filter((operation): operation is Extract<DeepForkOperation, { kind: K }> =>
    operation.kind === kind
  );
}

describe("deep fork canonical source pages — UNEXECUTED regressions", () => {
  it("reads all four streams in bounded revision pages and resumes a source checkpoint without duplicates", async () => {
    const fixture = combinedFixture();
    const limit = 17;
    const first = await readDeepForkSourcePage({
      reader: fixture.reader,
      published: fixture.published,
      limit,
    });
    if (first === null || first.stream !== "messages") throw new Error("expected a message page");
    expect(first.rows).toHaveLength(limit);

    // Crash after the first canonical source page: only its checkpoint is
    // carried forward. No complete source array is passed to the reader API.
    let checkpoint: DeepForkSourceCheckpoint = first.checkpoint;
    const seen: Record<DeepForkSourceStream, string[]> = {
      messages: first.rows.map((row) => row.id),
      runs: [],
      objects: [],
      events: [],
    };
    for (let guard = 0; guard < 2_000; guard += 1) {
      const page = await readDeepForkSourcePage({
        reader: fixture.reader,
        published: fixture.published,
        checkpoint,
        limit,
      });
      if (page === null) {
        checkpoint = { ...checkpoint, stage: "complete", cursor: null, afterKey: null };
        break;
      }
      expect(page.rows.length).toBeLessThanOrEqual(limit);
      if (page.stream === "messages") seen.messages.push(...page.rows.map((row) => row.id));
      else if (page.stream === "runs") seen.runs.push(...page.rows.map((row) => row.id));
      else if (page.stream === "objects") {
        seen.objects.push(...page.rows.map((row) => row.kind === "artifact" ? row.artifact.id : row.attachment.id));
      } else seen.events.push(...page.rows.map((row) => row.seq));
      checkpoint = page.checkpoint;
      if (guard === 1_999) throw new Error("canonical source pager did not finish");
    }

    expect(checkpoint.stage).toBe("complete");
    expect(seen.messages).toEqual([...fixture.published.messageIds].sort());
    expect(seen.runs).toEqual(fixture.runs.map((run) => run.id));
    expect(seen.objects).toHaveLength(7);
    expect(seen.events).toHaveLength(fixture.published.eventSeqs.length);
    for (const ids of Object.values(seen)) expect(new Set(ids).size).toBe(ids.length);
    expect(seen.messages).not.toContain("message-private-unpublished");
    expect(seen.objects).not.toContain("artifact-private");
    expect(seen.events).not.toContain(fixture.events.at(-1)!.seq);
    for (const stream of STREAMS) {
      const calls = fixture.calls.filter((call) => call.stream === stream);
      expect(calls.length).toBeGreaterThan(0);
      expect(calls.every((call) => call.limit === limit && call.rowCount <= limit)).toBe(true);
    }
    expect(fixture.calls.filter((call) => call.stream === "messages").length).toBeGreaterThan(30);
  });

  it("builds >500 messages and >200KB plus objects/events from pages and resumes output checkpoints", async () => {
    const fixture = combinedFixture();
    const plan = await createDeepForkPlanFromPages({
      jobId: "large-fork-job",
      recipientUserId: "recipient-large",
      published: fixture.published,
      reader: fixture.reader,
      quota: { usedBytes: 0, reservedBytes: 0, limitBytes: 1_000_000 },
      sourcePageSize: 19,
      pageSize: 43,
    });
    const messages = operationsOf(plan, "copy_message").map((operation) => operation.message);
    const copiedBytes = messages.reduce((sum, message) => sum + Buffer.byteLength(message.content, "utf8"), 0);

    expect(messages).toHaveLength(603);
    expect(copiedBytes).toBeGreaterThan(200_000);
    expect(messages.map((message) => message.id)).toEqual(
      [...messages.map((message) => message.id)].sort(),
    );
    expect(plan.totals.runs).toBe(3); // active + queued source runs create no target rows
    expect(plan.idMap.runs["run-active"]).toBeUndefined();
    expect(plan.idMap.runs["run-queued"]).toBeUndefined();
    expect(plan.totals.artifacts).toBe(3);
    expect(plan.totals.attachments).toBe(4);
    expect(plan.totals.events).toBe(fixture.published.eventSeqs.length);
    expect(plan.requiredActualBytes).toBe(fixture.expectedActualBytes);
    expect(JSON.stringify(plan)).not.toContain("PRIVATE_");
    expect(JSON.stringify(plan)).not.toContain("DUPLICATE_CLIENT_TEXT");
    expect(fixture.calls.length).toBeGreaterThan(35);
    expect(fixture.calls.every((call) => call.limit === 19 && call.rowCount <= 19)).toBe(true);

    const emitted: string[] = [];
    let checkpoint = plan.initialCheckpoint;
    let traversedPages = 0;
    let checkedObjectReplay = false;
    for (let guard = 0; guard < 100; guard += 1) {
      const current = resumeDeepForkPlan({ plan, checkpoint });
      const page = current.page;
      if (page === null) {
        expect(current.progress.complete).toBe(true);
        expect(current.progress.copied).toEqual(plan.totals);
        break;
      }
      expect(page.operations.length).toBeLessThanOrEqual(43);
      emitted.push(...page.operations.map((operation) => operation.key));

      if (traversedPages === 2) {
        const afterLostCheckpoint = resumeDeepForkPlan({
          plan,
          checkpoint,
          appliedOperationKeys: page.operationKeys,
        });
        expect(afterLostCheckpoint.checkpoint).toEqual(page.checkpointAfterPage);
        expect(afterLostCheckpoint.page?.operations.map((operation) => operation.key) ?? [])
          .not.toContain(page.operationKeys[0]);
      }
      const object = page.operations.find((operation) => operation.kind === "copy_object");
      if (object !== undefined) {
        const afterObject = resumeDeepForkPlan({
          plan,
          checkpoint,
          appliedOperationKeys: [object.key],
        });
        expect(afterObject.checkpoint).toEqual(checkpoint);
        expect(afterObject.page?.operations.map((operation) => operation.key)).not.toContain(object.key);
        checkedObjectReplay = true;
      }
      checkpoint = page.checkpointAfterPage;
      traversedPages += 1;
      if (guard === 99) throw new Error("deep-fork output pager did not finish");
    }
    expect(traversedPages).toBe(plan.pageCount);
    expect(checkedObjectReplay).toBe(true);
    expect(emitted).toHaveLength(plan.operations.length);
    expect(new Set(emitted).size).toBe(emitted.length);
  });

  it("fails closed on foreign checkpoints, oversized pages, cursor loops, and unpublished revisions", async () => {
    const fixture = combinedFixture();
    const foreign = initialDeepForkSourceCheckpoint(fixture.published);
    foreign.revisionFingerprint = "f".repeat(64);
    await expect(readDeepForkSourcePage({
      reader: fixture.reader,
      published: fixture.published,
      checkpoint: foreign,
    })).rejects.toMatchObject({ code: "checkpoint_mismatch" });

    const oversized: DeepForkCanonicalSourceReader = {
      ...fixture.reader,
      async readMessages({ limit }) {
        return { rows: fixture.messages.slice(0, limit + 1), nextCursor: null };
      },
    };
    await expect(readDeepForkSourcePage({
      reader: oversized,
      published: fixture.published,
      limit: 2,
    })).rejects.toMatchObject({ code: "invalid_published_revision" });

    const looping: DeepForkCanonicalSourceReader = {
      ...fixture.reader,
      async readMessages({ limit }) {
        return { rows: fixture.messages.slice(0, limit), nextCursor: "same-cursor" };
      },
    };
    const first = await readDeepForkSourcePage({
      reader: looping,
      published: fixture.published,
      limit: 2,
    });
    await expect(readDeepForkSourcePage({
      reader: looping,
      published: fixture.published,
      checkpoint: first!.checkpoint,
      limit: 2,
    })).rejects.toMatchObject({ code: "invalid_published_revision" });

    await expect(readDeepForkSourcePage({
      reader: fixture.reader,
      published: { ...fixture.published, state: "revoked" },
    })).rejects.toMatchObject({ code: "share_unavailable" });
  });
});
