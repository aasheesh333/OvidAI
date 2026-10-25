import { afterAll, beforeAll, describe, expect, it } from "vitest";
import Fastify from "fastify";
import { createLifecycle, createPostgresDeletionStore } from "@ovid/account";
import { createDb, migrate, newId, users, type Db } from "@ovid/db";
import type { AuthPrincipal } from "../auth.js";
import { registerAccountRoutes, withCollabDeletionFence } from "../routes/account.js";
import { CollabLifecycle } from "./lifecycle.js";
import { CollabMembership } from "./membership.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-task-2-lifecycle-test-authority-secret";

function principal(uid: string): AuthPrincipal {
  return { uid, email: null, authTime: 1_700_000_000, signInProvider: "google.com" };
}

type Unsafe = (query: string, parameters?: readonly unknown[]) => Promise<unknown>;
interface ReservedForObservation {
  unsafe: Unsafe;
  release(): void;
}
interface PoolObservation {
  attempts: number;
  releases: number;
  active: number;
  maxActive: number;
  rootTransactions: string[];
  reservedTransactions: string[];
  pids: Set<number>;
  restore(): void;
}

/** Observe the real driver boundary; never replace SQL or transaction behavior. */
function observePool(db: Db): PoolObservation {
  const client = db.$client as unknown as {
    reserve(): Promise<ReservedForObservation>;
    unsafe: Unsafe;
  };
  const originalReserve = client.reserve.bind(client);
  const originalRootUnsafe = client.unsafe.bind(client);
  const observation: PoolObservation = {
    attempts: 0,
    releases: 0,
    active: 0,
    maxActive: 0,
    rootTransactions: [],
    reservedTransactions: [],
    pids: new Set<number>(),
    restore: () => {
      client.reserve = originalReserve;
      client.unsafe = originalRootUnsafe;
    },
  };
  const transaction = (query: string): boolean => /^(?:BEGIN|COMMIT|ROLLBACK)(?:\s|$)/i.test(query);
  client.unsafe = async (query, parameters) => {
    if (transaction(query)) observation.rootTransactions.push(query);
    return originalRootUnsafe(query, parameters);
  };
  client.reserve = async () => {
    observation.attempts += 1;
    const reserved = await originalReserve();
    observation.active += 1;
    observation.maxActive = Math.max(observation.maxActive, observation.active);
    const originalUnsafe = reserved.unsafe.bind(reserved);
    const pidRows = await originalUnsafe("SELECT pg_backend_pid() AS pid", []) as Array<{ pid: number }>;
    if (pidRows[0] !== undefined) observation.pids.add(pidRows[0].pid);
    reserved.unsafe = async (query, parameters) => {
      if (transaction(query)) observation.reservedTransactions.push(query);
      return originalUnsafe(query, parameters);
    };
    const originalRelease = reserved.release.bind(reserved);
    let released = false;
    reserved.release = () => {
      if (!released) {
        released = true;
        observation.releases += 1;
        observation.active -= 1;
      }
      originalRelease();
    };
    return reserved;
  };
  return observation;
}

