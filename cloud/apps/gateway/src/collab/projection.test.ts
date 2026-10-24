import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { createDb, migrate, newId, type Db } from "@ovid/db";

import { CollabProjection, CollabProjectionError } from "./projection.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const SCHEMA = "collab_projection_test";

const CANONICAL_TABLES = [
  "users",
  "account_deletions",
  "sessions",
  "messages",
  "runs",
  "run_usage",
  "session_event_mirror",
] as const;

// Task 2 metadata is still landing separately. Canonical transcript/model
// tables are cloned from real migrations above; only that absent metadata is
// fixture DDL, with no substitute transcript or run columns.
const FIXTURE_DDL = `
CREATE TABLE collab_rooms (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  owner_user_id text NOT NULL,
  lifecycle text NOT NULL,
  generation bigint NOT NULL DEFAULT 1
);
CREATE TABLE collab_members (
  room_id text NOT NULL,
  user_id text NOT NULL,
  participant_id text NOT NULL,
  role text NOT NULL,
  status text NOT NULL,
  display_name text,
  generation bigint NOT NULL DEFAULT 1,
  joined_at timestamptz NOT NULL,
  PRIMARY KEY (room_id, user_id),
  UNIQUE (room_id, participant_id)
);
CREATE TABLE collab_turns (
  id text PRIMARY KEY,
  room_id text NOT NULL,
  participant_id text NOT NULL,
  run_id text,
  user_message_id text,
  model text,
  created_at timestamptz NOT NULL
);
CREATE TABLE collab_sender_leases (
  id text PRIMARY KEY,
  room_id text NOT NULL,
  holder_participant_id text NOT NULL,
  run_id text NOT NULL,
  started_at timestamptz NOT NULL,
  heartbeat_at timestamptz NOT NULL,
  released_at timestamptz
);
`;

interface Fixture {
  roomId: string;
  sessionId: string;
  ownerUid: string;
  guestUid: string;
  ownerParticipantId: string;
  guestParticipantId: string;
}

