import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { eq } from "drizzle-orm";
import { PrivateMemoryError } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import { createPrivateMemoryStore } from "./privateMemory.js";
import { newId, sessions, users } from "./repos.js";
import {
  PROJECT_FILE_CAPS,
  ProjectError,
  projectFileCap,
  projectsRepo,
} from "./projectRepos.js";
import { plans as plansTable, privateMemoryFiles, sessions as sessionsTable, users as usersTable } from "./schema.js";

const url = process.env.TEST_DATABASE_URL;

describe.skipIf(!url)("W1 projects + project memory (real postgres)", () => {
  let db: Db;
  let store: ReturnType<typeof createPrivateMemoryStore>;

  beforeAll(async () => {
    await migrate(url!);
    db = createDb(url!);
    store = createPrivateMemoryStore(db);
    // The plan table is owner-editable; pin the four tiers this suite reads
    // so cap assertions do not depend on leftover rows from other files.
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

  async function fixture() {
    const uid = `proj-${newId()}`;
    await users.ensure(db, uid, null);
    return { uid };
  }

  it("creates, lists, renames and deletes owner-scoped projects; names are unique per owner", async () => {
    const { uid } = await fixture();
    const alpha = await projectsRepo.create(db, uid, "Alpha");
    expect(alpha).not.toBeNull();
    expect(alpha!.name).toBe("Alpha");
    expect(await projectsRepo.create(db, uid, "Alpha")).toBeNull();
    const beta = await projectsRepo.create(db, uid, "  Beta  ");
    expect(beta!.name).toBe("Beta");

    const list = await projectsRepo.list(db, uid);
    expect(list.map((p) => p.name)).toEqual(["Alpha", "Beta"]);
    expect(list[0]!.sessionCount).toBe(0);
    expect(list[0]!.fileCount).toBe(0);
    expect(list[0]!.fileCap).toBe(PROJECT_FILE_CAPS[0]);

    const renamed = await projectsRepo.rename(db, uid, alpha!.id, "Alpha 2");
    expect(renamed!.name).toBe("Alpha 2");
    await expect(projectsRepo.rename(db, uid, alpha!.id, "Beta")).rejects.toBeInstanceOf(ProjectError);

    expect(await projectsRepo.delete(db, uid, beta!.id)).toBe(true);
    expect(await projectsRepo.delete(db, uid, beta!.id)).toBe(false);
    expect((await projectsRepo.list(db, uid)).map((p) => p.name)).toEqual(["Alpha 2"]);
  });

  it("foreign projects are indistinguishable from unknown ones", async () => {
    const owner = await fixture();
    const stranger = await fixture();
    const project = (await projectsRepo.create(db, owner.uid, "Private"))!;

    expect(await projectsRepo.get(db, stranger.uid, project.id)).toBeNull();
    expect(await projectsRepo.rename(db, stranger.uid, project.id, "Hijacked")).toBeNull();
    expect(await projectsRepo.delete(db, stranger.uid, project.id)).toBe(false);
    // The owner's row is untouched.
    expect((await projectsRepo.get(db, owner.uid, project.id))!.name).toBe("Private");
  });

  it("moves an owned chat in and out of an owned project; foreign ids fail closed", async () => {
    const { uid } = await fixture();
    const other = await fixture();
    const project = (await projectsRepo.create(db, uid, "Work"))!;
    const foreignProject = (await projectsRepo.create(db, other.uid, "Theirs"))!;
    const mine = await sessions.create(db, uid, "Mine");
    const theirs = await sessions.create(db, other.uid, "Theirs");

    const moved = await projectsRepo.moveSession(db, uid, mine.id, project.id);
    expect(moved!.projectId).toBe(project.id);

    const summary = (await projectsRepo.list(db, uid)).find((p) => p.id === project.id)!;
    expect(summary.sessionCount).toBe(1);

    // A foreign project cannot receive this user's chat…
    await expect(projectsRepo.moveSession(db, uid, mine.id, foreignProject.id)).rejects.toBeInstanceOf(ProjectError);
    // …and a foreign chat cannot be moved by this user.
    expect(await projectsRepo.moveSession(db, uid, theirs.id, project.id)).toBeNull();

    // null detaches.
    expect((await projectsRepo.moveSession(db, uid, mine.id, null))!.projectId).toBeNull();
  });

  it("deleting a project detaches its chats and cascades its memory", async () => {
    const { uid } = await fixture();
    const project = (await projectsRepo.create(db, uid, "Temp"))!;
    const chat = await sessions.create(db, uid, "Chat");
    await projectsRepo.moveSession(db, uid, chat.id, project.id);
    await store.save(uid, { projectId: project.id }, "MEMORY.md", "temp fact");

    expect(await projectsRepo.delete(db, uid, project.id)).toBe(true);

    const [sessionRow] = await db.select().from(sessionsTable).where(eq(sessionsTable.id, chat.id));
    expect(sessionRow!.projectId).toBeNull();
    const memory = await db
      .select()
      .from(privateMemoryFiles)
      .where(eq(privateMemoryFiles.projectId, project.id));
    expect(memory).toEqual([]);
  });

  it("project memory is isolated: project A never reaches project B, a session, or another owner", async () => {
    const { uid } = await fixture();
    const other = await fixture();
    const a = (await projectsRepo.create(db, uid, "A"))!;
    const b = (await projectsRepo.create(db, uid, "B"))!;
    const foreign = (await projectsRepo.create(db, other.uid, "Foreign"))!;
    const chat = await sessions.create(db, uid, "Standalone");

    const saved = await store.save(uid, { projectId: a.id }, "MEMORY.md", "alpha-only fact");
    expect(saved.name).toBe("MEMORY.md");

    expect((await store.read(uid, { projectId: a.id }, "MEMORY.md"))?.content).toBe("alpha-only fact");
    // Project B is a different scope.
    expect(await store.read(uid, { projectId: b.id }, "MEMORY.md")).toBeNull();
    expect(await store.list(uid, { projectId: b.id })).toEqual([]);
    // A chat's session memory is a different scope too.
    expect(await store.read(uid, { sessionId: chat.id, shared: false }, "MEMORY.md")).toBeNull();
    // Another owner cannot name this project.
    await expect(store.read(other.uid, { projectId: a.id }, "MEMORY.md")).rejects.toBeInstanceOf(PrivateMemoryError);
    await expect(store.save(other.uid, { projectId: foreign.id }, "MEMORY.md", "x")).resolves.toBeTruthy();
    // Session memory still works and does not see project memory.
    await store.save(uid, { sessionId: chat.id, shared: false }, "MEMORY.md", "chat-only fact");
    expect((await store.read(uid, { sessionId: chat.id, shared: false }, "MEMORY.md"))?.content).toBe("chat-only fact");
    expect((await store.read(uid, { projectId: a.id }, "MEMORY.md"))?.content).toBe("alpha-only fact");
  });

  it("enforces the plan cap atomically for project memory (Free = 80)", async () => {
    const { uid } = await fixture();
    const project = (await projectsRepo.create(db, uid, "Capped"))!;
    expect(await projectFileCap(db, uid)).toBe(80);

    // Fill the project to one below its cap directly (the API path is
    // covered in the gateway suite); the last allowed write and the 81st
    // must be judged by the store's lock.
    await db.$client.unsafe(
      `INSERT INTO private_memory_files (user_id, scope, project_id, name, content, revision)
       SELECT $1, 'project:' || $2, $2, 'n' || g || '.md', 'x', repeat('a', 64)
       FROM generate_series(1, 79) AS g`,
      [uid, project.id],
    );
    await expect(
      store.save(uid, { projectId: project.id }, "last.md", "the 80th"),
    ).resolves.toMatchObject({ name: "last.md" });
    expect((await store.list(uid, { projectId: project.id })).length).toBe(80);
    await expect(
      store.save(uid, { projectId: project.id }, "extra.md", "over the cap"),
    ).rejects.toMatchObject({ code: "limit_reached" });
    // Replacing an existing file is still allowed at the cap.
    const existing = await store.read(uid, { projectId: project.id }, "n1.md");
    await expect(
      store.save(uid, { projectId: project.id }, "n1.md", "updated", existing!.revision),
    ).resolves.toMatchObject({ name: "n1.md" });
  });

  it("maps the live plan table to 80/100/150/250 and fails closed to Free", async () => {
    const { uid } = await fixture();
    const expected: Array<[string, number]> = [
      ["free", 80],
      ["go", 100],
      ["plus", 150],
      ["pro", 250],
    ];
    for (const [tier, cap] of expected) {
      await db.update(usersTable).set({ tier }).where(eq(usersTable.uid, uid));
      expect(await projectFileCap(db, uid)).toBe(cap);
    }
    await db.update(usersTable).set({ tier: "mystery-tier" }).where(eq(usersTable.uid, uid));
    expect(await projectFileCap(db, uid)).toBe(80);
  });

  it("the database rejects a project-scoped row that does not carry project_id", async () => {
    const { uid } = await fixture();
    const project = (await projectsRepo.create(db, uid, "Check"))!;
    await expect(
      db.$client.unsafe(
        `INSERT INTO private_memory_files (user_id, scope, name, content, revision)
         VALUES ($1, $2, 'x.md', 'x', repeat('a', 64))`,
        [uid, `project:${project.id}`],
      ),
    ).rejects.toBeTruthy();
  });
});