describe.skipIf(!TEST_DATABASE_URL).sequential("CollabLifecycle deletion fencing against real Postgres", () => {
  let db: Db;
  let membership: CollabMembership;
  let lifecycle: CollabLifecycle;
  let sequence = 0;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 8 });
    membership = new CollabMembership(db, { authoritySecret: AUTHORITY_SECRET });
    lifecycle = new CollabLifecycle(membership);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function uid(prefix: string): Promise<string> {
    sequence += 1;
    const value = `collab-lifecycle-${prefix}-${process.pid}-${sequence}`;
    await users.ensure(db, value, null);
    return value;
  }

  // UNEXECUTED fix-round-2 regression: real immediate deletion, max one connection.
  it("immediate deletion fences on real reserved transactions and releases every connection", async () => {
    const single = createDb(TEST_DATABASE_URL!, { max: 1 });
    const owner = `collab-lifecycle-immediate-${process.pid}-${newId()}`;
    const app = Fastify({ logger: false });
    let observation: PoolObservation | undefined;
    try {
      await users.ensure(single, owner, null);
      const membership = new CollabMembership(single, { authoritySecret: AUTHORITY_SECRET });
      const collabLifecycle = new CollabLifecycle(membership);
      const room = await membership.createRoom({
        principal: principal(owner), requestId: `immediate-room-${newId()}`,
      });
      const accountLifecycle = createLifecycle({
        store: createPostgresDeletionStore(single),
        admin: {
          user: async () => ({ disabled: false, last_login_ms: 0 }),
          disable: async () => {}, enable: async () => {}, delete: async () => {},
        },
        data: { prepare: async () => ({}), revokeKeys: async () => {}, deletionSteps: () => [] },
        clock: () => 1_700_000_100,
      });
      registerAccountRoutes(app, {
        lifecycle: accountLifecycle,
        verify: async () => ({
          uid: owner,
          auth_time: 1_700_000_000,
          firebase: { sign_in_provider: "google.com" },
        }),
        collabLifecycle,
      });
      await app.ready();
      observation = observePool(single);
      const response = await app.inject({
        method: "POST",
        url: "/account/deletion",
        headers: { authorization: "Bearer verified", "x-firebase-appcheck": "attested" },
        payload: { request_id: "immediate-0001" },
      });
      expect(response.statusCode).toBe(200);
      expect(response.json().state).toBe("pending");
      expect((await single.$client`SELECT lifecycle FROM collab_rooms WHERE id = ${room.roomId}`)[0]?.lifecycle)
        .toBe("closed");
      expect(observation.rootTransactions).toEqual([]);
      expect(observation.reservedTransactions).toContain("BEGIN");
      expect(observation.reservedTransactions).toContain("COMMIT");
      expect(observation.attempts).toBeGreaterThanOrEqual(2);
      expect(observation.attempts).toBe(observation.releases);
      expect(observation.active).toBe(0);
      expect(observation.maxActive).toBe(1);
      expect(observation.pids.size).toBe(1);
    } finally {
      observation?.restore();
      await app.close();
      await single.$client.end({ timeout: 1 });
    }
  }, 15_000);

  // UNEXECUTED fix-round-2 regression: final cleanup uses the same UID session.
  it("final deletion cleanup reuses and releases its one reserved UID connection", async () => {
    const single = createDb(TEST_DATABASE_URL!, { max: 1 });
    const owner = `collab-lifecycle-final-${process.pid}-${newId()}`;
    let observation: PoolObservation | undefined;
    try {
      await users.ensure(single, owner, null);
      const membership = new CollabMembership(single, { authoritySecret: AUTHORITY_SECRET });
      const collabLifecycle = new CollabLifecycle(membership);
      const room = await membership.createRoom({
        principal: principal(owner), requestId: `final-room-${newId()}`,
      });
      await single.$client`INSERT INTO account_deletions (uid, state, delete_after, record)
        VALUES (${owner}, 'deleting', 0, ${single.$client.json({
          uid: owner,
          request_id: "final-cleanup-0001",
          state: "deleting",
          requested_at: 0,
          delete_after: 0,
          baseline_login_ms: 0,
          fence_at: 0,
          fence_owned: false,
          completed: ["data"],
          request_aliases: [],
          attempts: 0,
          next_attempt: 0,
          previous_requests: [],
          cleanup_context: {},
        })}::jsonb)`;
      let callbackPid: number | undefined;
      const data = withCollabDeletionFence({
        prepare: async () => ({}),
        revokeKeys: async () => {},
        deletionSteps: () => [],
      }, async (uid, connection) => {
        expect(connection).toBeDefined();
        callbackPid = (await connection!.$client`SELECT pg_backend_pid() AS pid`)[0]?.pid;
        await collabLifecycle.onDeletionPending(uid, connection);
      });
      const accountLifecycle = createLifecycle({
        store: createPostgresDeletionStore(single),
        admin: {
          user: async () => ({ disabled: false, last_login_ms: 0 }),
          disable: async () => {}, enable: async () => {}, delete: async () => {},
        },
        data,
        clock: () => 1,
      });
      observation = observePool(single);
      expect((await accountLifecycle.finalize(owner, { scheduled: true })).state).toBe("deleted");
      expect((await single.$client`SELECT lifecycle FROM collab_rooms WHERE id = ${room.roomId}`)[0]?.lifecycle)
        .toBe("closed");
      expect(callbackPid).toBeDefined();
      expect(observation.pids.has(callbackPid!)).toBe(true);
      expect(observation.rootTransactions).toEqual([]);
      expect(observation.reservedTransactions).toContain("BEGIN");
      expect(observation.reservedTransactions).toContain("COMMIT");
      expect(observation.attempts).toBe(1);
      expect(observation.releases).toBe(1);
      expect(observation.active).toBe(0);
      expect(observation.maxActive).toBe(1);
      expect(observation.pids.size).toBe(1);
    } finally {
      observation?.restore();
      await single.$client.end({ timeout: 1 });
    }
  }, 15_000);

  it("never enters HTTP account admission while cleanup already owns the UID lock", async () => {
    const directUid = await uid("direct-fence");
    const fencedMembership = new CollabMembership(db, {
      authoritySecret: AUTHORITY_SECRET,
      admission: async () => { throw new Error("nested HTTP admission must not run"); },
    });
    await new CollabLifecycle(fencedMembership).onDeletionPending(directUid);
  });

  it("idempotently closes owned rooms, revokes memberships/invites, and requests cancellation for every affected active turn", async () => {
    const owner = await uid("owner");
    const guest = await uid("guest");
    const otherHost = await uid("other-host");
    const owned = await membership.createRoom({ principal: principal(owner), requestId: `owned-${newId()}` });
    const other = await membership.createRoom({ principal: principal(otherHost), requestId: `other-${newId()}` });
    const ownedInvite = await membership.createInvite({
      principal: principal(owner), token: owned.sessionToken,
      idempotencyKey: `owned-invite-${newId()}`, maxUses: 5, ttlSeconds: 60,
    });
    const otherInvite = await membership.createInvite({
      principal: principal(otherHost), token: other.sessionToken,
      idempotencyKey: `other-invite-${newId()}`, maxUses: 5, ttlSeconds: 60,
    });
    const joined = await membership.join({
      principal: principal(owner), token: other.sessionToken, inviteCode: otherInvite.inviteCode,
      idempotencyKey: `owner-joins-other-${newId()}`,
    });
    await membership.join({
      principal: principal(guest), token: owned.sessionToken, inviteCode: ownedInvite.inviteCode,
      idempotencyKey: `guest-joins-owned-${newId()}`,
    });

    async function activeTurn(roomId: string, sessionId: string, actorUserId: string, participantId: string) {
      const messageId = newId();
      const runId = newId();
      await db.$client`INSERT INTO messages (id, session_id, role, content)
        VALUES (${messageId}, ${sessionId}, 'user', 'active deletion fixture')`;
      await db.$client`INSERT INTO runs (id, session_id, status, prompt_message_id, cancel_requested)
        VALUES (${runId}, ${sessionId}, 'running', ${messageId}, false)`;
      await db.$client`INSERT INTO collab_turns
        (id, room_id, participant_id, actor_user_id, run_id, user_message_id, idempotency_key, status, created_at, updated_at)
        VALUES (${newId()}, ${roomId}, ${participantId}, ${actorUserId}, ${runId}, ${messageId},
                ${`turn-${newId()}`}, 'running', now(), now())`;
      await db.$client`INSERT INTO collab_sender_leases
        (id, room_id, holder_participant_id, holder_user_id, run_id, generation, started_at, heartbeat_at)
        VALUES (${newId()}, ${roomId}, ${participantId}, ${actorUserId}, ${runId}, 1, now(), now())`;
      return runId;
    }
    const ownedRun = await activeTurn(owned.roomId, owned.session.sessionId, guest,
      (await db.$client`SELECT participant_id FROM collab_members WHERE room_id = ${owned.roomId} AND user_id = ${guest}`)[0]!.participant_id);
    const otherRun = await activeTurn(other.roomId, other.session.sessionId, owner, joined.member.participantId);
    const baseline = await db.$client`SELECT
      (SELECT count(*)::int FROM messages WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS messages,
      (SELECT count(*)::int FROM runs WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS runs,
      (SELECT count(*)::int FROM run_outbox WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS outbox`;

    await db.$client`INSERT INTO account_deletions (uid, state, delete_after, record)
      VALUES (${owner}, 'pending', 1, '{"uid":"pending-fixture"}'::jsonb)`;
    await db.$client`UPDATE collab_rooms SET lifecycle = 'closing' WHERE id = ${owned.roomId}`;
    await lifecycle.onDeletionPending(owner);
    const firstGeneration = await db.$client`SELECT generation FROM collab_rooms WHERE id = ${owned.roomId}`;
    await lifecycle.onDeletionPending(owner);
    const secondGeneration = await db.$client`SELECT generation FROM collab_rooms WHERE id = ${owned.roomId}`;
    expect(secondGeneration).toEqual(firstGeneration);

    expect((await db.$client`SELECT lifecycle FROM collab_rooms WHERE id = ${owned.roomId}`)[0]?.lifecycle).toBe("closed");
    expect((await db.$client`SELECT status FROM collab_members WHERE room_id = ${other.roomId} AND user_id = ${owner}`)[0]?.status).toBe("revoked");
    expect((await db.$client`SELECT count(*)::int AS count FROM collab_invites
      WHERE revoked_at IS NULL AND (room_id = ${owned.roomId} OR issued_by_user_id = ${owner})`)[0]?.count).toBe(0);
    expect((await db.$client`SELECT revoked_at FROM collab_invites WHERE id = ${otherInvite.inviteId}`)[0]?.revoked_at)
      .toBeNull();
    expect((await db.$client`SELECT count(*)::int AS count FROM collab_turns
      WHERE run_id IN (${ownedRun}, ${otherRun}) AND cancel_requested_at IS NOT NULL`)[0]?.count).toBe(2);
    expect((await db.$client`SELECT count(*)::int AS count FROM collab_sender_leases
      WHERE run_id IN (${ownedRun}, ${otherRun}) AND cancel_requested_at IS NOT NULL`)[0]?.count).toBe(2);
    expect((await db.$client`SELECT id FROM runs WHERE id IN (${ownedRun}, ${otherRun}) AND cancel_requested = true`)).toHaveLength(2);

    await db.$client`UPDATE account_deletions SET state = 'deleted' WHERE uid = ${owner}`;
    const deniedBefore = await db.$client`SELECT
      (SELECT count(*)::int FROM collab_members WHERE room_id = ${other.roomId}) AS members,
      (SELECT uses FROM collab_invites WHERE id = ${otherInvite.inviteId}) AS invite_uses`;
    for (const operation of [
      () => membership.authorize({ principal: principal(owner), token: owned.sessionToken }),
      () => membership.authorize({ principal: principal(owner), token: other.sessionToken }),
      () => membership.join({
        principal: principal(owner), token: other.sessionToken, inviteCode: otherInvite.inviteCode,
        idempotencyKey: `deleted-rejoin-${newId()}`,
      }),
      () => membership.createRoom({ principal: principal(owner), requestId: `deleted-create-${newId()}` }),
    ]) {
      await expect(operation()).rejects.toMatchObject({ code: "not_member" });
    }
    expect((await db.$client`SELECT
      (SELECT count(*)::int FROM messages WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS messages,
      (SELECT count(*)::int FROM runs WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS runs,
      (SELECT count(*)::int FROM run_outbox WHERE session_id IN (${owned.session.sessionId}, ${other.session.sessionId})) AS outbox`)[0])
      .toEqual(baseline[0]);
    expect((await db.$client`SELECT
      (SELECT count(*)::int FROM collab_members WHERE room_id = ${other.roomId}) AS members,
      (SELECT uses FROM collab_invites WHERE id = ${otherInvite.inviteId}) AS invite_uses`)[0])
      .toEqual(deniedBefore[0]);
  });
});
