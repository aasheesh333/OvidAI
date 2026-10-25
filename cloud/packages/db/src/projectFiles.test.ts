import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq, sql } from "drizzle-orm";
import { createDb, migrate, type Db } from "./client.js";
import { createPrivateMemoryStore } from "./privateMemory.js";
import {
  ProjectFileLimitError,
  assertSessionFileCapacity,
  projectFileUsage,
} from "./projectFiles.js";
import { PROJECT_FILE_CAPS, projectsRepo } from "./projectRepos.js";
import { attachments, newId, sessions, users, workspaceObjects } from "./repos.js";
import {
  attachments as attachmentsTable,
  plans as plansTable,
  sessions as sessionsTable,
  workspaceObjects as workspaceObjectsTable,
} from "./schema.js";

const url = process.env.TEST_DATABASE_URL;

/**
 * W1 follow-up (0022): one project budget across memory + attachments +
 * active artifacts. These are REAL-Postgres tests: the enforcement is a
 * transactional count under an advisory lock, so mocking the db would prove
 * nothing.
 */
describe.skipIf(!url)("project-scoped file accounting (real postgres)", () => {
  let db: Db;
  let store: ReturnType<typeof createPrivateMemoryStore>;

  beforeAll(async () => {
    await migrate(url!);
    db = createDb(url!);
    store = createPrivateMemoryStore(db);
    await db.delete(plansTable);
    const base = {
      enabled: true,
      aliases: [] as string[],
      windowHours: 24,
      mult: "1",
      slowMode: false,
      autoOss: false,
    };
    await db.insert(plansTable).values([
      { ...base, id: "free", name: "Free", priceUsd: "0", position: 0 },
      { ...base, id: "go", name: "Ovid Go", priceUsd: "5", position: 1 },
      { ...base, id: "plus", name: "Ovid Plus", priceUsd: "18", position: 2 },
      { ...base, id: "pro", name: "Ovid Pro", priceUsd: "99", position: 3 },
    ]);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  async function fixture(): Promise<{
    uid: string;
    projectId: string;
    sessionId: string;
    standaloneId: string;
  }> {
    const uid = `pf-${newId()}`;
    await users.ensure(db, uid, null);
    const project = await projectsRepo.create(db, uid, `Project ${newId().slice(0, 8)}`);
    const session = await sessions.create(db, uid, "in project");
    await db
      .update(sessionsTable)
      .set({ projectId: project!.id })
      .where(eq(sessionsTable.id, session.id));
    const standalone = await sessions.create(db, uid, "standalone");
    return { uid, projectId: project!.id, sessionId: session.id, standaloneId: standalone.id };
  }

  function attachmentInput(uid: string, sessionId: string, size = 10) {
    const id = newId();
    return {
      id,
      sessionId,
      userId: uid,
      name: `${id}.bin`,
      size,
      r2Key: `users/${uid}/sessions/${sessionId}/uploads/${id}`,
    };
  }

  async function addAttachment(uid: string, sessionId: string, size = 10): Promise<void> {
    await attachments.create(db, attachmentInput(uid, sessionId, size));
  }

  async function addArtifact(uid: string, sessionId: string, bytes = 20): Promise<string> {
    const id = newId();
    await workspaceObjects.registerArtifact(db, {
      id,
      userId: uid,
      sessionId,
      r2Key: `users/${uid}/sessions/${sessionId}/artifacts/${id}`,
      bytes,
      sha256: "a".repeat(64),
      contentType: "application/octet-stream",
      meta: { name: `${id}.bin` },
    });
    return id;
  }

  it("counts memory, attachments and active artifacts together with bytes", async () => {
    const { uid, projectId, sessionId, standaloneId } = await fixture();
    await store.save(uid, { projectId, maxFiles: 80 }, "MEMORY.md", "hello", undefined);
    await addAttachment(uid, sessionId, 100);
    await addArtifact(uid, sessionId, 200);
    // Standalone files never enter the project's budget.
    await addAttachment(uid, standaloneId, 999);

    const usage = await projectFileUsage(db, uid, projectId);
    expect(usage.used).toBe(3);
    expect(usage.memoryFiles).toBe(1);
    expect(usage.attachments).toBe(1);
    expect(usage.artifacts).toBe(1);
    expect(usage.bytes).toBe(5 + 100 + 200);

    const summary = await projectsRepo.getSummary(db, uid, projectId);
    expect(summary).not.toBeNull();
    expect(summary!.fileCount).toBe(3);
    expect(summary!.fileCap).toBe(PROJECT_FILE_CAPS[0]);
    expect(summary!.fileBreakdown).toEqual({ memory: 1, attachments: 1, artifacts: 1 });
    expect(summary!.fileBytes).toBe(305);
  });

  // UNEXECUTED N1: failed ordinary uploads consume neither slots nor bytes.
  it("excludes failed attachments from project usage consistently", async () => {
    const { uid, projectId, sessionId } = await fixture();
    await addAttachment(uid, sessionId, 12);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(1);
    await db.update(attachmentsTable)
      .set({ uploadStatus: "failed", actualBytes: 12, finalizedAt: null })
      .where(eq(attachmentsTable.sessionId, sessionId));
    expect(await projectFileUsage(db, uid, projectId)).toMatchObject({
      used: 0,
      attachments: 0,
      attachmentBytes: 0,
      bytes: 0,
    });
    await addAttachment(uid, sessionId, 3);
    expect(await projectFileUsage(db, uid, projectId)).toMatchObject({
      used: 1,
      attachments: 1,
      attachmentBytes: 3,
    });
  });

  it("refuses the write after the last allowed slot; deleting a file frees it", async () => {
    const { uid, projectId, sessionId } = await fixture();
    // One memory file + 78 uploads = 79 used; an artifact takes the last slot.
    await store.save(uid, { projectId, maxFiles: 80 }, "MEMORY.md", "m", undefined);
    for (let i = 0; i < 78; i++) await addAttachment(uid, sessionId);
    const artifactId = await addArtifact(uid, sessionId);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(80);

    // Next upload is refused BEFORE a row exists.
    await expect(addAttachment(uid, sessionId)).rejects.toBeInstanceOf(ProjectFileLimitError);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(80);
    const attachmentRows = await db
      .select({ count: sql<number>`count(*)::int` })
      .from(attachmentsTable)
      .where(eq(attachmentsTable.projectId, projectId));
    expect(attachmentRows[0]!.count).toBe(78);

    // Soft-deleting an artifact frees a slot; the next upload is accepted.
    await db
      .update(workspaceObjectsTable)
      .set({ status: "deleted" })
      .where(eq(workspaceObjectsTable.id, artifactId));
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(79);
    await expect(addAttachment(uid, sessionId)).resolves.toBeUndefined();
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(80);

    // Hard-deleting an upload frees a slot too.
    const [one] = await db
      .select({ id: attachmentsTable.id })
      .from(attachmentsTable)
      .where(eq(attachmentsTable.projectId, projectId))
      .limit(1);
    await db.delete(attachmentsTable).where(eq(attachmentsTable.id, one!.id));
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(79);
  });

  it("project memory shares the same budget (save is refused when full)", async () => {
    const { uid, projectId, sessionId } = await fixture();
    for (let i = 0; i < 80; i++) await addAttachment(uid, sessionId);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(80);
    await expect(
      store.save(uid, { projectId, maxFiles: 80 }, "NEW.md", "x", undefined),
    ).rejects.toMatchObject({ code: "limit_reached" });
  });

  it("standalone chats are unaffected and have no project budget", async () => {
    const { uid, standaloneId } = await fixture();
    for (let i = 0; i < 5; i++) await addAttachment(uid, standaloneId);
    const usage = await assertSessionFileCapacity(db, uid, standaloneId, 1);
    expect(usage).toBeNull();
  });

  it("cross-user and cross-project isolation", async () => {
    const a = await fixture();
    const b = await fixture();
    await addAttachment(a.uid, a.sessionId);
    await addAttachment(b.uid, b.sessionId);
    expect((await projectFileUsage(db, a.uid, a.projectId)).used).toBe(1);
    expect((await projectFileUsage(db, b.uid, b.projectId)).used).toBe(1);
    // Foreign project is invisible to the owner-scoped summary and capacity check.
    expect(await projectsRepo.getSummary(db, a.uid, b.projectId)).toBeNull();
    expect(await assertSessionFileCapacity(db, a.uid, b.sessionId, 1)).toBeNull();
    // Foreign sessions never gain a project through the owner-scoped helper.
    expect(await assertSessionFileCapacity(db, b.uid, a.sessionId, 1)).toBeNull();
  });

  it("legacy rows with NULL project_id are attributed through the session join", async () => {
    const { uid, projectId, sessionId } = await fixture();
    // Simulate a pre-0022 row that never got the backfill (raw insert).
    const legacyId = newId();
    await db.insert(attachmentsTable).values({
      id: legacyId,
      sessionId,
      userId: uid,
      projectId: null,
      name: "legacy.bin",
      size: 7,
      r2Key: `legacy/${legacyId}`,
    });
    const legacyArtifact = newId();
    await db.insert(workspaceObjectsTable).values({
      id: legacyArtifact,
      userId: uid,
      sessionId,
      projectId: null,
      kind: "artifact",
      r2Key: `legacy-artifact/${legacyArtifact}`,
      bytes: 9,
      sha256: "b".repeat(64),
      contentType: "application/octet-stream",
      status: "active",
      meta: { name: "legacy-artifact.bin" },
    });

    const usage = await projectFileUsage(db, uid, projectId);
    expect(usage.used).toBe(2);
    expect(usage.bytes).toBe(16);
  });

  it("moving a chat restamps its files and the old project stops counting them", async () => {
    const { uid, projectId, sessionId } = await fixture();
    const other = await projectsRepo.create(db, uid, `Other ${newId().slice(0, 8)}`);
    await addAttachment(uid, sessionId);
    await addArtifact(uid, sessionId);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(2);

    await projectsRepo.moveSession(db, uid, sessionId, other!.id);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(0);
    expect((await projectFileUsage(db, uid, other!.id)).used).toBe(2);

    await projectsRepo.moveSession(db, uid, sessionId, null);
    expect((await projectFileUsage(db, uid, other!.id)).used).toBe(0);
    const [stamped] = await db
      .select({ projectId: attachmentsTable.projectId })
      .from(attachmentsTable)
      .where(eq(attachmentsTable.sessionId, sessionId))
      .limit(1);
    expect(stamped!.projectId).toBeNull();
  });

  it("soft-deleting a chat frees its upload slots but keeps its artifacts (Vault retention)", async () => {
    const { uid, projectId, sessionId } = await fixture();
    await addAttachment(uid, sessionId, 11);
    await addArtifact(uid, sessionId, 22);
    expect((await projectFileUsage(db, uid, projectId)).used).toBe(2);

    await db
      .update(sessionsTable)
      .set({ deletedAt: new Date() })
      .where(eq(sessionsTable.id, sessionId));

    // Mirrors W13's storage rule: a soft-deleted chat's attachment bytes are
    // freed; artifacts stay (they remain reachable in the account Vault).
    const usage = await projectFileUsage(db, uid, projectId);
    expect(usage.used).toBe(1);
    expect(usage.attachments).toBe(0);
    expect(usage.artifacts).toBe(1);
    expect(usage.bytes).toBe(22);
  });

  it("an unknown project contributes no usage and reports the caller's cap", async () => {
    const { uid } = await fixture();
    const usage = await projectFileUsage(db, uid, newId());
    expect(usage.used).toBe(0);
    expect(usage.cap).toBe(PROJECT_FILE_CAPS[0]);
  });
});
