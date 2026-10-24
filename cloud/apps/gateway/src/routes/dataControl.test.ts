import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Db } from "@ovid/db";
import type { StorageAdapter } from "@ovid/storage";

/**
 * The two destructive settings actions.
 *
 *   POST /cloud/v1/data/delete-all — every chat, its rows, and the R2 objects
 *   those rows reference. Confirmed by typing the account's registered email.
 *
 *   POST /cloud/v1/memory/reset — every memory file the account owns (chat,
 *   project and the shared/global file), behind the same confirmation.
 *
 * The repository (the SQL that actually deletes) is mocked here so a failure
 * means the ROUTE is wrong. What this file pins is the contract a destructive
 * route must keep:
 *
 *   - the confirmation is part of the request, checked server-side against the
 *     account — a mismatch is a typed 400 and deletes nothing;
 *   - the scope is `request.principal.uid`, never a body field;
 *   - byte deletion goes through the storage adapter and happens BEFORE any
 *     row is removed, so a storage failure cannot orphan an object;
 *   - a deployment without storage refuses loudly when there are objects to
 *     remove instead of half-deleting;
 *   - a second call succeeds and reports zero, never an error.
 */
const repo = vi.hoisted(() => ({
  registeredEmail: vi.fn(),
  ownedStorageKeys: vi.fn(),
  deleteAllData: vi.fn(),
  resetAllMemory: vi.fn(),
}));

vi.mock("@ovid/db", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/db")>();
  return { ...actual, dataControlRepo: repo };
});

import { buildGateway } from "../app.js";
import type { Verifier } from "../auth.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

const DELETE_ALL = "/cloud/v1/data/delete-all";
const RESET_MEMORY = "/cloud/v1/memory/reset";

function stubStorage(
  failKeys: ReadonlySet<string> = new Set(),
  removeBeforeFailure = false,
) {
  const deleted: string[] = [];
  const adapter: StorageAdapter = {
    kind: "fs",
    put: async () => {
      throw new Error("unused in this test");
    },
    get: async () => null,
    getBuffer: async () => null,
    head: async () => null,
    delete: async (key) => {
      if (failKeys.has(key)) {
        if (removeBeforeFailure) deleted.push(key);
        throw new Error("storage unavailable");
      }
      deleted.push(key);
    },
    presignGet: async () => "",
    presignPut: async () => "",
    readerSpec: async () => null,
  };
  return { adapter, deleted };
}

function buildApp(opts: { storage?: StorageAdapter; verifier?: Verifier } = {}) {
  return buildGateway({
    system: stubSystemBus(),
    // Every db call this route makes is behind the mocked repo.
    db: {} as Db,
    queues: stubQueues().queues,
    verifier: opts.verifier ?? stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    ...(opts.storage !== undefined ? { storage: opts.storage } : {}),
  });
}

async function post(
  url: string,
  body: unknown,
  opts: {
    storage?: StorageAdapter;
    verifier?: Verifier;
    uid?: string;
    capable?: boolean;
  } = {},
) {
  const response = await buildApp(opts).inject({
    method: "POST",
    url,
    headers: {
      ...authHeaders(opts.uid ?? "u1"),
      ...(opts.capable === false
        ? {}
        : { "x-ovid-client-capabilities": "data-control-partial-v1" }),
    },
    payload: body as Record<string, unknown>,
  });
  return { status: response.statusCode, body: response.json() };
}

beforeEach(() => {
  vi.clearAllMocks();
  repo.registeredEmail.mockImplementation(async (_db: unknown, uid: string) => `${uid}@stub.test`);
  repo.ownedStorageKeys.mockResolvedValue([]);
  repo.deleteAllData.mockResolvedValue({
    sessions: 0,
    attachments: 0,
    artifacts: 0,
    workspaceFiles: 0,
  });
  repo.resetAllMemory.mockResolvedValue(0);
});

