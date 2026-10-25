import { describe, expect, it } from "vitest";

import {
  CollabTurnError,
  acceptedCollabExecutionSnapshot,
  collabRunAdmissionInput,
  collabTurnJob,
  collabTurnReplay,
  collabTurnResult,
  normalizeCollabTurnRequest,
  planCollabDescendantLease,
  planCollabPublication,
  resolveCollabModel,
  storedCollabBodyPayload,
  type CollabCurrentAuthority,
  type CollabTurnRecord,
  type CollabTurnRequest,
} from "./turnPlan.js";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. Pure contract tests only: no claim
// of TypeScript, Postgres, queue, worker, restart, or two-process verification.

const ROOM = "10000000-0000-7000-8000-000000000001";
const SESSION = "20000000-0000-7000-8000-000000000001";
const ATTACHMENT = "30000000-0000-7000-8000-000000000001";
const TURN = "40000000-0000-7000-8000-000000000001";
const MESSAGE = "40000000-0000-7000-8000-000000000002";
const RUN = "40000000-0000-7000-8000-000000000003";
const OUTBOX = "40000000-0000-7000-8000-000000000004";
const LEASE = "40000000-0000-7000-8000-000000000005";
const PARTICIPANT = `p${"0".repeat(31)}1`;
const T0 = new Date("2026-10-25T00:00:00.000Z");

function request(): CollabTurnRequest {
  return {
    schemaVersion: 1,
    idempotencyKey: "sender-turn-key",
    text: "hello collaborators",
    model: "provider/model",
    attachmentIds: [ATTACHMENT],
  };
}

function authorization() {
  return {
    roomId: ROOM,
    sessionId: SESSION,
    ownerUserId: "host-user",
    participantId: PARTICIPANT,
    role: "participant" as const,
    roomGeneration: 4,
    membershipGeneration: 4,
  };
}

function record(): CollabTurnRecord {
  const req = request();
  return {
    message: {
      id: MESSAGE,
      sessionId: SESSION,
      role: "user",
      content: req.text,
      reasoning: null,
      clientMsgId: null,
      searchVector: "",
      createdAt: T0,
    },
    run: {
      id: RUN,
      sessionId: SESSION,
      status: "queued",
      promptMessageId: MESSAGE,
      attempts: 0,
      lastError: null,
      cancelRequested: false,
      lastActiveAt: null,
      startedAt: null,
      finishedAt: null,
      createdAt: T0,
    },
    turn: {
      id: TURN,
      roomId: ROOM,
      participantId: PARTICIPANT,
      actorUserId: "sender-user",
      runId: RUN,
      userMessageId: MESSAGE,
      idempotencyKey: req.idempotencyKey,
      model: "provider/model",
      status: "queued",
      cancelRequestedAt: null,
      createdAt: T0,
      updatedAt: T0,
    },
    lease: {
      id: LEASE,
      roomId: ROOM,
      holderParticipantId: PARTICIPANT,
      holderUserId: "sender-user",
      runId: RUN,
      generation: 9,
      roomGeneration: 4,
      membershipGeneration: 4,
      startedAt: T0,
      heartbeatAt: T0,
      releasedAt: null,
      cancelRequestedAt: null,
    },
    outbox: {
      outboxId: OUTBOX,
      actorUserId: "sender-user",
      sessionId: SESSION,
      runId: RUN,
      userMessageId: MESSAGE,
      idempotencyKey: req.idempotencyKey,
      status: "queued",
      requestPayload: { ...req, attachmentIds: [...req.attachmentIds!] },
      bodyPayload: {
        ownerUserId: "host-user",
        requestedModel: "provider/model",
        userId: "sender-user",
        sessionId: SESSION,
        runId: RUN,
        modelContext: {
          requestedModel: "provider/model",
          byokKeyId: null,
          temperature: null,
          actorUserId: "sender-user",
        },
        byokKeyId: null,
        tier: "free",
        queuePriority: 1,
        collab: {
          roomId: ROOM,
          participantId: PARTICIPANT,
          membershipGeneration: 4,
          leaseId: LEASE,
          leaseGeneration: 9,
          outboxId: OUTBOX,
          rootRunId: RUN,
        },
      },
      jobId: RUN,
      attempts: 0,
      publishedAt: null,
      lastAttemptAt: null,
      settledAt: null,
      lastError: null,
      createdAt: T0,
      updatedAt: T0,
    },
  };
}

