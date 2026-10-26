import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { and, eq } from "drizzle-orm";
import {
  createDb,
  migrate,
  newId,
  schema,
  type Db,
} from "@ovid/db";
import {
  agentRunJobSchema,
  collabAuthorityToken,
  type AgentRunCollab,
  type AgentRunCollabPublication,
  type AgentRunJob,
} from "@ovid/queue";
import type { KeyResolver } from "@ovid/shared";

import {
  claimCollabRun,
  collabRunExecution,
} from "./collabRun.js";
import { runKeyAdapter } from "./runAccount.js";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. Authored worker contract and
// real-Postgres regressions only; no compilation, test, queue or claim evidence.

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const T0 = new Date("2026-10-25T00:00:00.000Z");
const ROOM = "10000000-0000-7000-8000-000000000001";
const SESSION = "20000000-0000-7000-8000-000000000001";
const TURN = "30000000-0000-7000-8000-000000000001";
const RUN = "40000000-0000-7000-8000-000000000001";
const MESSAGE = "50000000-0000-7000-8000-000000000001";
const OUTBOX = "60000000-0000-7000-8000-000000000001";
const LEASE = "70000000-0000-7000-8000-000000000001";
const PARTICIPANT = `p${"0".repeat(31)}1`;

interface JobFixture {
  job: AgentRunJob;
  collab: AgentRunCollab;
  publication: AgentRunCollabPublication;
  participantId: string;
  roomGeneration: number;
  membershipGeneration: number;
}

function jobFixture(): JobFixture {
  const collab: AgentRunCollab = {
    roomId: ROOM,
    participantId: PARTICIPANT,
    membershipGeneration: 4,
    leaseId: LEASE,
    leaseGeneration: 9,
    outboxId: OUTBOX,
    rootRunId: RUN,
  };
  const publication: AgentRunCollabPublication = {
    outboxStatus: "published",
    outboxAttempts: 1,
    runStatus: "queued",
    turnStatus: "queued",
    leaseGeneration: 9,
    authorityToken: collabAuthorityToken({
      roomId: ROOM,
      sessionId: SESSION,
      ownerUserId: "host-user",
      actorUserId: "sender-user",
      participantId: PARTICIPANT,
      roomGeneration: 4,
      membershipGeneration: 4,
      leaseId: LEASE,
      leaseGeneration: 9,
      rootRunId: RUN,
      turnId: TURN,
    }),
  };
  const job: AgentRunJob = {
    runId: RUN,
    sessionId: SESSION,
    userId: "host-user",
    ownerUserId: "host-user",
    actorUserId: "sender-user",
    source: "collab",
    prompt: "hello collaborators",
    requestedModel: "provider/model",
    tier: "free",
    byokKeyId: "accepted-key-id",
    byokModel: "accepted-provider-model",
    modelContext: {
      requestedModel: "provider/model",
      byokKeyId: "accepted-key-id",
      byokModel: "accepted-provider-model",
      temperature: null,
      actorUserId: "sender-user",
    },
    collab,
    collabPublication: publication,
  };
  return {
    job,
    collab,
    publication,
    participantId: PARTICIPANT,
    roomGeneration: 4,
    membershipGeneration: 4,
  };
}