describe("POST /cloud/v1/data/delete-all", () => {
  it("requires the registered email: missing, wrong and untyped confirmations are 400s that delete nothing", async () => {
    for (const body of [{}, { confirmation: "" }, { confirmation: 42 }]) {
      const { status, body: response } = await post(DELETE_ALL, body);
      expect(status).toBe(400);
      expect(response.error.code).toBe("bad_request");
    }
    // A well-formed but wrong string is its own typed refusal, not a schema error.
    const mismatch = await post(DELETE_ALL, { confirmation: "someone@else.test" });
    expect(mismatch.status).toBe(400);
    expect(mismatch.body.error.code).toBe("confirmation_mismatch");

    expect(repo.deleteAllData).not.toHaveBeenCalled();
    expect(repo.ownedStorageKeys).not.toHaveBeenCalled();
  });

  it("accepts the registered email case-insensitively and trimmed, and never echoes it on failure", async () => {
    const ok = await post(DELETE_ALL, { confirmation: "  U1@STUB.TEST  " });
    expect(ok.status).toBe(200);
    expect(repo.deleteAllData).toHaveBeenCalledWith(expect.anything(), "u1");

    const bad = await post(DELETE_ALL, { confirmation: "nope@stub.test" });
    expect(bad.status).toBe(400);
    expect(JSON.stringify(bad.body)).not.toContain("u1@stub.test");
  });

  it("deletes every referenced R2 object through the adapter before removing rows", async () => {
    repo.ownedStorageKeys.mockResolvedValue(["users/u1/a.bin", "users/u1/b.bin"]);
    repo.deleteAllData.mockResolvedValue({
      sessions: 3,
      attachments: 2,
      artifacts: 4,
      workspaceFiles: 1,
    });
    const { adapter, deleted } = stubStorage();
    const order: string[] = [];
    const deleteBytes = adapter.delete.bind(adapter);
    adapter.delete = async (key) => {
      order.push(`storage:${key}`);
      await deleteBytes(key);
    };
    repo.deleteAllData.mockImplementation(async () => {
      order.push("db");
      return { sessions: 3, attachments: 2, artifacts: 4, workspaceFiles: 1 };
    });

    const { status, body } = await post(
      DELETE_ALL,
      { confirmation: "u1@stub.test" },
      { storage: adapter },
    );

    expect(status).toBe(200);
    expect(deleted).toEqual(["users/u1/a.bin", "users/u1/b.bin"]);
    // Bytes first: a failed storage delete can never leave an orphaned object.
    expect(order).toEqual(["storage:users/u1/a.bin", "storage:users/u1/b.bin", "db"]);
    expect(repo.deleteAllData).toHaveBeenCalledWith(expect.anything(), "u1");
    expect(body.deleted).toMatchObject({
      sessions: 3,
      attachments: 2,
      artifacts: 4,
      workspaceFiles: 1,
      storageObjects: 2,
    });
  });

  it("refuses with a typed 503 when objects exist but no storage adapter is wired", async () => {
    repo.ownedStorageKeys.mockResolvedValue(["users/u1/a.bin"]);
    const { status, body } = await post(DELETE_ALL, { confirmation: "u1@stub.test" });
    expect(status).toBe(503);
    expect(body.error.code).toBe("storage_not_configured");
    expect(repo.deleteAllData).not.toHaveBeenCalled();
  });

  it("keeps rows for a retry but reports bytes already removed before a storage failure", async () => {
    repo.ownedStorageKeys.mockResolvedValue(["users/u1/a.bin", "users/u1/b.bin"]);
    const { adapter, deleted } = stubStorage(new Set(["users/u1/b.bin"]));
    const { status, body } = await post(
      DELETE_ALL,
      { confirmation: "u1@stub.test" },
      { storage: adapter },
    );
    expect(status).toBe(503);
    expect(body.error.code).toBe("storage_delete_partial");
    expect(body.error.message).not.toContain("Nothing was deleted");
    expect(body.error.confirmedDeletedStorageObjects).toBe(1);
    expect(body.error.message).toContain("At least 1 stored file was removed");
    expect(deleted).toEqual(["users/u1/a.bin"]);
    expect(repo.deleteAllData).not.toHaveBeenCalled();
  });

  it("does not claim nothing was deleted when the failing storage outcome is ambiguous", async () => {
    repo.ownedStorageKeys.mockResolvedValue(["users/u1/a.bin"]);
    const { adapter, deleted } = stubStorage(
      new Set(["users/u1/a.bin"]),
      true,
    );
    const { status, body } = await post(
      DELETE_ALL,
      { confirmation: "u1@stub.test" },
      { storage: adapter },
    );
    expect(status).toBe(503);
    expect(body.error.code).toBe("storage_delete_failed");
    expect(body.error.message).not.toContain("Nothing was deleted");
    expect(body.error.message).toContain("chats were not deleted");
    expect(deleted).toEqual(["users/u1/a.bin"]);
    expect(repo.deleteAllData).not.toHaveBeenCalled();
  });

  it("refuses an unsupported client before reading or deleting any storage", async () => {
    repo.ownedStorageKeys.mockResolvedValue(["users/u1/a.bin"]);
    const { adapter, deleted } = stubStorage();
    const { status, body } = await post(
      DELETE_ALL,
      { confirmation: "u1@stub.test" },
      { storage: adapter, capable: false },
    );
    expect(status).toBe(409);
    expect(body.error.code).toBe("client_upgrade_required");
    expect(repo.ownedStorageKeys).not.toHaveBeenCalled();
    expect(deleted).toEqual([]);
    expect(repo.deleteAllData).not.toHaveBeenCalled();
  });

  it("is idempotent: the second call answers 200 with zeroes", async () => {
    repo.deleteAllData
      .mockResolvedValueOnce({ sessions: 2, attachments: 1, artifacts: 1, workspaceFiles: 0 })
      .mockResolvedValueOnce({ sessions: 0, attachments: 0, artifacts: 0, workspaceFiles: 0 });

    const first = await post(DELETE_ALL, { confirmation: "u1@stub.test" });
    const second = await post(DELETE_ALL, { confirmation: "u1@stub.test" });

    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    expect(second.body.deleted).toEqual({
      sessions: 0,
      attachments: 0,
      artifacts: 0,
      workspaceFiles: 0,
      storageObjects: 0,
    });
  });

  it("takes its scope from the principal — a body-supplied uid is rejected, never honoured", async () => {
    const { status } = await post(DELETE_ALL, {
      confirmation: "u1@stub.test",
      uid: "victim",
    });
    expect(status).toBe(400);
    expect(repo.deleteAllData).not.toHaveBeenCalled();

    const ok = await post(
      DELETE_ALL,
      { confirmation: "u2@stub.test" },
      { uid: "u2" },
    );
    expect(ok.status).toBe(200);
    expect(repo.deleteAllData).toHaveBeenCalledWith(expect.anything(), "u2");
  });

  it("refuses when the account has no email on file to confirm against", async () => {
    repo.registeredEmail.mockResolvedValue(null);
    const noEmail: Verifier = async () => ({ uid: "u1", email: null, authTime: 0 });
    const { status, body } = await post(
      DELETE_ALL,
      { confirmation: "u1@stub.test" },
      { verifier: noEmail },
    );
    expect(status).toBe(409);
    expect(body.error.code).toBe("confirmation_unavailable");
    expect(repo.deleteAllData).not.toHaveBeenCalled();
  });
});

