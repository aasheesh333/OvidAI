// Authored failing-first on 2026-10-25 against the absent adapter.
// Every test in this file is UNEXECUTED under
// /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
import { createHash } from "node:crypto";
import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import {
  appendExactItem,
  createDb,
  migrate,
  messages,
  newId,
  runs,
  schema,
  sessions,
  users,
  type CompactionExactObjectReader,
  type Db,
  type ExactHistoryEntry,
  type StoredExactHistoryItem,
} from "@ovid/db";
import type { ExactRecallChunk } from "@ovid/shared";
import {
  readExactHistory as realReadExactHistory,
} from "../../../packages/db/src/compactionRepos.js";
import {
  createMigrationScratch,
  type MigrationScratch,
} from "../../../packages/db/src/migrationTestKit.js";
import {
  RawHistoryContractError,
  RawHistoryCursorError,
  RAW_HISTORY_MAX_CHUNK_BYTES,
  RAW_HISTORY_MAX_PAGE_DATA_BYTES,
} from "./routes/trajectoryRecall.js";
import { redactForProjection } from "./routes/trajectoryRedaction.js";
import { closeDb, TEST_DATABASE_URL } from "./test/db.js";
import {
  createBoundedExactRecall,
  type BoundedExactRecallRead,
} from "./trajectoryExactRecall.js";

const readExactHistoryMock = vi.hoisted(() => vi.fn());

vi.mock("@ovid/db", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/db")>();
  return { ...actual, readExactHistory: readExactHistoryMock };
});

const SID = "11111111-1111-4111-8111-111111111111";
const OTHER_SID = "22222222-2222-4222-8222-222222222222";
const ROOT = "33333333-3333-4333-8333-333333333333";
const OTHER_ROOT = "44444444-4444-4444-8444-444444444444";
const TEST_CURSOR_SECRET = "a1".repeat(32);
const OTHER_CURSOR_SECRET = "b2".repeat(32);
const identity = (value: unknown): unknown => value;

type ReadExactHistoryInput = Parameters<typeof realReadExactHistory>[1];

function inlineEntry(
  position: string,
  stableId: string,
  data: unknown,
  overrides: Partial<StoredExactHistoryItem> = {},
): ExactHistoryEntry {
  return {
    item: {
      stableId,
      kind: "message",
      sessionId: SID,
      rootTaskRunId: ROOT,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: stableId,
      inlinePayload: data,
      byteLength: Buffer.byteLength(JSON.stringify(data), "utf8"),
      ...overrides,
    },
    data,
    position,
    createdAt: null,
  };
}

function referenceEntry(
  position: string,
  stableId: string,
  objectRef: string,
  data: unknown,
  overrides: Partial<StoredExactHistoryItem> = {},
): ExactHistoryEntry {
  return {
    item: {
      stableId,
      kind: "message",
      sessionId: SID,
      rootTaskRunId: ROOT,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: stableId,
      objectRef,
      byteLength: Buffer.byteLength(JSON.stringify(data), "utf8"),
      ...overrides,
    },
    data,
    position,
    createdAt: null,
  };
}

function input(overrides: Partial<BoundedExactRecallRead> = {}): BoundedExactRecallRead {
  return {
    sessionId: SID,
    cursor: null,
    limit: 20,
    chunkBytes: 1024,
    redact: identity,
    ...overrides,
  };
}

function useHistory(entries: readonly ExactHistoryEntry[]): void {
  readExactHistoryMock.mockImplementation(async (_db: Db, read: ReadExactHistoryInput) => {
    const after = read.cursor === undefined ? 0 : Number(read.cursor);
    const found = entries
      .filter((entry) => Number(entry.position) > after)
      .filter((entry) => read.rootTaskRunId === undefined ||
        entry.item.rootTaskRunId === read.rootTaskRunId)
      .filter((entry) => read.logicalWorkerId === undefined ||
        entry.item.logicalWorkerId === read.logicalWorkerId)
      .filter((entry) => read.attemptId === undefined ||
        entry.item.attemptId === read.attemptId)
      .slice(0, (read.limit ?? 50) + 1);
    const items = found.slice(0, read.limit ?? 50);
    return {
      items,
      nextCursor: found.length > (read.limit ?? 50) && items.length > 0
        ? items[items.length - 1]!.position
        : null,
    };
  });
}

