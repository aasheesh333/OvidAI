import { describe, expect, it } from "vitest";
import {
  createDeepForkPlan,
  DeepForkPlanError,
  resumeDeepForkPlan,
  type DeepForkCheckpoint,
  type DeepForkObjectCopy,
  type DeepForkOperation,
  type DeepForkPlan,
  type DeepForkPlanInput,
  type DeepForkPublishedRevision,
  type DeepForkSource,
} from "./deepForkPlan.js";

// UNEXECUTED: authored under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// These are pure Vitest cases: no Postgres, storage, queue, gateway, or clock is used.

const HASH_A = "a".repeat(64);
const HASH_B = "b".repeat(64);

function at(seconds: number): string {
  return new Date(Date.UTC(2026, 0, 1, 0, 0, seconds)).toISOString();
}

function sourceFixture(): DeepForkSource {
  return {
    session: {
      id: "source-session",
      title: "Published chat",
      mode: "auto",
      createdAt: at(0),
      updatedAt: at(99),
    },
    messages: [
      {
        id: "message-z-assistant",
        sessionId: "source-session",
        role: "assistant",
        content: "Visible answer",
        reasoning: "PRIVATE_REASONING",
        clientMsgId: "assistant-client-id",
        createdAt: at(5),
      },
      {
        id: "message-a-user",
        sessionId: "source-session",
        role: "user",
        content: "Visible question",
        clientMsgId: "user-client-id",
        createdAt: at(1),
      },
      {
        id: "message-scratch",
        sessionId: "source-session",
        role: "system",
        content: "PRIVATE_SCRATCH",
        createdAt: at(6),
      },
    ],
    runs: [
      {
        id: "run-active",
        sessionId: "source-session",
        promptMessageId: "message-a-user",
        status: "running",
        createdAt: at(7),
        startedAt: at(7),
        finishedAt: null,
      },
      {
        id: "run-complete",
        sessionId: "source-session",
        promptMessageId: "message-a-user",
        status: "completed",
        createdAt: at(1.5),
        startedAt: at(2),
        finishedAt: at(12),
      },
    ],
    events: [
      {
        sessionId: "source-session",
        seq: "12-0",
        type: "run_completed",
        ts: at(12),
        payload: { runId: "run-complete", usage: "PRIVATE_USAGE", author: "PRIVATE_AUTHOR" },
      },
      {
        sessionId: "source-session",
        seq: "10-0",
        type: "artifact_created",
        ts: at(10),
        payload: {
          artifactId: "artifact-live",
          sessionId: "source-session",
          name: "FORGED_NAME",
          sizeBytes: 999_999,
          contentType: "text/html",
          url: "https://signed.invalid/PRIVATE_URL",
          expiresAt: at(100),
        },
      },
      {
        sessionId: "source-session",
        seq: "5-0",
        type: "message_completed",
        ts: at(5),
        payload: {
          messageId: "message-z-assistant",
          runId: "run-complete",
          content: "DUPLICATE_CLIENT_TEXT",
          reasoning: "PRIVATE_REASONING",
        },
      },
      {
        sessionId: "source-session",
        seq: "4-0",
        type: "tool_completed",
        ts: at(4),
        payload: {
          runId: "run-complete",
          callId: "call-1",
          name: "safe_tool",
          isError: false,
          content: "PRIVATE_TOOL_OUTPUT",
        },
      },
      {
        sessionId: "source-session",
        seq: "3-0",
        type: "tool_started",
        ts: at(3),
        payload: {
          runId: "run-complete",
          callId: "call-1",
          name: "safe_tool",
          input: "PRIVATE_TOOL_INPUT",
        },
      },
      {
        sessionId: "source-session",
        seq: "2-0",
        type: "run_started",
        ts: at(2),
        payload: { runId: "run-complete", model: "safe-model", usage: "PRIVATE_USAGE" },
      },
      {
        sessionId: "source-session",
        seq: "13-0",
        type: "subagent_started",
        ts: at(13),
        payload: { runId: "run-active", prompt: "PRIVATE_SUBAGENT" },
      },
    ],
    artifacts: [
      {
        id: "artifact-revoked",
        sessionId: "source-session",
        kind: "artifact",
        status: "deleted",
        r2Key: "users/source/sessions/source-session/artifacts/revoked",
        bytes: 1_000,
        sha256: HASH_B,
        contentType: "text/plain",
        meta: { name: "PRIVATE_REVOKED" },
        createdAt: at(6.5),
      },
      {
        id: "artifact-live",
        sessionId: "source-session",
        kind: "artifact",
        status: "active",
        r2Key: "users/source/sessions/source-session/artifacts/live",
        bytes: 11,
        sha256: HASH_A,
        contentType: "text/plain",
        meta: { name: "safe.txt", private: "PRIVATE_METADATA" },
        createdAt: at(6),
      },
    ],
    attachments: [
      {
        id: "attachment-pending",
        sessionId: "source-session",
        name: "pending.txt",
        uploadStatus: "pending",
        r2Key: "users/source/sessions/source-session/uploads/pending",
        size: 500,
        actualBytes: null,
        contentType: "text/plain",
        actualContentType: null,
        messageId: "message-a-user",
        createdAt: at(1.25),
      },
      {
        id: "attachment-live",
        sessionId: "source-session",
        name: "upload.txt",
        uploadStatus: "ready",
        r2Key: "users/source/sessions/source-session/uploads/live",
        size: 999,
        actualBytes: 7,
        sha256: HASH_B,
        contentType: "application/octet-stream",
        actualContentType: "text/plain",
        contentTypeDeclared: true,
        messageId: "message-a-user",
        createdAt: at(1.25),
        finalizedAt: at(1.5),
      },
    ],
  };
}

