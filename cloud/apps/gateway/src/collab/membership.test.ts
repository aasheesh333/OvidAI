import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createLifecycle, createPostgresDeletionStore } from "@ovid/account";
import { createDb, migrate, newId, users, type Db } from "@ovid/db";
import type { AuthPrincipal } from "../auth.js";
import { CollabMembership, type AccountAdmission } from "./membership.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-task-2-membership-test-authority-secret";

function principal(uid: string): AuthPrincipal {
  return { uid, email: `${uid}@example.test`, authTime: 1_700_000_000, signInProvider: "google.com" };
}

/** The real account store/lifecycle admission used by the production composition. */
function productionAdmission(db: Db): AccountAdmission {
  const lifecycle = createLifecycle({
    store: createPostgresDeletionStore(db),
    admin: {
      user: async () => null,
      disable: async () => {},
      enable: async () => {},
      delete: async () => {},
    },
    data: {
      prepare: async () => ({}),
      revokeKeys: async () => {},
      deletionSteps: () => [],
    },
  });
  return (caller, fn) => lifecycle.access({
    uid: caller.uid,
    auth_time: caller.authTime,
    firebase: { sign_in_provider: caller.signInProvider },
  }, (uid, session) => fn(uid, session));
}

describe.skipIf(!TEST_DATABASE_URL).sequential("CollabMembership against isolated real Postgres", () => {
  let db: Db;
  let membership: CollabMembership;
  let sequence = 0;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    // Four connections make a nested acquisition per admitted join starve the
    // pool before any of 50 distinct UIDs can finish and release its UID lock.
    db = createDb(TEST_DATABASE_URL!, { max: 4 });
    membership = new CollabMembership(db, {
      authoritySecret: AUTHORITY_SECRET,
      admission: productionAdmission(db),
    });
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function uid(prefix: string): Promise<string> {
    sequence += 1;
    const value = `collab-member-${prefix}-${process.pid}-${sequence}`;
    await users.ensure(db, value, null);
    return value;
  }

  async function room(owner: string) {
    return membership.createRoom({ principal: principal(owner), requestId: `create-${newId()}` });
  }

  async function counts(roomId: string, sessionId: string) {
    const rows = await db.$client.unsafe(
      `SELECT
        (SELECT count(*)::int FROM collab_members WHERE room_id = $1) AS members,
        (SELECT count(*)::int FROM collab_members WHERE room_id = $1 AND status = 'active') AS active,
        (SELECT count(*)::int FROM messages WHERE session_id = $2) AS messages,
        (SELECT count(*)::int FROM runs WHERE session_id = $2) AS runs,
        (SELECT count(*)::int FROM run_outbox WHERE session_id = $2) AS outbox`,
      [roomId, sessionId],
    );
    return rows[0]!;
  }

  // UNEXECUTED fix-round-1 regression: real AccountAdmission + bounded pool.
  it("admits exactly 50 concurrent actives including owner through real AccountAdmission without pool self-starvation", async () => {
    const owner = await uid("cap-owner");
    const created = await room(owner);
    const invite = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `invite-${newId()}`, maxUses: 50, ttlSeconds: 3600,
    });
    const guests = await Promise.all(Array.from({ length: 50 }, (_, index) => uid(`cap-guest-${index}`)));
    const results = await Promise.allSettled(guests.map((guest, index) => membership.join({
      principal: principal(guest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `join-${index}-${newId()}`,
    })));
    expect(results.filter((result) => result.status === "fulfilled")).toHaveLength(49);
    const denied = results.filter((result): result is PromiseRejectedResult => result.status === "rejected");
    expect(denied).toHaveLength(1);
    expect(denied[0]!.reason).toMatchObject({ code: "session_full" });
    const successfulGuest = guests.find((_, index) => results[index]!.status === "fulfilled")!;
    const beforeReconnect = await counts(created.roomId, created.session.sessionId);
    const inviteBeforeReconnect = await db.$client`SELECT uses FROM collab_invites WHERE id = ${invite.inviteId}`;
    const ownerReconnect = await membership.join({
      principal: principal(owner), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `owner-reconnect-${newId()}`,
    });
    expect(ownerReconnect.member).toEqual(created.member);
    const reconnect = await membership.join({
      principal: principal(successfulGuest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `reconnect-${newId()}`,
    });
    expect(reconnect.member.status).toBe("active");
    expect(await counts(created.roomId, created.session.sessionId)).toEqual(beforeReconnect);
    expect(beforeReconnect).toMatchObject({ active: 50, messages: 0, runs: 0, outbox: 0 });
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${invite.inviteId}`)[0]?.uses)
      .toBe(inviteBeforeReconnect[0]?.uses);
    expect(inviteBeforeReconnect[0]?.uses).toBe(49);

    const extra = await uid("cap-fifty-first-distinct");
    const beforeDenied = await counts(created.roomId, created.session.sessionId);
    await expect(membership.join({
      principal: principal(extra), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `join-extra-${newId()}`,
    })).rejects.toMatchObject({ code: "session_full" });
    expect(await counts(created.roomId, created.session.sessionId)).toEqual(beforeDenied);
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${invite.inviteId}`)[0]?.uses).toBe(49);
  }, 30_000);

  // UNEXECUTED fix-round-1 regression: max=1 proves no nested pool acquisition.
  it("uses the account store's reserved session instead of opening a nested pool transaction", async () => {
    const single = createDb(TEST_DATABASE_URL!, { max: 1 });
    const owner = `collab-member-single-pool-${process.pid}-${newId()}`;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const admitted = new CollabMembership(single, {
        authoritySecret: AUTHORITY_SECRET,
        admission: productionAdmission(single),
      });
      const operation = (async () => {
        const created = await admitted.createRoom({
          principal: principal(owner), requestId: `single-pool-${newId()}`,
        });
        expect(created.member.role).toBe("owner");
        expect((await admitted.authorize({ principal: principal(owner), token: created.sessionToken })).roomId)
          .toBe(created.roomId);
      })();
      await Promise.race([
        operation,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(() => reject(new Error("nested pool acquisition starved the single connection")), 5_000);
        }),
      ]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
      await single.$client.end({ timeout: 1 });
    }
  }, 10_000);

  it("admits a verified first-time user without requiring a prior users row", async () => {
    const owner = await uid("first-time-owner");
    const created = await room(owner);
    const invite = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `first-time-invite-${newId()}`, maxUses: 1, ttlSeconds: 60,
    });
    const firstTimeUid = `collab-member-first-time-${process.pid}-${newId()}`;
    const joined = await membership.join({
      principal: principal(firstTimeUid), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `first-time-join-${newId()}`,
    });
    expect(joined.member.role).toBe("participant");
    expect((await db.$client`SELECT uid FROM users WHERE uid = ${firstTimeUid}`)).toHaveLength(1);
  });

  it("enforces expiry, use bound, and revocation without consuming a denied invite", async () => {
    const owner = await uid("invite-owner");
    const created = await room(owner);
    const expiring = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `expiry-${newId()}`, maxUses: 2, ttlSeconds: 60,
    });
    await db.$client`UPDATE collab_invites SET expires_at = now() - interval '1 second' WHERE id = ${expiring.inviteId}`;
    const expiredGuest = await uid("expired-guest");
    await expect(membership.join({
      principal: principal(expiredGuest), token: created.sessionToken, inviteCode: expiring.inviteCode,
      idempotencyKey: `expired-${newId()}`,
    })).rejects.toMatchObject({ code: "invite_invalid" });
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${expiring.inviteId}`)[0]?.uses).toBe(0);

    const single = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `single-${newId()}`, maxUses: 1, ttlSeconds: 60,
    });
    const first = await uid("single-first");
    await membership.join({
      principal: principal(first), token: created.sessionToken, inviteCode: single.inviteCode,
      idempotencyKey: `single-first-${newId()}`,
    });
    const second = await uid("single-second");
    await expect(membership.join({
      principal: principal(second), token: created.sessionToken, inviteCode: single.inviteCode,
      idempotencyKey: `single-second-${newId()}`,
    })).rejects.toMatchObject({ code: "invite_invalid" });
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${single.inviteId}`)[0]?.uses).toBe(1);

    const revocable = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `revocable-${newId()}`, maxUses: 5, ttlSeconds: 60,
    });
    await membership.revokeInvite({ principal: principal(owner), token: created.sessionToken, inviteId: revocable.inviteId });
    const revokedGuest = await uid("revoked-invite-guest");
    await expect(membership.join({
      principal: principal(revokedGuest), token: created.sessionToken, inviteCode: revocable.inviteCode,
      idempotencyKey: `revoked-invite-${newId()}`,
    })).rejects.toMatchObject({ code: "invite_invalid" });
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${revocable.inviteId}`)[0]?.uses).toBe(0);
  });

  it("never revives a revoked member and gives wrong-tenant/unknown access the same denial with no writes", async () => {
    const owner = await uid("revoke-owner");
    const guest = await uid("revoke-guest");
    const stranger = await uid("wrong-tenant");
    const created = await room(owner);
    const invite = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `invite-${newId()}`, maxUses: 5, ttlSeconds: 60,
    });
    const joined = await membership.join({
      principal: principal(guest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `join-${newId()}`,
    });
    await membership.remove({
      principal: principal(owner), token: created.sessionToken,
      participantId: joined.member.participantId,
    });
    const before = await counts(created.roomId, created.session.sessionId);
    for (const operation of [
      () => membership.authorize({ principal: principal(guest), token: created.sessionToken }),
      () => membership.authorize({ principal: principal(stranger), token: created.sessionToken }),
      () => membership.authorize({ principal: principal(stranger), token: "X".repeat(43) }),
    ]) {
      await expect(operation()).rejects.toMatchObject({ code: "not_member" });
    }
    await expect(membership.join({
      principal: principal(guest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `revoked-rejoin-${newId()}`,
    })).rejects.toMatchObject({ code: "not_member" });
    expect(await counts(created.roomId, created.session.sessionId)).toEqual(before);
    expect((await db.$client`SELECT uses FROM collab_invites WHERE id = ${invite.inviteId}`)[0]?.uses).toBe(1);
  });

  it("advances generations on leave/remove, permits only left-member rejoin, and closes reads and late writes", async () => {
    const owner = await uid("generation-owner");
    const guest = await uid("generation-guest");
    const created = await room(owner);
    const invite = await membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `generation-invite-${newId()}`, maxUses: 5, ttlSeconds: 60,
    });
    const joined = await membership.join({
      principal: principal(guest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `generation-join-${newId()}`,
    });
    const joinedAuth = await membership.authorize({ principal: principal(guest), token: created.sessionToken });
    const left = await membership.leave({ principal: principal(guest), token: created.sessionToken });
    expect(left.member.status).toBe("left");
    const leftAuth = await db.$client`SELECT generation FROM collab_rooms WHERE id = ${created.roomId}`;
    expect(Number(leftAuth[0]?.generation)).toBeGreaterThan(joinedAuth.roomGeneration);
    await expect(membership.authorize({ principal: principal(guest), token: created.sessionToken }))
      .rejects.toMatchObject({ code: "not_member" });

    const rejoined = await membership.join({
      principal: principal(guest), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `generation-rejoin-${newId()}`,
    });
    expect(rejoined.member.participantId).toBe(joined.member.participantId);
    const beforeRemove = await membership.authorize({ principal: principal(owner), token: created.sessionToken });
    const removed = await membership.remove({
      principal: principal(owner), token: created.sessionToken,
      participantId: joined.member.participantId,
    });
    expect(removed.member.status).toBe("revoked");
    const afterRemove = await membership.authorize({ principal: principal(owner), token: created.sessionToken });
    expect(afterRemove.roomGeneration).toBeGreaterThan(beforeRemove.roomGeneration);
    expect(afterRemove.membershipGeneration).toBeGreaterThan(beforeRemove.membershipGeneration);

    const closed = await membership.close({
      principal: principal(owner), token: created.sessionToken, idempotencyKey: `close-${newId()}`,
    });
    expect(closed.session.lifecycle).toBe("closed");
    await expect(membership.authorize({ principal: principal(owner), token: created.sessionToken }))
      .rejects.toMatchObject({ code: "session_closed" });
    const beforeDenied = await counts(created.roomId, created.session.sessionId);
    await expect(membership.createInvite({
      principal: principal(owner), token: created.sessionToken,
      idempotencyKey: `closed-invite-${newId()}`, maxUses: 1, ttlSeconds: 60,
    })).rejects.toMatchObject({ code: "session_closed" });
    const other = await uid("closed-join");
    await expect(membership.join({
      principal: principal(other), token: created.sessionToken, inviteCode: invite.inviteCode,
      idempotencyKey: `closed-join-${newId()}`,
    })).rejects.toMatchObject({ code: "session_closed" });
    expect(await counts(created.roomId, created.session.sessionId)).toEqual(beforeDenied);
  });
});
