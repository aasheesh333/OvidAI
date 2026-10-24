import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { createDb, migrate, newId, type Db } from "@ovid/db";

import { CollabProjection, type CollabEventPage, type CollabProjectionReader, type CollabPageInput } from "./projection.js";
import { longPoll } from "./longPoll.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const SCHEMA = "collab_long_poll_test";

function page(events: CollabEventPage["events"] = [], nextCursor = "v1:0"): CollabEventPage {
  return { schemaVersion: 1, events, nextCursor, hasMore: false };
}

function event(sequence: number): CollabEventPage["events"][number] {
  return {
    schemaVersion: 1,
    eventId: `message:${sequence}`,
    sessionId: "session-1",
    eventSequence: sequence,
    senderParticipantId: "participant-1",
    kind: "message",
    createdAt: "2026-01-01T00:00:00.000Z",
    payload: { text: `message ${sequence}`, role: "user" },
  };
}

function input(overrides: Partial<CollabPageInput & { waitSeconds: number; signal: AbortSignal }> = {}) {
  return {
    roomId: "room-1",
    viewerUid: "viewer-1",
    cursor: "v1:0" as string | null,
    limit: 100,
    waitSeconds: 0,
    signal: new AbortController().signal,
    ...overrides,
  };
}

describe("longPoll authoritative rechecks", () => {
  it("returns events after the cursor immediately without sleeping", async () => {
    const reader: CollabProjectionReader = { page: vi.fn(async () => page([event(1)], "v1:1")) };
    const sleep = vi.fn(async () => {});

    const result = await longPoll(reader, input({ waitSeconds: 25 }), { sleep });

    expect(result.events.map((item) => item.eventId)).toEqual(["message:1"]);
    expect(reader.page).toHaveBeenCalledTimes(1);
    expect(sleep).not.toHaveBeenCalled();
  });

  it("rechecks the authoritative cursor before the first sleep", async () => {
    const pages = [page(), page([event(1)], "v1:1")];
    let calls = 0;
    const reader: CollabProjectionReader = {
      page: vi.fn(async () => {
        const result = pages[calls]!;
        calls += 1;
        return result;
      }),
    };
    const sleep = vi.fn(async () => {});

    const result = await longPoll(reader, input({ waitSeconds: 25 }), { sleep });

    expect(result.events).toHaveLength(1);
    expect(reader.page).toHaveBeenCalledTimes(2);
    expect(sleep).not.toHaveBeenCalled();
  });

  it("rechecks again after a bounded wait and before answering", async () => {
    let calls = 0;
    let now = 0;
    const reader: CollabProjectionReader = {
      page: vi.fn(async () => {
        calls += 1;
        return calls < 3 ? page() : page([event(1)], "v1:1");
      }),
    };

    const result = await longPoll(reader, input({ waitSeconds: 1 }), {
      now: () => now,
      pollIntervalMs: 1000,
      sleep: async (ms) => { now += ms; },
    });

    expect(result.events).toHaveLength(1);
    expect(calls).toBe(3);
  });

  it("clamps wait to 25 seconds and pages to 100 even when a wake hint never arrives", async () => {
    let now = 0;
    const limits: number[] = [];
    const reader: CollabProjectionReader = {
      page: vi.fn(async (args) => {
        limits.push(args.limit);
        return page([], "v1:9");
      }),
    };
    const sleep = vi.fn(async (ms: number) => { now += ms; });
    const wake = vi.fn(async () => new Promise<void>(() => {}));

    const result = await longPoll(
      reader,
      input({ cursor: "v1:9", limit: 1000, waitSeconds: 999 }),
      { now: () => now, sleep, wake, pollIntervalMs: 25_000 },
    );

    expect(now).toBe(25_000);
    expect(limits.every((limit) => limit === 100)).toBe(true);
    expect(sleep).toHaveBeenCalledTimes(1);
    expect(wake).toHaveBeenCalledTimes(1);
    expect(result).toEqual(page([], "v1:9"));
  });

  it("clamps a negative wait to zero and a low limit to one", async () => {
    const reader: CollabProjectionReader = { page: vi.fn(async () => page()) };
    const sleep = vi.fn(async () => {});

    const result = await longPoll(reader, input({ limit: 0, waitSeconds: -100 }), { sleep });

    expect(result).toEqual(page());
    expect(reader.page).toHaveBeenCalledWith(expect.objectContaining({ limit: 1 }));
    expect(sleep).not.toHaveBeenCalled();
  });

  it("returns an unchanged empty cursor after an ordinary bounded timeout", async () => {
    let now = 0;
    const reader: CollabProjectionReader = { page: vi.fn(async () => page([], "v1:41")) };

    const result = await longPoll(reader, input({ cursor: "v1:41", waitSeconds: 2 }), {
      now: () => now,
      pollIntervalMs: 2000,
      sleep: async (ms) => { now += ms; },
    });

    expect(result).toEqual({ schemaVersion: 1, events: [], nextCursor: "v1:41", hasMore: false });
    expect(now).toBe(2000);
  });

  it("aborts a sleeping poll on disconnect without another authoritative read", async () => {
    const controller = new AbortController();
    const reader: CollabProjectionReader = { page: vi.fn(async () => page()) };
    let notifyStarted!: () => void;
    const started = new Promise<void>((resolve) => { notifyStarted = resolve; });
    const sleep = vi.fn(async (_ms: number, signal: AbortSignal) => {
      notifyStarted();
      return new Promise<void>((_resolve, reject) => {
        signal.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
      });
    });

    const pending = longPoll(reader, input({ waitSeconds: 25, signal: controller.signal }), { sleep });
    await started;
    controller.abort();

    await expect(pending).rejects.toMatchObject({ name: "AbortError" });
    expect(reader.page).toHaveBeenCalledTimes(2);
  });

  it("aborts even when a wake or sleep implementation ignores its signal", async () => {
    const controller = new AbortController();
    const reader: CollabProjectionReader = { page: vi.fn(async () => page()) };
    let notifyStarted!: () => void;
    const started = new Promise<void>((resolve) => { notifyStarted = resolve; });

    const pending = longPoll(reader, input({ waitSeconds: 25, signal: controller.signal }), {
      sleep: async () => {
        notifyStarted();
        return new Promise<void>(() => {});
      },
      wake: async () => new Promise<void>(() => {}),
    });
    await started;
    controller.abort();
    const outcome = await Promise.race([
      pending.catch((error: unknown) => error),
      new Promise<string>((resolve) => setTimeout(() => resolve("timeout"), 50)),
    ]);

    expect(outcome).toMatchObject({ name: "AbortError" });
  });

  it("does not query at all for an already disconnected caller", async () => {
    const controller = new AbortController();
    controller.abort();
    const reader: CollabProjectionReader = { page: vi.fn(async () => page()) };

    await expect(longPoll(reader, input({ signal: controller.signal }))).rejects.toMatchObject({ name: "AbortError" });
    expect(reader.page).not.toHaveBeenCalled();
  });
});

