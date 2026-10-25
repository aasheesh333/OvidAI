import { afterEach, beforeEach, describe, expect, it, vi, type MockInstance } from "vitest";
import {
  sessions,
  studioRepos,
  type Db,
  type SessionRow,
  type StudioRepoBinding,
  type StudioRepoUpsert,
} from "@ovid/db";

import { StudioRunBinding } from "./studioRunBinding.js";

const UID = "user-owner";
const SESSION_ID = "11111111-1111-4111-8111-111111111111";
const OTHER_SESSION_ID = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2026-10-24T12:00:00.000Z");

const SESSION: SessionRow = {
  id: SESSION_ID,
  userId: UID,
  title: "Studio",
  mode: "studio",
  projectId: null,
  createdAt: NOW,
  updatedAt: NOW,
  archivedAt: null,
  pinnedAt: null,
  deletedAt: null,
};

function row(patch: Partial<StudioRepoBinding> = {}): StudioRepoBinding {
  return {
    sessionId: SESSION_ID,
    userId: UID,
    repo: "acme/app",
    repoDir: "app",
    branch: "main",
    createdAt: NOW,
    updatedAt: NOW,
    ...patch,
  };
}

describe("StudioRunBinding", () => {
  let db: Db;
  let binding: StudioRunBinding;
  let sessionGet: MockInstance<typeof sessions.get>;
  let repoGet: MockInstance<typeof studioRepos.get>;
  let repoUpsert: MockInstance<typeof studioRepos.upsert>;
  let sql: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    sessionGet = vi.spyOn(sessions, "get").mockResolvedValue(SESSION);
    repoGet = vi.spyOn(studioRepos, "get").mockResolvedValue(row());
    repoUpsert = vi.spyOn(studioRepos, "upsert").mockImplementation(
      async (_db, input) => row(input),
    );
    sql = vi.fn(async () => []);
    db = { $client: sql } as unknown as Db;
    binding = new StudioRunBinding(db);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("reads only the verified uid/session binding", async () => {
    await expect(binding.get({ userId: UID, sessionId: SESSION_ID })).resolves.toEqual(row());
    expect(sessionGet).toHaveBeenCalledWith(db, SESSION_ID, UID);
    expect(repoGet).toHaveBeenCalledWith(db, UID, SESSION_ID);
  });

  it("fails closed for a foreign session without reading or writing its binding", async () => {
    sessionGet.mockResolvedValue(null);

    await expect(binding.get({ userId: UID, sessionId: OTHER_SESSION_ID }))
      .rejects.toMatchObject({ code: "not_found", message: "Session not found." });
    expect(repoGet).not.toHaveBeenCalled();

    const input: StudioRepoUpsert = {
      sessionId: OTHER_SESSION_ID,
      userId: UID,
      repo: "acme/evil",
      repoDir: "evil",
      branch: "main",
    };
    await expect(binding.upsert({ userId: UID, sessionId: OTHER_SESSION_ID }, input))
      .rejects.toMatchObject({ code: "not_found" });
    expect(repoUpsert).not.toHaveBeenCalled();
    expect(sql).not.toHaveBeenCalled();
  });

  it("verifies ownership again before storing a clone binding", async () => {
    const input = {
      sessionId: SESSION_ID,
      userId: UID,
      repo: "acme/app",
      repoDir: "actual-clone-dir",
      branch: "actual-branch",
    };
    await expect(binding.upsert({ userId: UID, sessionId: SESSION_ID }, input))
      .resolves.toMatchObject({ repoDir: "actual-clone-dir", branch: "actual-branch" });
    expect(sessionGet.mock.invocationCallOrder[0]).toBeLessThan(repoUpsert.mock.invocationCallOrder[0]!);
    expect(repoUpsert).toHaveBeenCalledWith(db, input);
  });

  it("uses one owner/binding-scoped conditional UPDATE for branch CAS", async () => {
    const expected = row();
    const updated = row({ branch: "topic", updatedAt: new Date("2026-10-24T12:01:00.000Z") });
    sql.mockResolvedValueOnce([updated]);

    await expect(binding.compareAndSetBranch(
      { userId: UID, sessionId: SESSION_ID },
      expected,
      "topic",
    )).resolves.toEqual(updated);

    expect(sql).toHaveBeenCalledTimes(1);
    const [strings, ...values] = sql.mock.calls[0]!;
    const text = (strings as unknown as TemplateStringsArray).join("?").replace(/\s+/g, " ");
    expect(text).toContain("UPDATE studio_repos");
    expect(text).toContain("SET branch =");
    expect(text).toContain("updated_at = NOW()");
    expect(text).toContain("session_id =");
    expect(text).toContain("user_id =");
    expect(text).toContain("repo =");
    expect(text).toContain("repo_dir =");
    expect(text).toContain("branch =");
    expect(text).toContain("RETURNING");
    expect(values).toEqual(["topic", SESSION_ID, UID, "acme/app", "app", "main"]);
    expect(repoUpsert).not.toHaveBeenCalled();
  });

  it("returns null on a stale branch CAS and never falls back to an overwrite", async () => {
    sql.mockResolvedValueOnce([]);

    await expect(binding.compareAndSetBranch(
      { userId: UID, sessionId: SESSION_ID },
      row({ branch: "main" }),
      "stale-topic",
    )).resolves.toBeNull();

    expect(repoUpsert).not.toHaveBeenCalled();
    expect(repoGet).not.toHaveBeenCalled();
  });

  it("does not issue a CAS for a foreign session", async () => {
    sessionGet.mockResolvedValue(null);

    await expect(binding.compareAndSetBranch(
      { userId: UID, sessionId: OTHER_SESSION_ID },
      row({ sessionId: OTHER_SESSION_ID }),
      "topic",
    )).rejects.toMatchObject({ code: "not_found" });
    expect(sql).not.toHaveBeenCalled();
    expect(repoUpsert).not.toHaveBeenCalled();
  });
});
