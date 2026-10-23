import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

import { createDb, migrate, type Db } from "./client.js";
import { newId, sessions, users } from "./repos.js";
import { sessions as sessionsTable, studioRepos as studioReposTable } from "./schema.js";
import { studioRepos as studioReposRepo } from "./studioRepos.js";

/**
 * The Studio session → repo binding. Real Postgres: the point of the row is
 * that a reload cannot orphan a clone, and that nobody can retarget another
 * person's session at a repository of their choosing.
 */
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;

describe.skipIf(!TEST_DATABASE_URL)("studioReposRepo", () => {
  let db: Db;

  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function user(): Promise<string> {
    const uid = `u-${newId()}`;
    await users.ensure(db, uid, `${uid}@example.test`);
    return uid;
  }

  async function sessionFor(uid: string): Promise<string> {
    const row = await sessions.create(db, uid, "studio");
    return row.id;
  }

  it("stores and reads the binding back", async () => {
    const uid = await user();
    const sessionId = await sessionFor(uid);

    const stored = await studioReposRepo.upsert(db, {
      sessionId,
      userId: uid,
      repo: "acme/app",
      repoDir: "app",
      branch: "main",
    });
    expect(stored).toMatchObject({ sessionId, repo: "acme/app", repoDir: "app", branch: "main" });
    expect(stored!.createdAt).toBeInstanceOf(Date);

    const read = await studioReposRepo.get(db, uid, sessionId);
    expect(read).toEqual(stored);
  });

  it("replaces the binding on a second clone instead of accumulating rows", async () => {
    const uid = await user();
    const sessionId = await sessionFor(uid);

    await studioReposRepo.upsert(db, {
      sessionId,
      userId: uid,
      repo: "acme/one",
      repoDir: "one",
      branch: "main",
    });
    await studioReposRepo.upsert(db, {
      sessionId,
      userId: uid,
      repo: "acme/two",
      repoDir: "two",
      branch: "feat/x",
    });

    const rows = await db.select().from(studioReposTable).where(eq(studioReposTable.sessionId, sessionId));
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ repo: "acme/two", repoDir: "two", branch: "feat/x" });
  });

  it("is owner-scoped on read, upsert and remove", async () => {
    const owner = await user();
    const other = await user();
    const sessionId = await sessionFor(owner);

    await studioReposRepo.upsert(db, {
      sessionId,
      userId: owner,
      repo: "acme/app",
      repoDir: "app",
      branch: "main",
    });

    expect(await studioReposRepo.get(db, other, sessionId)).toBeNull();
    expect(
      await studioReposRepo.upsert(db, {
        sessionId,
        userId: other,
        repo: "evil/repo",
        repoDir: "evil",
        branch: "main",
      }),
    ).toBeNull();
    expect(await studioReposRepo.remove(db, other, sessionId)).toBe(false);

    // The original binding is untouched.
    expect(await studioReposRepo.get(db, owner, sessionId)).toMatchObject({ repo: "acme/app" });
    expect(await studioReposRepo.remove(db, owner, sessionId)).toBe(true);
    expect(await studioReposRepo.get(db, owner, sessionId)).toBeNull();
  });

  it("cascades when the session is hard-deleted", async () => {
    const uid = await user();
    const sessionId = await sessionFor(uid);
    await studioReposRepo.upsert(db, {
      sessionId,
      userId: uid,
      repo: "acme/app",
      repoDir: "app",
      branch: "main",
    });

    await db.delete(sessionsTable).where(eq(sessionsTable.id, sessionId));
    expect(await studioReposRepo.get(db, uid, sessionId)).toBeNull();
  });
});
