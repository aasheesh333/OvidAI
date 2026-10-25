// UNEXECUTED: authored while /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md
// prohibits test execution. These are in-memory port-contract tests, not Postgres evidence.
import { describe, expect, it } from "vitest";

import {
  createStudioPreviewStore,
  type StudioPreviewAdmissionTransaction,
  type StudioPreviewCasUpdate,
  type StudioPreviewRecord,
  type StudioPreviewStorePort,
} from "./studioPreviewStore.js";

const UID = "preview-user";
const SID = "00000000-0000-4000-8000-000000000008";
const T0 = Date.parse("2026-10-24T12:00:00.000Z");
const CAPS = { perUser: 2, global: 32 } as const;
const LIVE = new Set(["starting", "running", "stopping"]);

function iso(offsetMs = 0): string {
  return new Date(T0 + offsetMs).toISOString();
}

function previewId(value: number): string {
  return `00000000-0000-4000-8000-${String(value).padStart(12, "0")}`;
}

function previewRecord(
  id: string,
  overrides: Partial<StudioPreviewRecord> = {},
): StudioPreviewRecord {
  return {
    id,
    sessionId: SID,
    userId: UID,
    generation: 1,
    kind: "dev_server",
    workspacePath: "/srv/ovid/workspaces/preview-user",
    projectDir: "/srv/ovid/workspaces/preview-user/app",
    startScript: "dev",
    processId: null,
    processGroupId: null,
    workerEpoch: "worker-a",
    bindHost: "127.0.0.1",
    port: 20000,
    status: "starting",
    createdAt: iso(),
    lastAccessAt: null,
    expiresAt: iso(15 * 60_000),
    endedAt: null,
    exitCode: null,
    failureCode: null,
    logBytes: 0,
    ...overrides,
  };
}

