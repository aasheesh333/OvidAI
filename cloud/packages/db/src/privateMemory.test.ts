import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { PrivateMemoryError } from "@ovid/shared";
import { createDb, migrate, type Db } from "./client.js";
import { newId, sessions, users } from "./repos.js";
import { createPrivateMemoryStore } from "./privateMemory.js";

const url = process.env.TEST_DATABASE_URL;
const revision = (s: string) => createHash("sha256").update(s).digest("hex");
describe.skipIf(!url)("private DB memory hard boundary", () => {
  let db: Db;
  beforeAll(async () => { await migrate(url!); db = createDb(url!); }, 60000);
  afterAll(async () => { await db?.$client.end({ timeout: 5 }); });

  async function fixture() {
    const uid = `mem-${newId()}`;
    await users.ensure(db, uid, null);
    const a = await sessions.create(db, uid, "A");
    const b = await sessions.create(db, uid, "B");
    return { uid, a: { sessionId: a.id, shared: false }, b: { sessionId: b.id, shared: false }, store: createPrivateMemoryStore(db) };
  }

  it("A facts live only in private rows, not shared preferences/state, and B/other owners cannot read them", async () => {
    const { uid, a, b, store } = await fixture();
    const saved = await store.save(uid, a, "MEMORY.md", "private fact A");
    expect(saved.revision).toBe(revision("private fact A"));
    expect((await store.read(uid, a, "MEMORY.md"))?.content).toBe("private fact A");
    expect(await store.read(uid, b, "MEMORY.md")).toBeNull();
    expect(await store.list(uid, b)).toEqual([]);
    await expect(store.read("foreign-owner", a, "MEMORY.md")).rejects.toBeInstanceOf(PrivateMemoryError);
    const [row] = await db.$client`SELECT preferences FROM users WHERE uid = ${uid}`;
    expect(JSON.stringify(row)).not.toContain("private fact A");
    const state = await db.$client`SELECT state FROM session_agent_state WHERE session_id = ${a.sessionId}`;
    expect(JSON.stringify(state)).not.toContain("private fact A");
  });

  it("shared facts require explicit shared namespace and an owned live chat", async () => {
    const { uid, a, b, store } = await fixture();
    await store.save(uid, { ...a, shared: true }, "MEMORY.md", "shared fact");
    expect((await store.read(uid, { ...b, shared: true }, "MEMORY.md"))?.content).toBe("shared fact");
    expect(await store.read(uid, b, "MEMORY.md")).toBeNull();
    await expect(store.read(uid, { sessionId: newId(), shared: true }, "MEMORY.md")).rejects.toMatchObject({ code: "not_found" });
    await sessions.softDelete(db, b.sessionId, uid);
    await expect(store.read(uid, { ...b, shared: true }, "MEMORY.md")).rejects.toMatchObject({ code: "not_found" });
  });

  it("simultaneous same-revision edits commit exactly one and preserve failed-write contents", async () => {
    const { uid, a, store } = await fixture();
    const first = await store.save(uid, a, "notes.md", "original");
    const edits = await Promise.allSettled([
      store.save(uid, a, "notes.md", "one", first.revision),
      store.save(uid, a, "notes.md", "two", first.revision),
    ]);
    expect(edits.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect(edits.filter(r => r.status === "rejected")).toHaveLength(1);
    const winner = await store.read(uid, a, "notes.md");
    await expect(store.save(uid, a, "notes.md", "bad overwrite")).rejects.toMatchObject({ code: "baseline_mismatch" });
    await expect(store.save(uid, a, "notes.md", "too big".repeat(10000), winner!.revision)).rejects.toMatchObject({ code: "bad_request" });
    expect(await store.read(uid, a, "notes.md")).toEqual(winner);
  });

  it("canonical name/UTF8/count safeguards are atomic per namespace", async () => {
    const { uid, a, store } = await fixture();
    await expect(store.save(uid, a, "../escape.md", "x")).rejects.toMatchObject({ code: "bad_request" });
    await expect(store.save(uid, a, "memory.md", "x")).rejects.toMatchObject({ code: "bad_request" });
    await expect(store.save(uid, a, "large.md", "é".repeat(16385))).rejects.toMatchObject({ code: "bad_request" });
    await store.save(uid, a, "NOTES.md", "x");
    await expect(store.save(uid, a, "notes.md", "y")).rejects.toMatchObject({ code: "bad_request" });
    await Promise.all(Array.from({ length: 29 }, (_, i) => store.save(uid, a, `f${i}.md`, "x")));
    const last = await Promise.allSettled([store.save(uid, a, "last.md", "x"), store.save(uid, a, "overflow.md", "y")]);
    expect(last.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect((await store.list(uid, a)).length).toBe(31); // virtual MEMORY.md counts toward 32
  });

  it("hard chat deletion cascades isolated notes and account deletion cascades remaining shared notes", async () => {
    const { uid, a, store } = await fixture();
    await store.save(uid, a, "MEMORY.md", "isolated");
    await store.save(uid, { ...a, shared: true }, "MEMORY.md", "shared");
    await db.$client`DELETE FROM sessions WHERE user_id = ${uid}`;
    expect((await db.$client`SELECT scope FROM private_memory_files WHERE user_id = ${uid}`).map(r => r.scope)).toEqual(["shared"]);
    await db.$client`DELETE FROM users WHERE uid = ${uid}`;
    expect(await db.$client`SELECT scope FROM private_memory_files WHERE user_id = ${uid}`).toHaveLength(0);
  });
});
