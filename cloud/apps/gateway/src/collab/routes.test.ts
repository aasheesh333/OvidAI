import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { createDb, migrate, newId, users, type Db } from "@ovid/db";
import { buildGateway } from "../app.js";
import { authHeaders, noopEvents, stubKeys, stubMint, stubQueues, stubSystemBus, stubTickets, stubVerifier } from "../test/stubs.js";
import { CollabLifecycle } from "./lifecycle.js";
import { CollabMembership } from "./membership.js";
import { CollabProjection } from "./projection.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-task-2-routes-test-authority-secret";

describe.skipIf(!TEST_DATABASE_URL).sequential("strict root /chat routes against real Postgres", () => {
  let db: Db;
  let app: FastifyInstance;
  let membership: CollabMembership;
  let lifecycle: CollabLifecycle;
  let sequence = 0;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 12 });
  }, 60_000);

  beforeEach(async () => {
    membership = new CollabMembership(db, { authoritySecret: AUTHORITY_SECRET });
    lifecycle = new CollabLifecycle(membership);
    app = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      system: stubSystemBus(),
      collab: { membership, projection: new CollabProjection(db) },
    });
    await app.ready();
  });

  afterEach(async () => {
    await app?.close();
  });

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function uid(prefix: string): Promise<string> {
    sequence += 1;
    const value = `collab-route-${prefix}-${process.pid}-${sequence}`;
    await users.ensure(db, value, null);
    return value;
  }

  async function create(owner: string) {
    const requestId = `create-${newId()}`;
    const valid = await app.inject({
      method: "POST", url: "/chat", headers: authHeaders(owner),
      payload: { schemaVersion: 1, requestId, idempotencyKey: requestId },
    });
    expect(valid.statusCode).toBe(200);
    expect(valid.headers["cache-control"]).toBe("private, no-store");
    return valid.json() as {
      sessionToken: string;
      session: { sessionId: string };
      member: { participantId: string };
    };
  }

  async function invite(owner: string, token: string, maxUses = 5) {
    const response = await app.inject({
      method: "POST", url: `/chat/${token}/members`, headers: authHeaders(owner),
      payload: { schemaVersion: 1, idempotencyKey: `invite-${newId()}`, maxUses, ttlSeconds: 60 },
    });
    expect(response.statusCode).toBe(200);
    return response.json() as { inviteId: string; inviteCode: string };
  }

  async function join(guest: string, token: string, invitationCode: string) {
    return app.inject({
      method: "POST", url: `/chat/${token}/members`, headers: authHeaders(guest),
      payload: { schemaVersion: 1, invitationCode, idempotencyKey: `join-${newId()}` },
    });
  }

  async function canonicalCounts(sessionId: string) {
    return (await db.$client`SELECT
      (SELECT count(*)::int FROM messages WHERE session_id = ${sessionId}) AS messages,
      (SELECT count(*)::int FROM runs WHERE session_id = ${sessionId}) AS runs,
      (SELECT count(*)::int FROM run_outbox WHERE session_id = ${sessionId}) AS outbox`)[0]!;
  }

  it("keeps strict root routes unmounted without the collaboration composition", async () => {
    const off = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(), keys: stubKeys(), mint: stubMint(), events: noopEvents,
      system: stubSystemBus(),
    });
    try {
      for (const url of ["/chat", "/chat/anything", "/cloud/v1/chat"]) {
        const response = await off.inject({ method: "GET", url });
        expect(response.statusCode).toBe(404);
        expect(response.json()).toEqual({ error: { code: "not_found", message: "Route not found." } });
      }
    } finally {
      await off.close();
    }
  });

  it("serves create/invite/join/state with verified identity, opaque one-time DTO credentials, and strict bodies", async () => {
    const owner = await uid("owner");
    const guest = await uid("guest");
    const created = await create(owner);
    expect(created.sessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const invitation = await invite(owner, created.sessionToken, 2);
    expect(invitation.inviteCode).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(invitation.inviteId).toMatch(/^i[0-9a-f]{32}$/);
    const joined = await join(guest, created.sessionToken, invitation.inviteCode);
    expect(joined.statusCode).toBe(200);
    expect(joined.json().member.role).toBe("participant");
    const state = await app.inject({ method: "GET", url: `/chat/${created.sessionToken}`, headers: authHeaders(guest) });
    expect(state.statusCode).toBe(200);
    expect(state.json()).toMatchObject({
      schemaVersion: 1,
      session: { sessionId: created.session.sessionId, lifecycle: "active" },
      member: { role: "participant", status: "active" },
      turn: null,
    });
    expect(JSON.stringify(state.json())).not.toContain(created.sessionToken);
    expect(JSON.stringify(state.json())).not.toContain(invitation.inviteCode);

    const wrongTenant = await uid("wrong-tenant");
    for (const token of [created.sessionToken, "Z".repeat(43)]) {
      const denied = await app.inject({ method: "GET", url: `/chat/${token}`, headers: authHeaders(wrongTenant) });
      expect(denied.statusCode).toBe(403);
      expect(denied.json()).toMatchObject({ schemaVersion: 1, code: "not_member" });
      expect(denied.headers["cache-control"]).toBe("private, no-store");
    }
    const deniedBeforeQueryValidation = await app.inject({
      method: "GET", url: `/chat/${created.sessionToken}/events?unexpected=1`, headers: authHeaders(wrongTenant),
    });
    expect(deniedBeforeQueryValidation.statusCode).toBe(403);
    expect(deniedBeforeQueryValidation.json().code).toBe("not_member");

    const before = await db.$client`SELECT count(*)::int AS count FROM collab_rooms`;
    const requestId = `forged-${newId()}`;
    const forged = await app.inject({
      method: "POST", url: "/chat", headers: authHeaders(owner),
      payload: { schemaVersion: 1, requestId, idempotencyKey: requestId, author: "owner", role: "owner" },
    });
    expect(forged.statusCode).toBe(400);
    expect(forged.json()).toMatchObject({ schemaVersion: 1, code: "invalid_request" });
    expect((await db.$client`SELECT count(*)::int AS count FROM collab_rooms`)[0]?.count).toBe(before[0]?.count);
  });

  it("supports invite/member revocation and close denial for reads and late writes without canonical rows", async () => {
    const owner = await uid("lifecycle-owner");
    const guest = await uid("lifecycle-guest");
    const created = await create(owner);
    const invitation = await invite(owner, created.sessionToken);
    const joined = await join(guest, created.sessionToken, invitation.inviteCode);
    expect(joined.statusCode).toBe(200);
    const participantId = joined.json().member.participantId as string;

    const left = await app.inject({
      method: "DELETE", url: `/chat/${created.sessionToken}/members/me`, headers: authHeaders(guest),
    });
    expect(left.statusCode).toBe(200);
    expect(left.json().member.status).toBe("left");
    expect(Object.keys(left.json()).sort()).toEqual(["member", "schemaVersion"]);

    const removed = await app.inject({
      method: "DELETE", url: `/chat/${created.sessionToken}/members/${participantId}`, headers: authHeaders(owner),
    });
    expect(removed.statusCode).toBe(200);
    expect(removed.json().member.status).toBe("revoked");
    expect(Object.keys(removed.json()).sort()).toEqual(["member", "schemaVersion"]);
    const revoked = await app.inject({ method: "GET", url: `/chat/${created.sessionToken}`, headers: authHeaders(guest) });
    expect(revoked.statusCode).toBe(403);
    expect(revoked.json().code).toBe("not_member");

    const revokeInvite = await app.inject({
      method: "DELETE", url: `/chat/${created.sessionToken}/invites/${invitation.inviteId}`, headers: authHeaders(owner),
    });
    expect(revokeInvite.statusCode).toBe(200);
    expect(revokeInvite.json()).toMatchObject({ schemaVersion: 1, inviteId: invitation.inviteId, revoked: true });

    const key = `close-${newId()}`;
    const closed = await app.inject({
      method: "POST", url: `/chat/${created.sessionToken}/close`, headers: authHeaders(owner),
      payload: { schemaVersion: 1, idempotencyKey: key },
    });
    expect(closed.statusCode).toBe(200);
    expect(closed.json().session.lifecycle).toBe("closed");
    const before = await canonicalCounts(created.session.sessionId);
    for (const request of [
      { method: "GET" as const, url: `/chat/${created.sessionToken}` },
      { method: "GET" as const, url: `/chat/${created.sessionToken}/events?wait=0` },
      {
        method: "POST" as const, url: `/chat/${created.sessionToken}/turns`,
        payload: { schemaVersion: 1, idempotencyKey: `turn-${newId()}`, text: "late write" },
      },
    ]) {
      const denied = await app.inject({ ...request, headers: authHeaders(owner) });
      expect(denied.statusCode).toBe(409);
      expect(denied.json()).toMatchObject({ schemaVersion: 1, code: "session_closed" });
    }
    expect(await canonicalCounts(created.session.sessionId)).toEqual(before);
  });

  it("has no arbitrary event writer and the unimplemented turn seam is a side-effect-free loud refusal", async () => {
    const owner = await uid("turn-owner");
    const created = await create(owner);
    const before = await canonicalCounts(created.session.sessionId);
    const append = await app.inject({
      method: "POST", url: `/chat/${created.sessionToken}/events`, headers: authHeaders(owner),
      payload: { schemaVersion: 1, idempotencyKey: `append-${newId()}`, events: [{ eventId: "forged" }] },
    });
    expect(append.statusCode).toBe(404);
    for (const extra of [{ model: { forged: true } }, { attachmentIds: "not-an-array" }]) {
      const invalid = await app.inject({
        method: "POST", url: `/chat/${created.sessionToken}/turns`, headers: authHeaders(owner),
        payload: { schemaVersion: 1, idempotencyKey: `invalid-turn-${newId()}`, text: "strict", ...extra },
      });
      expect(invalid.statusCode).toBe(400);
      expect(invalid.json().code).toBe("invalid_request");
    }
    const turn = await app.inject({
      method: "POST", url: `/chat/${created.sessionToken}/turns`, headers: authHeaders(owner),
      payload: { schemaVersion: 1, idempotencyKey: `turn-${newId()}`, text: "not admitted yet" },
    });
    expect(turn.statusCode).toBe(503);
    expect(turn.json()).toMatchObject({ schemaVersion: 1, code: "temporarily_unavailable" });
    expect(await canonicalCounts(created.session.sessionId)).toEqual(before);
  });

  it("fences an in-flight long poll on close and on pending/final account deletion", async () => {
    const owner = await uid("poll-owner");
    const guest = await uid("poll-guest");
    const created = await create(owner);
    const invitation = await invite(owner, created.sessionToken);
    expect((await join(guest, created.sessionToken, invitation.inviteCode)).statusCode).toBe(200);

    const ownerPoll = app.inject({
      method: "GET", url: `/chat/${created.sessionToken}/events?wait=25`, headers: authHeaders(owner),
    });
    await new Promise((resolve) => setTimeout(resolve, 100));
    await membership.close({ principal: { uid: owner, email: null, authTime: 1 }, token: created.sessionToken, idempotencyKey: `poll-close-${newId()}` });
    const closedPoll = await ownerPoll;
    expect(closedPoll.statusCode).toBe(409);
    expect(closedPoll.json().code).toBe("session_closed");

    const otherOwner = await uid("poll-other-owner");
    const other = await create(otherOwner);
    const otherInvite = await invite(otherOwner, other.sessionToken);
    expect((await join(guest, other.sessionToken, otherInvite.inviteCode)).statusCode).toBe(200);
    const deletionPoll = app.inject({
      method: "GET", url: `/chat/${other.sessionToken}/events?wait=25`, headers: authHeaders(guest),
    });
    await new Promise((resolve) => setTimeout(resolve, 100));
    await db.$client`INSERT INTO account_deletions (uid, state, delete_after, record)
      VALUES (${guest}, 'pending', 1, '{"uid":"pending-route-fixture"}'::jsonb)`;
    await lifecycle.onDeletionPending(guest);
    const fencedPoll = await deletionPoll;
    expect(fencedPoll.statusCode).toBe(403);
    expect(fencedPoll.json().code).toBe("not_member");

    await db.$client`UPDATE account_deletions SET state = 'deleted' WHERE uid = ${guest}`;
    const final = await app.inject({
      method: "GET", url: `/chat/${other.sessionToken}/events?wait=25`, headers: authHeaders(guest),
    });
    expect(final.statusCode).toBe(403);
    expect(final.json().code).toBe("not_member");
    const lateWrite = await app.inject({
      method: "POST", url: `/chat/${other.sessionToken}/turns`, headers: authHeaders(guest),
      payload: { schemaVersion: 1, idempotencyKey: `deleted-turn-${newId()}`, text: "deleted late write" },
    });
    expect(lateWrite.statusCode).toBe(403);
    expect(lateWrite.json().code).toBe("not_member");
    expect(await canonicalCounts(other.session.sessionId)).toMatchObject({ messages: 0, runs: 0, outbox: 0 });
  }, 15_000);
});