describe("POST /cloud/v1/memory/reset", () => {
  it("requires the registered email before wiping anything", async () => {
    const bad = await post(RESET_MEMORY, { confirmation: "someone@else.test" });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe("confirmation_mismatch");
    expect(repo.resetAllMemory).not.toHaveBeenCalled();
  });

  it("wipes every memory file for the caller and reports how many", async () => {
    repo.resetAllMemory.mockResolvedValue(7);
    const { status, body } = await post(RESET_MEMORY, { confirmation: "u1@stub.test" });
    expect(status).toBe(200);
    expect(repo.resetAllMemory).toHaveBeenCalledWith(expect.anything(), "u1");
    expect(body).toEqual({ reset: { files: 7 } });
  });

  it("is idempotent and never touches storage", async () => {
    repo.resetAllMemory.mockResolvedValueOnce(3).mockResolvedValueOnce(0);
    const { adapter } = stubStorage();
    const first = await post(RESET_MEMORY, { confirmation: "u1@stub.test" }, { storage: adapter });
    const second = await post(RESET_MEMORY, { confirmation: "u1@stub.test" }, { storage: adapter });
    expect(first.body).toEqual({ reset: { files: 3 } });
    expect(second.body).toEqual({ reset: { files: 0 } });
    expect(repo.ownedStorageKeys).not.toHaveBeenCalled();
  });
});