function publishedFixture(): DeepForkPublishedRevision {
  return {
    shareId: "share-1",
    revisionId: "revision-1",
    state: "published",
    sessionId: "source-session",
    messageIds: ["message-z-assistant", "message-a-user", "message-a-user"],
    runIds: ["run-complete"],
    eventSeqs: ["12-0", "10-0", "5-0", "4-0", "3-0", "2-0"],
    artifactIds: ["artifact-live"],
    attachmentIds: ["attachment-live"],
  };
}

function inputFixture(): DeepForkPlanInput {
  return {
    jobId: "fork-request-1",
    recipientUserId: "recipient-1",
    published: publishedFixture(),
    source: sourceFixture(),
    quota: { usedBytes: 10, reservedBytes: 5, limitBytes: 1_000 },
    pageSize: 4,
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

function objectCopies(plan: DeepForkPlan): DeepForkObjectCopy[] {
  return operationsOf(plan, "copy_object").map((operation) => operation.object);
}

function expectCode(code: string, fn: () => unknown): void {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(DeepForkPlanError);
    expect((error as DeepForkPlanError).code).toBe(code);
    return;
  }
  throw new Error(`expected ${code}`);
}

describe("deep fork published-source planning", () => {
  it("is deterministic, complete beyond the legacy preview cap, and independent of input order", () => {
    const input = inputFixture();
    input.pageSize = 50;
    input.published.messageIds = [];
    input.published.runIds = [];
    input.published.eventSeqs = [];
    input.published.artifactIds = [];
    input.published.attachmentIds = [];
    input.source.messages = Array.from({ length: 601 }, (_, index) => ({
      id: `message-${String(index).padStart(3, "0")}`,
      sessionId: "source-session",
      role: index % 2 === 0 ? "user" : "assistant",
      content: `Visible message ${index}`,
      createdAt: new Date(Date.UTC(2026, 0, 1) + index * 1_000).toISOString(),
    }));
    input.published.messageIds = input.source.messages.map((message) => message.id).reverse();
    input.source.runs = [];
    input.source.events = [];
    input.source.artifacts = [];
    input.source.attachments = [];

    const first = createDeepForkPlan(input);
    const reordered = createDeepForkPlan({
      ...input,
      source: { ...input.source, messages: [...input.source.messages].reverse() },
    });

    expect(reordered).toEqual(first);
    expect(operationsOf(first, "copy_message")).toHaveLength(601);
    expect(first.totals.messages).toBe(601);
    expect(first.pageCount).toBe(Math.ceil(first.operations.length / 50));

    const seen: string[] = [];
    let checkpoint: DeepForkCheckpoint = first.initialCheckpoint;
    for (let guard = 0; guard < 100; guard += 1) {
      const resumed = resumeDeepForkPlan({ plan: first, checkpoint });
      if (resumed.page === null) {
        expect(resumed.progress.complete).toBe(true);
        expect(resumed.progress.copied).toEqual(first.totals);
        expect(seen).toHaveLength(first.operations.length);
        expect(new Set(seen).size).toBe(seen.length);
        return;
      }
      seen.push(...resumed.page.operations.map((operation) => operation.key));
      checkpoint = resumed.page.checkpointAfterPage;
    }
    throw new Error("planner did not finish every bounded page");
  });

  it("maps every visible link to fresh chronological IDs and terminal historical runs", () => {
    const plan = createDeepForkPlan(inputFixture());
    const messages = operationsOf(plan, "copy_message").map((operation) => operation.message);
    const runs = operationsOf(plan, "copy_run").map((operation) => operation.run);
    const objects = objectCopies(plan);

    expect(messages.map((message) => message.content)).toEqual(["Visible question", "Visible answer"]);
    expect(messages[0]!.id).toBe(plan.idMap.messages["message-a-user"]);
    expect(messages[1]!.id).toBe(plan.idMap.messages["message-z-assistant"]);
    expect(messages[0]!.id < messages[1]!.id).toBe(true);
    expect(messages.every((message) => message.sessionId === plan.targetSessionId)).toBe(true);
    expect(messages.every((message) => message.reasoning === null && message.clientMsgId === null)).toBe(true);

    expect(runs).toHaveLength(1);
    expect(runs[0]!.status).toBe("completed");
    expect(runs[0]!.promptMessageId).toBe(plan.idMap.messages["message-a-user"]);
    expect(runs[0]!.attempts).toBe(0);
    expect(runs[0]!.cancelRequested).toBe(false);
    expect(runs[0]!.lastActiveAt).toBeNull();

    const attachment = objects.find((object) => object.kind === "attachment");
    const artifact = objects.find((object) => object.kind === "artifact");
    expect(attachment?.attachment.messageId).toBe(plan.idMap.messages["message-a-user"]);
    expect(attachment?.attachment.name).toBe("upload.txt");
    expect(artifact?.artifact.id).toBe(plan.idMap.artifacts["artifact-live"]);
    expect(attachment?.attachment.id).toBe(plan.idMap.attachments["attachment-live"]);

    for (const operation of plan.operations) {
      expect(operation.kind).not.toContain("outbox");
      expect(operation.kind).not.toContain("lease");
    }
    expect(operationsOf(plan, "copy_run").every((operation) =>
      ["completed", "failed", "cancelled"].includes(operation.run.status)
    )).toBe(true);
  });

  it("copies only allowlisted public event fields and uses canonical linked data", () => {
    const plan = createDeepForkPlan(inputFixture());
    const events = operationsOf(plan, "copy_event").map((operation) => operation.event);
    const wire = JSON.stringify(events);

    expect(events.map((event) => event.seq)).toEqual(["2-0", "3-0", "4-0", "5-0", "10-0", "12-0"]);
    expect(events.every((event) => event.sessionId === plan.targetSessionId)).toBe(true);
    expect(events[0]!.payload).toEqual({ runId: plan.idMap.runs["run-complete"], model: "safe-model" });
    expect(events[1]!.payload).toEqual({
      runId: plan.idMap.runs["run-complete"],
      callId: "call-1",
      name: "safe_tool",
    });
    expect(events[2]!.payload).toEqual({
      runId: plan.idMap.runs["run-complete"],
      callId: "call-1",
      name: "safe_tool",
      isError: false,
    });
    expect(events[3]!.payload).toEqual({
      messageId: plan.idMap.messages["message-z-assistant"],
      runId: plan.idMap.runs["run-complete"],
      role: "assistant",
      content: "Visible answer",
    });
    expect(events[4]!.payload).toEqual({
      artifactId: plan.idMap.artifacts["artifact-live"],
      sessionId: plan.targetSessionId,
      name: "safe.txt",
      sizeBytes: 11,
      contentType: "text/plain",
    });
    expect(events[5]!.payload).toEqual({ runId: plan.idMap.runs["run-complete"] });
    for (const forbidden of [
      "PRIVATE_",
      "DUPLICATE_",
      "FORGED_",
      "signed.invalid",
      "source-session",
      "run-complete",
      "message-z-assistant",
      "artifact-live",
    ]) {
      expect(wire).not.toContain(forbidden);
    }
  });

  it("fails closed for unpublished, private, revoked, and incomplete exposed sources", () => {
    const revoked = inputFixture();
    revoked.published.state = "revoked";
    expectCode("share_unavailable", () => createDeepForkPlan(revoked));

    const scratch = inputFixture();
    scratch.published.messageIds = [...scratch.published.messageIds, "message-scratch"];
    expectCode("private_source_not_copyable", () => createDeepForkPlan(scratch));

    const deleted = inputFixture();
    deleted.published.artifactIds = [...deleted.published.artifactIds, "artifact-revoked"];
    expectCode("object_not_copyable", () => createDeepForkPlan(deleted));

    const pending = inputFixture();
    pending.published.attachmentIds = [...pending.published.attachmentIds, "attachment-pending"];
    expectCode("object_not_copyable", () => createDeepForkPlan(pending));

    const unknownBytes = inputFixture();
    unknownBytes.source.attachments[1]!.actualBytes = null;
    expectCode("actual_bytes_required", () => createDeepForkPlan(unknownBytes));

    const hiddenEvent = inputFixture();
    hiddenEvent.published.eventSeqs = [...hiddenEvent.published.eventSeqs, "13-0"];
    expectCode("private_source_not_copyable", () => createDeepForkPlan(hiddenEvent));
  });

  it("does not copy unexposed rows or duplicate rows repeated in the publication manifest", () => {
    const plan = createDeepForkPlan(inputFixture());
    expect(operationsOf(plan, "copy_message")).toHaveLength(2);
    expect(operationsOf(plan, "copy_run")).toHaveLength(1);
    expect(operationsOf(plan, "copy_object")).toHaveLength(2);
    expect(JSON.stringify(plan)).not.toContain("PRIVATE_SCRATCH");
    expect(JSON.stringify(plan)).not.toContain("PRIVATE_REVOKED");
  });
});

describe("deep fork recipient quota and independent objects", () => {
  it("prechecks actual bytes once, never declared attachment bytes, and keeps one charge identity", () => {
    const plan = createDeepForkPlan(inputFixture());
    const reserves = operationsOf(plan, "reserve_quota");
    const finalizes = operationsOf(plan, "finalize_quota");

    expect(plan.requiredActualBytes).toBe(18); // artifact 11 + attachment actual 7, not declared 999
    expect(reserves).toHaveLength(1);
    expect(finalizes).toHaveLength(1);
    expect(reserves[0]!.charge).toEqual(finalizes[0]!.charge);
    expect(reserves[0]!.charge.actualBytes).toBe(18);
    expect(reserves[0]!.charge.ownerUserId).toBe("recipient-1");
    expect(reserves[0]!.charge.actorUserId).toBe("recipient-1");
    expect(reserves[0]!.charge.reservationId).toBe(plan.quotaReservationId);

    const exact = inputFixture();
    exact.quota.limitBytes = 33; // used 10 + reserved 5 + actual 18
    expect(() => createDeepForkPlan(exact)).not.toThrow();
    exact.quota.limitBytes = 32;
    expectCode("storage_quota_exceeded", () => createDeepForkPlan(exact));
  });

  it("plans physical copies with new recipient-owned object identities, not source aliases", () => {
    const input = inputFixture();
    const plan = createDeepForkPlan(input);
    const copies = objectCopies(plan);

    expect(copies).toHaveLength(2);
    for (const copy of copies) {
      expect(copy.targetObjectId).toMatch(/^[0-9a-f-]{36}$/);
      expect(copy.targetKey).toContain("users/recipient-1/");
      expect(copy.targetKey).toContain(plan.targetSessionId);
      expect(copy.targetKey).toContain(copy.targetObjectId);
      expect(copy.targetKey).not.toBe(copy.sourceKey);
      expect(copy.actualBytes).toBe(copy.kind === "artifact" ? copy.artifact.bytes : copy.attachment.actualBytes);
    }

    const targetKeys = copies.map((copy) => copy.targetKey);
    input.source.session.title = "source mutated after planning";
    input.source.artifacts[1]!.r2Key = "deleted-source-key";
    expect(copies.map((copy) => copy.targetKey)).toEqual(targetKeys);
    expect(operationsOf(plan, "create_session")[0]!.session.title).toBe("Published chat");

    const replay = createDeepForkPlan(inputFixture());
    expect(replay.idMap).toEqual(plan.idMap);
    expect(replay.quotaReservationId).toBe(plan.quotaReservationId);
  });
});

describe("deep fork checkpoints and crash replay", () => {
  it("resumes after a committed page without emitting duplicate operations", () => {
    const plan = createDeepForkPlan(inputFixture());
    const first = resumeDeepForkPlan({ plan });
    expect(first.page).not.toBeNull();
    const page = first.page!;

    const fromCheckpoint = resumeDeepForkPlan({
      plan,
      checkpoint: page.checkpointAfterPage,
    });
    expect(fromCheckpoint.page?.index).toBe(1);
    expect(fromCheckpoint.page?.operations.map((operation) => operation.key)).not.toContain(
      page.operations[0]!.key,
    );

    // Crash after the page commit but before its checkpoint was persisted.
    const fromReceipts = resumeDeepForkPlan({
      plan,
      checkpoint: plan.initialCheckpoint,
      appliedOperationKeys: page.operationKeys,
    });
    expect(fromReceipts.checkpoint).toEqual(page.checkpointAfterPage);
    expect(fromReceipts.page?.index).toBe(1);
    const replayedKeys = fromReceipts.page?.operations.map((operation) => operation.key) ?? [];
    expect(replayedKeys.filter((key) => page.operationKeys.includes(key))).toEqual([]);
  });

  it("resumes after an object copy with the same IDs and no duplicate object or charge", () => {
    const plan = createDeepForkPlan(inputFixture());
    const objectOperation = operationsOf(plan, "copy_object")[0]!;
    let checkpoint = plan.initialCheckpoint;

    for (;;) {
      const current = resumeDeepForkPlan({ plan, checkpoint });
      const page = current.page;
      expect(page).not.toBeNull();
      if (page!.operationKeys.includes(objectOperation.key)) {
        const partial = resumeDeepForkPlan({
          plan,
          checkpoint,
          appliedOperationKeys: [objectOperation.key],
        });
        expect(partial.checkpoint).toEqual(checkpoint);
        expect(partial.page?.index).toBe(page!.index);
        expect(partial.page?.operations.map((operation) => operation.key)).not.toContain(objectOperation.key);
        expect(partial.page?.operations).toHaveLength(page!.operationKeys.length - 1);
        expect(resumeDeepForkPlan({
          plan,
          checkpoint,
          appliedOperationKeys: [objectOperation.key],
        })).toEqual(partial);

        const committed = resumeDeepForkPlan({
          plan,
          checkpoint,
          appliedOperationKeys: page!.operationKeys,
        });
        expect(committed.checkpoint).toEqual(page!.checkpointAfterPage);
        expect(committed.page?.operations.map((operation) => operation.key) ?? []).not.toContain(objectOperation.key);
        break;
      }
      checkpoint = page!.checkpointAfterPage;
    }

    const allKeys = plan.operations.map((operation) => operation.key);
    const complete = resumeDeepForkPlan({ plan, appliedOperationKeys: allKeys });
    expect(complete.page).toBeNull();
    expect(complete.progress.complete).toBe(true);
    expect(complete.progress.chargedActualBytes).toBe(18);
    expect(complete.progress.copied.objects).toBe(2);
    expect(resumeDeepForkPlan({ plan, checkpoint: complete.checkpoint, appliedOperationKeys: allKeys }))
      .toEqual(complete);
    expect(operationsOf(plan, "reserve_quota")).toHaveLength(1);
    expect(operationsOf(plan, "finalize_quota")).toHaveLength(1);
  });

  it("reports copied counts from checkpoints/receipts, never from merely planned work", () => {
    const plan = createDeepForkPlan(inputFixture());
    const initial = resumeDeepForkPlan({ plan });
    expect(initial.progress.copied.messages).toBe(0);
    expect(initial.progress.copied.objects).toBe(0);
    expect(initial.progress.chargedActualBytes).toBe(0);

    const message = operationsOf(plan, "copy_message")[0]!;
    const messageIndex = plan.operations.findIndex((operation) => operation.key === message.key);
    const priorKeys = plan.operations.slice(0, messageIndex + 1).map((operation) => operation.key);
    const partial = resumeDeepForkPlan({ plan, appliedOperationKeys: priorKeys });
    expect(partial.progress.copied.sessions).toBe(1);
    expect(partial.progress.copied.messages).toBe(1);
    expect(partial.progress.copied.objects).toBe(0);
    expect(partial.progress.chargedActualBytes).toBe(0);
  });

  it("rejects foreign, malformed, and mid-page checkpoints", () => {
    const plan = createDeepForkPlan(inputFixture());
    expectCode("checkpoint_mismatch", () => resumeDeepForkPlan({
      plan,
      checkpoint: { ...plan.initialCheckpoint, planFingerprint: "f".repeat(64) },
    }));
    expectCode("invalid_checkpoint", () => resumeDeepForkPlan({
      plan,
      checkpoint: { ...plan.initialCheckpoint, nextOperation: 1 },
    }));
    expectCode("invalid_checkpoint", () => resumeDeepForkPlan({
      plan,
      checkpoint: { ...plan.initialCheckpoint, nextOperation: plan.operations.length + 1 },
    }));
  });
});

describe("deep fork fix round 1 regressions", () => {
  it("copies visible active-source history without a recipient active run or fabricated terminal row", () => {
    const input = inputFixture();
    input.source.runs = [
      ...input.source.runs,
      {
        id: "run-queued",
        sessionId: "source-session",
        promptMessageId: "message-a-user",
        status: "queued",
        createdAt: at(7.5),
        startedAt: null,
        finishedAt: null,
      },
    ];
    input.source.artifacts = [
      ...input.source.artifacts,
      {
        id: "artifact-active",
        sessionId: "source-session",
        kind: "artifact",
        status: "active",
        r2Key: "users/source/sessions/source-session/artifacts/active",
        bytes: 5,
        sha256: "c".repeat(64),
        contentType: "text/plain",
        meta: { name: "active.txt" },
        createdAt: at(11),
      },
    ];
    input.source.events = [
      ...input.source.events,
      {
        sessionId: "source-session",
        seq: "7-0",
        type: "run_started",
        ts: at(7),
        payload: { runId: "run-active", model: "active-model" },
      },
      {
        sessionId: "source-session",
        seq: "8-0",
        type: "message_segment",
        ts: at(8),
        payload: { runId: "run-active", content: "Visible active answer so far" },
      },
      {
        sessionId: "source-session",
        seq: "9-0",
        type: "tool_started",
        ts: at(9),
        payload: {
          runId: "run-active",
          callId: "active-call",
          name: "safe_tool",
          input: "PRIVATE_ACTIVE_TOOL_INPUT",
        },
      },
      {
        sessionId: "source-session",
        seq: "11-0",
        type: "artifact_created",
        ts: at(11),
        payload: {
          runId: "run-active",
          artifactId: "artifact-active",
          sessionId: "source-session",
          name: "FORGED_ACTIVE_NAME",
          sizeBytes: 999_999,
          contentType: "text/html",
          url: "https://signed.invalid/PRIVATE_ACTIVE_URL",
          expiresAt: at(100),
        },
      },
    ];
    input.published.runIds = ["run-complete", "run-active", "run-queued"];
    input.published.artifactIds = ["artifact-live", "artifact-active"];
    input.published.eventSeqs = [
      ...input.published.eventSeqs,
      "7-0",
      "8-0",
      "9-0",
      "11-0",
    ];

    const plan = createDeepForkPlan(input);
    const runs = operationsOf(plan, "copy_run").map((operation) => operation.run);
    const events = operationsOf(plan, "copy_event").map((operation) => operation.event);
    const bySeq = new Map(events.map((event) => [event.seq, event]));

    expect(runs.map((run) => run.id)).toEqual([plan.idMap.runs["run-complete"]]);
    expect(runs.map((run) => run.status)).toEqual(["completed"]);
    expect(plan.idMap.runs["run-active"]).toBeUndefined();
    expect(plan.idMap.runs["run-queued"]).toBeUndefined();
    expect(plan.totals.runs).toBe(1);
    expect(operationsOf(plan, "copy_message")).toHaveLength(2);
    expect(operationsOf(plan, "copy_object")).toHaveLength(3);
    expect(bySeq.get("7-0")?.payload).toEqual({ model: "active-model" });
    expect(bySeq.get("8-0")?.payload).toEqual({ content: "Visible active answer so far" });
    expect(bySeq.get("9-0")?.payload).toEqual({ callId: "active-call", name: "safe_tool" });
    expect(bySeq.get("11-0")?.payload).toEqual({
      artifactId: plan.idMap.artifacts["artifact-active"],
      sessionId: plan.targetSessionId,
      name: "active.txt",
      sizeBytes: 5,
      contentType: "text/plain",
    });
    for (const seq of ["7-0", "8-0", "9-0", "11-0"]) {
      expect(bySeq.get(seq)?.payload.runId).toBeUndefined();
    }
    expect(plan.operations.some((operation) => /lease|outbox|enqueue/.test(operation.kind))).toBe(false);
    expect(JSON.stringify(plan)).not.toContain("PRIVATE_ACTIVE_");
  });

  it("accepts canonical failed/cancelled events with or without runId and preserves cancellation", () => {
    const input = inputFixture();
    input.source.runs = [
      {
        id: "run-failed",
        sessionId: "source-session",
        promptMessageId: "message-a-user",
        status: "failed",
        createdAt: at(20),
        startedAt: at(20),
        finishedAt: at(21),
      },
      {
        id: "run-cancelled",
        sessionId: "source-session",
        promptMessageId: "message-a-user",
        status: "cancelled",
        createdAt: at(22),
        startedAt: null,
        finishedAt: at(23),
      },
    ];
    input.source.events = [
      {
        sessionId: "source-session",
        seq: "20-0",
        type: "run_failed",
        ts: at(20),
        payload: { code: "model_terminal", message: "SAFE_FAILURE", detail: "PRIVATE_DETAIL" },
      },
      {
        sessionId: "source-session",
        seq: "21-0",
        type: "run_failed",
        ts: at(21),
        payload: {
          runId: "run-failed",
          code: "attachment_unavailable",
          message: "SAFE_ATTACHMENT_FAILURE",
        },
      },
      {
        sessionId: "source-session",
        seq: "22-0",
        type: "run_failed",
        ts: at(22),
        payload: { code: "cancelled", message: "Stopped by user." },
      },
      {
        sessionId: "source-session",
        seq: "23-0",
        type: "run_failed",
        ts: at(23),
        payload: { runId: "run-cancelled", code: "cancelled", message: "Stopped by user." },
      },
      {
        sessionId: "source-session",
        seq: "24-0",
        type: "run_cancelled",
        ts: at(24),
        payload: { runId: "run-cancelled", reason: "user_requested" },
      },
      {
        sessionId: "source-session",
        seq: "25-0",
        type: "run_cancelled",
        ts: at(25),
        payload: { code: "cancelled", message: "Stopped by user." },
      },
    ];
    input.published.runIds = ["run-failed", "run-cancelled"];
    input.published.eventSeqs = ["25-0", "23-0", "21-0", "20-0", "24-0", "22-0"];

    const plan = createDeepForkPlan(input);
    const events = operationsOf(plan, "copy_event").map((operation) => operation.event);
    const bySeq = new Map(events.map((event) => [event.seq, event]));
    const failedId = plan.idMap.runs["run-failed"];
    const cancelledId = plan.idMap.runs["run-cancelled"];

    expect(operationsOf(plan, "copy_run").map((operation) => operation.run.status))
      .toEqual(["failed", "cancelled"]);
    expect(bySeq.get("20-0")).toMatchObject({
      type: "run_failed",
      payload: { code: "model_terminal" },
    });
    expect(bySeq.get("20-0")?.payload.runId).toBeUndefined();
    expect(bySeq.get("21-0")?.payload).toEqual({
      runId: failedId,
      code: "attachment_unavailable",
    });
    expect(bySeq.get("22-0")?.payload).toEqual({ code: "cancelled" });
    expect(bySeq.get("23-0")?.payload).toEqual({
      runId: cancelledId,
      code: "cancelled",
    });
    expect(bySeq.get("24-0")?.payload).toEqual({ runId: cancelledId });
    expect(bySeq.get("25-0")?.payload).toEqual({ code: "cancelled" });

    const presentation = (seq: string): string => {
      const event = bySeq.get(seq)!;
      if (event.type === "run_cancelled" || event.payload.code === "cancelled") return "cancelled";
      return event.type === "run_failed" ? "failed" : "other";
    };
    expect(["22-0", "23-0", "24-0", "25-0"].map(presentation))
      .toEqual(["cancelled", "cancelled", "cancelled", "cancelled"]);
    expect(presentation("20-0")).toBe("failed");
    expect(JSON.stringify(events)).not.toContain("PRIVATE_DETAIL");
  });

  it("preserves canonical UUIDv7 message keyset order across imported timestamp inversions and ties", () => {
    const input = inputFixture();
    const firstId = "00000000-0000-7000-8000-000000000010";
    const secondId = "00000000-0000-7000-8000-000000000020";
    const thirdId = "00000000-0000-7000-8000-000000000030";
    input.source.messages = [
      {
        id: thirdId,
        sessionId: "source-session",
        role: "assistant",
        content: "third by source ID",
        createdAt: "2000-01-01T00:00:00.000Z",
      },
      {
        id: secondId,
        sessionId: "source-session",
        role: "user",
        content: "second by source ID",
        createdAt: "2000-01-01T00:00:00.000Z",
      },
      {
        id: firstId,
        sessionId: "source-session",
        role: "user",
        content: "first by source ID despite newer imported timestamp",
        createdAt: "2030-01-01T00:00:00.000Z",
      },
    ];
    input.source.runs = [{
      id: "run-imported",
      sessionId: "source-session",
      promptMessageId: secondId,
      status: "completed",
      createdAt: at(2),
      startedAt: at(2),
      finishedAt: at(3),
    }];
    input.source.attachments[1]!.messageId = secondId;
    input.source.events = [];
    input.published.messageIds = [thirdId, firstId, secondId];
    input.published.runIds = ["run-imported"];
    input.published.eventSeqs = [];

    const plan = createDeepForkPlan(input);
    const messages = operationsOf(plan, "copy_message").map((operation) => operation.message);
    const targetIds = messages.map((message) => message.id);

    expect(messages.map((message) => message.content)).toEqual([
      "first by source ID despite newer imported timestamp",
      "second by source ID",
      "third by source ID",
    ]);
    expect(messages.map((message) => message.createdAt)).toEqual([
      "2030-01-01T00:00:00.000Z",
      "2000-01-01T00:00:00.000Z",
      "2000-01-01T00:00:00.000Z",
    ]);
    expect([...targetIds].sort()).toEqual(targetIds);
    expect(new Set(targetIds).size).toBe(3);
    expect(plan.idMap.messages[firstId]).toBe(targetIds[0]);
    expect(plan.idMap.messages[secondId]).toBe(targetIds[1]);
    expect(plan.idMap.messages[thirdId]).toBe(targetIds[2]);
    expect(operationsOf(plan, "copy_run")[0]!.run.promptMessageId).toBe(targetIds[1]);
    expect(objectCopies(plan).find((object) => object.kind === "attachment")?.attachment.messageId)
      .toBe(targetIds[1]);
  });
});