const CANONICAL_TABLES = [
  "users",
  "account_deletions",
  "sessions",
  "messages",
  "runs",
  "run_usage",
  "session_event_mirror",
] as const;

const FIXTURE_DDL = `
CREATE TABLE collab_rooms (id text PRIMARY KEY, session_id text NOT NULL, owner_user_id text NOT NULL, lifecycle text NOT NULL, generation bigint NOT NULL DEFAULT 1);
CREATE TABLE collab_members (room_id text NOT NULL, user_id text NOT NULL, participant_id text NOT NULL, role text NOT NULL, status text NOT NULL, display_name text, generation bigint NOT NULL DEFAULT 1, joined_at timestamptz NOT NULL, PRIMARY KEY (room_id, user_id), UNIQUE (room_id, participant_id));
CREATE TABLE collab_turns (id text PRIMARY KEY, room_id text NOT NULL, participant_id text NOT NULL, run_id text, user_message_id text, model text, created_at timestamptz NOT NULL);
CREATE TABLE collab_sender_leases (id text PRIMARY KEY, room_id text NOT NULL, holder_participant_id text NOT NULL, run_id text NOT NULL, started_at timestamptz NOT NULL, heartbeat_at timestamptz NOT NULL, released_at timestamptz);
`;

describe.skipIf(!TEST_DATABASE_URL)("longPoll lifecycle races against real Postgres", () => {
  let db: Db;
  let sequence = 0;

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
  }, 60_000);

  afterAll(async () => {
    await db?.$client.unsafe(`SET search_path TO public`);
    await db?.$client.unsafe(`DROP SCHEMA IF EXISTS ${SCHEMA} CASCADE`);
    await db?.$client.end({ timeout: 5 });
  });

  async function fixture() {
    sequence += 1;
    const roomId = newId();
    const sessionId = newId();
    const uid = `race-user-${sequence}`;
    await db.$client.unsafe(`INSERT INTO users (uid) VALUES ($1)`, [uid]);
    await db.$client.unsafe(`INSERT INTO sessions (id, user_id) VALUES ($1, $2)`, [sessionId, uid]);
    await db.$client.unsafe(`INSERT INTO collab_rooms (id, session_id, owner_user_id, lifecycle) VALUES ($1, $2, $3, 'active')`, [roomId, sessionId, uid]);
    await db.$client.unsafe(
      `INSERT INTO collab_members (room_id, user_id, participant_id, role, status, display_name, joined_at)
       VALUES ($1, $2, 'race-participant-' || $3::text, 'owner', 'active', 'Owner', now())`,
      [roomId, uid, String(sequence)],
    );
    await db.$client.unsafe(
      `INSERT INTO messages (id, session_id, role, content, created_at) VALUES ($1, $2, 'user', 'existing', now())`,
      [newId(), sessionId],
    );
    return { roomId, sessionId, uid };
  }

  for (const scenario of ["revoke", "close", "session_delete", "account_delete"] as const) {
    it(`fences ${scenario} during a 25 second wait`, async () => {
      const f = await fixture();
      const projection = new CollabProjection(db);
      const head = await projection.page({ roomId: f.roomId, viewerUid: f.uid, cursor: null, limit: 100 });
      let now = 0;
      let sleeps = 0;

      const pending = longPoll(
        projection,
        { roomId: f.roomId, viewerUid: f.uid, cursor: head.nextCursor, limit: 100, waitSeconds: 25, signal: new AbortController().signal },
        {
          now: () => now,
          pollIntervalMs: 25_000,
          sleep: async (ms) => {
            sleeps += 1;
            if (scenario === "revoke") {
              await db.$client.unsafe(`UPDATE collab_members SET status = 'revoked' WHERE room_id = $1 AND user_id = $2`, [f.roomId, f.uid]);
            } else if (scenario === "close") {
              await db.$client.unsafe(`UPDATE collab_rooms SET lifecycle = 'closed' WHERE id = $1`, [f.roomId]);
            } else if (scenario === "session_delete") {
              await db.$client.unsafe(`UPDATE sessions SET deleted_at = now() WHERE id = $1`, [f.sessionId]);
            } else {
              await db.$client.unsafe(`INSERT INTO account_deletions (uid, state, delete_after, record) VALUES ($1, 'pending', 0, '{}'::jsonb)`, [f.uid]);
            }
            now += ms;
          },
        },
      );

      await expect(pending).rejects.toMatchObject({ code: scenario === "close" ? "session_closed" : "not_member" });
      expect(sleeps).toBe(1);
    });
  }
});