function current(): CollabCurrentAuthority {
  return {
    room: {
      id: ROOM,
      tokenHash: "0".repeat(64),
      sessionId: SESSION,
      ownerUserId: "host-user",
      requestId: "create-room",
      lifecycle: "active",
      generation: 4,
      closeRequestId: null,
      createdAt: T0,
      updatedAt: T0,
    },
    member: {
      roomId: ROOM,
      userId: "sender-user",
      participantId: PARTICIPANT,
      role: "participant",
      status: "active",
      displayName: "sender",
      generation: 4,
      joinRequestId: "join-room",
      joinInviteHash: null,
      joinedAt: T0,
      updatedAt: T0,
      revokedAt: null,
    },
    hostSession: {
      id: SESSION,
      userId: "host-user",
      title: "host session",
      mode: "auto",
      projectId: null,
      createdAt: T0,
      updatedAt: T0,
      archivedAt: null,
      pinnedAt: null,
      deletedAt: null,
    },
    latestLeaseGeneration: 9,
    senderActive: true,
    now: T0,
    staleAfterMs: 45_000,
  };
}

function thrown(fn: () => unknown): unknown {
  try {
    fn();
  } catch (error) {
    return error;
  }
  throw new Error("expected function to throw");
}

describe("Collab canonical turn contracts (UNEXECUTED)", () => {
  it("uses the exact current RunAdmissionInput and stored body shapes with opaque participant identity", () => {
    const original = record();
    const input = collabRunAdmissionInput({
      actorUserId: "sender-user",
      authorization: authorization(),
      request: request(),
      lease: original.lease,
    });

    expect(input).toEqual({
      actorUserId: "sender-user",
      sessionId: SESSION,
      idempotencyKey: "sender-turn-key",
      content: "hello collaborators",
      requestPayload: request(),
      bodyPayload: { ownerUserId: "host-user", requestedModel: "provider/model" },
      authorization: {
        ownerUserId: "host-user",
        collab: {
          roomId: ROOM,
          participantId: PARTICIPANT,
          membershipGeneration: 4,
          leaseId: LEASE,
          leaseGeneration: 9,
        },
      },
    });
    expect(storedCollabBodyPayload(input, OUTBOX, RUN, {
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: null,
        temperature: null,
        actorUserId: "sender-user",
      },
      byokKeyId: null,
      tier: "free",
      queuePriority: 1,
    })).toEqual(original.outbox.bodyPayload);
    expect(input.authorization.collab?.participantId).toMatch(/^p[0-9a-f]{32}$/);
  });

  it("accepts the current outbox's omitted-or-null requestedModel representation for Auto", () => {
    const omitted = record();
    omitted.turn.model = null;
    delete omitted.outbox.requestPayload.model;
    delete omitted.outbox.bodyPayload.requestedModel;
    omitted.outbox.bodyPayload.modelContext = {
      ...omitted.outbox.bodyPayload.modelContext as object,
      requestedModel: null,
    };
    expect(collabTurnResult(omitted).model).toBe("auto");
    expect(collabTurnJob(omitted)).not.toHaveProperty("requestedModel");

    const explicitNull = record();
    explicitNull.turn.model = null;
    delete explicitNull.outbox.requestPayload.model;
    explicitNull.outbox.bodyPayload.requestedModel = null;
    explicitNull.outbox.bodyPayload.modelContext = {
      ...explicitNull.outbox.bodyPayload.modelContext as object,
      requestedModel: null,
    };
    expect(collabTurnResult(explicitNull).model).toBe("auto");
  });

  it("strictly rejects forged fields, overlong keys, malformed models and attachments", () => {
    const invalid = [
      { ...request(), role: "assistant" },
      { ...request(), idempotencyKey: "x".repeat(65) },
      { ...request(), model: "byok-secret" },
      { ...request(), attachmentIds: ["not-a-uuid"] },
      { ...request(), text: "   " },
    ];
    for (const candidate of invalid) {
      expect(thrown(() => normalizeCollabTurnRequest(candidate))).toMatchObject({ code: "invalid_request" });
    }
  });

  it("resolves eligibility from the declared post-lock sender facts", () => {
    expect(resolveCollabModel({
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
      sender: {
        tier: "free",
        byokDefault: { keyId: "sender-key", model: "provider-key-model", available: true },
      },
    })).toMatchObject({ ok: false, code: "manual_model_not_allowed" });

    expect(resolveCollabModel({
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
      sender: {
        tier: "plus",
        byokDefault: { keyId: "sender-key", model: "provider-key-model", available: true },
      },
    })).toEqual({
      ok: true,
      requestedModel: "provider/model",
      bodyRequestedModel: "provider/model",
      resultModel: "provider/model",
      billingClass: "byok",
    });
  });

  it("captures the accepted secret-free BYOK snapshot, sender priority and host workspace tier", () => {
    const sender = {
      tier: "plus",
      byokDefault: { keyId: "sender-key", model: "provider-key-model", available: true },
    };
    const resolution = resolveCollabModel({
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
      sender,
    });
    if (!resolution.ok) throw new Error("expected accepted model");
    expect(acceptedCollabExecutionSnapshot({
      actorUserId: "sender-user",
      resolution,
      sender,
      hostWorkspaceTier: "free",
    })).toEqual({
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: "sender-key",
        byokModel: "provider-key-model",
        temperature: null,
        actorUserId: "sender-user",
      },
      byokKeyId: "sender-key",
      byokModel: "provider-key-model",
      tier: "free",
      queuePriority: 1,
    });

    const auto = { schemaVersion: 1 as const, idempotencyKey: "free-auto", text: "auto" };
    const autoResolution = resolveCollabModel({
      request: auto,
      catalog: { state: "unavailable" },
      sender: { tier: "free", byokDefault: null },
    });
    if (!autoResolution.ok) throw new Error("expected accepted Auto");
    expect(acceptedCollabExecutionSnapshot({
      actorUserId: "sender-user",
      resolution: autoResolution,
      sender: { tier: "free", byokDefault: null },
      hostWorkspaceTier: "pro",
    })).toMatchObject({ tier: "pro", queuePriority: 2, byokKeyId: null });
  });

  it("refuses unknown models and catalog outages before canonical writes", () => {
    for (const catalog of [
      { state: "known", modelIds: ["another/model"] },
      { state: "known", modelIds: [] },
      { state: "unavailable" },
    ] as const) {
      const resolved = resolveCollabModel({
        request: request(),
        catalog,
        sender: { tier: "plus", byokDefault: null },
      });
      expect(resolved.ok).toBe(false);
      if (!resolved.ok) {
        expect(["model_unavailable", "temporarily_unavailable"]).toContain(resolved.code);
      }
    }
  });

  it("fails closed when the post-lock selected sender BYOK key is unavailable", () => {
    const resolved = resolveCollabModel({
      request: request(),
      catalog: { state: "known", modelIds: ["provider/model"] },
      sender: {
        tier: "plus",
        byokDefault: { keyId: "removed-key", model: "provider-key-model", available: false },
      },
    });
    expect(resolved).toMatchObject({ ok: false, code: "key_not_minted" });
  });

  it("allows Auto without manual catalog evidence even on an auto-only sender plan", () => {
    const auto = { schemaVersion: 1 as const, idempotencyKey: "auto-key", text: "auto" };
    expect(resolveCollabModel({
      request: auto,
      catalog: { state: "unavailable" },
      sender: { tier: "free", byokDefault: null },
    })).toEqual({
      ok: true,
      requestedModel: null,
      bodyRequestedModel: null,
      resultModel: "auto",
      billingClass: "ovid_allowance",
    });
  });

  it("derives CollabTurnResult with canonical userEventId and no invented response fields", () => {
    expect(collabTurnResult(record())).toEqual({
      schemaVersion: 1,
      turnId: TURN,
      runId: RUN,
      userMessageId: MESSAGE,
      userEventId: `message:${MESSAGE}`,
      status: "queued",
      model: "provider/model",
    });
  });

  it("maps an active replay to queued and preserves terminal result states", () => {
    const running = record();
    running.run.status = "running";
    running.turn.status = "running";
    expect(collabTurnResult(running).status).toBe("queued");

    for (const [turnStatus, runStatus] of [
      ["completed", "completed"],
      ["failed", "failed"],
      ["cancelled", "cancelled"],
      ["interrupted", "cancelled"],
    ] as const) {
      const terminal = record();
      terminal.turn.status = turnStatus;
      terminal.run.status = runStatus;
      terminal.outbox.status = "settled";
      expect(collabTurnResult(terminal).status).toBe(turnStatus);
    }
  });

  it("derives only durable job fields with explicit host owner and sender actor", () => {
    const job = collabTurnJob(record());
    expect(job).toEqual({
      runId: RUN,
      sessionId: SESSION,
      userId: "host-user",
      ownerUserId: "host-user",
      actorUserId: "sender-user",
      source: "collab",
      prompt: "hello collaborators",
      requestedModel: "provider/model",
      tier: "free",
      byokKeyId: null,
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: null,
        temperature: null,
        actorUserId: "sender-user",
      },
      attachmentIds: [ATTACHMENT],
      collab: {
        roomId: ROOM,
        participantId: PARTICIPANT,
        membershipGeneration: 4,
        leaseId: LEASE,
        leaseGeneration: 9,
        outboxId: OUTBOX,
        rootRunId: RUN,
      },
    });
    expect(job).not.toHaveProperty("collabPublication");
  });

  it("reconstructs the accepted BYOK snapshot instead of a changed sender default", () => {
    const original = record();
    original.outbox.bodyPayload = {
      ...original.outbox.bodyPayload,
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: "accepted-key-id",
        byokModel: "accepted-provider-model",
        temperature: null,
        actorUserId: "sender-user",
      },
      byokKeyId: "accepted-key-id",
      byokModel: "accepted-provider-model",
      tier: "pro",
      queuePriority: 2,
    };

    expect(collabTurnJob(original)).toMatchObject({
      userId: "host-user",
      ownerUserId: "host-user",
      actorUserId: "sender-user",
      requestedModel: "provider/model",
      tier: "pro",
      byokKeyId: "accepted-key-id",
      byokModel: "accepted-provider-model",
      modelContext: {
        byokKeyId: "accepted-key-id",
        byokModel: "accepted-provider-model",
        actorUserId: "sender-user",
      },
    });
  });

  it("same-key replay derives originals from durable rows, not a cached response", () => {
    const original = record();
    original.turn.status = "completed";
    original.run.status = "completed";
    original.outbox.status = "settled";
    original.lease.releasedAt = new Date(T0.getTime() + 1_000);

    expect(collabTurnReplay({
      record: original,
      request: request(),
      actorUserId: "sender-user",
      authorization: authorization(),
    })).toEqual({
      schemaVersion: 1,
      turnId: TURN,
      runId: RUN,
      userMessageId: MESSAGE,
      userEventId: `message:${MESSAGE}`,
      status: "completed",
      model: "provider/model",
    });
  });

  it("changed payload or cross-sender room-key replay is request_already_used", () => {
    for (const changed of [
      { ...request(), text: "changed" },
      { ...request(), model: "provider/other" },
      { ...request(), attachmentIds: [] },
    ]) {
      expect(thrown(() => collabTurnReplay({
        record: record(), request: changed, actorUserId: "sender-user", authorization: authorization(),
      }))).toMatchObject({ code: "request_already_used" });
    }
    expect(thrown(() => collabTurnReplay({
      record: record(), request: request(), actorUserId: "other-sender", authorization: authorization(),
    }))).toMatchObject({ code: "request_already_used" });
  });

  it("rejects every broken canonical room/run/message/outbox/lease/body linkage", () => {
    const mutations: Array<(value: CollabTurnRecord) => void> = [
      (value) => { value.turn.runId = TURN; },
      (value) => { value.turn.userMessageId = TURN; },
      (value) => { value.run.sessionId = TURN; },
      (value) => { value.run.promptMessageId = TURN; },
      (value) => { value.message.role = "assistant"; },
      (value) => { value.message.content = "changed"; },
      (value) => { value.outbox.runId = TURN; },
      (value) => { value.outbox.userMessageId = TURN; },
      (value) => { value.outbox.jobId = TURN; },
      (value) => { value.lease.runId = TURN; },
      (value) => { value.lease.holderParticipantId = "other-participant"; },
      (value) => { value.turn.model = "provider/other"; },
      (value) => { value.outbox.requestPayload = { ...request(), model: "provider/other" }; },
      (value) => { value.outbox.bodyPayload = { ...value.outbox.bodyPayload, requestedModel: "provider/other" }; },
      (value) => {
        value.outbox.bodyPayload = {
          ...value.outbox.bodyPayload,
          collab: { ...(value.outbox.bodyPayload.collab as object), rootRunId: TURN },
        };
      },
      (value) => {
        value.outbox.bodyPayload = {
          ...value.outbox.bodyPayload,
          collab: { ...(value.outbox.bodyPayload.collab as object), outboxId: TURN },
        };
      },
      (value) => {
        value.outbox.bodyPayload = {
          ...value.outbox.bodyPayload,
          collab: { ...(value.outbox.bodyPayload.collab as object), leaseGeneration: 8 },
        };
      },
      (value) => { value.outbox.bodyPayload = { ...value.outbox.bodyPayload, modelContext: {} }; },
    ];
    for (const mutate of mutations) {
      const candidate = record();
      mutate(candidate);
      expect(thrown(() => collabTurnResult(candidate))).toMatchObject({ code: "invalid_record" });
    }
  });

  it("fresh committed work publishes only after commit with jobId=runId", () => {
    const decision = planCollabPublication({ record: record(), current: current() });
    expect(decision).toMatchObject({
      kind: "publish",
      outboxId: OUTBOX,
      options: { jobId: RUN, priority: 1 },
      expectation: {
        fromStatus: "queued",
        fromAttempts: 0,
        outboxStatus: "published",
        outboxAttempts: 1,
        runStatus: "queued",
        turnStatus: "queued",
        leaseGeneration: 9,
      },
      job: {
        collabPublication: {
          outboxStatus: "published",
          outboxAttempts: 1,
          leaseGeneration: 9,
        },
      },
    });
  });

  it("queue failure and restart recovery derive the identical durable job", () => {
    const failed = record();
    failed.outbox.status = "failed";
    failed.outbox.lastError = "queue_unavailable";
    failed.outbox.attempts = 1;
    const first = planCollabPublication({ record: failed, current: current() });
    const second = planCollabPublication({ record: failed, current: current() });
    expect(first).toEqual(second);
    expect(first).toMatchObject({ kind: "publish", options: { jobId: RUN } });
    if (first.kind === "publish") {
      expect(first.job).toEqual(collabTurnJob(record(), first.job.collabPublication));
      expect(first.expectation).toMatchObject({
        fromStatus: "failed",
        fromAttempts: 1,
        outboxAttempts: 2,
      });
    }
  });

  it("published and settled outboxes never republish", () => {
    const published = record();
    published.outbox.status = "published";
    published.outbox.publishedAt = T0;
    expect(planCollabPublication({ record: published, current: current() })).toMatchObject({ kind: "noop" });

    const settled = record();
    settled.outbox.status = "settled";
    settled.lease.releasedAt = T0;
    settled.turn.status = "completed";
    settled.run.status = "completed";
    expect(planCollabPublication({ record: settled, current: current() })).toMatchObject({ kind: "noop" });
  });

  it("ambiguous pre-add publication recovery advances the attempt and preserves the durable snapshot", () => {
    const ambiguous = record();
    ambiguous.outbox.status = "published";
    ambiguous.outbox.attempts = 1;
    ambiguous.outbox.publishedAt = null;
    const decision = planCollabPublication({ record: ambiguous, current: current() });
    expect(decision).toMatchObject({
      kind: "publish",
      expectation: {
        fromStatus: "published",
        fromAttempts: 1,
        fromPublishedAt: null,
        outboxStatus: "published",
        outboxAttempts: 2,
      },
      options: { jobId: RUN, priority: 1 },
    });
  });

  it("a fresh running retryable outbox reconciles the publication marker without another queue add", () => {
    const running = record();
    running.run.status = "running";
    running.turn.status = "running";
    running.run.startedAt = T0;
    expect(planCollabPublication({ record: running, current: current() })).toEqual({
      kind: "mark_published",
      outboxId: OUTBOX,
    });
  });

  it("terminal or cancelled retryable state is fenced rather than resurrected", () => {
    for (const [turnStatus, runStatus] of [
      ["completed", "completed"],
      ["failed", "failed"],
      ["cancelled", "cancelled"],
      ["interrupted", "cancelled"],
    ] as const) {
      const terminal = record();
      terminal.turn.status = turnStatus;
      terminal.run.status = runStatus;
      const decision = planCollabPublication({ record: terminal, current: current() });
      expect(decision).toMatchObject({ kind: "fenced", code: "terminal_outbox_unreconciled" });
    }
  });

  it("published terminal work settles without using a stale independent status", () => {
    const terminal = record();
    terminal.turn.status = "completed";
    terminal.run.status = "completed";
    terminal.outbox.status = "published";
    terminal.lease.releasedAt = T0;
    expect(planCollabPublication({ record: terminal, current: current() })).toEqual({
      kind: "settle",
      outboxId: OUTBOX,
    });
  });

  it("stale heartbeat, released lease and superseded generation fence publication", () => {
    const stale = current();
    stale.now = new Date(T0.getTime() + 45_001);
    expect(planCollabPublication({ record: record(), current: stale }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const released = record();
    released.lease.releasedAt = T0;
    expect(planCollabPublication({ record: released, current: current() }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const superseded = current();
    superseded.latestLeaseGeneration = 10;
    expect(planCollabPublication({ record: record(), current: superseded }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const staleAdvanced = record();
    staleAdvanced.lease.generation = 10;
    staleAdvanced.lease.releasedAt = T0;
    staleAdvanced.lease.cancelRequestedAt = T0;
    expect(planCollabPublication({
      record: staleAdvanced,
      current: { ...current(), latestLeaseGeneration: 10 },
    })).toMatchObject({ kind: "fenced", code: "stale_authorization" });
  });

  it("room/member generation and host liveness/ownership are recovery fences", () => {
    const staleRoom = current();
    staleRoom.room = { ...staleRoom.room, generation: 5 };
    expect(planCollabPublication({ record: record(), current: staleRoom }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const staleMember = current();
    staleMember.member = { ...staleMember.member, generation: 5 };
    expect(planCollabPublication({ record: record(), current: staleMember }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const deleted = current();
    deleted.hostSession = { ...deleted.hostSession, deletedAt: T0 };
    expect(planCollabPublication({ record: record(), current: deleted }))
      .toMatchObject({ kind: "fenced", code: "not_member" });

    const wrongOwner = current();
    wrongOwner.hostSession = { ...wrongOwner.hostSession, userId: "other-host" };
    expect(planCollabPublication({ record: record(), current: wrongOwner }))
      .toMatchObject({ kind: "fenced", code: "not_member" });
  });

  it("descendants inherit the validated root fence and never acquire a second lease", () => {
    const inherited = planCollabDescendantLease({ root: record(), current: current() });
    expect(inherited).toMatchObject({
      kind: "inherit",
      collab: { leaseId: LEASE, leaseGeneration: 9, outboxId: OUTBOX, rootRunId: RUN },
      writes: [],
    });

    const stale = planCollabDescendantLease({
      root: record(),
      current: { ...current(), latestLeaseGeneration: 10 },
    });
    expect(stale).toMatchObject({ kind: "refuse", code: "stale_authorization", writes: [] });
  });

  it("publication rejects a tampered durable record instead of publishing it", () => {
    const tampered = record();
    tampered.turn.participantId = "another-participant";
    expect(thrown(() => planCollabPublication({ record: tampered, current: current() })))
      .toBeInstanceOf(CollabTurnError);
    expect(thrown(() => planCollabPublication({ record: tampered, current: current() })))
      .toMatchObject({ code: "invalid_record" });
  });
});