function pureRecall(
  objects?: CompactionExactObjectReader,
  cursorSecret: string | null = TEST_CURSOR_SECRET,
) {
  return createBoundedExactRecall({
    db: {} as Db,
    ...(objects ? { objects } : {}),
    ...(cursorSecret === null ? {} : { cursorSecret }),
  });
}

function readInputs(): ReadExactHistoryInput[] {
  return readExactHistoryMock.mock.calls.map((call) => call[1] as ReadExactHistoryInput);
}

beforeEach(() => {
  readExactHistoryMock.mockReset();
});

describe("gateway bounded exact recall (pure, UNEXECUTED)", () => {
  it("maps DB item cursors across pages with one-item reads", async () => {
    useHistory([
      inlineEntry("1", "item-1", { sequence: 1 }),
      inlineEntry("2", "item-2", { sequence: 2 }),
      inlineEntry("3", "item-3", { sequence: 3 }),
    ]);
    const recall = pureRecall();

    const first = await recall.read(input({ limit: 2 }));
    expect(first.chunks.map((chunk) => chunk.item.stableId)).toEqual(["item-1", "item-2"]);
    expect(first.chunks.map((chunk) => JSON.parse(chunk.data))).toEqual([
      { sequence: 1 },
      { sequence: 2 },
    ]);
    expect(first.nextCursor).not.toBeNull();
    expect(first.nextCursor).not.toBe("2");

    const second = await recall.read(input({ cursor: first.nextCursor, limit: 2 }));
    expect(second.chunks.map((chunk) => chunk.item.stableId)).toEqual(["item-3"]);
    expect(second.chunks.map((chunk) => JSON.parse(chunk.data))).toEqual([{ sequence: 3 }]);
    expect(second.nextCursor).toBeNull();
    expect(readInputs().map((read) => read.cursor)).toEqual([undefined, "1", "2"]);
    expect(readInputs().map((read) => read.limit)).toEqual([1, 1, 1]);
  });

  it("does not preload all history to fill a bounded chunk page", async () => {
    useHistory(Array.from({ length: 50 }, (_, index) =>
      inlineEntry(String(index + 1), `item-${index + 1}`, { sequence: index + 1 })));
    const recall = pureRecall();

    const page = await recall.read(input({ limit: 2 }));

    expect(page.chunks).toHaveLength(2);
    expect(page.nextCursor).not.toBeNull();
    expect(readExactHistoryMock).toHaveBeenCalledTimes(2);
    expect(readInputs().map((read) => read.limit)).toEqual([1, 1]);
    expect(readInputs().every((read) => read.sessionId === SID)).toBe(true);
  });

  it("continues oversized UTF-8 data within exact chunk and page byte bounds", async () => {
    const payload = {
      text: `${"x".repeat(RAW_HISTORY_MAX_PAGE_DATA_BYTES)}-${"🌍".repeat(80)}-after`,
    };
    useHistory([inlineEntry("1", "oversized", payload)]);
    const recall = pureRecall();
    const read = (cursor: string | null) => recall.read(input({
      cursor,
      limit: 50,
      chunkBytes: RAW_HISTORY_MAX_CHUNK_BYTES,
    }));

    const first = await read(null);
    expect(first.chunks).toHaveLength(16);
    expect(first.chunks.reduce((sum, chunk) => sum + Buffer.byteLength(chunk.data, "utf8"), 0))
      .toBe(RAW_HISTORY_MAX_PAGE_DATA_BYTES);
    expect(first.nextCursor).not.toBeNull();
    for (const chunk of first.chunks) {
      expect(Buffer.byteLength(chunk.data, "utf8")).toBeLessThanOrEqual(RAW_HISTORY_MAX_CHUNK_BYTES);
      expect(chunk.item.inlinePayload).toBeNull();
    }

    const second = await read(first.nextCursor);
    expect(second.nextCursor).toBeNull();
    const chunks = [...first.chunks, ...second.chunks];
    expect(chunks.map((chunk) => chunk.data).join("")).toBe(JSON.stringify(payload));
    expect(chunks.at(-1)!.nextOffset).toBeNull();
    for (const chunk of chunks) {
      expect(chunk.data).not.toContain("�");
      expect(Buffer.byteLength(chunk.data, "utf8")).toBeLessThanOrEqual(RAW_HISTORY_MAX_CHUNK_BYTES);
    }
    expect(readInputs().map((readInput) => readInput.limit)).toEqual([1, 1]);
  });

  it("keeps a secret stable ID out of opaque cursors across adapter instances", async () => {
    const stableId = ["github", "pat", "cursor", "stable", "canary"].join("_");
    const payload = { text: `oversized-${"x".repeat(700)}` };
    const entry = inlineEntry("1", stableId, payload, { eventCursor: "safe-event-cursor" });
    useHistory([entry]);
    const recalls = [pureRecall(), pureRecall()];
    const readsByAdapter = [0, 0];
    const redact = (value: unknown): unknown => redactForProjection(value);
    const chunks: ExactRecallChunk[] = [];
    let cursor: string | null = null;
    let firstCursor: string | null = null;

    for (let page = 0; page < 32; page += 1) {
      const adapterIndex = page % recalls.length;
      readsByAdapter[adapterIndex] = readsByAdapter[adapterIndex]! + 1;
      const result = await recalls[adapterIndex]!.read(input({
        cursor,
        limit: 2,
        chunkBytes: 96,
        redact,
      }));
      const wire = JSON.stringify(result);
      expect(wire.includes(stableId)).toBe(false);
      for (const chunk of result.chunks) expect(chunk.item.stableId).toBe("[redacted]");
      chunks.push(...result.chunks);
      cursor = result.nextCursor;
      if (page === 0) {
        firstCursor = cursor;
        expect(firstCursor).not.toBeNull();
        expect(firstCursor!.startsWith("v3.")).toBe(true);
        expect(firstCursor!.length).toBeLessThanOrEqual(4096);
        const encoded = firstCursor!.slice(3);
        expect(encoded).toMatch(/^[A-Za-z0-9_-]+$/);
        const serialized = Buffer.from(encoded, "base64url");
        expect(serialized.toString("base64url")).toBe(encoded);
        const envelope = JSON.parse(serialized.toString("utf8")) as Record<string, unknown>;
        expect(envelope).not.toBeNull();
        expect(Array.isArray(envelope)).toBe(false);
        expect(Object.keys(envelope).sort()).toEqual(["ciphertext", "iv", "tag", "wrappedDek"]);
        const decodeField = (field: string, minimum: number, maximum: number): Buffer => {
          const value = envelope[field];
          expect(typeof value).toBe("string");
          const text = value as string;
          expect(text).toMatch(/^[A-Za-z0-9+/]*={0,2}$/);
          const bytes = Buffer.from(text, "base64");
          expect(bytes.toString("base64")).toBe(text);
          expect(bytes.length).toBeGreaterThanOrEqual(minimum);
          expect(bytes.length).toBeLessThanOrEqual(maximum);
          return bytes;
        };
        expect(decodeField("wrappedDek", 60, 60)).toHaveLength(60);
        expect(decodeField("iv", 12, 12)).toHaveLength(12);
        expect(decodeField("tag", 16, 16)).toHaveLength(16);
        decodeField("ciphertext", 1, 4096);

        const stableIdDigest = createHash("sha256").update(stableId).digest("hex");
        const contentVersionDigest = createHash("sha256")
          .update(JSON.stringify({ item: entry.item, data: entry.data }))
          .digest("hex");
        const forbidden = [
          stableId,
          stableIdDigest,
          contentVersionDigest,
          SID,
          ROOT,
          "stableId",
          "itemId",
          "projectedItemId",
          "contentHash",
          "contentBytes",
          "sessionId",
          "rootTaskRunId",
          "logicalWorkerId",
          "attemptId",
          "dbCursor",
          "itemPosition",
          "itemOffset",
        ];
        const envelopeJson = JSON.stringify(envelope);
        for (const value of forbidden) {
          expect(envelopeJson).not.toContain(value);
          expect(firstCursor).not.toContain(value);
        }
        for (const value of [stableId, stableIdDigest, contentVersionDigest]) {
          for (const encoding of ["base64", "base64url"] as const) {
            const encodedSecret = Buffer.from(value, "utf8").toString(encoding);
            expect(envelopeJson).not.toContain(encodedSecret);
            expect(firstCursor).not.toContain(encodedSecret);
          }
        }
        for (const digest of [stableIdDigest, contentVersionDigest]) {
          for (const encoding of ["base64", "base64url"] as const) {
            const encodedDigest = Buffer.from(digest, "hex").toString(encoding);
            expect(envelopeJson).not.toContain(encodedDigest);
            expect(firstCursor).not.toContain(encodedDigest);
          }
        }
      }
      if (cursor === null) break;
    }

    expect(cursor).toBeNull();
    expect(readsByAdapter[0]).toBeGreaterThan(0);
    expect(readsByAdapter[1]).toBeGreaterThan(0);
    expect(chunks.length).toBeGreaterThan(2);
    expect(chunks.map((chunk) => chunk.data).join("")).toBe(JSON.stringify(payload));
    expect(readExactHistoryMock.mock.calls.length).toBeGreaterThan(2);
  });

  it("rejects cursor tampering, wrong scope, replacement identity and changed content", async () => {
    const stableId = ["github", "pat", "cursor", "tamper", "canary"].join("_");
    const payload = { text: `original-${"x".repeat(400)}` };
    const history = [inlineEntry("1", stableId, payload, { eventCursor: "safe-event-cursor" })];
    useHistory(history);
    const redact = (value: unknown): unknown => redactForProjection(value);
    const recall = pureRecall();
    const otherProcess = pureRecall();
    const read = (cursor: string | null, overrides: Partial<BoundedExactRecallRead> = {}) =>
      otherProcess.read(input({ cursor, limit: 1, chunkBytes: 48, redact, ...overrides }));
    const first = await recall.read(input({ limit: 1, chunkBytes: 48, redact }));
    const cursor = first.nextCursor!;
    expect(cursor).not.toBeNull();

    const beforeInvalid = readExactHistoryMock.mock.calls.length;
    const index = Math.floor(cursor.length / 2);
    const tampered = `${cursor.slice(0, index)}${cursor[index] === "A" ? "B" : "A"}${cursor.slice(index + 1)}`;
    await expect(read(tampered)).rejects.toBeInstanceOf(RawHistoryCursorError);
    await expect(read(cursor, { rootTaskRunId: OTHER_ROOT }))
      .rejects.toBeInstanceOf(RawHistoryCursorError);
    expect(readExactHistoryMock).toHaveBeenCalledTimes(beforeInvalid);

    history[0] = inlineEntry("1", "replacement-item", payload, { eventCursor: "safe-event-cursor" });
    await expect(read(cursor)).rejects.toBeInstanceOf(RawHistoryCursorError);
    history[0] = inlineEntry("1", stableId, { text: `mutated-${"y".repeat(400)}` }, {
      eventCursor: "safe-event-cursor",
    });
    await expect(read(cursor)).rejects.toBeInstanceOf(RawHistoryCursorError);
  });

  it("requires cursor encryption and rejects continuation under a different key", async () => {
    useHistory([inlineEntry("1", "encrypted-item", { text: `secret-${"x".repeat(400)}` })]);
    const unconfigured = pureRecall(undefined, null);
    await expect(unconfigured.read(input())).rejects.toMatchObject({
      name: "RawHistoryCursorUnavailableError",
    });
    expect(readExactHistoryMock).not.toHaveBeenCalled();
    const invalidKey = pureRecall(undefined, "not-a-production-key");
    await expect(invalidKey.read(input())).rejects.toMatchObject({
      name: "RawHistoryCursorUnavailableError",
    });
    expect(readExactHistoryMock).not.toHaveBeenCalled();

    const first = await pureRecall().read(input({ limit: 1, chunkBytes: 48 }));
    expect(first.nextCursor).not.toBeNull();
    const beforeWrongKey = readExactHistoryMock.mock.calls.length;
    await expect(pureRecall(undefined, OTHER_CURSOR_SECRET).read(input({
      cursor: first.nextCursor,
      limit: 1,
      chunkBytes: 48,
    }))).rejects.toBeInstanceOf(RawHistoryCursorError);
    expect(readExactHistoryMock).toHaveBeenCalledTimes(beforeWrongKey);
  });

  it("rejects referenced data mutated between pages instead of reconstructing a hybrid", async () => {
    const objectRef = "sealed:exact:gateway:mutable";
    let payload = { text: `original-${"x".repeat(240)}` };
    const objects: CompactionExactObjectReader = {
      openReference: vi.fn(async () => payload),
    };
    readExactHistoryMock.mockImplementation(async (
      _db: Db,
      read: ReadExactHistoryInput,
      reader?: CompactionExactObjectReader,
    ) => {
      expect(read).toMatchObject({ sessionId: SID, limit: 1 });
      const data = await reader!.openReference(objectRef);
      return {
        items: [referenceEntry("1", "mutable-item", objectRef, data)],
        nextCursor: null,
      };
    });
    const recall = pureRecall(objects);
    const read = (cursor: string | null) => recall.read(input({
      cursor,
      limit: 1,
      chunkBytes: 32,
    }));

    const first = await read(null);
    expect(first.chunks).toHaveLength(1);
    expect(first.nextCursor).not.toBeNull();
    payload = { text: `mutated-${"y".repeat(240)}` };

    await expect(read(first.nextCursor)).rejects.toBeInstanceOf(RawHistoryCursorError);
    expect(objects.openReference).toHaveBeenCalledTimes(2);
  });

  it("never assigns ambiguous all-null child lineage to the caller current root", async () => {
    useHistory([inlineEntry("1", "ambiguous-child", { repeatedPrompt: true }, {
      sessionId: OTHER_SID,
      rootTaskRunId: null,
      logicalWorkerId: null,
      attemptId: null,
    })]);
    const recall = pureRecall();

    await expect(recall.read(input())).rejects.toBeInstanceOf(RawHistoryContractError);
    const scoped = await recall.read(input({ rootTaskRunId: ROOT }));
    expect(scoped).toEqual({ chunks: [], nextCursor: null });
    expect(readInputs()[1]).toMatchObject({
      rootTaskRunId: ROOT,
      logicalWorkerId: null,
      attemptId: null,
      limit: 1,
    });
  });

  it("does not infer null lineage when a session has multiple roots", async () => {
    useHistory([
      inlineEntry("1", "root-one", { root: 1 }),
      inlineEntry("2", "null-among-roots", { unknown: true }, {
        rootTaskRunId: null,
        logicalWorkerId: null,
        attemptId: null,
      }),
      inlineEntry("3", "root-two", { root: 2 }, { rootTaskRunId: OTHER_ROOT }),
    ]);
    const recall = pureRecall();

    await expect(recall.read(input())).rejects.toBeInstanceOf(RawHistoryContractError);
    const scoped = await recall.read(input({ rootTaskRunId: ROOT }));
    expect(scoped.chunks.map((chunk) => chunk.item.stableId)).toEqual(["root-one"]);
  });

  it("never relabels a null-root worker item with main-root lineage", async () => {
    readExactHistoryMock.mockResolvedValue({
      items: [inlineEntry("1", "legacy-worker", { legacy: true }, {
        rootTaskRunId: null,
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      })],
      nextCursor: null,
    });
    const recall = pureRecall();

    await expect(recall.read(input({ rootTaskRunId: ROOT })))
      .rejects.toBeInstanceOf(RawHistoryContractError);
  });

  it.each([
    {
      name: "unrelated legacy artifact",
      stableId: "legacy-artifact",
      overrides: { kind: "artifact", rootTaskRunId: null, logicalWorkerId: null, attemptId: null },
    },
    {
      name: "unrelated legacy compaction",
      stableId: "legacy-compaction",
      overrides: { kind: "compaction", rootTaskRunId: null, logicalWorkerId: null, attemptId: null },
    },
    {
      name: "item from an unrelated root",
      stableId: "other-root-item",
      overrides: { rootTaskRunId: OTHER_ROOT, logicalWorkerId: null, attemptId: null },
    },
  ])("rejects $name instead of assigning the current root", async ({ stableId, overrides }) => {
    readExactHistoryMock.mockResolvedValue({
      items: [inlineEntry("1", stableId, { legacy: true },
        overrides as Partial<StoredExactHistoryItem>)],
      nextCursor: null,
    });
    const recall = pureRecall();

    await expect(recall.read(input({ rootTaskRunId: ROOT })))
      .rejects.toBeInstanceOf(RawHistoryContractError);
  });

  it("keeps owner raw main-only by default and filters the current root", async () => {
    useHistory([
      inlineEntry("1", "main-current", { main: true }),
      inlineEntry("2", "worker-current", { worker: true }, {
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      }),
      inlineEntry("3", "main-other-root", { otherRoot: true }, { rootTaskRunId: OTHER_ROOT }),
    ]);
    const recall = pureRecall();

    const page = await recall.read(input({ rootTaskRunId: ROOT }));

    expect(page.chunks.map((chunk) => chunk.item.stableId)).toEqual(["main-current"]);
    expect(readInputs()[0]).toMatchObject({
      rootTaskRunId: ROOT,
      logicalWorkerId: null,
      attemptId: null,
      limit: 1,
    });
  });

  it("preserves and filters exact root, worker and attempt lineage for internal recall", async () => {
    useHistory([
      inlineEntry("1", "main-item", { main: true }),
      inlineEntry("2", "worker-target", { worker: true }, {
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      }),
      inlineEntry("3", "worker-other-attempt", { otherAttempt: true }, {
        logicalWorkerId: "worker-1",
        attemptId: "attempt-2",
      }),
      inlineEntry("4", "worker-other-root", { otherRoot: true }, {
        rootTaskRunId: OTHER_ROOT,
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      }),
    ]);
    const recall = pureRecall();

    const page = await recall.read(input({
      rootTaskRunId: ROOT,
      logicalWorkerId: "worker-1",
      attemptId: "attempt-1",
    }));

    expect(page.chunks.map((chunk) => chunk.item.stableId)).toEqual(["worker-target"]);
    expect(page.chunks[0]!.item).toMatchObject({
      rootTaskRunId: ROOT,
      logicalWorkerId: "worker-1",
      attemptId: "attempt-1",
    });
    expect(readInputs()[0]).toMatchObject({
      rootTaskRunId: ROOT,
      logicalWorkerId: "worker-1",
      attemptId: "attempt-1",
      limit: 1,
    });
  });

  it("preserves the actual objectRef and resolves it only through the injected DB reader", async () => {
    const objectRef = "sealed:exact:gateway:object-1";
    const payload = { exact: "resolved sealed value" };
    const objects: CompactionExactObjectReader = {
      openReference: vi.fn(async (reference: string) => reference === objectRef ? payload : null),
    };
    readExactHistoryMock.mockImplementation(async (
      _db: Db,
      read: ReadExactHistoryInput,
      reader?: CompactionExactObjectReader,
    ) => {
      expect(read).toMatchObject({ sessionId: SID, limit: 1 });
      expect(reader).toBe(objects);
      const data = await reader!.openReference(objectRef);
      return { items: [referenceEntry("1", "object-1", objectRef, data)], nextCursor: null };
    });
    const recall = pureRecall(objects);

    const page = await recall.read(input());

    expect(page.chunks).toHaveLength(1);
    expect(page.chunks[0]!.item.objectRef).toBe(objectRef);
    expect(Object.hasOwn(page.chunks[0]!.item, "inlinePayload")).toBe(false);
    expect(JSON.parse(page.chunks[0]!.data)).toEqual(payload);
    expect(objects.openReference).toHaveBeenCalledTimes(1);
    expect(objects.openReference).toHaveBeenCalledWith(objectRef);
  });

  it("redacts resolved data and metadata before multi-chunk projection", async () => {
    const secret = "fixture-exact-recall-canary";
    const policy = { secretValues: [secret], providerBaseUrls: [] };
    const payload = {
      authorization: `Bearer ${secret}`,
      ordinary: "keep this",
      text: `${"x".repeat(180)}${secret}${"🌍".repeat(20)}`,
    };
    useHistory([inlineEntry("1", "redacted-item", payload, {
      eventCursor: `https://events.example.invalid/${secret}`,
    })]);
    const redact = (value: unknown): unknown => redactForProjection(value, policy);
    const recall = pureRecall();
    const chunks: ExactRecallChunk[] = [];
    let cursor: string | null = null;

    for (let page = 0; page < 10; page += 1) {
      const result = await recall.read(input({ cursor, limit: 2, chunkBytes: 48, redact }));
      chunks.push(...result.chunks);
      cursor = result.nextCursor;
      if (cursor === null) break;
    }

    expect(cursor).toBeNull();
    expect(chunks.length).toBeGreaterThan(2);
    const reconstructed = chunks.map((chunk) => chunk.data).join("");
    expect(reconstructed).toBe(JSON.stringify(redactForProjection(payload, policy)));
    expect(JSON.parse(reconstructed)).toMatchObject({
      authorization: "[redacted]",
      ordinary: "keep this",
    });
    expect(chunks[0]!.item.eventCursor).toBe("[redacted]");
    for (const chunk of chunks) {
      expect(Buffer.byteLength(chunk.data, "utf8")).toBeLessThanOrEqual(48);
      expect(JSON.stringify(chunk).includes(secret)).toBe(false);
    }
  });

  it("fails closed on missing referenced data without reading a path or secret fallback", async () => {
    const objects: CompactionExactObjectReader = { openReference: vi.fn(async () => null) };
    readExactHistoryMock.mockResolvedValue({
      items: [referenceEntry("1", "missing", "file:///etc/passwd", null)],
      nextCursor: null,
    });
    const recall = pureRecall(objects);

    await expect(recall.read(input())).rejects.toBeInstanceOf(RawHistoryContractError);
    expect(objects.openReference).not.toHaveBeenCalled();
  });

  it("rejects DB-position, item-offset, cross-session and cross-root cursor confusion", async () => {
    useHistory([
      inlineEntry("1", "item-1", { text: "one" }),
      inlineEntry("2", "item-2", { text: "two" }),
    ]);
    const recall = pureRecall();
    const first = await recall.read(input({ limit: 1 }));
    const cursor = first.nextCursor!;
    expect(cursor).not.toBeNull();
    const callsBeforeInvalidReads = readExactHistoryMock.mock.calls.length;
    const itemOffsetCursor = Buffer.from(JSON.stringify({ id: "item-1", nextOffset: 4 }), "utf8")
      .toString("base64url");

    await expect(recall.read(input({ cursor: "1" }))).rejects.toBeInstanceOf(RawHistoryCursorError);
    await expect(recall.read(input({ cursor: itemOffsetCursor })))
      .rejects.toBeInstanceOf(RawHistoryCursorError);
    await expect(recall.read(input({ cursor, sessionId: OTHER_SID })))
      .rejects.toBeInstanceOf(RawHistoryCursorError);
    await expect(recall.read(input({ cursor, rootTaskRunId: OTHER_ROOT })))
      .rejects.toBeInstanceOf(RawHistoryCursorError);
    expect(readExactHistoryMock).toHaveBeenCalledTimes(callsBeforeInvalidReads);

    const second = await recall.read(input({ cursor, limit: 1 }));
    expect(second.chunks[0]!.item.stableId).toBe("item-2");
  });

  it("binds continuation cursors to root, worker and attempt scope", async () => {
    useHistory([
      inlineEntry("1", "scoped-1", { sequence: 1 }, {
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      }),
      inlineEntry("2", "scoped-2", { sequence: 2 }, {
        logicalWorkerId: "worker-1",
        attemptId: "attempt-1",
      }),
    ]);
    const recall = pureRecall();
    const scope = {
      rootTaskRunId: ROOT,
      logicalWorkerId: "worker-1",
      attemptId: "attempt-1",
    } as const;
    const first = await recall.read(input({ ...scope, limit: 1 }));
    const cursor = first.nextCursor!;
    expect(cursor).not.toBeNull();
    const callsBeforeInvalidReads = readExactHistoryMock.mock.calls.length;
    const invalidScopes: Array<Partial<BoundedExactRecallRead>> = [
      { ...scope, rootTaskRunId: OTHER_ROOT },
      { ...scope, logicalWorkerId: "worker-2" },
      { ...scope, attemptId: "attempt-2" },
      { rootTaskRunId: ROOT },
    ];

    for (const invalidScope of invalidScopes) {
      await expect(recall.read(input({ ...invalidScope, cursor })))
        .rejects.toBeInstanceOf(RawHistoryCursorError);
    }
    expect(readExactHistoryMock).toHaveBeenCalledTimes(callsBeforeInvalidReads);

    const second = await recall.read(input({ ...scope, cursor, limit: 1 }));
    expect(second.chunks[0]!.item.stableId).toBe("scoped-2");
    expect(readInputs().at(-1)).toMatchObject({ ...scope, limit: 1 });
  });
});

