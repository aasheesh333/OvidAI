import { createHash, createHmac, randomBytes } from "node:crypto";
import { sql, type SQL } from "drizzle-orm";
import type { Db } from "./client.js";
import { withUidLock } from "./moneyRepos.js";
import { newId, sessions, users } from "./repos.js";

export const COLLAB_MAX_ACTIVE_MEMBERS = 50;
export const COLLAB_MAX_INVITE_USES = 50;
export const COLLAB_MAX_INVITE_TTL_SECONDS = 7 * 86_400;

export type CollabErrorCode =
  | "invalid_request"
  | "not_member"
  | "invite_invalid"
  | "invite_not_found"
  | "member_not_found"
  | "session_closed"
  | "session_full"
  | "owner_not_removable"
  | "request_already_used"
  | "temporarily_unavailable";

export class CollabError extends Error {
  constructor(
    readonly code: CollabErrorCode,
    readonly status = ({
      invalid_request: 400,
      not_member: 403,
      invite_invalid: 403,
      invite_not_found: 404,
      member_not_found: 404,
      session_closed: 409,
      session_full: 409,
      owner_not_removable: 409,
      request_already_used: 409,
      temporarily_unavailable: 503,
    } satisfies Record<CollabErrorCode, number>)[code],
  ) {
    super(code);
    this.name = "CollabError";
  }
}

export interface CollabMemberDto {
  participantId: string;
  role: "owner" | "participant";
  status: "active" | "left" | "revoked";
  displayName?: string;
}

export interface CollabSessionDto {
  schemaVersion: 1;
  sessionId: string;
  ownerParticipantId: string;
  lifecycle: "active" | "closing" | "closed";
}

export interface CollabRoomResult {
  roomId: string;
  requestId: string;
  sessionToken: string;
  session: CollabSessionDto;
  member: CollabMemberDto;
  cursor: "v1:0";
}

export interface CollabInviteResult {
  inviteId: string;
  inviteCode: string;
  expiresAt: string;
  maxUses: number;
  idempotencyKey: string;
}

export interface CollabJoinResult {
  member: CollabMemberDto;
  cursor: "v1:0";
}

export interface CollabAuthorization {
  roomId: string;
  sessionId: string;
  ownerUserId: string;
  participantId: string;
  role: "owner" | "participant";
  roomGeneration: number;
  membershipGeneration: number;
}

interface CollabReposOptions {
  authoritySecret: string;
  /** Internal: AccountAdmission already holds this UID's lock. */
  accountLock?: boolean;
}

interface RoomRow {
  id: string;
  token_hash: string;
  session_id: string;
  owner_user_id: string;
  request_id: string;
  lifecycle: "active" | "closing" | "closed";
  generation: number | string;
  close_request_id: string | null;
}

interface MemberRow {
  room_id: string;
  user_id: string;
  participant_id: string;
  role: "owner" | "participant";
  status: "active" | "left" | "revoked";
  display_name: string | null;
  generation: number | string;
  join_request_id: string | null;
  join_invite_hash: string | null;
}

interface InviteRow {
  id: string;
  room_id: string;
  code_hash: string;
  issued_by_user_id: string;
  idempotency_key: string;
  issued_generation: number | string;
  max_uses: number;
  uses: number;
  expires_at: Date | string;
  revoked_at: Date | string | null;
  created_at: Date | string;
  expired?: boolean;
}

function digest(value: string): string {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

function requestKey(value: string): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(value)) throw new CollabError("invalid_request");
  return value;
}

function iso(value: Date | string): string {
  return (value instanceof Date ? value : new Date(value)).toISOString();
}

function memberDto(row: MemberRow): CollabMemberDto {
  return {
    participantId: row.participant_id,
    role: row.role,
    status: row.status,
    ...(row.display_name === null ? {} : { displayName: row.display_name }),
  };
}

function sessionDto(room: RoomRow, ownerParticipantId: string): CollabSessionDto {
  return {
    schemaVersion: 1,
    sessionId: room.session_id,
    ownerParticipantId,
    lifecycle: room.lifecycle,
  };
}

async function query<T>(db: Db, statement: SQL): Promise<T[]> {
  return await db.execute(statement) as unknown as T[];
}

async function manualTransaction<T>(db: Db, fn: (tx: Db) => Promise<T>): Promise<T> {
  await db.execute(sql`BEGIN`);
  try {
    const result = await fn(db);
    await db.execute(sql`COMMIT`);
    return result;
  } catch (error) {
    try { await db.execute(sql`ROLLBACK`); } catch { /* the UID lock cleanup also rolls back */ }
    throw error;
  }
}