describe("Collab worker execution adapter (UNEXECUTED)", () => {
  it("consumes the amended queue schema with host owner, sender actor and captured BYOK", () => {
    const { job } = jobFixture();
    expect(agentRunJobSchema.parse(job)).toEqual(job);
    const execution = collabRunExecution(job);

    expect(execution).toMatchObject({
      ownerUserId: "host-user",
      actorUserId: "sender-user",
      workspaceTier: "free",
      billingClass: "byok",
      modelContext: {
        requestedModel: "provider/model",
        byokKeyId: "accepted-key-id",
        byokModel: "accepted-provider-model",
        actorUserId: "sender-user",
      },
      keySelection: {
        ctx: { unattended: false, byokKeyId: "accepted-key-id" },
        byokDefault: null,
        modelContext: { byokKeyId: "accepted-key-id" },
      },
    });
  });

  it("never falls back to Ovid when the accepted BYOK key cannot be resolved", async () => {
    const { job } = jobFixture();
    const execution = collabRunExecution(job);
    const keyCalls: Array<string | null> = [];
    const resolver: KeyResolver = {
      async resolveForRun(_uid, ctx) {
        keyCalls.push(ctx.byokKeyId ?? null);
        // A null-context call would be an Ovid fallback and must never happen.
        return null;
      },
    };
    const adapter = runKeyAdapter({
      resolver,
      defaultModel: "ovid/default",
      ...execution.keySelection,
    });

    await expect(adapter.resolve("sender-user", "host-session-model")).resolves.toBeNull();
    expect(keyCalls).toEqual(["accepted-key-id"]);
  });

  it("rejects host/actor, model, lineage or publication inconsistencies", () => {
    const { job } = jobFixture();
    const invalid = [
      { ...job, userId: "sender-user" },
      { ...job, requestedModel: "host-session-model" },
      { ...job, modelContext: { ...job.modelContext!, actorUserId: "host-user" } },
      { ...job, modelContext: { ...job.modelContext!, byokKeyId: null } },
      { ...job, collab: { ...job.collab!, rootRunId: "different-run" } },
      { ...job, collabPublication: { ...job.collabPublication!, leaseGeneration: 10 } },
    ];
    for (const candidate of invalid) {
      expect(() => collabRunExecution(candidate)).toThrow();
    }
  });
});