describe.skipIf(!TEST_DATABASE_URL)("CollabProjection real Postgres", () => {
  let db: Db;
  let sequence = 0;
  const queries: string[] = [];

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!, { max: 1 });
    await db.$client.unsafe(`SET client_min_messages TO WARNING`);
    await db.$client.unsafe(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
    await db.$client.unsafe(`CREATE SCHEMA ${SCHEMA}`);
    for (const table of CANONICAL_TABLES) {
      await db.$client.unsafe(
        `CREATE TABLE ${SCHEMA}.${table} (LIKE public.${table} INCLUDING ALL)`,
      );
    }
    await db.$client.unsafe(`SET search_path TO ${SCHEMA}`);
    await db.$client.unsafe(FIXTURE_DDL);

    const mutable = db.$client as unknown as {
      unsafe: (query: string, parameters?: readonly unknown[]) => Promise<unknown>;
    };
    const original = mutable.unsafe.bind(db.$client);
    mutable.unsafe = async (query, parameters) => {
      queries.push(query);
      return original(query, parameters);
    };
  }, 60_000);

  afterAll(async () => {
    await db?.$client.unsafe(`SET search_path TO public`);
    await db?.$client.unsafe(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
    await db?.$client.end({ timeout: 5 });
  });

  beforeEach(() => {
    queries.length = 0;
  });

  async function fixture(withGuest = true): Promise<Fixture> {
    sequence += 1;
    const n = sequence;
    const value: Fixture = {
      roomId: newId(),
      sessionId: newId(),
      ownerUid: `owner-${n}`,
      guestUid: `guest-${n}`,
      ownerParticipantId: `participant-owner-${n}`,
      guestParticipantId: `participant-guest-${n}`,
    };
    await db.$client.unsafe(
      `INSERT INTO users (uid) VALUES ($1), ($2)`,
      [value.ownerUid, value.guestUid],
    );
    await db.$client.unsafe(
      `INSERT INTO sessions (id, user_id) VALUES ($1, $2)`,
      [value.sessionId, value.ownerUid],
    );
    await db.$client.unsafe(
      `INSERT INTO collab_rooms (id, session_id, owner_user_id, lifecycle)
       VALUES ($1, $2, $3, 'active')`,
      [value.roomId, value.sessionId, value.ownerUid],
    );
    await db.$client.unsafe(
      `INSERT INTO collab_members
         (room_id, user_id, participant_id, role, status, display_name, joined_at)
       VALUES
         ($1, $2, $4, 'owner', 'active', 'Owner Member', '2026-01-01T00:00:00Z'),
         ($1, $3, $5, 'participant', $6, 'Guest Member', '2026-01-01T00:00:01Z')`,
      [
        value.roomId,
        value.ownerUid,
        value.guestUid,
        value.ownerParticipantId,
        value.guestParticipantId,
        withGuest ? "active" : "revoked",
      ],
    );
    queries.length = 0;
    return value;
  }

  function projection(): CollabProjection {
    return new CollabProjection(db);
  }

  async function seedThreeMessages(f: Fixture): Promise<string[]> {
    const ids = [newId(), newId(), newId()];
    for (const [index, id] of ids.entries()) {
      await db.$client.unsafe(
        `INSERT INTO messages (id, session_id, role, content, created_at)
         VALUES ($1, $2, 'user', $3, $4)`,
        [id, f.sessionId, `message ${index + 1}`, `2026-04-01T00:00:0${index + 1}Z`],
      );
    }
    return ids;
  }

  it("projects only canonical visible content with stable IDs and an authoritative lease", async () => {
    const f = await fixture();
    const userId = "00000000-0000-0000-0000-000000000001";
    const assistantId = "00000000-0000-0000-0000-000000000002";
    const runId = "00000000-0000-0000-0000-000000000101";
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, reasoning, created_at)
       VALUES
       ($1, $3, 'user', 'Canonical question', NULL, '2026-01-01T00:00:01Z'),
       ($2, $3, 'assistant', 'Canonical answer', 'PRIVATE_REASONING', '2026-01-01T00:00:05Z'),
       ('00000000-0000-0000-0000-000000000003', $3, 'system', 'PRIVATE_SCRATCH', NULL, '2026-01-01T00:00:05.001Z')`,
      [userId, assistantId, f.sessionId],
    );
    await db.$client.unsafe(
      `INSERT INTO runs
         (id, session_id, prompt_message_id, status, created_at, started_at, finished_at)
       VALUES ($1, $2, $3, 'completed', '2026-01-01T00:00:01.500Z',
               '2026-01-01T00:00:02Z', '2026-01-01T00:00:07Z')`,
      [runId, f.sessionId, userId],
    );
    await db.$client.unsafe(
      `INSERT INTO run_usage (id, user_id, session_id, run_id, model)
       VALUES ($1, $2, $3, $4, 'canonical-model')`,
      [newId(), f.guestUid, f.sessionId, runId],
    );
    await db.$client.unsafe(
      `INSERT INTO collab_turns
         (id, room_id, participant_id, run_id, user_message_id, model, created_at)
       VALUES ($5, $1, $2, $3, $4, 'canonical-model', '2026-01-01T00:00:01Z')`,
      [f.roomId, f.guestParticipantId, runId, userId, newId()],
    );
    await db.$client.unsafe(
      `INSERT INTO collab_sender_leases
         (id, room_id, holder_participant_id, run_id, started_at, heartbeat_at)
       VALUES ('lease-1', $1, $2, $3, '2026-01-01T00:00:01Z', '2026-01-01T00:00:08Z')`,
      [f.roomId, f.guestParticipantId, runId],
    );
    const mirrors = [
      ["1000-0", "run_started", "2026-01-01T00:00:02Z", { runId, model: "CLIENT_MODEL", usage: { total: 999 } }],
      // Actual producer shape: run_started_retry has no runId.
      ["1000-1", "run_started_retry", "2026-01-01T00:00:02.500Z", { attempt: 2, nextBackoffMs: 3000 }],
      ["1001-0", "tool_started", "2026-01-01T00:00:03Z", { runId, callId: "call-1", name: "safe_tool", input: "PRIVATE_TOOL_INPUT" }],
      ["1002-0", "tool_completed", "2026-01-01T00:00:04Z", { runId, callId: "call-1", name: "safe_tool", isError: false, content: "PRIVATE_TOOL_OUTPUT" }],
      ["1003-0", "message_completed", "2026-01-01T00:00:05Z", { messageId: assistantId, content: "DUPLICATE_CLIENT_TEXT", reasoning: "PRIVATE_REASONING" }],
      // Actual registerArtifact producer shape: no runId and a signed URL.
      ["1004-0", "artifact_created", "2026-01-01T00:00:06Z", { artifactId: "artifact-1", name: "safe.txt", sessionId: f.sessionId, sizeBytes: 12, contentType: "text/plain", url: "https://signed.invalid/PRIVATE_URL", expiresAt: "2026-01-02T00:00:00Z" }],
      ["1005-0", "run_completed", "2026-01-01T00:00:07Z", { runId, usage: { total: 999 }, author: "CLIENT_AUTHOR" }],
    ] as const;
    for (const [seq, type, ts, payload] of mirrors) {
      await db.$client.unsafe(
        `INSERT INTO session_event_mirror (session_id, seq, type, payload, ts)
         VALUES ($1, $2, $3, $4::jsonb, $5)`,
        [f.sessionId, seq, type, JSON.stringify(payload), ts],
      );
    }
    queries.length = 0;

    const page = await projection().page({
      roomId: f.roomId,
      viewerUid: f.guestUid,
      cursor: null,
      limit: 100,
    });

    expect(page.schemaVersion).toBe(1);
    expect(page.events.map((event) => event.eventSequence)).toEqual([1, 2, 3, 4, 5, 6, 7, 8]);
    expect(page.events.map((event) => event.eventId)).toEqual([
      `message:${userId}`,
      "mirror:1000-0",
      "mirror:1000-1",
      "mirror:1001-0",
      "mirror:1002-0",
      `message:${assistantId}`,
      "mirror:1004-0",
      "mirror:1005-0",
    ]);
    expect(page.nextCursor).toMatch(/^v1:/);
    expect(page.hasMore).toBe(false);
    expect(page.events[0]).toMatchObject({
      kind: "message",
      senderParticipantId: f.guestParticipantId,
      senderDisplayName: "Guest Member",
      payload: { text: "Canonical question", role: "user" },
    });
    expect(page.events[1]).toMatchObject({
      kind: "modelStatus",
      senderParticipantId: f.guestParticipantId,
      payload: { runId, status: "running", streaming: true, model: "canonical-model" },
    });
    expect(page.events[2]).toMatchObject({
      kind: "modelStatus",
      senderParticipantId: f.guestParticipantId,
      payload: { runId, status: "queued", streaming: false, model: "canonical-model" },
    });
    expect(page.events[3]?.payload).toEqual({ runId, callId: "call-1", name: "safe_tool", status: "running" });
    expect(page.events[4]?.payload).toEqual({ runId, callId: "call-1", name: "safe_tool", isError: false, status: "completed" });
    expect(page.events[5]).toMatchObject({
      kind: "message",
      senderParticipantId: f.guestParticipantId,
      payload: { text: "Canonical answer", role: "assistant", model: "canonical-model" },
    });
    expect(page.events[6]).toMatchObject({
      senderParticipantId: f.guestParticipantId,
      payload: {
        runId,
        artifactId: "artifact-1",
        name: "safe.txt",
        sizeBytes: 12,
        contentType: "text/plain",
      },
    });
    expect(page.events[7]?.payload).toMatchObject({ runId, status: "completed", streaming: false });
    const wire = JSON.stringify(page);
    for (const forbidden of ["PRIVATE_", "DUPLICATE_", "CLIENT_", "signed.invalid", "usage", "reasoning"]) {
      expect(wire).not.toContain(forbidden);
    }
    expect(queries.join("\n")).not.toMatch(/\bcollab_events\b/i);
    expect(queries.join("\n")).not.toMatch(/\b(?:INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\s+INTO?\b/i);

    const replay = await projection().page({ roomId: f.roomId, viewerUid: f.guestUid, cursor: null, limit: 100 });
    expect(replay).toEqual(page);

    const state = await projection().state({ roomId: f.roomId, viewerUid: f.guestUid });
    expect(state).toEqual({
      schemaVersion: 1,
      session: {
        schemaVersion: 1,
        sessionId: f.sessionId,
        ownerParticipantId: f.ownerParticipantId,
        lifecycle: "active",
      },
      member: {
        participantId: f.guestParticipantId,
        role: "participant",
        status: "active",
        displayName: "Guest Member",
      },
      members: [
        { participantId: f.ownerParticipantId, role: "owner", status: "active", displayName: "Owner Member" },
        { participantId: f.guestParticipantId, role: "participant", status: "active", displayName: "Guest Member" },
      ],
      initialMembers: [
        { participantId: f.ownerParticipantId, role: "owner", status: "active", displayName: "Owner Member" },
      ],
      replayThroughSequence: 8,
      cursor: "v1:0",
      turn: {
        holderParticipantId: f.guestParticipantId,
        runId,
        startedAt: "2026-01-01T00:00:01.000Z",
        heartbeatAt: "2026-01-01T00:00:08.000Z",
      },
    });
  });

  it("leaves actor unknown when runless producer events have no lease evidence", async () => {
    const f = await fixture();
    await db.$client.unsafe(
      `INSERT INTO session_event_mirror (session_id, seq, type, payload, ts)
       VALUES
       ($1, '2000-0', 'run_started_retry', '{"attempt":2,"nextBackoffMs":3000}'::jsonb, '2026-01-02T00:00:00Z'),
       ($1, '2001-0', 'artifact_created', $2::jsonb, '2026-01-02T00:00:01Z')`,
      [
        f.sessionId,
        JSON.stringify({
          artifactId: "artifact-unknown",
          name: "unknown.txt",
          sessionId: f.sessionId,
          sizeBytes: 1,
          contentType: "text/plain",
          url: "https://signed.invalid/not-forwarded",
          expiresAt: "2026-01-03T00:00:00Z",
        }),
      ],
    );

    const page = await projection().page({ roomId: f.roomId, viewerUid: f.guestUid, cursor: null, limit: 100 });

    expect(page.events).toHaveLength(2);
    expect(page.events.map((event) => event.senderParticipantId)).toEqual(["", ""]);
    expect(page.events.every((event) => event.senderDisplayName === undefined)).toBe(true);
    expect(page.events.every((event) => event.payload.runId === null)).toBe(true);
    expect(page.events[0]?.senderParticipantId).not.toBe(f.ownerParticipantId);
    expect(page.events[1]?.senderParticipantId).not.toBe(f.ownerParticipantId);
  });

  it("caps pages at 100, replays without duplicates, and leaves an empty cursor unchanged", async () => {
    const f = await fixture();
    const messageIds: string[] = [];
    for (let index = 1; index <= 101; index += 1) {
      const id = newId();
      messageIds.push(id);
      await db.$client.unsafe(
        `INSERT INTO messages (id, session_id, role, content, created_at)
         VALUES ($1, $2, 'user', $3, $4)`,
        [
          id,
          f.sessionId,
          `message ${index}`,
          new Date(Date.UTC(2026, 1, 1, 0, 0, 0, index)).toISOString(),
        ],
      );
    }

    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 1000 });
    expect(first.events).toHaveLength(100);
    expect(first.events.map((event) => event.eventSequence)).toEqual(Array.from({ length: 100 }, (_, i) => i + 1));
    expect(first.nextCursor).toMatch(/^v1:/);
    expect(first.hasMore).toBe(true);
    expect(await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 1000 })).toEqual(first);

    const second = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 });
    expect(second.events.map((event) => event.eventId)).toEqual([`message:${messageIds[100]}`]);
    expect(second.nextCursor).toMatch(/^v1:/);
    expect(second.hasMore).toBe(false);
    expect(second.events.some((event) => first.events.some((old) => old.eventId === event.eventId))).toBe(false);

    const empty = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: second.nextCursor, limit: 100 });
    expect(empty).toEqual({ schemaVersion: 1, events: [], nextCursor: second.nextCursor, hasMore: false });

    const clampedLow = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 0 });
    expect(clampedLow.events).toHaveLength(1);
    expect(clampedLow.nextCursor).toMatch(/^v1:/);
  });

  it("resets when middle-history deletion would otherwise renumber an unseen event", async () => {
    const f = await fixture();
    const ids = await seedThreeMessages(f);
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 2 });
    await db.$client.unsafe(`DELETE FROM messages WHERE id = $1`, [ids[1]]);

    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 }))
      .rejects.toMatchObject({ code: "cursor_reset" });
  });

  it("resets when a backdated insertion lands inside the delivered prefix", async () => {
    const f = await fixture();
    await seedThreeMessages(f);
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 2 });
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES ($1, $2, 'user', 'backdated', '2026-04-01T00:00:01.500Z')`,
      [newId(), f.sessionId],
    );

    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 }))
      .rejects.toMatchObject({ code: "cursor_reset" });
  });

  it("resets when a delivered event becomes invisible instead of skipping its successor", async () => {
    const f = await fixture();
    const ids = await seedThreeMessages(f);
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 2 });
    await db.$client.unsafe(`UPDATE messages SET role = 'system' WHERE id = $1`, [ids[0]]);

    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 }))
      .rejects.toMatchObject({ code: "cursor_reset" });
  });

  it("replays an insertion after the delivered prefix without duplicates", async () => {
    const f = await fixture();
    await seedThreeMessages(f);
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 2 });
    const lateId = newId();
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES ($1, $2, 'user', 'late', '2026-04-01T00:00:04Z')`,
      [lateId, f.sessionId],
    );

    const next = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 });
    expect(next.events.map((event) => event.eventId)).toContain(`message:${lateId}`);
    expect(next.events.map((event) => event.eventSequence)).toEqual([3, 4]);
    expect(next.events.some((event) => first.events.some((old) => old.eventId === event.eventId))).toBe(false);
  });

  it("resets when a same-time backdated insert sorts before an already delivered message", async () => {
    const f = await fixture();
    const firstId = "00000000-0000-7000-8000-000000000002";
    const insertedId = "00000000-0000-7000-8000-000000000001";
    const thirdId = "00000000-0000-7000-8000-000000000003";
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES
       ($1, $3, 'user', 'first delivered', '2026-04-02T00:00:00Z'),
       ($2, $3, 'user', 'third delivered', '2026-04-02T00:00:01Z')`,
      [firstId, thirdId, f.sessionId],
    );
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 1 });
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES ($1, $2, 'user', 'same-time predecessor', '2026-04-02T00:00:00Z')`,
      [insertedId, f.sessionId],
    );

    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 }))
      .rejects.toMatchObject({ code: "cursor_reset" });
  });

  it("resets only malformed, future, or pruned cursors", async () => {
    const f = await fixture();
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at)
       VALUES ('one', $1, 'user', 'one', '2026-03-01T00:00:01Z'),
              ('two', $1, 'user', 'two', '2026-03-01T00:00:02Z')`,
      [f.sessionId],
    );
    const first = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: null, limit: 1 });
    const valid = await projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 });
    expect(valid.events).toHaveLength(1);
    for (const cursor of ["", "v2:1", "v1:nope", "v1:-1", "v1:3", "v1:9007199254740992"]) {
      await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor, limit: 100 }))
        .rejects.toMatchObject({ code: "cursor_reset" });
    }

    await db.$client.unsafe(`DELETE FROM messages WHERE session_id = $1`, [f.sessionId]);
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: first.nextCursor, limit: 100 }))
      .rejects.toMatchObject({ code: "cursor_reset" });
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: "v1:0", limit: 100 }))
      .resolves.toEqual({ schemaVersion: 1, events: [], nextCursor: "v1:0", hasMore: false });
  });

  it("authorizes denied readers before decoding a malformed cursor", async () => {
    const f = await fixture();
    const malformed = "definitely-not-a-cursor";

    await expect(projection().page({ roomId: f.roomId, viewerUid: "wrong-user", cursor: malformed, limit: 100 }))
      .rejects.toMatchObject({ code: "not_member" });

    await db.$client.unsafe(`UPDATE collab_members SET status = 'revoked' WHERE room_id = $1 AND user_id = $2`, [f.roomId, f.guestUid]);
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.guestUid, cursor: malformed, limit: 100 }))
      .rejects.toMatchObject({ code: "not_member" });

    await db.$client.unsafe(`UPDATE collab_rooms SET lifecycle = 'closed' WHERE id = $1`, [f.roomId]);
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: malformed, limit: 100 }))
      .rejects.toMatchObject({ code: "session_closed" });

    await db.$client.unsafe(`UPDATE collab_rooms SET lifecycle = 'active' WHERE id = $1`, [f.roomId]);
    await db.$client.unsafe(`UPDATE sessions SET deleted_at = now() WHERE id = $1`, [f.sessionId]);
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: malformed, limit: 100 }))
      .rejects.toMatchObject({ code: "not_member" });

    await db.$client.unsafe(`UPDATE sessions SET deleted_at = NULL WHERE id = $1`, [f.sessionId]);
    await db.$client.unsafe(`INSERT INTO account_deletions (uid, state, delete_after, record) VALUES ($1, 'pending', 0, '{}'::jsonb)`, [f.ownerUid]);
    await expect(projection().page({ roomId: f.roomId, viewerUid: f.ownerUid, cursor: malformed, limit: 100 }))
      .rejects.toMatchObject({ code: "not_member" });
  });

  it("fences wrong, revoked, closed, deleted, and deletion-pending readers", async () => {
    const f = await fixture();
    const read = () => projection().page({ roomId: f.roomId, viewerUid: f.guestUid, cursor: null, limit: 100 });
    await expect(projection().page({ roomId: f.roomId, viewerUid: "wrong-user", cursor: null, limit: 100 }))
      .rejects.toMatchObject({ code: "not_member" });
    await expect(read()).resolves.toMatchObject({ schemaVersion: 1 });

    await db.$client.unsafe(`UPDATE collab_members SET status = 'revoked' WHERE room_id = $1 AND user_id = $2`, [f.roomId, f.guestUid]);
    await expect(read()).rejects.toMatchObject({ code: "not_member" });
    await db.$client.unsafe(`UPDATE collab_members SET status = 'active' WHERE room_id = $1 AND user_id = $2`, [f.roomId, f.guestUid]);

    await db.$client.unsafe(`UPDATE collab_rooms SET lifecycle = 'closed' WHERE id = $1`, [f.roomId]);
    await expect(read()).rejects.toMatchObject({ code: "session_closed" });
    await db.$client.unsafe(`UPDATE collab_rooms SET lifecycle = 'active' WHERE id = $1`, [f.roomId]);

    await db.$client.unsafe(`UPDATE sessions SET deleted_at = now() WHERE id = $1`, [f.sessionId]);
    await expect(read()).rejects.toMatchObject({ code: "not_member" });
    await db.$client.unsafe(`UPDATE sessions SET deleted_at = NULL WHERE id = $1`, [f.sessionId]);

    await db.$client.unsafe(`INSERT INTO account_deletions (uid, state, delete_after, record) VALUES ($1, 'pending', 0, '{}'::jsonb)`, [f.guestUid]);
    await expect(read()).rejects.toMatchObject({ code: "not_member" });

    await db.$client.unsafe(`UPDATE account_deletions SET state = 'cancelled' WHERE uid = $1`, [f.guestUid]);
    await expect(read()).resolves.toMatchObject({ schemaVersion: 1 });
    await db.$client.unsafe(`UPDATE account_deletions SET state = 'fenced' WHERE uid = $1`, [f.guestUid]);
    await expect(read()).rejects.toMatchObject({ code: "not_member" });
  });

  it("exports the typed denial used by route adapters", () => {
    const error = new CollabProjectionError("cursor_reset");
    expect(error).toBeInstanceOf(Error);
    expect(error.code).toBe("cursor_reset");
  });
});