export class CollabRepos {
  private readonly accountLock: boolean;

  constructor(
    private readonly db: Db,
    private readonly options: CollabReposOptions,
  ) {
    this.accountLock = options.accountLock ?? true;
  }

  private authoritySecret(): string {
    if (this.options.authoritySecret.length < 32) {
      throw new Error("collaboration authority secret must be at least 32 bytes");
    }
    return this.options.authoritySecret;
  }

  /**
   * A supplied handle is already reserved by AccountAdmission/final cleanup.
   * Without one, retain the ordinary UID-lock path so immediate/direct deletion
   * fencing gets its own reserved connection. Manual BEGIN never targets the
   * root pool, whose statements could otherwise land on different connections.
   */
  admitted(connection?: Db): CollabRepos {
    return new CollabRepos(connection ?? this.db, {
      ...this.options,
      accountLock: connection === undefined,
    });
  }

  private async locked<T>(uid: string, fn: (tx: Db) => Promise<T>): Promise<T> {
    if (!this.accountLock) return manualTransaction(this.db, fn);
    return withUidLock(this.db, uid, (locked) => manualTransaction(locked, fn));
  }

  private token(roomId: string, uid: string, requestId: string): string {
    return createHmac("sha256", this.authoritySecret())
      .update(`room:${roomId}\0${uid}\0${requestId}`, "utf8")
      .digest("base64url");
  }

  private inviteCode(inviteId: string): string {
    return createHmac("sha256", this.authoritySecret())
      .update(`invite:${inviteId}`, "utf8")
      .digest("base64url");
  }

  private async assertAccount(tx: Db, uid: string): Promise<void> {
    const rows = await query<{ allowed: boolean }>(tx, sql`
      SELECT EXISTS (
        SELECT 1 FROM users u
        WHERE u.uid = ${uid}
          AND NOT EXISTS (
            SELECT 1 FROM account_deletions d
            WHERE d.uid = u.uid AND d.state NOT IN ('active','cancelled')
          )
      ) AS allowed`);
    if (rows[0]?.allowed !== true) throw new CollabError("not_member");
  }

  private async roomForUpdate(tx: Db, token: string): Promise<RoomRow> {
    const rows = await query<RoomRow>(tx, sql`
      SELECT id, token_hash, session_id, owner_user_id, request_id, lifecycle,
             generation, close_request_id
      FROM collab_rooms WHERE token_hash = ${digest(token)} FOR UPDATE`);
    const room = rows[0];
    if (room === undefined) throw new CollabError("not_member");
    return room;
  }

  private async member(tx: Db, roomId: string, uid: string): Promise<MemberRow | null> {
    const rows = await query<MemberRow>(tx, sql`
      SELECT room_id, user_id, participant_id, role, status, display_name,
             generation, join_request_id, join_invite_hash
      FROM collab_members WHERE room_id = ${roomId} AND user_id = ${uid}`);
    return rows[0] ?? null;
  }

  private async activeMember(tx: Db, room: RoomRow, uid: string): Promise<MemberRow> {
    const member = await this.member(tx, room.id, uid);
    if (member === null || member.status !== "active") throw new CollabError("not_member");
    return member;
  }

  private async activeOwner(tx: Db, room: RoomRow, uid: string): Promise<MemberRow> {
    const owner = await this.activeMember(tx, room, uid);
    if (owner.role !== "owner" || room.owner_user_id !== uid) throw new CollabError("not_member");
    return owner;
  }

  private requireActive(room: RoomRow): void {
    if (room.lifecycle !== "active") throw new CollabError("session_closed");
  }

  private async advanceGeneration(tx: Db, roomId: string): Promise<number> {
    const rows = await query<{ generation: number | string }>(tx, sql`
      UPDATE collab_rooms SET generation = generation + 1, updated_at = now()
      WHERE id = ${roomId} RETURNING generation`);
    const generation = Number(rows[0]!.generation);
    await tx.execute(sql`
      UPDATE collab_members SET generation = ${generation}, updated_at = now()
      WHERE room_id = ${roomId} AND status = 'active'`);
    return generation;
  }

