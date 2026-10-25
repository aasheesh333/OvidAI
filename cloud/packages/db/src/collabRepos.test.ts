import { createHash } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, migrate, type Db } from "./client.js";
import { CollabRepos } from "./collabRepos.js";
import { newId, users } from "./repos.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const AUTHORITY_SECRET = "collab-task-2-test-only-authority-secret";

describe.skipIf(!TEST_DATABASE_URL).sequential("collab repositories against isolated real Postgres", () => {
  let db: Db;
  let repos: CollabRepos;
  let sequence = 0;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 8 });
    repos = new CollabRepos(db, { authoritySecret: AUTHORITY_SECRET });
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function uid(prefix: string): Promise<string> {
    sequence += 1;
    const value = `collab-repo-${prefix}-${process.pid}-${sequence}`;
    await users.ensure(db, value, null);
    return value;
  }

  it("stores only bearer hashes while deterministic idempotent retry recovers credentials without plaintext columns", async () => {
    const owner = await uid("hash-owner");
    const created = await repos.createRoom({ uid: owner, requestId: `create-${newId()}` });
    expect(created.sessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(created.session.sessionId).toMatch(/^[0-9a-f-]{36}$/);

    const replay = await repos.createRoom({ uid: owner, requestId: created.requestId });
    expect(replay.sessionToken).toBe(created.sessionToken);
    expect(replay.session).toEqual(created.session);

    const invite = await repos.createInvite({
      uid: owner,
      token: created.sessionToken,
      idempotencyKey: `invite-${newId()}`,
      maxUses: 2,
      ttlSeconds: 3600,
    });
    expect(invite.inviteId).toMatch(/^i[0-9a-f]{32}$/);
    expect(invite.inviteCode).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const inviteReplay = await repos.createInvite({
      uid: owner,
      token: created.sessionToken,
      idempotencyKey: invite.idempotencyKey,
      maxUses: 2,
      ttlSeconds: 3600,
    });
    expect(inviteReplay).toEqual(invite);

    const rooms = await db.$client.unsafe(
      "SELECT * FROM collab_rooms WHERE id = $1",
      [created.roomId],
    );
    const invites = await db.$client.unsafe(
      "SELECT * FROM collab_invites WHERE id = $1",
      [invite.inviteId],
    );
    expect(JSON.stringify(rooms)).not.toContain(created.sessionToken);
    expect(JSON.stringify(invites)).not.toContain(invite.inviteCode);
    expect(rooms[0]).toMatchObject({
      token_hash: createHash("sha256").update(created.sessionToken).digest("hex"),
    });
    expect(invites[0]).toMatchObject({
      code_hash: createHash("sha256").update(invite.inviteCode).digest("hex"),
      uses: 0,
      max_uses: 2,
    });
    expect(Object.keys(rooms[0]!)).not.toContain("token");
    expect(Object.keys(invites[0]!)).not.toContain("code");
  });

  it("enforces active-owner and one-current-lease uniqueness in PostgreSQL", async () => {
    const owner = await uid("constraints");
    const room = await repos.createRoom({ uid: owner, requestId: `create-${newId()}` });
    const messageId = newId();
    const runId = newId();
    const secondRunId = newId();
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content) VALUES ($1, $2, 'user', 'constraint fixture')`,
      [messageId, room.session.sessionId],
    );
    await db.$client.unsafe(
      `INSERT INTO runs (id, session_id, status, prompt_message_id) VALUES ($1, $2, 'running', $3)`,
      [runId, room.session.sessionId, messageId],
    );
    await db.$client.unsafe(
      `INSERT INTO runs (id, session_id, status, prompt_message_id) VALUES ($1, $2, 'running', $3)`,
      [secondRunId, room.session.sessionId, messageId],
    );
    await db.$client.unsafe(
      `INSERT INTO collab_sender_leases
        (id, room_id, holder_participant_id, holder_user_id, run_id, generation, started_at, heartbeat_at)
       VALUES ($1, $2, $3, $4, $5, 1, now(), now())`,
      [newId(), room.roomId, room.member.participantId, owner, runId],
    );
    // UNEXECUTED fix-round-1 regression: a distinct run isolates room-active uniqueness.
    await expect(db.$client.unsafe(
      `INSERT INTO collab_sender_leases
        (id, room_id, holder_participant_id, holder_user_id, run_id, generation, started_at, heartbeat_at)
       VALUES ($1, $2, $3, $4, $5, 1, now(), now())`,
      [newId(), room.roomId, room.member.participantId, owner, secondRunId],
    )).rejects.toMatchObject({ code: "23505", constraint_name: "collab_sender_leases_room_active_uq" });

    // Same-run reuse is independent: another room leaves only run uniqueness to fail.
    const secondRoom = await repos.createRoom({ uid: owner, requestId: `create-${newId()}` });
    await expect(db.$client.unsafe(
      `INSERT INTO collab_sender_leases
        (id, room_id, holder_participant_id, holder_user_id, run_id, generation, started_at, heartbeat_at)
       VALUES ($1, $2, $3, $4, $5, 1, now(), now())`,
      [newId(), secondRoom.roomId, secondRoom.member.participantId, owner, runId],
    )).rejects.toMatchObject({ code: "23505", constraint_name: "collab_sender_leases_run_uq" });
    await expect(db.$client.unsafe(
      `INSERT INTO collab_members
        (room_id, user_id, participant_id, role, status, generation, joined_at, updated_at)
       VALUES ($1, $2, $3, 'owner', 'active', 1, now(), now())`,
      [room.roomId, await uid("second-owner"), `p${"0".repeat(32)}`],
    )).rejects.toMatchObject({ code: "23505" });
  });
});