describe.skipIf(!TEST_DATABASE_URL).sequential("Collab worker claim fence (UNEXECUTED)", () => {
  let db: Db;
  let secondDb: Db;
  const createdSessionIds: string[] = [];

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 12 });
    secondDb = createDb(TEST_DATABASE_URL!, { max: 12 });
  }, 60_000);

  // The collab stale sweep scans every lease in the database, so this file's
  // sessions must not outlive their test. Session deletes cascade to runs,
  // rooms, turns and leases, but `messages` and `run_outbox` need explicit
  // dependency-ordered deletes first.
  afterEach(async () => {
    for (const sessionId of createdSessionIds) {
      await db.$client`DELETE FROM run_outbox WHERE session_id = ${sessionId}`;
      await db.$client`
        DELETE FROM collab_sender_leases
         WHERE run_id IN (SELECT id FROM runs WHERE session_id = ${sessionId})`;
      await db.$client`
        DELETE FROM collab_turns
         WHERE run_id IN (SELECT id FROM runs WHERE session_id = ${sessionId})`;
      await db.$client`DELETE FROM messages WHERE session_id = ${sessionId}`;
      await db.$client`DELETE FROM runs WHERE session_id = ${sessionId}`;
      await db.$client`DELETE FROM collab_rooms WHERE session_id = ${sessionId}`;
      await db.$client`DELETE FROM sessions WHERE id = ${sessionId}`;
    }
    createdSessionIds.length = 0;
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
    await secondDb?.$client.end({ timeout: 5 });
  }, 30_000);

  async function durableFixture() {
    const base = jobFixture();
    const suffix = newId().replaceAll("-", "");
    const ids = {
      roomId: newId(),
      sessionId: newId(),
      turnId: newId(),
      runId: newId(),
      messageId: newId(),
      outboxId: newId(),
      leaseId: newId(),
      participantId: `p${suffix}`,
    };
    createdSessionIds.push(ids.sessionId);
    const ownerUserId = `host-${newId()}`;
    const actorUserId = `sender-${newId()}`;
    const collab: AgentRunCollab = {
      ...base.collab,
      roomId: ids.roomId,
      participantId: ids.participantId,
      leaseId: ids.leaseId,
      outboxId: ids.outboxId,
      rootRunId: ids.runId,
    };
    const publication: AgentRunCollabPublication = {
      ...base.publication,
      authorityToken: collabAuthorityToken({
        roomId: ids.roomId,
        sessionId: ids.sessionId,
        ownerUserId,
        actorUserId,
        participantId: ids.participantId,
        roomGeneration: 4,
        membershipGeneration: 4,
        leaseId: ids.leaseId,
        leaseGeneration: 9,
        rootRunId: ids.runId,
        turnId: ids.turnId,
      }),
    };
    const job: AgentRunJob = {
      ...base.job,
      runId: ids.runId,
      sessionId: ids.sessionId,
      userId: ownerUserId,
      ownerUserId,
      actorUserId,
      modelContext: {
        ...base.job.modelContext!,
        actorUserId,
      },
      collab,
      collabPublication: publication,
    };

    await db.insert(schema.users).values([
      { uid: ownerUserId, tier: "free" },
      { uid: actorUserId, tier: "plus" },
    ]);
    await db.insert(schema.sessions).values({ id: ids.sessionId, userId: ownerUserId });
    await db.insert(schema.collabRooms).values({
      id: ids.roomId,
      tokenHash: `${suffix}${suffix}`,
      sessionId: ids.sessionId,
      ownerUserId,
      requestId: `create-${newId()}`,
      lifecycle: "active",
      generation: 4,
    });
    await db.insert(schema.collabMembers).values([
      {
        roomId: ids.roomId,
        userId: ownerUserId,
        participantId: `p${"f".repeat(32)}`,
        role: "owner",
        status: "active",
        generation: 4,
      },
      {
        roomId: ids.roomId,
        userId: actorUserId,
        participantId: ids.participantId,
        role: "participant",
        status: "active",
        generation: 4,
      },
    ]);
    await db.insert(schema.messages).values({
      id: ids.messageId,
      sessionId: ids.sessionId,
      role: "user",
      content: "hello collaborators",
      createdAt: T0,
    });
    await db.insert(schema.runs).values({
      id: ids.runId,
      sessionId: ids.sessionId,
      status: "queued",
      promptMessageId: ids.messageId,
      createdAt: T0,
    });
    await db.insert(schema.collabTurns).values({
      id: ids.turnId,
      roomId: ids.roomId,
      participantId: ids.participantId,
      actorUserId,
      runId: ids.runId,
      userMessageId: ids.messageId,
      idempotencyKey: "turn-key",
      model: "provider/model",
      status: "queued",
      createdAt: T0,
      updatedAt: T0,
    });
    await db.insert(schema.collabSenderLeases).values({
      id: ids.leaseId,
      roomId: ids.roomId,
      holderParticipantId: ids.participantId,
      holderUserId: actorUserId,
      runId: ids.runId,
      generation: 9,
      roomGeneration: 4,
      membershipGeneration: 4,
      startedAt: T0,
      heartbeatAt: T0,
    });
    await db.insert(schema.runOutbox).values({
      outboxId: ids.outboxId,
      actorUserId,
      sessionId: ids.sessionId,
      runId: ids.runId,
      userMessageId: ids.messageId,
      idempotencyKey: "turn-key",
      status: "published",
      attempts: 1,
      publishedAt: null,
      lastAttemptAt: T0,
      requestPayload: {
        schemaVersion: 1,
        idempotencyKey: "turn-key",
        text: "hello collaborators",
        model: "provider/model",
      },
      bodyPayload: {
        ownerUserId,
        requestedModel: "provider/model",
        userId: actorUserId,
        sessionId: ids.sessionId,
        runId: ids.runId,
        modelContext: {
          requestedModel: "provider/model",
          byokKeyId: "accepted-key-id",
          byokModel: "accepted-provider-model",
          temperature: null,
          actorUserId,
        },
        byokKeyId: "accepted-key-id",
        byokModel: "accepted-provider-model",
        tier: "free",
        queuePriority: 1,
        collab,
      },
      jobId: ids.runId,
      createdAt: T0,
      updatedAt: T0,
    });
    return { ...base, ...ids, ownerUserId, actorUserId, job, collab, publication };
  }

  it("claims a valid queued run once with the captured snapshot and current fence", async () => {
    const f = await durableFixture();
    const result = await claimCollabRun(db, f.job, { now: () => T0 });
    expect(result).toMatchObject({
      kind: "claimed",
      execution: {
        ownerUserId: f.ownerUserId,
        actorUserId: f.actorUserId,
        workspaceTier: "free",
        billingClass: "byok",
      },
    });
    const rows = await db.$client`
      SELECT r.status AS run_status, t.status AS turn_status, l.heartbeat_at
        FROM runs r
        JOIN collab_turns t ON t.run_id = r.id
        JOIN collab_sender_leases l ON l.run_id = r.id
       WHERE r.id = ${f.runId}`;
    expect(rows[0]).toMatchObject({ run_status: "running", turn_status: "running" });
    // Drizzle's raw postgres-js client keeps timestamptz as text.
    expect(new Date(rows[0]!.heartbeat_at as string)).toEqual(T0);
  });

  it("a second durable room fixture uses an independent token hash and can claim", async () => {
    const first = await durableFixture();
    const second = await durableFixture();
    const rooms = await db.$client`
      SELECT id, token_hash FROM collab_rooms WHERE id IN (${first.roomId}, ${second.roomId})
      ORDER BY id`;
    expect(rooms).toHaveLength(2);
    expect(new Set(rooms.map((room) => room.token_hash)).size).toBe(2);
    expect(await claimCollabRun(secondDb, second.job, { now: () => T0 }))
      .toMatchObject({ kind: "claimed" });
  });

  it("a post-decision pre-claim membership revocation cannot claim stale work", async () => {
    const f = await durableFixture();
    await db.update(schema.collabMembers)
      .set({ status: "revoked", generation: 5 })
      .where(and(
        eq(schema.collabMembers.roomId, f.roomId),
        eq(schema.collabMembers.userId, f.actorUserId),
      ));
    await db.update(schema.collabRooms).set({ generation: 5 })
      .where(eq(schema.collabRooms.id, f.roomId));

    expect(await claimCollabRun(db, f.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced" });
    const run = await db.$client`SELECT status FROM runs WHERE id = ${f.runId}`;
    expect(run[0]).toEqual({ status: "queued" });
  });

  it("room close, lease release/cancel and stale heartbeat each fence worker claim", async () => {
    const closed = await durableFixture();
    await db.update(schema.collabRooms).set({ lifecycle: "closed", generation: 5 })
      .where(eq(schema.collabRooms.id, closed.roomId));
    expect(await claimCollabRun(db, closed.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "session_closed" });

    const released = await durableFixture();
    await db.update(schema.collabSenderLeases)
      .set({ releasedAt: T0, cancelRequestedAt: T0, generation: 10 })
      .where(eq(schema.collabSenderLeases.id, released.leaseId));
    expect(await claimCollabRun(db, released.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const stale = await durableFixture();
    expect(await claimCollabRun(db, stale.job, { now: () => new Date(T0.getTime() + 45_001) }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });
    const rows = await db.$client`
      SELECT status FROM runs WHERE id IN (${closed.runId}, ${released.runId}, ${stale.runId})`;
    expect(rows.map((row) => row.status)).toEqual(["queued", "queued", "queued"]);
  });

  it("changed accepted snapshot or attempt/authority token cannot claim", async () => {
    const changedModel = await durableFixture();
    const stored = await db.$client`
      SELECT body_payload FROM run_outbox WHERE outbox_id = ${changedModel.outboxId}`;
    await db.update(schema.runOutbox).set({
      bodyPayload: { ...stored[0]!.body_payload, tier: "pro" },
    }).where(eq(schema.runOutbox.outboxId, changedModel.outboxId));
    expect(await claimCollabRun(db, changedModel.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "invalid_record" });

    const changedTurnModel = await durableFixture();
    await db.update(schema.collabTurns).set({ model: "provider/other" })
      .where(eq(schema.collabTurns.runId, changedTurnModel.runId));
    expect(await claimCollabRun(db, changedTurnModel.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "invalid_record" });

    const wrongAttempt = await durableFixture();
    wrongAttempt.job.collabPublication = {
      ...wrongAttempt.publication,
      outboxAttempts: 2,
    };
    expect(await claimCollabRun(db, wrongAttempt.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });

    const wrongAuthority = await durableFixture();
    wrongAuthority.job.collabPublication = {
      ...wrongAuthority.publication,
      authorityToken: "b".repeat(64),
    };
    expect(await claimCollabRun(db, wrongAuthority.job, { now: () => T0 }))
      .toMatchObject({ kind: "fenced", code: "stale_authorization" });
  });

  it("an older duplicate attempt can claim only the identical current snapshot, and only once", async () => {
    const f = await durableFixture();
    // A retry advanced the durable attempt after this duplicate was delivered.
    await db.update(schema.runOutbox).set({ attempts: 2 })
      .where(eq(schema.runOutbox.outboxId, f.outboxId));
    f.job.collabPublication = { ...f.publication, outboxAttempts: 1 };

    const claims = await Promise.all([
      claimCollabRun(db, f.job, { now: () => T0 }),
      claimCollabRun(secondDb, f.job, { now: () => T0 }),
    ]);
    expect(claims.map((claim) => claim.kind).sort()).toEqual(["claimed", "fenced"]);
    const rows = await db.$client`SELECT status FROM runs WHERE id = ${f.runId}`;
    expect(rows[0]).toEqual({ status: "running" });
  });
});