  private async cancelTurns(
    tx: Db,
    scope: { roomIds?: readonly string[]; actorUserId?: string; participantId?: string },
  ): Promise<void> {
    const roomIds = scope.roomIds ?? [];
    const roomScope = roomIds.length === 0
      ? sql`false`
      : sql`t.room_id IN (${sql.join(roomIds.map((id) => sql`${id}`), sql`,`)})`;
    const actorScope = scope.actorUserId === undefined
      ? sql`false`
      : sql`t.actor_user_id = ${scope.actorUserId}`;
    const participantScope = scope.participantId === undefined
      ? sql`true`
      : sql`t.participant_id = ${scope.participantId}`;
    await tx.execute(sql`
      WITH affected AS (
        SELECT t.id, t.run_id, t.room_id
        FROM collab_turns t
        WHERE (${roomScope} OR ${actorScope}) AND ${participantScope}
          AND t.status IN ('queued','running')
      ), marked_turns AS (
        UPDATE collab_turns t SET cancel_requested_at = COALESCE(t.cancel_requested_at, now()), updated_at = now()
        FROM affected a WHERE t.id = a.id
        RETURNING t.id
      ), marked_runs AS (
        UPDATE runs r SET cancel_requested = true
        FROM affected a WHERE r.id = a.run_id
        RETURNING r.id
      )
      UPDATE collab_sender_leases l
      SET cancel_requested_at = COALESCE(l.cancel_requested_at, now())
      FROM affected a
      WHERE l.run_id = a.run_id AND l.released_at IS NULL`);
  }

  async createRoom(input: {
    uid: string;
    requestId: string;
    sessionId?: string;
    email?: string | null;
    displayName?: string | null;
  }): Promise<CollabRoomResult> {
    const requestId = requestKey(input.requestId);
    return this.locked(input.uid, async (tx) => {
      await users.ensure(tx, input.uid, input.email ?? null);
      await this.assertAccount(tx, input.uid);
      const existing = await query<RoomRow>(tx, sql`
        SELECT id, token_hash, session_id, owner_user_id, request_id, lifecycle, generation, close_request_id
        FROM collab_rooms WHERE owner_user_id = ${input.uid} AND request_id = ${requestId}
        FOR UPDATE`);
      if (existing[0] !== undefined) {
        const room = existing[0];
        this.requireActive(room);
        if (input.sessionId !== undefined && input.sessionId !== room.session_id) {
          throw new CollabError("request_already_used");
        }
        const owner = await this.activeOwner(tx, room, input.uid);
        const token = this.token(room.id, input.uid, requestId);
        if (digest(token) !== room.token_hash) throw new CollabError("request_already_used");
        return {
          roomId: room.id, requestId, sessionToken: token,
          session: sessionDto(room, owner.participant_id), member: memberDto(owner), cursor: "v1:0",
        };
      }

      let sessionId = input.sessionId;
      if (sessionId !== undefined) {
        const owned = await query<{ id: string }>(tx, sql`
          SELECT id FROM sessions
          WHERE id = ${sessionId} AND user_id = ${input.uid} AND deleted_at IS NULL`);
        if (owned[0] === undefined) throw new CollabError("not_member");
        const alreadyMapped = await query<{ id: string }>(tx, sql`
          SELECT id FROM collab_rooms WHERE session_id = ${sessionId}`);
        if (alreadyMapped[0] !== undefined) throw new CollabError("request_already_used");
      } else {
        sessionId = (await sessions.create(tx, input.uid)).id;
      }
      const roomId = newId();
      const participantId = `p${randomBytes(16).toString("hex")}`;
      const token = this.token(roomId, input.uid, requestId);
      await tx.execute(sql`
        INSERT INTO collab_rooms
          (id, token_hash, session_id, owner_user_id, request_id, lifecycle, generation, created_at, updated_at)
        VALUES (${roomId}, ${digest(token)}, ${sessionId}, ${input.uid}, ${requestId}, 'active', 1, now(), now())`);
      const displayName = input.displayName?.trim() || null;
      await tx.execute(sql`
        INSERT INTO collab_members
          (room_id, user_id, participant_id, role, status, display_name, generation, joined_at, updated_at)
        VALUES (${roomId}, ${input.uid}, ${participantId}, 'owner', 'active', ${displayName}, 1, now(), now())`);
      const room: RoomRow = {
        id: roomId, token_hash: digest(token), session_id: sessionId, owner_user_id: input.uid,
        request_id: requestId, lifecycle: "active", generation: 1, close_request_id: null,
      };
      const member: MemberRow = {
        room_id: roomId, user_id: input.uid, participant_id: participantId, role: "owner",
        status: "active", display_name: displayName, generation: 1,
        join_request_id: null, join_invite_hash: null,
      };
      return {
        roomId, requestId, sessionToken: token,
        session: sessionDto(room, participantId), member: memberDto(member), cursor: "v1:0",
      };
    });
  }