function staticRecord(id: string): StudioPreviewRecord {
  return previewRecord(id, {
    kind: "static",
    workspacePath: "/srv/ovid/workspaces/preview-user/dist",
    projectDir: null,
    startScript: null,
    processId: null,
    processGroupId: null,
    workerEpoch: null,
    bindHost: null,
    port: null,
    status: "running",
    logBytes: null,
  });
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function yieldToRacers(): Promise<void> {
  return new Promise((resolve) => setImmediate(resolve));
}

class AdmissionMutex {
  private tail: Promise<void> = Promise.resolve();

  async acquire(): Promise<() => void> {
    const previous = this.tail;
    let release!: () => void;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    let released = false;
    return () => {
      if (released) throw new Error("advisory lock released twice");
      released = true;
      release();
    };
  }
}

/**
 * A shared fake database, not a real Postgres adapter. transaction() itself
 * deliberately does not serialize callers: only lockCapacity() does. The
 * yields make a missing lock or a lock taken after counting oversubscribe.
 */
class SharedPreviewDatabase {
  private readonly rows = new Map<string, StudioPreviewRecord>();
  private readonly admissionMutex = new AdmissionMutex();

  facade(): StudioPreviewStorePort {
    return {
      transaction: async <T>(
        run: (tx: StudioPreviewAdmissionTransaction) => Promise<T>,
      ): Promise<T> => {
        let release: (() => void) | undefined;
        let locked = false;
        try {
          return await run({
            lockCapacity: async () => {
              if (locked) throw new Error("capacity lock acquired twice");
              locked = true;
              release = await this.admissionMutex.acquire();
            },
            liveDevServerCounts: async (userId) => {
              await yieldToRacers();
              const live = [...this.rows.values()].filter((row) =>
                row.kind === "dev_server" && LIVE.has(row.status));
              return {
                perUser: live.filter((row) => row.userId === userId).length,
                global: live.length,
              };
            },
            insert: async (record) => {
              await yieldToRacers();
              if (this.rows.has(record.id)) throw new Error("duplicate preview id");
              const saved = clone(record);
              this.rows.set(saved.id, saved);
              return clone(saved);
            },
          });
        } finally {
          release?.();
        }
      },
      getForUser: async (userId, sessionId, id) => [...this.rows.values()]
        .filter((row) =>
          row.userId === userId && row.sessionId === sessionId &&
          (id === undefined || row.id === id))
        .map((row) => clone(row)),
      getLive: async () => [...this.rows.values()]
        .filter((row) => LIVE.has(row.status))
        .map((row) => clone(row)),
      compareAndSwap: async (id, generation, update: StudioPreviewCasUpdate) => {
        if (update.generation !== generation + 1) {
          throw new Error("CAS did not increment exactly the expected generation");
        }
        // No await between the comparison and replacement: this models one SQL
        // UPDATE ... WHERE id = ... AND generation = ... RETURNING ... statement.
        const current = this.rows.get(id);
        if (current === undefined || current.generation !== generation) return null;
        const next = { ...current, ...clone(update) };
        this.rows.set(id, next);
        return clone(next);
      },
      touch: async ({ id, generation, now }) => {
        // No await between the checks and replacement: this models one atomic
        // conditional UPDATE of lastAccessAt, not an unlocked read-then-write.
        const current = this.rows.get(id);
        if (current === undefined || current.generation !== generation) return false;
        if (current.status !== "starting" && current.status !== "running") return false;
        const at = Date.parse(now);
        if (Date.parse(current.expiresAt) <= at) return false;
        const last = current.lastAccessAt === null ? null : Date.parse(current.lastAccessAt);
        if (last !== null && at - last < 1_000) return false;
        this.rows.set(id, { ...current, lastAccessAt: now });
        return true;
      },
      sweepExpired: async (now, limit) => [...this.rows.values()]
        .filter((row) => LIVE.has(row.status) && Date.parse(row.expiresAt) <= Date.parse(now))
        .sort((left, right) =>
          Date.parse(left.expiresAt) - Date.parse(right.expiresAt) || left.id.localeCompare(right.id))
        .slice(0, limit)
        .map((row) => clone(row)),
    };
  }

  async seed(record: StudioPreviewRecord): Promise<void> {
    this.rows.set(record.id, clone(record));
  }

  all(): StudioPreviewRecord[] {
    return [...this.rows.values()].map((row) => clone(row));
  }
}

function harness() {
  const database = new SharedPreviewDatabase();
  return {
    database,
    store: createStudioPreviewStore(database.facade()),
    anotherStore: createStudioPreviewStore(database.facade()),
  };
}

describe("Studio preview DB port contract (in-memory; Postgres not exercised)", () => {
  it("fails closed on invalid capacities before admitting a row", async () => {
    const { database, store } = harness();

    await expect(store.start(previewRecord(previewId(1)), { perUser: 0, global: 32 }))
      .rejects.toThrow(RangeError);
    await expect(store.start(previewRecord(previewId(2)), { perUser: 2, global: 1.5 }))
      .rejects.toThrow(RangeError);

    expect(database.all()).toEqual([]);
  });

  it("round-trips the exact record and preserves unknown runtime fields as null", async () => {
    const { store } = harness();
    const original = staticRecord(previewId(1));

    const started = await store.start(original, CAPS);

    expect(started).toEqual(original);
    expect(started).toEqual({
      id: previewId(1),
      sessionId: SID,
      userId: UID,
      generation: 1,
      kind: "static",
      workspacePath: "/srv/ovid/workspaces/preview-user/dist",
      projectDir: null,
      startScript: null,
      processId: null,
      processGroupId: null,
      workerEpoch: null,
      bindHost: null,
      port: null,
      status: "running",
      createdAt: "2026-10-24T12:00:00.000Z",
      lastAccessAt: null,
      expiresAt: "2026-10-24T12:15:00.000Z",
      endedAt: null,
      exitCode: null,
      failureCode: null,
      logBytes: null,
    });
    expect(Object.keys(started)).toHaveLength(21);
  });

  it("keeps the global dev-server cap at 32 across racing store facades", async () => {
    const { database, store, anotherStore } = harness();
    const stores = [store, anotherStore];

    const attempts = await Promise.allSettled(Array.from({ length: 33 }, (_, index) =>
      stores[index % stores.length]!.start(previewRecord(previewId(index + 1), {
        userId: `global-user-${index}`,
        port: 20000 + index,
      }), CAPS)));

    expect(attempts.filter((result) => result.status === "fulfilled")).toHaveLength(32);
    const denied = attempts.filter((result) => result.status === "rejected");
    expect(denied).toHaveLength(1);
    expect((denied[0] as PromiseRejectedResult).reason).toMatchObject({
      name: "StudioPreviewCapacityError",
      code: "global_capacity",
    });
    expect(database.all().filter((row) => row.kind === "dev_server" && LIVE.has(row.status)))
      .toHaveLength(32);
  });

  it("denies a third live dev server for one user without inserting a row", async () => {
    const { database, store, anotherStore } = harness();
    await Promise.all([
      store.start(previewRecord(previewId(1)), CAPS),
      anotherStore.start(previewRecord(previewId(2), { port: 20001 }), CAPS),
    ]);

    await expect(store.start(previewRecord(previewId(3), { port: 20002 }), CAPS))
      .rejects.toMatchObject({ code: "per_user_capacity" });

    expect(database.all().map((row) => row.id).sort()).toEqual([previewId(1), previewId(2)]);
  });

  it("does not charge static previews or terminal dev servers against process caps", async () => {
    const { database, store } = harness();
    await database.seed(staticRecord(previewId(1)));
    await database.seed(previewRecord(previewId(2), {
      status: "stopped",
      endedAt: iso(60_000),
    }));

    const admitted = await store.start(previewRecord(previewId(3)), CAPS);

    expect(admitted.status).toBe("starting");
    expect(database.all()).toHaveLength(3);
  });

  it("continues to charge stopping previews until terminal cleanup releases capacity", async () => {
    const { database, store } = harness();
    await database.seed(previewRecord(previewId(1), { status: "stopping" }));

    await expect(store.start(previewRecord(previewId(2)), { perUser: 1, global: 1 }))
      .rejects.toMatchObject({ code: "per_user_capacity" });

    expect(database.all()).toHaveLength(1);
  });

  it("scopes user/session reads and returns live rows without terminal rows", async () => {
    const { database, store } = harness();
    const owned = previewRecord(previewId(1), { status: "running" });
    const ownedTerminal = previewRecord(previewId(2), { status: "failed" });
    await database.seed(owned);
    await database.seed(ownedTerminal);
    await database.seed(previewRecord(previewId(3), { userId: "another-user" }));
    await database.seed(previewRecord(previewId(4), { sessionId: "another-session" }));

    expect((await store.getForUser(UID, SID)).map((row) => row.id).sort())
      .toEqual([previewId(1), previewId(2)]);
    expect(await store.getForUser(UID, SID, owned.id)).toEqual([owned]);
    expect(await store.getForUser("another-user", SID, owned.id)).toEqual([]);
    expect(await store.getForUser(UID, "another-session", owned.id)).toEqual([]);
    expect(await store.getForUser(UID, SID, previewId(99))).toEqual([]);

    await database.seed(staticRecord(previewId(5)));
    await database.seed(previewRecord(previewId(6), { status: "stopping" }));
    await database.seed(previewRecord(previewId(7), { status: "expired" }));
    expect((await store.getLive()).map((row) => row.id).sort()).toEqual([
      previewId(1), previewId(3), previewId(4), previewId(5), previewId(6),
    ]);
  });

  it("increments generation with each CAS patch and rejects stale or missing writes", async () => {
    const { store } = harness();
    const original = previewRecord(previewId(1));
    await store.start(original, CAPS);

    const updated = await store.update(original.id, 1, {
      status: "running",
      processId: 4242,
      processGroupId: "/sys/fs/cgroup/ovid/preview-1",
      lastAccessAt: iso(30_000),
      logBytes: 128,
    });

    expect(updated).toEqual({
      ...original,
      generation: 2,
      status: "running",
      processId: 4242,
      processGroupId: "/sys/fs/cgroup/ovid/preview-1",
      lastAccessAt: iso(30_000),
      logBytes: 128,
    });
    expect(await store.update(original.id, 1, { status: "failed" })).toBeNull();
    expect(await store.update(previewId(99), 1, { status: "failed" })).toBeNull();

    const nulled = await store.update(original.id, 2, {
      processId: null,
      processGroupId: null,
      lastAccessAt: null,
    });
    expect(nulled).toMatchObject({
      generation: 3,
      status: "running",
      processId: null,
      processGroupId: null,
      lastAccessAt: null,
      logBytes: 128,
    });
  });

  it("UNEXECUTED: touch changes only lastAccessAt at the same generation and preserves nullable unknowns", async () => {
    const { store } = harness();
    const original = staticRecord(previewId(1));
    original.generation = 7;
    await store.start(original, CAPS);

    expect(await store.touch({ id: original.id, generation: 7, now: iso(30_000) })).toBe(true);
    expect((await store.getForUser(UID, SID, original.id))[0]).toEqual({
      ...original,
      lastAccessAt: iso(30_000),
    });

    const updated = await store.update(original.id, 7, { status: "stopping" });
    expect(updated).toEqual({
      ...original,
      generation: 8,
      status: "stopping",
      lastAccessAt: iso(30_000),
    });
  });

  it("UNEXECUTED: touch uses now for exact one-second throttle inputs and reports only real writes", async () => {
    const { database, store } = harness();
    const original = previewRecord(previewId(1), {
      generation: 4,
      status: "starting",
      lastAccessAt: iso(10_000),
    });
    await database.seed(original);

    expect(await store.touch({ id: original.id, generation: 4, now: iso(10_999) })).toBe(false);
    expect((await store.getForUser(UID, SID, original.id))[0]).toEqual(original);
    expect(await store.touch({ id: original.id, generation: 4, now: iso(11_000) })).toBe(true);
    expect(await store.touch({ id: original.id, generation: 4, now: iso(11_999) })).toBe(false);
    expect((await store.getForUser(UID, SID, original.id))[0]).toEqual({
      ...original,
      lastAccessAt: iso(11_000),
    });
    expect(await store.touch({ id: original.id, generation: 4, now: iso(12_000) })).toBe(true);
    expect((await store.getForUser(UID, SID, original.id))[0]).toEqual({
      ...original,
      lastAccessAt: iso(12_000),
    });
  });

  it("UNEXECUTED: touch denies stale, missing, stopping, terminal, and expired rows without mutation", async () => {
    const { database, store } = harness();
    const current = previewRecord(previewId(1), { generation: 4, status: "running" });
    const stopping = previewRecord(previewId(2), { status: "stopping" });
    const terminal = previewRecord(previewId(3), {
      status: "stopped",
      endedAt: iso(),
    });
    const expired = previewRecord(previewId(4), {
      status: "running",
      expiresAt: iso(30_000),
    });
    await database.seed(current);
    await database.seed(stopping);
    await database.seed(terminal);
    await database.seed(expired);
    const before = database.all();

    expect(await store.touch({ id: current.id, generation: 3, now: iso(60_000) })).toBe(false);
    expect(await store.touch({ id: previewId(99), generation: 1, now: iso(60_000) })).toBe(false);
    for (const denied of [stopping, terminal, expired]) {
      expect(await store.touch({
        id: denied.id,
        generation: denied.generation,
        now: iso(60_000),
      })).toBe(false);
    }
    expect(database.all()).toEqual(before);
  });

  it("returns bounded expired live candidates in expiry order without terminalizing them", async () => {
    const { database, store } = harness();
    await database.seed(previewRecord(previewId(1), {
      status: "running",
      expiresAt: iso(-1_000),
    }));
    await database.seed(previewRecord(previewId(2), {
      status: "stopping",
      expiresAt: iso(-3_000),
    }));
    await database.seed(previewRecord(previewId(3), {
      status: "starting",
      expiresAt: iso(-2_000),
    }));
    await database.seed(previewRecord(previewId(4), {
      status: "stopped",
      expiresAt: iso(-4_000),
    }));
    await database.seed(previewRecord(previewId(5), {
      status: "running",
      expiresAt: iso(1_000),
    }));

    expect((await store.sweepExpired(iso(), 2)).map((row) => row.id))
      .toEqual([previewId(2), previewId(3)]);
    expect((await store.sweepExpired(iso(), 10)).map((row) => row.id))
      .toEqual([previewId(2), previewId(3), previewId(1)]);
    expect((await store.getForUser(UID, SID, previewId(1)))[0]).toMatchObject({
      generation: 1,
      status: "running",
      endedAt: null,
      failureCode: null,
    });
  });
});
