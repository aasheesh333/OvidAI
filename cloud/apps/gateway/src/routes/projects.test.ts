import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { schema, users, type Db } from "@ovid/db";import { projectDtoSchema, sessionDtoSchema, type ProjectDto, type SessionDto } from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

describe.skipIf(!TEST_DATABASE_URL)("W1 project routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;

  beforeAll(async () => {
    db = await openTestDb();
    const { queues } = stubQueues();
    app = buildGateway({
      system: stubSystemBus(),
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function createSession(uid: string, title?: string): Promise<SessionDto> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/sessions",
      headers: authHeaders(uid),
      payload: title === undefined ? {} : { title },
    });
    expect(res.statusCode).toBe(201);
    return sessionDtoSchema.parse(res.json());
  }

  async function createProject(uid: string, name: string): Promise<ProjectDto> {
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
      payload: { name },
    });
    expect(res.statusCode).toBe(201);
    return projectDtoSchema.parse(res.json());
  }

  /**
   * Pin a first-position Free plan and make [uid] use it, so the cap
   * assertions do not depend on whatever rows the shared scratch DB holds.
   */
  async function pinFreePlan(uid: string): Promise<void> {
    await users.ensure(db, uid, null);
    // `projectFileCap` maps the tier to the LIVE plan list ordered by
    // position. Pin the canonical `free` row first (index 0 → cap 80) so
    // leftover plans from other test files cannot shift the mapping.
    await db
      .insert(schema.plans)
      .values({
        id: "free",
        name: "Free",
        priceUsd: "0",
        enabled: true,
        aliases: [],
        windowHours: 24,
        mult: "1",
        slowMode: false,
        autoOss: false,
        position: -1_000_000,
      })
      .onConflictDoUpdate({
        target: schema.plans.id,
        set: { enabled: true, position: -1_000_000 },
      });
    await db.$client.unsafe("UPDATE users SET tier = 'free' WHERE uid = $1", [uid]);
  }

  it("creates, lists, renames and deletes a project; duplicate names are 409", async () => {
    const uid = testUid("proj-crud");
    await pinFreePlan(uid);
    const created = await createProject(uid, "Research");
    expect(created.id).toMatch(UUID_RE);
    expect(created.sessionCount).toBe(0);
    expect(created.fileCount).toBe(0);
    expect(created.fileCap).toBe(80);
    expect(created.fileBytes).toBe(0);
    expect(created.fileBreakdown).toEqual({ memory: 0, attachments: 0, artifacts: 0 });

    const dup = await app.inject({
      method: "POST",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
      payload: { name: "Research" },
    });
    expect(dup.statusCode).toBe(409);
    expect(dup.json().error.code).toBe("name_taken");

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
    });
    expect(list.statusCode).toBe(200);
    expect(list.json().items.map((p: ProjectDto) => p.name)).toEqual(["Research"]);
    // W1 follow-up: the client gates @project turn refs on this capability,
    // so a client that ships before the gateway never sends the field.
    expect(list.json().capabilities).toEqual({ turnProjectRefs: true });

    const renamed = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/projects/${created.id}`,
      headers: authHeaders(uid),
      payload: { name: "Research 2" },
    });
    expect(renamed.statusCode).toBe(200);
    expect(projectDtoSchema.parse(renamed.json()).name).toBe("Research 2");

    const deleted = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/projects/${created.id}`,
      headers: authHeaders(uid),
    });
    expect(deleted.statusCode).toBe(204);
    const after = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${created.id}`,
      headers: authHeaders(uid),
    });
    // There is no GET /projects/:id route; the list is the read surface.
    expect(after.statusCode).toBe(404);
    const listAfter = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
    });
    expect(listAfter.json().items).toEqual([]);
  });

  it("foreign projects answer 404 on every project surface", async () => {
    const owner = testUid("proj-owner");
    const stranger = testUid("proj-stranger");
    const project = await createProject(owner, "Mine");

    for (const [method, url, payload] of [
      ["PATCH", `/cloud/v1/projects/${project.id}`, { name: "Stolen" }],
      ["DELETE", `/cloud/v1/projects/${project.id}`, undefined],
      ["GET", `/cloud/v1/projects/${project.id}/memory`, undefined],
      ["PUT", `/cloud/v1/projects/${project.id}/memory/MEMORY.md`, { content: "x" }],
      ["DELETE", `/cloud/v1/projects/${project.id}/memory/MEMORY.md`, undefined],
    ] as const) {
      const res = await app.inject({
        method,
        url,
        headers: authHeaders(stranger),
        ...(payload === undefined ? {} : { payload }),
      });
      expect(res.statusCode, `${method} ${url}`).toBe(404);
      expect(res.json().error.code).toBe("not_found");
    }
    // The owner's project is untouched.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(owner),
    });
    expect(list.json().items[0].name).toBe("Mine");
  });

  it("moves an owned session into and out of a project; foreign ids fail closed", async () => {
    const uid = testUid("proj-move");
    const other = testUid("proj-move-other");
    const project = await createProject(uid, "Work");
    const foreign = await createProject(other, "Theirs");
    const session = await createSession(uid, "Chat");
    const foreignSession = await createSession(other, "Their chat");

    const moved = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${session.id}/project`,
      headers: authHeaders(uid),
      payload: { projectId: project.id },
    });
    expect(moved.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(moved.json()).projectId).toBe(project.id);

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
    });
    expect(list.json().items.find((p: ProjectDto) => p.id === project.id).sessionCount).toBe(1);

    const foreignMove = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${session.id}/project`,
      headers: authHeaders(uid),
      payload: { projectId: foreign.id },
    });
    expect(foreignMove.statusCode).toBe(404);

    const foreignSessionMove = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${foreignSession.id}/project`,
      headers: authHeaders(uid),
      payload: { projectId: project.id },
    });
    expect(foreignSessionMove.statusCode).toBe(404);

    const detached = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${session.id}/project`,
      headers: authHeaders(uid),
      payload: { projectId: null },
    });
    expect(detached.statusCode).toBe(200);
    expect(sessionDtoSchema.parse(detached.json()).projectId).toBeNull();

    // Unknown shapes are rejected without touching the db.
    const bad = await app.inject({
      method: "POST",
      url: `/cloud/v1/sessions/${session.id}/project`,
      headers: authHeaders(uid),
      payload: { projectId: "not-a-uuid" },
    });
    expect(bad.statusCode).toBe(404);
  });

  it("project memory CRUD is isolated per project and per session", async () => {
    const uid = testUid("proj-mem");
    const a = await createProject(uid, "A");
    const b = await createProject(uid, "B");
    const chat = await createSession(uid, "Standalone");

    const saved = await app.inject({
      method: "PUT",
      url: `/cloud/v1/projects/${a.id}/memory/MEMORY.md`,
      headers: authHeaders(uid),
      payload: { content: "alpha fact" },
    });
    expect(saved.statusCode).toBe(200);
    expect(saved.json()).toMatchObject({ name: "MEMORY.md", scope: "project" });
    const revision = saved.json().revision as string;

    const read = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${a.id}/memory/MEMORY.md`,
      headers: authHeaders(uid),
    });
    expect(read.json().content).toBe("alpha fact");

    // Project B and the standalone chat see nothing.
    const otherProject = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${b.id}/memory`,
      headers: authHeaders(uid),
    });
    expect(otherProject.json()).toMatchObject({ items: [], scope: "project" });
    const chatMemory = await app.inject({
      method: "GET",
      url: `/cloud/v1/memory?sessionId=${chat.id}`,
      headers: authHeaders(uid),
    });
    expect(chatMemory.json().items).toEqual([]);

    // Stale revisions are a 409.
    const stale = await app.inject({
      method: "PUT",
      url: `/cloud/v1/projects/${a.id}/memory/MEMORY.md`,
      headers: authHeaders(uid),
      payload: { content: "changed", ifRevision: "0".repeat(64) },
    });
    expect(stale.statusCode).toBe(409);
    expect(stale.json().error.code).toBe("baseline_mismatch");

    // The count is visible in the sidebar DTO.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
    });
    expect(list.json().items.find((p: ProjectDto) => p.id === a.id).fileCount).toBe(1);

    const removed = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/projects/${a.id}/memory/MEMORY.md`,
      headers: authHeaders(uid),
    });
    expect(removed.statusCode).toBe(204);
    const gone = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${a.id}/memory/MEMORY.md`,
      headers: authHeaders(uid),
    });
    expect(gone.statusCode).toBe(404);
    // The revision variable is intentionally exercised above.
    expect(revision).toHaveLength(64);
  });

  it("enforces the Free project cap (80 files) on the API", async () => {
    const uid = testUid("proj-cap");
    await pinFreePlan(uid);
    const project = await createProject(uid, "Capped");
    await db.$client.unsafe(
      `INSERT INTO private_memory_files (user_id, scope, project_id, name, content, revision)
       SELECT $1, 'project:' || $2, $2, 'n' || g || '.md', 'x', repeat('a', 64)
       FROM generate_series(1, 80) AS g`,
      [uid, project.id],
    );

    const over = await app.inject({
      method: "PUT",
      url: `/cloud/v1/projects/${project.id}/memory/extra.md`,
      headers: authHeaders(uid),
      payload: { content: "one too many" },
    });
    expect(over.statusCode).toBe(400);
    expect(over.json().error.message).toContain("80");

    // The list surface truthfully reports the cap and the count.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/projects",
      headers: authHeaders(uid),
    });
    const row = list.json().items.find((p: ProjectDto) => p.id === project.id);
    expect(row.fileCount).toBe(80);
    expect(row.fileCap).toBe(80);
  });

  it("GET /projects/:id is owner-scoped: the detail DTO is returned to the owner and 404 to everyone else", async () => {
    const owner = testUid("proj-detail-owner");
    const stranger = testUid("proj-detail-stranger");
    await pinFreePlan(owner);
    await pinFreePlan(stranger);
    const project = await createProject(owner, "Detail");

    const detail = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${project.id}`,
      headers: authHeaders(owner),
    });
    expect(detail.statusCode).toBe(200);
    const dto = projectDtoSchema.parse(detail.json());
    expect(dto.id).toBe(project.id);
    expect(dto.fileCount).toBe(0);
    expect(dto.fileBytes).toBe(0);

    const foreign = await app.inject({
      method: "GET",
      url: `/cloud/v1/projects/${project.id}`,
      headers: authHeaders(stranger),
    });
    expect(foreign.statusCode).toBe(404);
    expect(foreign.json().error.code).toBe("not_found");
  });
});