  async createInvite(input: {
    uid: string;
    token: string;
    idempotencyKey: string;
    maxUses: number;
    ttlSeconds: number;
  }): Promise<CollabInviteResult> {
    const key = requestKey(input.idempotencyKey);
    if (!Number.isInteger(input.maxUses) || input.maxUses < 1 || input.maxUses > COLLAB_MAX_INVITE_USES ||
        !Number.isInteger(input.ttlSeconds) || input.ttlSeconds < 1 || input.ttlSeconds > COLLAB_MAX_INVITE_TTL_SECONDS) {
      throw new CollabError("invalid_request");
    }
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      this.requireActive(room);
      await this.activeOwner(tx, room, input.uid);
      const prior = await query<InviteRow>(tx, sql`
        SELECT id, room_id, code_hash, issued_by_user_id, idempotency_key, issued_generation,
               max_uses, uses, expires_at, revoked_at, created_at
        FROM collab_invites
        WHERE room_id = ${room.id} AND issued_by_user_id = ${input.uid} AND idempotency_key = ${key}
        FOR UPDATE`);
      if (prior[0] !== undefined) {
        const invite = prior[0];
        const ttl = Math.round((new Date(invite.expires_at).getTime() - new Date(invite.created_at).getTime()) / 1000);
        if (invite.max_uses !== input.maxUses || ttl !== input.ttlSeconds || invite.revoked_at !== null) {
          throw new CollabError("request_already_used");
        }
        return {
          inviteId: invite.id, inviteCode: this.inviteCode(invite.id),
          expiresAt: iso(invite.expires_at), maxUses: invite.max_uses, idempotencyKey: key,
        };
      }
      const inviteId = `i${randomBytes(16).toString("hex")}`;
      const code = this.inviteCode(inviteId);
      const inserted = await query<InviteRow>(tx, sql`
        INSERT INTO collab_invites
          (id, room_id, code_hash, issued_by_user_id, idempotency_key, issued_generation,
           max_uses, uses, expires_at, created_at)
        VALUES (${inviteId}, ${room.id}, ${digest(code)}, ${input.uid}, ${key}, ${room.generation},
                ${input.maxUses}, 0, now() + (${input.ttlSeconds} * interval '1 second'), now())
        RETURNING id, room_id, code_hash, issued_by_user_id, idempotency_key, issued_generation,
                  max_uses, uses, expires_at, revoked_at, created_at`);
      const invite = inserted[0]!;
      return {
        inviteId, inviteCode: code, expiresAt: iso(invite.expires_at),
        maxUses: invite.max_uses, idempotencyKey: key,
      };
    });
  }

  async revokeInvite(input: { uid: string; token: string; inviteId: string }): Promise<void> {
    if (!/^i[0-9a-f]{32}$/.test(input.inviteId)) throw new CollabError("invite_not_found");
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      this.requireActive(room);
      await this.activeOwner(tx, room, input.uid);
      const rows = await query<{ id: string }>(tx, sql`
        UPDATE collab_invites SET revoked_at = COALESCE(revoked_at, now())
        WHERE id = ${input.inviteId} AND room_id = ${room.id}
        RETURNING id`);
      if (rows[0] === undefined) throw new CollabError("invite_not_found");
    });
  }

  async join(input: {
    uid: string;
    token: string;
    inviteCode: string;
    idempotencyKey: string;
    displayName?: string | null;
    email?: string | null;
  }): Promise<CollabJoinResult> {
    const key = requestKey(input.idempotencyKey);
    const inviteHash = digest(input.inviteCode);
    return this.locked(input.uid, async (tx) => {
      await users.ensure(tx, input.uid, input.email ?? null);
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      this.requireActive(room);
      let member = await this.member(tx, room.id, input.uid);
      if (member?.status === "revoked") throw new CollabError("not_member");
      if (member?.status === "active") {
        if (member.join_request_id === key && member.join_invite_hash !== null &&
            member.join_invite_hash !== inviteHash) {
          throw new CollabError("request_already_used");
        }
        return { member: memberDto(member), cursor: "v1:0" };
      }
      if (member?.status === "left" && member.join_request_id === key) {
        throw new CollabError("request_already_used");
      }
      if (!/^[A-Za-z0-9_-]{43}$/.test(input.inviteCode)) throw new CollabError("invite_invalid");
      const invites = await query<InviteRow>(tx, sql`
        SELECT id, room_id, code_hash, issued_by_user_id, idempotency_key, issued_generation,
               max_uses, uses, expires_at, revoked_at, created_at, expires_at <= now() AS expired
        FROM collab_invites WHERE room_id = ${room.id} AND code_hash = ${inviteHash}
        FOR UPDATE`);
      const invite = invites[0];
      if (invite === undefined || invite.revoked_at !== null || invite.uses >= invite.max_uses ||
          invite.expired === true) {
        throw new CollabError("invite_invalid");
      }
      const active = await query<{ count: number | string }>(tx, sql`
        SELECT count(*)::int AS count FROM collab_members WHERE room_id = ${room.id} AND status = 'active'`);
      if (Number(active[0]!.count) >= COLLAB_MAX_ACTIVE_MEMBERS) throw new CollabError("session_full");
      const displayName = input.displayName?.trim() || member?.display_name || null;
      if (member === null) {
        await tx.execute(sql`
          INSERT INTO collab_members
            (room_id, user_id, participant_id, role, status, display_name, generation,
             join_request_id, join_invite_hash, joined_at, updated_at)
          VALUES (${room.id}, ${input.uid}, ${`p${randomBytes(16).toString("hex")}`}, 'participant',
                  'active', ${displayName}, ${Number(room.generation) + 1}, ${key}, ${inviteHash}, now(), now())`);
      } else {
        await tx.execute(sql`
          UPDATE collab_members SET status = 'active', display_name = ${displayName},
            generation = ${Number(room.generation) + 1}, join_request_id = ${key},
            join_invite_hash = ${inviteHash}, joined_at = now(), updated_at = now(), revoked_at = NULL
          WHERE room_id = ${room.id} AND user_id = ${input.uid}`);
      }
      await this.advanceGeneration(tx, room.id);
      await tx.execute(sql`UPDATE collab_invites SET uses = uses + 1 WHERE id = ${invite.id}`);
      member = (await this.member(tx, room.id, input.uid))!;
      return { member: memberDto(member), cursor: "v1:0" };
    });
  }

  async authorize(input: { uid: string; token: string }): Promise<CollabAuthorization> {
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      const member = await this.activeMember(tx, room, input.uid);
      this.requireActive(room);
      return {
        roomId: room.id, sessionId: room.session_id, ownerUserId: room.owner_user_id,
        participantId: member.participant_id, role: member.role,
        roomGeneration: Number(room.generation), membershipGeneration: Number(member.generation),
      };
    });
  }

  async leave(input: { uid: string; token: string }): Promise<CollabJoinResult> {
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      this.requireActive(room);
      const existing = await this.member(tx, room.id, input.uid);
      if (existing?.status === "left") return { member: memberDto(existing), cursor: "v1:0" };
      if (existing === null || existing.status !== "active") throw new CollabError("not_member");
      if (existing.role === "owner") throw new CollabError("owner_not_removable");
      const generation = await this.advanceGeneration(tx, room.id);
      await tx.execute(sql`
        UPDATE collab_members SET status = 'left', generation = ${generation}, updated_at = now()
        WHERE room_id = ${room.id} AND user_id = ${input.uid}`);
      await this.cancelTurns(tx, { roomIds: [room.id], participantId: existing.participant_id });
      return { member: memberDto((await this.member(tx, room.id, input.uid))!), cursor: "v1:0" };
    });
  }

  async remove(input: { uid: string; token: string; participantId: string }): Promise<CollabJoinResult> {
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      this.requireActive(room);
      await this.activeOwner(tx, room, input.uid);
      const targets = await query<MemberRow>(tx, sql`
        SELECT room_id, user_id, participant_id, role, status, display_name,
               generation, join_request_id, join_invite_hash
        FROM collab_members WHERE room_id = ${room.id} AND participant_id = ${input.participantId}
        FOR UPDATE`);
      const target = targets[0];
      if (target === undefined) throw new CollabError("member_not_found");
      if (target.role === "owner") throw new CollabError("owner_not_removable");
      if (target.status === "revoked") return { member: memberDto(target), cursor: "v1:0" };
      const generation = await this.advanceGeneration(tx, room.id);
      await tx.execute(sql`
        UPDATE collab_members SET status = 'revoked', generation = ${generation},
          revoked_at = COALESCE(revoked_at, now()), updated_at = now()
        WHERE room_id = ${room.id} AND participant_id = ${input.participantId}`);
      await this.cancelTurns(tx, { roomIds: [room.id], participantId: target.participant_id });
      const rows = await query<MemberRow>(tx, sql`
        SELECT room_id, user_id, participant_id, role, status, display_name,
               generation, join_request_id, join_invite_hash
        FROM collab_members WHERE room_id = ${room.id} AND participant_id = ${input.participantId}`);
      return { member: memberDto(rows[0]!), cursor: "v1:0" };
    });
  }

  async close(input: { uid: string; token: string; idempotencyKey: string }): Promise<{ session: CollabSessionDto }> {
    const key = requestKey(input.idempotencyKey);
    return this.locked(input.uid, async (tx) => {
      await this.assertAccount(tx, input.uid);
      const room = await this.roomForUpdate(tx, input.token);
      if (room.lifecycle === "closed") {
        if (room.owner_user_id !== input.uid) throw new CollabError("not_member");
        await this.activeOwner(tx, room, input.uid);
        if (room.close_request_id !== key) throw new CollabError("request_already_used");
        const owner = await this.activeOwner(tx, room, input.uid);
        return { session: sessionDto(room, owner.participant_id) };
      }
      this.requireActive(room);
      const owner = await this.activeOwner(tx, room, input.uid);
      await tx.execute(sql`
        UPDATE collab_rooms SET lifecycle = 'closed', close_request_id = ${key}, updated_at = now()
        WHERE id = ${room.id}`);
      await this.advanceGeneration(tx, room.id);
      await tx.execute(sql`
        UPDATE collab_invites SET revoked_at = COALESCE(revoked_at, now())
        WHERE room_id = ${room.id}`);
      await this.cancelTurns(tx, { roomIds: [room.id] });
      return { session: sessionDto({ ...room, lifecycle: "closed" }, owner.participant_id) };
    });
  }

  async fenceAccount(uid: string): Promise<void> {
    return this.locked(uid, async (tx) => {
      const affected = await query<{ id: string; owner_user_id: string; lifecycle: string }>(tx, sql`
        SELECT id, owner_user_id, lifecycle FROM collab_rooms
        WHERE owner_user_id = ${uid}
           OR EXISTS (SELECT 1 FROM collab_members m WHERE m.room_id = collab_rooms.id AND m.user_id = ${uid})
        ORDER BY id FOR UPDATE`);
      const roomIds = affected.map((row) => row.id);
      const ownedRoomIds = affected.filter((row) => row.owner_user_id === uid).map((row) => row.id);
      const ownedActive = affected.filter((row) => row.owner_user_id === uid && row.lifecycle !== "closed").map((row) => row.id);
      const memberActive = await query<{ room_id: string }>(tx, sql`
        SELECT room_id FROM collab_members
        WHERE user_id = ${uid} AND status = 'active'
          AND room_id NOT IN (SELECT id FROM collab_rooms WHERE owner_user_id = ${uid})
        ORDER BY room_id FOR UPDATE`);
      for (const roomId of [...ownedActive, ...memberActive.map((row) => row.room_id)]) {
        await this.advanceGeneration(tx, roomId);
      }
      if (roomIds.length > 0) {
        const ids = sql.join(roomIds.map((id) => sql`${id}`), sql`,`);
        await tx.execute(sql`
          UPDATE collab_rooms SET lifecycle = 'closed', updated_at = now()
          WHERE id IN (${ids}) AND owner_user_id = ${uid} AND lifecycle IN ('active','closing')`);
        if (ownedRoomIds.length > 0) {
          const ownedIds = sql.join(ownedRoomIds.map((id) => sql`${id}`), sql`,`);
          await tx.execute(sql`
            UPDATE collab_invites SET revoked_at = COALESCE(revoked_at, now())
            WHERE issued_by_user_id = ${uid} OR room_id IN (${ownedIds})`);
        }
        await tx.execute(sql`
          UPDATE collab_members m SET status = 'revoked', generation = r.generation,
            revoked_at = COALESCE(m.revoked_at, now()), updated_at = now()
          FROM collab_rooms r
          WHERE r.id = m.room_id AND m.room_id IN (${ids}) AND m.user_id = ${uid} AND m.status = 'active'`);
        await tx.execute(sql`
          UPDATE collab_members m SET generation = r.generation, updated_at = now()
          FROM collab_rooms r
          WHERE r.id = m.room_id AND m.room_id IN (${ids}) AND m.status = 'active' AND m.generation <> r.generation`);
      }
      await this.cancelTurns(tx, { roomIds: ownedActive, actorUserId: uid });
    });
  }
}