describe.skipIf(!TEST_DATABASE_URL).sequential("gateway bounded exact recall (real Postgres, UNEXECUTED)", () => {
  let scratch: MigrationScratch;
  let db: Db;

  beforeAll(async () => {
    scratch = await createMigrationScratch(TEST_DATABASE_URL!, "gateway_exact_recall");
    await migrate(scratch.url);
    db = createDb(scratch.url, { max: 4 });
  }, 180_000);

  beforeEach(() => {
    readExactHistoryMock.mockImplementation(realReadExactHistory);
  });

  afterAll(async () => {
    await closeDb(db);
    await scratch?.close();
  }, 30_000);

  async function mainFixture(label: string) {
    const userId = newId();
    await users.ensure(db, userId, null);
    const session = await sessions.create(db, userId, label);
    const prompt = await messages.append(db, {
      sessionId: session.id,
      role: "user",
      content: `${label} root`,
    });
    const root = await runs.create(db, { sessionId: session.id, promptMessageId: prompt.id });
    expect(await runs.claimNext(db, root.id)).toBe(true);
    return { userId, sessionId: session.id, rootTaskRunId: root.id };
  }

  async function appendCanonicalMessage(sessionId: string, rootTaskRunId: string, content: string) {
    const message = await messages.append(db, { sessionId, role: "assistant", content });
    await appendExactItem(db, {
      stableId: message.id,
      kind: "message",
      sessionId,
      rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      eventCursor: message.id,
      objectRef: `postgres:messages/${message.id}`,
      byteLength: Buffer.byteLength(content, "utf8"),
    });
    return message;
  }

  it("pages real canonical reads and preserves actual postgres object refs", async () => {
    const fixture = await mainFixture("gateway exact recall pages");
    const firstMessage = await appendCanonicalMessage(
      fixture.sessionId,
      fixture.rootTaskRunId,
      "first exact canonical value",
    );
    const secondMessage = await appendCanonicalMessage(
      fixture.sessionId,
      fixture.rootTaskRunId,
      "second exact canonical value",
    );
    const recall = createBoundedExactRecall({ db, cursorSecret: TEST_CURSOR_SECRET });

    const first = await recall.read(input({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      limit: 1,
    }));
    expect(first.chunks).toHaveLength(1);
    expect(first.chunks[0]!.item.objectRef).toBe(`postgres:messages/${firstMessage.id}`);
    expect(JSON.parse(first.chunks[0]!.data)).toMatchObject({
      id: firstMessage.id,
      content: "first exact canonical value",
    });
    expect(first.nextCursor).not.toBeNull();

    const second = await recall.read(input({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      cursor: first.nextCursor,
      limit: 1,
    }));
    expect(second.chunks).toHaveLength(1);
    expect(second.chunks[0]!.item.objectRef).toBe(`postgres:messages/${secondMessage.id}`);
    expect(JSON.parse(second.chunks[0]!.data)).toMatchObject({
      id: secondMessage.id,
      content: "second exact canonical value",
    });
    expect(second.nextCursor).toBeNull();
    expect(readInputs().map((read) => read.limit)).toEqual([1, 1]);
  });

  it("keeps ambiguous all-null lineage unreadable instead of assigning the current root", async () => {
    const fixture = await mainFixture("gateway exact legacy root");
    const payload = { content: "legacy lineage remains unknown" };
    await db.insert(schema.compactionHistoryItems).values({
      sessionId: fixture.sessionId,
      rootTaskRunId: null,
      logicalWorkerId: null,
      attemptId: null,
      kind: "message",
      stableId: "ambiguous-null-lineage",
      eventCursor: "ambiguous-null-lineage",
      inlinePayload: payload,
      byteLength: Buffer.byteLength(JSON.stringify(payload), "utf8"),
    });
    const recall = createBoundedExactRecall({ db, cursorSecret: TEST_CURSOR_SECRET });

    await expect(recall.read(input({ sessionId: fixture.sessionId })))
      .rejects.toBeInstanceOf(RawHistoryContractError);
    const scoped = await recall.read(input({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
    }));
    expect(scoped).toEqual({ chunks: [], nextCursor: null });
    expect(readInputs().at(-1)).toMatchObject({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      limit: 1,
    });
    const stored = await db.select({ rootTaskRunId: schema.compactionHistoryItems.rootTaskRunId })
      .from(schema.compactionHistoryItems)
      .where(eq(schema.compactionHistoryItems.stableId, "ambiguous-null-lineage"));
    expect(stored).toEqual([{ rootTaskRunId: null }]);
  });

  it("rejects foreign root evidence through the real DB-scoped read", async () => {
    const fixture = await mainFixture("gateway exact root owner");
    const foreign = await mainFixture("gateway exact foreign root");
    await appendCanonicalMessage(fixture.sessionId, fixture.rootTaskRunId, "root-private exact value");
    const recall = createBoundedExactRecall({ db, cursorSecret: TEST_CURSOR_SECRET });

    await expect(recall.read(input({
      sessionId: fixture.sessionId,
      rootTaskRunId: foreign.rootTaskRunId,
    }))).rejects.toMatchObject({ code: "actor_mismatch" });
  });

  it("fails closed when a real canonical reference is missing", async () => {
    const fixture = await mainFixture("gateway exact missing reference");
    const missingId = newId();
    await db.insert(schema.compactionHistoryItems).values({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
      logicalWorkerId: null,
      attemptId: null,
      kind: "message",
      stableId: missingId,
      eventCursor: missingId,
      objectRef: `postgres:messages/${missingId}`,
      byteLength: 1,
    });
    const recall = createBoundedExactRecall({ db, cursorSecret: TEST_CURSOR_SECRET });

    await expect(recall.read(input({
      sessionId: fixture.sessionId,
      rootTaskRunId: fixture.rootTaskRunId,
    }))).rejects.toMatchObject({ code: "history_reference_unavailable" });
  });
});
